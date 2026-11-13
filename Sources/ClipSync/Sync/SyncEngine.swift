import ClipSyncCore
import Foundation
import Network
import os

protocol SyncEngineDelegate: AnyObject {
    func syncEngine(_ engine: SyncEngine, didChangePeers peers: [SyncEngine.PeerInfo])
    func syncEngine(_ engine: SyncEngine, didReceive clip: Clip)
    func syncEngine(_ engine: SyncEngine, didReceiveHistory clips: [Clip], from peer: SyncEngine.PeerInfo)
    func syncEngine(_ engine: SyncEngine, didReportError message: String)
}

/// Discovers other ClipSync Macs on the local network with Bonjour and keeps
/// one direct TCP link to each of them. There is no server and no cloud.
final class SyncEngine {
    struct PeerInfo: Equatable {
        let id: String
        let name: String
    }

    weak var delegate: SyncEngineDelegate?

    private struct DiscoveredPeer {
        let endpoint: NWEndpoint
        let id: String?
        let name: String?
    }

    private let serviceType = "_clipsync._tcp"
    private let identity: PeerIdentity
    private var codeHash: String
    private let queue = DispatchQueue(label: "com.srihariphs.clipsync.sync")

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var reconcileTimer: DispatchSourceTimer?

    private var discovered: [String: DiscoveredPeer] = [:]
    private var pending: [UUID: PeerConnection] = [:]
    private var connections: [String: PeerConnection] = [:]
    private var dialing: Set<String> = []
    private var retryAfter: [String: Date] = [:]
    private var blockedUntil: [String: Date] = [:]
    private var ignoredEndpoints: Set<String> = []
    private var requestedHistory: Set<String> = []

    private var running = false
    private var historySnapshot: [Clip] = []
    private var lastErrorReported: (message: String, at: Date)?

    private let log = Logger(subsystem: "com.srihariphs.clipsync", category: "sync")

    init(identity: PeerIdentity, code: String) {
        self.identity = identity
        self.codeHash = PairingCode.hash(code)
    }

    deinit {
        listener?.cancel()
        browser?.cancel()
        reconcileTimer?.cancel()
    }

    // MARK: - Public API

    func start() {
        queue.async { [weak self] in
            guard let self, !self.running else { return }
            self.running = true
            self.startListenerLocked()
            self.startBrowserLocked()
            self.startReconcileTimerLocked()
            self.reconcileLocked()
            self.log.info("Sync started as \(self.identity.name, privacy: .public)")
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self, self.running else { return }
            self.stopLocked()
            self.log.info("Sync stopped")
        }
    }

    func restartDiscovery() {
        queue.async { [weak self] in
            guard let self, self.running else { return }
            self.stopLocked()
            self.startLocked()
            self.log.info("Discovery restarted")
        }
    }

    func broadcast(_ clip: Clip) {
        queue.async { [weak self] in
            guard let self, self.running, clip.isWithinLimits else { return }
            let envelope = Envelope.clip(clip, sender: self.identity, codeHash: self.codeHash)
            for connection in self.connections.values {
                connection.send(envelope)
            }
        }
    }

    func setHistorySnapshot(_ clips: [Clip]) {
        queue.async { [weak self] in
            self?.historySnapshot = Array(clips.prefix(25))
        }
    }

    func updateCode(_ code: String) {
        let hash = PairingCode.hash(code)
        queue.async { [weak self] in
            guard let self, hash != self.codeHash else { return }
            self.codeHash = hash
            self.blockedUntil.removeAll()
            self.requestedHistory.removeAll()
            let existing = Array(self.connections.values)
            self.connections.removeAll()
            for connection in existing {
                connection.close(reason: "Sync code changed")
            }
            self.notifyPeersLocked()
            self.reconcileLocked()
        }
    }

    // MARK: - Lifecycle (queue only)

    private func startLocked() {
        guard !running else { return }
        running = true
        startListenerLocked()
        startBrowserLocked()
        startReconcileTimerLocked()
        reconcileLocked()
    }

    private func stopLocked() {
        running = false

        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil

        browser?.stateUpdateHandler = nil
        browser?.browseResultsChangedHandler = nil
        browser?.cancel()
        browser = nil

        reconcileTimer?.cancel()
        reconcileTimer = nil

        let pendingConnections = Array(pending.values)
        let activeConnections = Array(connections.values)
        pending.removeAll()
        connections.removeAll()
        for connection in pendingConnections + activeConnections {
            connection.close(reason: "Sync stopped")
        }

        discovered.removeAll()
        dialing.removeAll()
        retryAfter.removeAll()
        blockedUntil.removeAll()
        requestedHistory.removeAll()
        notifyPeersLocked()
    }

