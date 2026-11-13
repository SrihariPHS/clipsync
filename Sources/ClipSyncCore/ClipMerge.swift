import Foundation

public enum ClipMerge {
    /// Deduplicate by clip ID, sort newest first, and cap the result.
    public static func merge(existing: [Clip], incoming: [Clip], limit: Int = 100) -> [Clip] {
        var seen = Set<UUID>()
        var result: [Clip] = []
        result.reserveCapacity(min(limit, existing.count + incoming.count))

        let combined = (existing + incoming).sorted { lhs, rhs in
            if lhs.copiedAt == rhs.copiedAt {
                return lhs.id.uuidString > rhs.id.uuidString
            }
            return lhs.copiedAt > rhs.copiedAt
        }

        for clip in combined where seen.insert(clip.id).inserted {
            result.append(clip)
            if result.count >= limit { break }
        }
        return result
    }

    public static func newestDate(in clips: [Clip]) -> Date? {
        clips.map(\.copiedAt).max()
    }

    /// When a peer connects, copy its newest clip locally only when it is
    /// recent and newer than anything on this Mac. That makes "copy on the
    /// Air, paste on the iMac" work after one Mac has been asleep, without
    /// clobbering something newer you copied here.
    public static func shouldApplyOnConnect(
        incoming: [Clip],
        existing: [Clip],
        now: Date = .now,
        maxAge: TimeInterval = 60 * 60
    ) -> Clip? {
        guard let newest = incoming.max(by: { $0.copiedAt < $1.copiedAt }) else {
            return nil
        }
        guard now.timeIntervalSince(newest.copiedAt) <= maxAge else { return nil }
        if let localNewest = newestDate(in: existing), localNewest >= newest.copiedAt {
            return nil
        }
        return newest
    }
}
