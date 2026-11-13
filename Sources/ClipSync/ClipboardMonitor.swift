import AppKit
import ClipSyncCore

/// Watches the general pasteboard. Local copies become `Clip` values; applying
/// a received clip writes to the pasteboard without echoing it back out.
final class ClipboardMonitor {
    private let pasteboard = NSPasteboard.general
    private let identity: PeerIdentity
    private let onClip: (Clip) -> Void

    private var timer: Timer?
    private var lastChangeCount: Int
    private var suppressedChangeCount: Int?

    private let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    init(identity: PeerIdentity, onClip: @escaping (Clip) -> Void) {
        self.identity = identity
        self.onClip = onClip
        self.lastChangeCount = pasteboard.changeCount
    }

    func start() {
        guard timer == nil else { return }
        lastChangeCount = pasteboard.changeCount

        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        suppressedChangeCount = nil
    }

    @discardableResult
    func apply(_ clip: Clip) -> Bool {
        pasteboard.clearContents()

        let success: Bool
        switch clip.kind {
        case .text:
            success = pasteboard.setString(clip.text ?? "", forType: .string)
        case .image:
            guard let data = clip.imageData, let image = NSImage(data: data) else {
                return false
            }
            success = pasteboard.writeObjects([image])
        }

        if success {
            suppressedChangeCount = pasteboard.changeCount
            lastChangeCount = pasteboard.changeCount
        }
        return success
    }

    private func poll() {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount

        if let suppressed = suppressedChangeCount {
            suppressedChangeCount = nil
            if suppressed == changeCount { return }
        }

        guard let clip = readClip() else { return }
        onClip(clip)
    }

    private func readClip() -> Clip? {
        let types = pasteboard.types ?? []

        // Password managers and other privacy-aware apps mark clips this way.
        if types.contains(concealedType) || types.contains(transientType) {
            return nil
        }

        if let text = pasteboard.string(forType: .string) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let bytes = text.data(using: .utf8),
                  bytes.count <= ClipLimits.maxTextBytes
            else { return nil }
            return Clip(
                kind: .text,
                text: text,
                originID: identity.id,
                originName: identity.name
            )
        }

        let png: Data?
        if let data = pasteboard.data(forType: .png) {
            png = data
        } else if let tiff = pasteboard.data(forType: .tiff),
                  let image = NSBitmapImageRep(data: tiff),
                  let data = image.representation(using: .png, properties: [:]) {
            png = data
        } else {
            png = nil
        }

        guard let png, !png.isEmpty, png.count <= ClipLimits.maxImageBytes else {
            return nil
        }
        return Clip(
            kind: .image,
            imageData: png,
            originID: identity.id,
            originName: identity.name
        )
    }
}
