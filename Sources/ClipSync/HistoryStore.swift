import ClipSyncCore
import Foundation

/// Local clipboard history, persisted in Application Support. Images are kept
/// as separate PNG files so the JSON index stays small.
final class HistoryStore {
    private(set) var clips: [Clip] = []

    private let maxClips = 60
    private let maxImages = 12
    private let directory: URL
    private let attachmentsDirectory: URL
    private let indexURL: URL

    private var pendingSave: DispatchWorkItem?
    private let saveQueue = DispatchQueue(
        label: "com.srihariphs.clipsync.history",
        qos: .utility
    )

    init() {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        directory = base.appendingPathComponent("ClipSync", isDirectory: true)
        attachmentsDirectory = directory.appendingPathComponent("Attachments", isDirectory: true)
        indexURL = directory.appendingPathComponent("history.json")
    }

    func load() {
        do {
            guard FileManager.default.fileExists(atPath: indexURL.path) else { return }
            let data = try Data(contentsOf: indexURL)
            let stored = try WireCoding.decode([StoredClip].self, from: data)
            clips = stored.compactMap { $0.toClip(attachments: attachmentsDirectory) }
            sortAndTrim()
        } catch {
            NSLog("ClipSync: could not load history: \(error)")
            clips = []
        }
    }

    @discardableResult
    func add(_ clip: Clip) -> Bool {
        guard !clips.contains(where: { $0.id == clip.id }) else { return false }
        clips.append(clip)
        sortAndTrim()
        scheduleSave()
        return true
    }

    @discardableResult
    func merge(_ incoming: [Clip]) -> Bool {
        guard !incoming.isEmpty else { return false }
        let before = Set(clips.map(\.id))
        clips = ClipMerge.merge(existing: clips, incoming: incoming, limit: maxClips)
        sortAndTrim()
        let changed = clips.contains { !before.contains($0.id) }
        if changed { scheduleSave() }
        return changed
    }

    func clip(withID id: UUID) -> Clip? {
        clips.first { $0.id == id }
    }

    func clear() {
        clips = []
        scheduleSave()
    }

    /// Synchronous flush for app termination.
    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        let snapshot = clips
        saveQueue.sync {
            Self.persist(snapshot, indexURL: indexURL, attachments: attachmentsDirectory)
        }
    }

    private func sortAndTrim() {
        clips = ClipMerge.merge(existing: clips, incoming: [], limit: maxClips)

        var imageCount = 0
        clips = clips.filter { clip in
            guard clip.kind == .image else { return true }
            imageCount += 1
            return imageCount <= maxImages
        }
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let snapshot = clips
        let work = DispatchWorkItem { [indexURL, attachmentsDirectory] in
            Self.persist(snapshot, indexURL: indexURL, attachments: attachmentsDirectory)
        }
        pendingSave = work
        saveQueue.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    private static func persist(_ clips: [Clip], indexURL: URL, attachments: URL) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: attachments, withIntermediateDirectories: true)

            var stored: [StoredClip] = []
            var usedFiles = Set<String>()

            for clip in clips {
                var fileName: String?
                if clip.kind == .image {
                    let name = "\(clip.id.uuidString).png"
                    let url = attachments.appendingPathComponent(name)
                    if let data = clip.imageData {
                        if !fm.fileExists(atPath: url.path) {
                            try data.write(to: url, options: .atomic)
                        }
                        fileName = name
                        usedFiles.insert(name)
                    }
                }
                stored.append(StoredClip(clip: clip, imageFileName: fileName))
            }

            let data = try WireCoding.encode(stored)
            try data.write(to: indexURL, options: .atomic)

            if let files = try? fm.contentsOfDirectory(atPath: attachments.path) {
                for file in files where !usedFiles.contains(file) {
                    try? fm.removeItem(at: attachments.appendingPathComponent(file))
                }
            }
        } catch {
            NSLog("ClipSync: could not save history: \(error)")
        }
    }
}

private struct StoredClip: Codable {
    var id: UUID
    var kind: Clip.Kind
    var text: String?
    var imageFileName: String?
    var copiedAt: Date
    var originID: String
    var originName: String

    init(clip: Clip, imageFileName: String?) {
        id = clip.id
        kind = clip.kind
        text = clip.text
        self.imageFileName = imageFileName
        copiedAt = clip.copiedAt
        originID = clip.originID
        originName = clip.originName
    }

    func toClip(attachments: URL) -> Clip? {
        var imageData: Data?
        if kind == .image {
            guard let imageFileName,
                  let data = try? Data(contentsOf: attachments.appendingPathComponent(imageFileName))
            else { return nil }
            imageData = data
        }

        return Clip(
            id: id,
            kind: kind,
            text: text,
            imageData: imageData,
            copiedAt: copiedAt,
            originID: originID,
            originName: originName
        )
    }
}