    private func startListenerLocked() {
        do {
            let listener = try NWListener(using: makeParameters())
            let txt = NWTXTRecord([
                "id": identity.id,
                "name": String(identity.name.prefix(60)),
                "v": String(ProtocolVersion.current),
            ])
            listener.service = NWListener.Service(
                name: "ClipSync",
                type: serviceType,
                txtRecord: txt.data
            )
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener, self.running else { return }
                switch state {
                case .ready:
                    let port = listener.port?.rawValue ?? 0
                    self.log.info("Listening on port \(port, privacy: .public)")
                case .failed(let error):
                    self.reportLocked("Could not start the local listener: \(error.localizedDescription)")
                    listener.cancel()
                    if self.listener === listener {
                        self.listener = nil
                    }
                    self.queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                        guard let self, self.running, self.listener == nil else { return }
                        self.startListenerLocked()
                    }
                case .cancelled, .waiting, .setup:
                    break
                @unknown default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.acceptLocked(connection)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            reportLocked("Could not start the local listener: \(error.localizedDescription)")
        }
    }

    private func startBrowserLocked() {
        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: .tcp)
        browser.stateUpdateHandler = { [weak self] state in
            guard let self, self.running else { return }
            if case .failed(let error) = state {
                self.reportLocked("Local discovery failed: \(error.localizedDescription)")
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, self.running else { return }
            self.updateResultsLocked(results)
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    private func startReconcileTimerLocked() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 5, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            self?.reconcileLocked()
        }
        timer.resume()
        reconcileTimer = timer
    }

