import Foundation
import XCTest
@testable import ClipSyncCore

final class FrameCodecTests: XCTestCase {
    func testRoundTripSingleFrame() throws {
        let payload = Data("hello clip sync".utf8)
        let framed = try FrameCodec.encode(payload)

        var decoder = FrameDecoder()
        decoder.append(framed)
        XCTAssertEqual(try decoder.nextPayload(), payload)
        XCTAssertNil(try decoder.nextPayload())
        XCTAssertEqual(decoder.bufferedBytes, 0)
    }

    func testSplitAcrossChunks() throws {
        let payload = Data(repeating: 0x41, count: 4096)
        let framed = try FrameCodec.encode(payload)

        var decoder = FrameDecoder()
        for byte in framed {
            decoder.append(Data([byte]))
        }
        XCTAssertEqual(try decoder.nextPayload(), payload)
    }

    func testMultipleFramesInOneChunk() throws {
        let first = try FrameCodec.encode(Data("one".utf8))
        let second = try FrameCodec.encode(Data("two".utf8))

        var decoder = FrameDecoder()
        decoder.append(first + second)
        XCTAssertEqual(try decoder.nextPayload(), Data("one".utf8))
        XCTAssertEqual(try decoder.nextPayload(), Data("two".utf8))
        XCTAssertNil(try decoder.nextPayload())
    }

    func testRejectsOversizedFrame() {
        var decoder = FrameDecoder()
        var header = UInt32(FrameCodec.maxFrameSize + 1).bigEndian
        decoder.append(Data(bytes: &header, count: 4))
        XCTAssertThrowsError(try decoder.nextPayload()) { error in
            XCTAssertEqual(error as? FrameError, .frameTooLarge(FrameCodec.maxFrameSize + 1))
        }
    }

    func testEncodeRejectsOversizedPayload() {
        let oversized = Data(repeating: 0, count: FrameCodec.maxFrameSize + 1)
        XCTAssertThrowsError(try FrameCodec.encode(oversized))
    }
}

final class EnvelopeTests: XCTestCase {
    func testEnvelopeJSONRoundTripPreservesMillisecondsAndImageData() throws {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000.123)
        let image = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF])
        let clip = Clip(
            kind: .image,
            imageData: image,
            copiedAt: timestamp,
            originID: "device-a",
            originName: "MacBook Air"
        )
        let envelope = Envelope(
            kind: .clip,
            senderID: "device-a",
            senderName: "MacBook Air",
            codeHash: "abc",
            sentAt: timestamp,
            clip: clip
        )

        let data = try WireCoding.encode(envelope)
        let decoded = try WireCoding.decode(Envelope.self, from: data)

        XCTAssertEqual(decoded, envelope)
        XCTAssertEqual(decoded.clip?.imageData, image)
        XCTAssertEqual(
            decoded.sentAt.timeIntervalSince1970,
            timestamp.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testPairingCodeIsNormalized() {
        XCTAssertEqual(PairingCode.hash("  Blue-House  "), PairingCode.hash("blue-house"))
        XCTAssertNotEqual(PairingCode.hash("blue-house"), PairingCode.hash("red-house"))
        XCTAssertEqual(PairingCode.hash("   "), "")
    }

    func testClipValidation() {
        let text = Clip(kind: .text, text: "hello", originID: "a", originName: "A")
        XCTAssertTrue(text.isWithinLimits)

        let empty = Clip(kind: .text, text: "", originID: "a", originName: "A")
        XCTAssertFalse(empty.isWithinLimits)

        let hugeText = Clip(
            kind: .text,
            text: String(repeating: "x", count: ClipLimits.maxTextBytes + 1),
            originID: "a",
            originName: "A"
        )
        XCTAssertFalse(hugeText.isWithinLimits)

        let image = Clip(kind: .image, imageData: Data([1, 2, 3]), originID: "a", originName: "A")
        XCTAssertTrue(image.isWithinLimits)

        let mismatched = Clip(kind: .image, originID: "a", originName: "A")
        XCTAssertFalse(mismatched.isWithinLimits)
    }

    func testFingerprintIgnoresOrigin() {
        let first = Clip(kind: .text, text: "same", originID: "a", originName: "A")
        let second = Clip(kind: .text, text: "same", originID: "b", originName: "B")
        XCTAssertEqual(first.contentFingerprint, second.contentFingerprint)

        let different = Clip(kind: .text, text: "different", originID: "a", originName: "A")
        XCTAssertNotEqual(first.contentFingerprint, different.contentFingerprint)
    }
}

final class ClipMergeTests: XCTestCase {
    private func clip(_ seconds: TimeInterval, text: String, id: UUID = UUID()) -> Clip {
        Clip(
            id: id,
            kind: .text,
            text: text,
            copiedAt: Date(timeIntervalSince1970: seconds),
            originID: "device",
            originName: "Mac"
        )
    }

    func testMergeDeduplicatesAndSortsNewestFirst() {
        let sharedID = UUID()
        let old = clip(100, text: "old")
        let new = clip(300, text: "new", id: sharedID)
        let duplicate = clip(200, text: "new", id: sharedID)
        let duplicateAgain = clip(200, text: "new", id: sharedID)

        let merged = ClipMerge.merge(existing: [old, duplicate], incoming: [new, duplicateAgain])

        XCTAssertEqual(merged.map(\.text), ["new", "old"])
        XCTAssertEqual(Set(merged.map(\.id)).count, merged.count)
    }

    func testMergeRespectsLimit() {
        let clips = (0..<20).map { clip(TimeInterval($0), text: "\($0)") }
        let merged = ClipMerge.merge(existing: [], incoming: clips, limit: 5)
        XCTAssertEqual(merged.count, 5)
        XCTAssertEqual(merged.first?.text, "19")
    }

    func testShouldApplyOnConnect() {
        let now = Date(timeIntervalSince1970: 10_000)
        let local = clip(now.timeIntervalSince1970 - 60, text: "local")
        let remoteOlder = clip(now.timeIntervalSince1970 - 120, text: "older")
        let remoteNewer = clip(now.timeIntervalSince1970 - 30, text: "newer")

        XCTAssertNil(
            ClipMerge.shouldApplyOnConnect(incoming: [remoteOlder], existing: [local], now: now)
        )
        XCTAssertEqual(
            ClipMerge.shouldApplyOnConnect(incoming: [remoteOlder, remoteNewer], existing: [local], now: now)?.text,
            "newer"
        )
        XCTAssertEqual(
            ClipMerge.shouldApplyOnConnect(incoming: [remoteNewer], existing: [], now: now)?.text,
            "newer"
        )

        let stale = clip(now.timeIntervalSince1970 - 7200, text: "stale")
        XCTAssertNil(
            ClipMerge.shouldApplyOnConnect(incoming: [stale], existing: [], now: now)
        )
    }
}
