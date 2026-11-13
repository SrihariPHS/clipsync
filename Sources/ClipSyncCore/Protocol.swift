import CryptoKit
import Foundation

public enum ProtocolVersion {
    public static let current = 1
}

/// A stable, friendly identity for one Mac.
public struct PeerIdentity: Codable, Equatable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Optional shared code. Macs only connect when their hashes match.
public enum PairingCode {
    public static func hash(_ code: String) -> String {
        let normalized = code
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return "" }
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// The only message type sent over the wire.
public struct Envelope: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case hello
        case clip
        case historyRequest
        case history
        case error
    }

    public var kind: Kind
    public var senderID: String
    public var senderName: String
    public var version: Int
    public var codeHash: String
    public var sentAt: Date
    public var clip: Clip?
    public var clips: [Clip]?
    public var note: String?

    public init(
        kind: Kind,
        senderID: String,
        senderName: String,
        version: Int = ProtocolVersion.current,
        codeHash: String = "",
        sentAt: Date = .now,
        clip: Clip? = nil,
        clips: [Clip]? = nil,
        note: String? = nil
    ) {
        self.kind = kind
        self.senderID = senderID
        self.senderName = senderName
        self.version = version
        self.codeHash = codeHash
        self.sentAt = sentAt
        self.clip = clip
        self.clips = clips
        self.note = note
    }
}

public extension Envelope {
    static func hello(sender: PeerIdentity, codeHash: String) -> Envelope {
        Envelope(kind: .hello, senderID: sender.id, senderName: sender.name, codeHash: codeHash)
    }

    static func clip(_ clip: Clip, sender: PeerIdentity, codeHash: String) -> Envelope {
        Envelope(
            kind: .clip,
            senderID: sender.id,
            senderName: sender.name,
            codeHash: codeHash,
            clip: clip
        )
    }

    static func historyRequest(sender: PeerIdentity, codeHash: String) -> Envelope {
        Envelope(kind: .historyRequest, senderID: sender.id, senderName: sender.name, codeHash: codeHash)
    }

    static func history(_ clips: [Clip], sender: PeerIdentity, codeHash: String) -> Envelope {
        Envelope(
            kind: .history,
            senderID: sender.id,
            senderName: sender.name,
            codeHash: codeHash,
            clips: clips
        )
    }

    static func error(_ note: String, sender: PeerIdentity, codeHash: String) -> Envelope {
        Envelope(
            kind: .error,
            senderID: sender.id,
            senderName: sender.name,
            codeHash: codeHash,
            note: note
        )
    }
}

public enum WireCoding {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: data)
    }

    public static func framed<T: Encodable>(_ value: T) throws -> Data {
        try FrameCodec.encode(encode(value))
    }
}