    private func makeParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 15
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 10
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        return parameters
    }

    // MARK: - Discovery (queue only)

    private func updateResultsLocked(_ results: Set<NWBrowser.Result>) {
        var seenKeys = Set<String>()

        for result in results {
            let key = endpointKey(result.endpoint)
            seenKeys.insert(key)
            if ignoredEndpoints.contains(key) { continue }

            var advertisedID: String?
            var advertisedName: String?
            if case .bonjour(let record) = result.metadata {
                advertisedID = txtString(record.getEntry(for: "id"))
                advertisedName = txtString(record.getEntry(for: "name"))
            }

            // Never connect to our own advertisement.
            if advertisedID == identity.id { continue }

            discovered[key] = DiscoveredPeer(
                endpoint: result.endpoint,
                id: advertisedID,
                name: advertisedName
            )
        }

        for key in Array(discovered.keys) where !seenKeys.contains(key) {
            discovered.removeValue(forKey: key)
            dialing.remove(key)
            retryAfter.removeValue(forKey: key)
            for connection in Array(pending.values) where connection.endpointKey == key {
                connection.close(reason: "Peer disappeared")
            }
            for connection in Array(connections.values) where connection.endpointKey == key {
                connection.close(reason: "Peer disappeared")
            }
        }

        reconcileLocked()
    }

    private func reconcileLocked() {
        guard running else { return }
        let now = Date()
        retryAfter = retryAfter.filter { $0.value > now }
        blockedUntil = blockedUntil.filter { $0.value > now }

        for (key, peer) in discovered {
            if let peerID = peer.id {
                if peerID == identity.id { continue }
                if connections[peerID] != nil { continue }
                if let blocked = blockedUntil[peerID], blocked > now { continue }
            }
            if ignoredEndpoints.contains(key) { continue }
            if dialing.contains(key) { continue }
            if pending.values.contains(where: { $0.endpointKey == key }) { continue }
            if let retry = retryAfter[key], retry > now { continue }
            dialLocked(key: key, peer: peer)
        }
    }

    private func dialLocked(key: String, peer: DiscoveredPeer) {
        dialing.insert(key)
        log.info("Dialing peer \(peer.name ?? "unknown", privacy: .public)")
        let connection = NWConnection(to: peer.endpoint, using: makeParameters())
        let peerConnection = PeerConnection(
            connection: connection,
            isOutbound: true,
            endpointKey: key,
            localID: identity.id,
            queue: queue
        )
        wireUpLocked(peerConnection)
        pending[peerConnection.id] = peerConnection
        peerConnection.start()
    }

    private func acceptLocked(_ connection: NWConnection) {
        let peerConnection = PeerConnection(
            connection: connection,
            isOutbound: false,
            endpointKey: nil,
            localID: identity.id,
            queue: queue
        )
        wireUpLocked(peerConnection)
        pending[peerConnection.id] = peerConnection
        peerConnection.start()
    }

    private func wireUpLocked(_ peer: PeerConnection) {
        peer.onReady = { [weak self, weak peer] in
            guard let self, let peer else { return }
            peer.send(.hello(sender: self.identity, codeHash: self.codeHash))
        }
        peer.onMessage = { [weak self, weak peer] envelope in
            guard let self, let peer else { return }
            self.handleLocked(envelope, on: peer)
        }
        peer.onClosed = { [weak self, weak peer] in
            guard let self, let peer else { return }
            self.closedLocked(peer)
        }
    }

    private func closedLocked(_ peer: PeerConnection) {
        if let reason = peer.closeReason {
            log.info("Connection to \(peer.peerName ?? "peer", privacy: .public) closed: \(reason, privacy: .public)")
        }

        pending.removeValue(forKey: peer.id)

        if let key = peer.endpointKey {
            dialing.remove(key)
            retryAfter[key] = Date().addingTimeInterval(3)
        }

        if let peerID = peer.peerID, connections[peerID]?.id == peer.id {
            connections.removeValue(forKey: peerID)
            requestedHistory.remove(peerID)
            notifyPeersLocked()
        }
    }

    // MARK: - Message handling (queue only)

    private func handleLocked(_ envelope: Envelope, on peer: PeerConnection) {
        guard envelope.version == ProtocolVersion.current else {
            reportLocked("\(envelope.senderName) is running a different ClipSync version. Update both Macs.")
            peer.send(.error("Protocol version mismatch", sender: identity, codeHash: codeHash))
            peer.close(reason: "Protocol version mismatch")
            return
        }

        switch envelope.kind {
        case .hello:
            guard envelope.codeHash == codeHash else {
                reportLocked("Sync code mismatch with \(envelope.senderName). Use the same code on both Macs.")
                peer.send(.error("Sync code mismatch", sender: identity, codeHash: codeHash))
                blockedUntil[envelope.senderID] = Date().addingTimeInterval(60)
                peer.close(reason: "Sync code mismatch")
                return
            }

            if envelope.senderID == identity.id {
                if let key = peer.endpointKey {
                    ignoredEndpoints.insert(key)
                }
                peer.close(reason: "Connected to self")
                return
            }

            blockedUntil.removeValue(forKey: envelope.senderID)
            promoteLocked(peer)

        case .clip:
            guard let peerID = peer.peerID,
                  connections[peerID]?.id == peer.id,
                  let clip = envelope.clip,
                  clip.isWithinLimits
            else { return }
            notifyReceiveLocked(clip)

        case .historyRequest:
            guard let peerID = peer.peerID,
                  connections[peerID]?.id == peer.id
            else { return }
            peer.send(.history(historySnapshot, sender: identity, codeHash: codeHash))

        case .history:
            guard let peerID = peer.peerID,
                  connections[peerID]?.id == peer.id,
                  let clips = envelope.clips
            else { return }
            let valid = clips.filter(\.isWithinLimits).prefix(30)
            let info = PeerInfo(id: peerID, name: peer.peerName ?? envelope.senderName)
            notifyHistoryLocked(Array(valid), from: info)

        case .error:
            reportLocked(envelope.note ?? "\(envelope.senderName) reported a connection error.")
        }
    }

    private func promoteLocked(_ peer: PeerConnection) {
        guard let peerID = peer.peerID else { return }

        pending.removeValue(forKey: peer.id)
        if let key = peer.endpointKey {
            dialing.remove(key)
            retryAfter.removeValue(forKey: key)
        }

        if let existing = connections[peerID], existing.id != peer.id {
            let preferredInitiator = min(identity.id, peerID)
            let newIsPreferred = peer.initiatorID == preferredInitiator
            let oldIsPreferred = existing.initiatorID == preferredInitiator

            if newIsPreferred && !oldIsPreferred {
                connections[peerID] = peer
                requestedHistory.remove(peerID)
                existing.close(reason: "Replaced by preferred connection")
            } else {
                peer.close(reason: "Duplicate connection")
                return
            }
        } else {
            connections[peerID] = peer
        }

        if requestedHistory.insert(peerID).inserted {
            peer.send(.historyRequest(sender: identity, codeHash: codeHash))
        }
        notifyPeersLocked()
    }

    // MARK: - Delegate notifications

    private func notifyPeersLocked() {
        let peers = connections.compactMap { peerID, connection -> PeerInfo? in
            guard let name = connection.peerName ?? discovered.values.first(where: { $0.id == peerID })?.name
            else { return nil }
            return PeerInfo(id: peerID, name: name)
        }.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.syncEngine(self, didChangePeers: peers)
        }
    }

    private func notifyReceiveLocked(_ clip: Clip) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.syncEngine(self, didReceive: clip)
        }
    }

    private func notifyHistoryLocked(_ clips: [Clip], from peer: PeerInfo) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.syncEngine(self, didReceiveHistory: clips, from: peer)
        }
    }

    private func reportLocked(_ message: String) {
        log.error("\(message, privacy: .public)")
        let now = Date()
        if let last = lastErrorReported, last.message == message, now.timeIntervalSince(last.at) < 10 {
            return
        }
        lastErrorReported = (message, now)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.syncEngine(self, didReportError: message)
        }
    }

    private func endpointKey(_ endpoint: NWEndpoint) -> String {
        if case let .service(name, type, domain, _) = endpoint {
            return "service:\(name).\(type).\(domain)"
        }
        return String(describing: endpoint)
    }

    private func txtString(_ entry: NWTXTRecord.Entry?) -> String? {
        guard case let .string(value)? = entry else { return nil }
        return value
    }
}
