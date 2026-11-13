import CryptoKit
import Foundation

/// A single clipboard item that can travel between Macs.
public struct Clip: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case text
        case image
    }

    public var id: UUID
    public var kind: Kind
    public var text: String?
    public var imageData: Data?
    public var copiedAt: Date
    public var originID: String
    public var originName: String

    public init(
        id: UUID = UUID(),
        kind: Kind,
        text: String? = nil,
        imageData: Data? = nil,
        copiedAt: Date = .now,
        originID: String,
        originName: String
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.imageData = imageData
        self.copiedAt = copiedAt
        self.originID = originID
        self.originName = originName
    }

    /// Guard rails applied to both local copies and incoming network clips.
    public var isWithinLimits: Bool {
        switch kind {
        case .text:
            guard let text, !text.isEmpty,
                  let bytes = text.data(using: .utf8),
                  bytes.count <= ClipLimits.maxTextBytes
            else { return false }
            return true
        case .image:
            guard let imageData, !imageData.isEmpty,
                  imageData.count <= ClipLimits.maxImageBytes
            else { return false }
            return true
        }
    }

    /// Stable content hash used to avoid re-broadcasting an identical copy.
    public var contentFingerprint: String {
        var hasher = SHA256()
        switch kind {
        case .text:
            hasher.update(data: Data((text ?? "").utf8))
        case .image:
            hasher.update(data: imageData ?? Data())
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// One-line description for the menu bar.
    public var summary: String {
        switch kind {
        case .text:
            let flattened = (text ?? "")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\t", with: " ")
            let collapsed = flattened
                .split(separator: " ", omittingEmptySubsequences: true)
                .joined(separator: " ")
            return collapsed.isEmpty ? "Empty clip" : String(collapsed.prefix(90))
        case .image:
            let size = ByteCountFormatter.string(
                fromByteCount: Int64(imageData?.count ?? 0),
                countStyle: .file
            )
            return "Image · \(size)"
        }
    }
}

public enum ClipLimits {
    public static let maxTextBytes = 256 * 1024
    public static let maxImageBytes = 5 * 1024 * 1024

    /// Images are fetched from history when a peer connects. Keep the total
    /// under this budget so a history message stays inside one frame.
    public static let maxHistoryImageBytes = 4 * 1024 * 1024
}
