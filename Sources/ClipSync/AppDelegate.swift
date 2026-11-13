import AppKit
import ClipSyncCore
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, SyncEngineDelegate {
    private enum Keys {
        static let syncEnabled = "syncEnabled"
        static let autoApply = "autoApply"
        static let syncCode = "syncCode"
        static let deviceID = "deviceID"
        static let hasLaunched = "hasLaunched"
    }

    private let defaults = UserDefaults.standard
    private let repoURL = URL(string: "https://github.com/SrihariPHS/clipsync")!

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()

    private var history: HistoryStore!
    private var monitor: ClipboardMonitor!
    private var engine: SyncEngine!
    private var peers: [SyncEngine.PeerInfo] = []

    private var deviceID = ""
    private var deviceName = ""
    private var syncCode = ""
    private var isSyncing = false
    private var autoApply = true

    private var lastError: String?
    private var errorClearWorkItem: DispatchWorkItem?
    private var iconFlashWorkItem: DispatchWorkItem?
    private var wakeObserver: NSObjectProtocol?

    private lazy var clipDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        loadIdentity()
        syncCode = defaults.string(forKey: Keys.syncCode) ?? ""
        autoApply = defaults.object(forKey: Keys.autoApply) as? Bool ?? true

        history = HistoryStore()
        history.load()

        engine = SyncEngine(
            identity: PeerIdentity(id: deviceID, name: deviceName),
            code: syncCode
        )
        engine.delegate = self
        engine.setHistorySnapshot(syncSnapshot())

        monitor = ClipboardMonitor(
            identity: PeerIdentity(id: deviceID, name: deviceName)
        ) { [weak self] clip in
            self?.handleLocalClip(clip)
        }

        setUpStatusItem()
        observeWake()

        if defaults.bool(forKey: Keys.syncEnabled) {
            startSync()
        }

        refreshStatusItem()
        showFirstRunMenuIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        monitor?.stop()
        engine?.stop()
        history?.saveNow()
    }

    // MARK: - Sync control

    private func startSync() {
        guard !isSyncing else { return }
        isSyncing = true
        defaults.set(true, forKey: Keys.syncEnabled)
        monitor.start()
        engine.setHistorySnapshot(syncSnapshot())
        engine.start()
        refreshStatusItem()
    }

    private func stopSync() {
        guard isSyncing else { return }
        isSyncing = false
        defaults.set(false, forKey: Keys.syncEnabled)
        monitor.stop()
        engine.stop()
        peers = []
        refreshStatusItem()
    }

    private func handleLocalClip(_ clip: Clip) {
        guard isSyncing else { return }
        guard clip.isWithinLimits else { return }

        // Ignore a re-copy of the same content as the newest item.
        if let newest = history.clips.first,
           newest.contentFingerprint == clip.contentFingerprint {
            return
        }

        history.add(clip)
        engine.broadcast(clip)
        engine.setHistorySnapshot(syncSnapshot())
    }

    private func syncSnapshot() -> [Clip] {
        // Keep the whole history message comfortably under the frame limit.
        // Base64 adds roughly a third, and JSON adds a little more.
        var payloadBudget = 6 * 1024 * 1024
        var imageBudget = ClipLimits.maxHistoryImageBytes
        var result: [Clip] = []

        for clip in history.clips.prefix(25) {
            let cost: Int
            switch clip.kind {
            case .text:
                cost = clip.text?.utf8.count ?? 0
            case .image:
                cost = clip.imageData?.count ?? 0
                guard cost <= imageBudget else { continue }
                imageBudget -= cost
            }
            guard cost <= payloadBudget else { continue }
            payloadBudget -= cost
            result.append(clip)
        }
        return result
    }

    // MARK: - SyncEngineDelegate

    func syncEngine(_ engine: SyncEngine, didChangePeers peers: [SyncEngine.PeerInfo]) {
        self.peers = peers
        refreshStatusItem()
    }

    func syncEngine(_ engine: SyncEngine, didReceive clip: Clip) {
        guard isSyncing else { return }
        history.add(clip)
        engine.setHistorySnapshot(syncSnapshot())
        if autoApply {
            monitor.apply(clip)
        }
    }

    func syncEngine(
        _ engine: SyncEngine,
        didReceiveHistory clips: [Clip],
        from peer: SyncEngine.PeerInfo
    ) {
        guard isSyncing else { return }
        let before = history.clips
        history.merge(clips)
        engine.setHistorySnapshot(syncSnapshot())

        if autoApply,
           let newest = ClipMerge.shouldApplyOnConnect(incoming: clips, existing: before) {
            monitor.apply(newest)
        }
    }

    func syncEngine(_ engine: SyncEngine, didReportError message: String) {
        setError(message)
    }

    // MARK: - Status item and menu

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.setAccessibilityLabel("ClipSync")

        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        refreshStatusItem()
    }

    private func refreshStatusItem() {
        let symbol = isSyncing ? "clipboard.fill" : "clipboard"
        let fallback = "doc.on.clipboard"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "ClipSync")
            ?? NSImage(systemSymbolName: fallback, accessibilityDescription: "ClipSync")
        image?.isTemplate = true

        statusItem?.button?.image = image
        statusItem?.button?.appearsDisabled = !isSyncing
        statusItem?.button?.toolTip = isSyncing
            ? "ClipSync is on — \(peerSummary)"
            : "ClipSync is off"
    }

    private var peerSummary: String {
        if peers.isEmpty { return "searching for Macs" }
        if peers.count == 1 { return "connected to \(peers[0].name)" }
        return "connected to \(peers.count) Macs"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let header = NSMenuItem(
            title: isSyncing ? "ClipSync is on" : "ClipSync is off",
            action: nil,
            keyEquivalent: ""
        )
        header.isEnabled = false
        menu.addItem(header)

        let subtitle = isSyncing
            ? (peers.isEmpty ? "Searching for other Macs on your network…" : peerSummary.capitalizedFirst)
            : "Turn on to share your clipboard with your other Macs."
        let subtitleItem = NSMenuItem()
        subtitleItem.attributedTitle = NSAttributedString(
            string: subtitle,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        subtitleItem.isEnabled = false
        menu.addItem(subtitleItem)

        if let lastError {
            let errorItem = NSMenuItem()
            let text = lastError.count > 90 ? String(lastError.prefix(90)) + "…" : lastError
            errorItem.attributedTitle = NSAttributedString(
                string: "⚠ \(text)",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.systemOrange,
                ]
            )
            errorItem.isEnabled = false
            menu.addItem(errorItem)
        }

        menu.addItem(.separator())

        let syncItem = NSMenuItem(
            title: "Sync Clipboard",
            action: #selector(toggleSync),
            keyEquivalent: ""
        )
        syncItem.target = self
        syncItem.state = isSyncing ? .on : .off
        menu.addItem(syncItem)

        let autoItem = NSMenuItem(
            title: "Copy Received Clips Automatically",
            action: #selector(toggleAutoApply),
            keyEquivalent: ""
        )
        autoItem.target = self
        autoItem.state = autoApply ? .on : .off
        autoItem.toolTip = "When on, a clip received from another Mac is placed on your clipboard immediately."
        menu.addItem(autoItem)

        menu.addItem(.separator())
        addRecentClips()
        menu.addItem(.separator())

        if isSyncing {
            addDevicesMenu()
        }

        let codeItem = NSMenuItem(
            title: syncCode.isEmpty ? "Set Sync Code…" : "Sync Code… (set)",
            action: #selector(changeSyncCode),
            keyEquivalent: ""
        )
        codeItem.target = self
        codeItem.toolTip = "Optional. All Macs must use the same code to connect."
        menu.addItem(codeItem)

        let launchItem = NSMenuItem(
            title: LoginItem.requiresApproval ? "Launch at Login (needs approval)" : "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchItem.target = self
        launchItem.state = LoginItem.requiresApproval
            ? .mixed
            : (LoginItem.isEnabled ? .on : .off)
        menu.addItem(launchItem)
        menu.addItem(.separator())

        let aboutItem = NSMenuItem(
            title: "About ClipSync",
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(
            title: "Quit ClipSync",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func addRecentClips() {
        let header = NSMenuItem(title: "Recent Clips", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if history.clips.isEmpty {
            let empty = NSMenuItem(
                title: "No clips yet — copy something to get started",
                action: nil,
                keyEquivalent: ""
            )
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }

        for clip in history.clips.prefix(8) {
            let title = clip.summary.count > 62
                ? String(clip.summary.prefix(62)) + "…"
                : clip.summary
            let item = NSMenuItem(
                title: title,
                action: #selector(copyHistoryClip(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = clip.id.uuidString
            item.toolTip = tooltip(for: clip)
            menu.addItem(item)
        }

        let clearItem = NSMenuItem(
            title: "Clear History…",
            action: #selector(clearHistory),
            keyEquivalent: ""
        )
        clearItem.target = self
        menu.addItem(clearItem)
    }

    private func addDevicesMenu() {
        let devicesItem = NSMenuItem(title: "Devices", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        if peers.isEmpty {
            let none = NSMenuItem(
                title: "No Macs connected yet",
                action: nil,
                keyEquivalent: ""
            )
            none.isEnabled = false
            submenu.addItem(none)
        } else {
            for peer in peers {
                let item = NSMenuItem(title: "● \(peer.name)", action: nil, keyEquivalent: "")
                item.isEnabled = false
                submenu.addItem(item)
            }
        }

        devicesItem.submenu = submenu
        menu.addItem(devicesItem)
    }

    private func tooltip(for clip: Clip) -> String {
        var lines = ["From \(clip.originName)", clipDateFormatter.string(from: clip.copiedAt)]
        if clip.kind == .text, let text = clip.text {
            lines.append(String(text.prefix(500)))
        }
        return lines.joined(separator: "\n")
    }

    private func flashStatusIcon() {
        iconFlashWorkItem?.cancel()
        statusItem?.button?.image = NSImage(
            systemSymbolName: "checkmark.circle.fill",
            accessibilityDescription: "Copied"
        )
        statusItem?.button?.appearsDisabled = false

        let work = DispatchWorkItem { [weak self] in
            self?.refreshStatusItem()
        }
        iconFlashWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    private func setError(_ message: String?) {
        lastError = message
        errorClearWorkItem?.cancel()

        guard message != nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.lastError = nil
        }
        errorClearWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    private func showFirstRunMenuIfNeeded() {
        guard !defaults.bool(forKey: Keys.hasLaunched) else { return }
        defaults.set(true, forKey: Keys.hasLaunched)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.statusItem?.button?.performClick(nil)
        }
    }

    private func observeWake() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isSyncing else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.isSyncing else { return }
                self.engine.restartDiscovery()
            }
        }
    }

    // MARK: - Menu actions

    @objc private func toggleSync() {
        if isSyncing {
            stopSync()
        } else {
            startSync()
        }
    }

    @objc private func toggleAutoApply() {
        autoApply.toggle()
        defaults.set(autoApply, forKey: Keys.autoApply)
    }

    @objc private func copyHistoryClip(_ sender: NSMenuItem) {
        guard let idString = sender.representedObject as? String,
              let id = UUID(uuidString: idString),
              let clip = history.clip(withID: id)
        else { return }

        if monitor.apply(clip) {
            flashStatusIcon()
        }
    }

    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear clipboard history?"
        alert.informativeText = "This removes clips stored on this Mac. Your current clipboard is not changed."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        activateForAlert()

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        history.clear()
        engine.setHistorySnapshot([])
    }

    @objc private func changeSyncCode() {
        let alert = NSAlert()
        alert.messageText = "Sync Code"
        alert.informativeText = """
        Optional. Every Mac that should sync must use the same code.

        This keeps other ClipSync apps on your network out, but it is not \
        encryption. Leave it empty for a simple zero-setup sync.
        """
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = syncCode
        field.placeholderString = "Leave empty for no code"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        activateForAlert()

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        syncCode = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(syncCode, forKey: Keys.syncCode)
        engine.updateCode(syncCode)
        setError(nil)
    }

    @objc private func toggleLaunchAtLogin() {
        if LoginItem.requiresApproval {
            LoginItem.openSettings()
            return
        }

        do {
            try LoginItem.setEnabled(!LoginItem.isEnabled)
        } catch {
            showAlert(
                title: "Couldn't change Launch at Login",
                message: """
                \(error.localizedDescription)

                Install ClipSync in /Applications (run `make install`), then try again.
                """
            )
        }
    }

    @objc private func showAbout() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let alert = NSAlert()
        alert.messageText = "ClipSync \(version)"
        alert.informativeText = """
        Copy on one Mac, paste on another. No accounts, no cloud.

        This Mac: \(deviceName)
        Sync code: \(syncCode.isEmpty ? "not set" : "set")

        Everything travels directly over your local network. ClipSync keeps \
        a short history in ~/Library/Application Support/ClipSync.
        """
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "View on GitHub")
        activateForAlert()

        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(repoURL)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    private func loadIdentity() {
        if let saved = defaults.string(forKey: Keys.deviceID), !saved.isEmpty {
            deviceID = saved
        } else {
            deviceID = UUID().uuidString
            defaults.set(deviceID, forKey: Keys.deviceID)
        }

        var name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        if name.hasSuffix(".local") {
            name.removeLast(6)
        }
        deviceName = name.isEmpty ? "Mac" : name
    }

    private func activateForAlert() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        activateForAlert()
        alert.runModal()
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
