import Foundation

public enum FrameError: Error, Equatable {
    case frameTooLarge(Int)
}

/// Length-prefixed framing: a 4-byte big-endian length followed by JSON.
public enum FrameCodec {
    public static let headerSize = 4
    /// The largest image we accept is 8 MB. Base64 plus JSON stays under this.
    public static let maxFrameSize = 16 * 1024 * 1024

    public static func encode(_ payload: Data) throws -> Data {
        guard payload.count <= maxFrameSize else {
            throw FrameError.frameTooLarge(payload.count)
        }
        var framed = Data(capacity: headerSize + payload.count)
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { framed.append(contentsOf: $0) }
        framed.append(payload)
        return framed
    }
}

/// Incremental decoder that tolerates arbitrary TCP chunk boundaries.
public struct FrameDecoder {
    private var buffer = Data()

    public init() {}

    public var bufferedBytes: Int { buffer.count }

    public mutating func append(_ data: Data) {
        buffer.append(data)
    }

    /// Returns the next complete payload, or nil when more bytes are needed.
    public mutating func nextPayload() throws -> Data? {
        guard buffer.count >= FrameCodec.headerSize else { return nil }

        let header = buffer.prefix(FrameCodec.headerSize)
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length <= UInt32(FrameCodec.maxFrameSize) else {
            buffer.removeAll(keepingCapacity: false)
            throw FrameError.frameTooLarge(Int(length))
        }

        let total = FrameCodec.headerSize + Int(length)
        guard buffer.count >= total else { return nil }

        let framed = buffer.prefix(total)
        let payload = Data(framed.dropFirst(FrameCodec.headerSize))
        buffer = Data(buffer.dropFirst(total))
        return payload
    }
}
