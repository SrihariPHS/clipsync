import ClipSyncCore
import Foundation
import Network
import os

final class PeerConnection {
    let id = UUID()
    let connection: NWConnection
    let isOutbound: Bool
    let endpointKey: String?
    let queue: DispatchQueue

    private(set) var peerID: String?
    private(set) var peerName: String?
    private(set) var closeReason: String?

    /// The device that opened this TCP connection. Used to pick one link when
    /// both Macs dial each other at the same time.
    var initiatorID: String?

    var onReady: (() -> Void)?
    var onMessage: ((Envelope) -> Void)?
    var onClosed: (() -> Void)?

    private var decoder = FrameDecoder()
    private var didStart = false
    private var didClose = false

    init(
        connection: NWConnection,
        isOutbound: Bool,
        endpointKey: String?,
        localID: String,
        queue: DispatchQueue
    ) {
        self.connection = connection
        self.isOutbound = isOutbound
        self.endpointKey = endpointKey
        self.queue = queue
        if isOutbound {
            initiatorID = localID
        }
    }

    func start() {
        guard !didStart else { return }
        didStart = true

        connection.stateUpdateHandler = { [weak self] state in
            self?.handleState(state)
        }
        connection.start(queue: queue)

        // A peer that never says hello is not worth keeping.
        queue.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, !self.didClose, self.peerID == nil else { return }
            self.close(reason: "Handshake timed out")
        }
    }

    func send(_ envelope: Envelope) {
        guard !didClose else { return }
        do {
            let frame = try WireCoding.framed(envelope)
            connection.send(content: frame, completion: .contentProcessed { [weak self] error in
                guard let self, let error else { return }
                self.close(reason: error.localizedDescription)
            })
        } catch {
            close(reason: "Could not encode message: \(error.localizedDescription)")
        }
    }

    func close(reason: String? = nil) {
        guard !didClose else { return }
        didClose = true
        closeReason = reason
        connection.stateUpdateHandler = nil
        connection.cancel()
        onClosed?()
    }

    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            startReceiving()
            onReady?()
        case .failed(let error):
            close(reason: error.localizedDescription)
        case .cancelled:
            close(reason: closeReason)
        case .waiting, .preparing, .setup:
            break
        @unknown default:
            break
        }
    }

    private func startReceiving() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self, !self.didClose else { return }

            if let data, !data.isEmpty {
                self.decoder.append(data)
                do {
                    while let payload = try self.decoder.nextPayload() {
                        let envelope = try WireCoding.decode(Envelope.self, from: payload)
                        self.notePeer(from: envelope)
                        self.onMessage?(envelope)
                    }
                } catch {
                    self.close(reason: "Protocol error: \(error.localizedDescription)")
                    return
                }
            }

            if let error {
                self.close(reason: error.localizedDescription)
                return
            }
            if isComplete {
                self.close(reason: "Peer closed the connection")
                return
            }
            self.startReceiving()
        }
    }

    private func notePeer(from envelope: Envelope) {
        guard peerID == nil else { return }
        peerID = envelope.senderID
        peerName = envelope.senderName
        if !isOutbound {
            initiatorID = envelope.senderID
        }
    }
}
