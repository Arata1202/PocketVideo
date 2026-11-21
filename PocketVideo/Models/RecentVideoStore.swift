import CryptoKit
import Foundation

@MainActor
final class RecentVideoStore: ObservableObject {
    @Published private(set) var videos: [RecentVideo] = []

    private var migration: Task<[RecentVideo], Never>?
    final class PendingOpen {
        fileprivate var wasCleared = false
        fileprivate var removedVideos: [RecentVideo] = []
    }

    private let pendingOpens = NSHashTable<PendingOpen>.weakObjects()
    private var historyRevision = 0
    private let storageKey = "recentVideos"
    private let maxItems: Int
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard, maxItems: Int = 10) {
        self.userDefaults = userDefaults
        self.maxItems = maxItems
        load()
    }

    func beginOpening() -> PendingOpen {
        let request = PendingOpen()
        pendingOpens.add(request)
        return request
    }

    /// Returns a playable entry even when a later history deletion prevents saving it.
    func addOrUpdate(url: URL, position: TimeInterval? = nil, request: PendingOpen? = nil) async throws -> RecentVideo {
        let pending = request ?? beginOpening()
        await finishMigration()
        let candidate = try await Self.prepareVideo(url: url, position: position, history: videos)
        while true {
            try Task.checkCancellation()
            let revision = historyRevision
            let removed = pending.removedVideos
            if pending.wasCleared || removed.contains(where: { $0.sourceKey == candidate.sourceKey }) {
                return candidate
            }
            if !removed.isEmpty, await Self.matchID(for: candidate, in: removed) != nil {
                return candidate
            }
            let matchID = await Self.matchID(for: candidate, in: videos)
            try Task.checkCancellation()
            // Another window may have opened or removed a video during comparison.
            guard revision == historyRevision else { continue }
            var result = candidate
            if let existing = videos.first(where: { $0.id == matchID }) {
                result = RecentVideo(
                    id: existing.id, title: candidate.title, sourceKey: candidate.sourceKey,
                    contentFingerprint: candidate.contentFingerprint,
                    contentDigest: candidate.contentDigest, contentModificationDate: candidate.contentModificationDate,
                    bookmarkData: candidate.bookmarkData, lastPosition: position ?? existing.lastPosition
                )
            }
            videos.removeAll { $0.sourceKey == candidate.sourceKey || $0.id == matchID }
            videos.insert(result, at: 0)
            videos = Array(videos.prefix(maxItems))
            historyRevision += 1
            save()
            return result
        }
    }

    private nonisolated static func matchID(for candidate: RecentVideo, in videos: [RecentVideo]) async -> UUID? {
        videos.first { matches($0, candidate) }?.id
    }

    private nonisolated static func prepareVideo(url: URL, position: TimeInterval?, history: [RecentVideo]) async throws -> RecentVideo {
        let didAccessSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let bookmarkData = try Self.bookmarkData(for: url)
        let title = url.lastPathComponent
        let sourceKey = Self.sourceKey(for: url)
        let contentFingerprint = try? Self.contentFingerprint(for: url)

        var metadataURL = url
        metadataURL.removeCachedResourceValue(forKey: .contentModificationDateKey)
        let modified = try? metadataURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let cached = history.first {
            $0.sourceKey == sourceKey && modified != nil && $0.contentModificationDate == modified
                && contentFingerprint != nil && $0.contentFingerprint == contentFingerprint
        }
        let digest = try cached?.contentDigest ?? fullContentDigest(for: url)
        return RecentVideo(
            title: title, sourceKey: sourceKey, contentFingerprint: contentFingerprint,
            contentDigest: digest, contentModificationDate: modified,
            bookmarkData: bookmarkData, lastPosition: position ?? 0
        )
    }

    func updatePosition(for videoID: RecentVideo.ID, position: TimeInterval) {
        guard let index = videos.firstIndex(where: { $0.id == videoID }) else { return }
        videos[index].lastPosition = position
        videos[index].updatedAt = Date()
        save()
    }

    func remove(_ video: RecentVideo) {
        guard let index = videos.firstIndex(where: { $0.id == video.id }) else { return }
        historyRevision += 1
        let removed = videos.remove(at: index)
        for request in pendingOpens.allObjects where !request.wasCleared {
            request.removedVideos.append(removed)
        }
        save()
    }

    func removeAll() {
        for request in pendingOpens.allObjects {
            request.wasCleared = true
            request.removedVideos.removeAll()
        }
        historyRevision += 1
        videos.removeAll()
        save()
    }

    func resolveURL(for video: RecentVideo) throws -> URL {
        let url = try Self.resolvedBookmarkedURL(for: video)

        let didAccessSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        if !FileManager.default.fileExists(atPath: url.path) {
            throw RecentVideoStoreError.fileUnavailable
        }
        return url
    }

    private nonisolated static func resolvedBookmarkedURL(for video: RecentVideo) throws -> URL {
        var isStale = false
        // A stale bookmark can still resolve after a rename. Opening the resolved URL
        // creates and persists a fresh bookmark in prepareVideo and addOrUpdate.
        return try URL(
            resolvingBookmarkData: video.bookmarkData,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }

    private nonisolated static func bookmarkData(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private nonisolated static func sourceKey(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private nonisolated static func contentFingerprint(for url: URL) throws -> String {
        let fingerprintChunkSize = 64 * 1024
        let file = try FileHandle(forReadingFrom: url)
        defer {
            try? file.close()
        }

        let fileSize = try file.seekToEnd()
        try file.seek(toOffset: 0)

        var hasher = SHA256()
        hasher.update(data: Data("\(fileSize)".utf8))

        if let head = try file.read(upToCount: fingerprintChunkSize) {
            hasher.update(data: head)
        }

        if fileSize > UInt64(fingerprintChunkSize) {
            try file.seek(toOffset: fileSize - UInt64(fingerprintChunkSize))

            if let tail = try file.read(upToCount: fingerprintChunkSize) {
                hasher.update(data: tail)
            }
        }

        let digest = hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()

        return "sampled-sha256:\(fileSize):\(digest)"
    }

    private nonisolated static func fullContentDigest(for url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func migratedVideo(_ video: RecentVideo) -> RecentVideo {
        guard video.contentFingerprint == nil else { return video }
        guard let url = try? resolvedBookmarkedURL(for: video) else { return video }

        let didAccessSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard FileManager.default.fileExists(atPath: url.path) else { return video }

        var migrated = video
        migrated.sourceKey = Self.sourceKey(for: url)
        migrated.contentFingerprint = try? Self.contentFingerprint(for: url)
        return migrated
    }

    private nonisolated static func matches(_ first: RecentVideo, _ second: RecentVideo) -> Bool {
        if let lhs = first.contentDigest, let rhs = second.contentDigest {
            return lhs == rhs
        }
        // Older history entries only have a sampled fingerprint.
        if first.sourceKey == second.sourceKey {
            return first.contentFingerprint == nil || second.contentFingerprint == nil
                || first.contentFingerprint == second.contentFingerprint
        }
        // The sampled hash only narrows candidates. Two different edits can share both ends.
        guard let fingerprint = first.contentFingerprint, fingerprint == second.contentFingerprint,
              let lhs = try? resolvedBookmarkedURL(for: first),
              let rhs = try? resolvedBookmarkedURL(for: second) else { return false }
        let accessedLeft = lhs.startAccessingSecurityScopedResource()
        let accessedRight = rhs.startAccessingSecurityScopedResource()
        defer {
            if accessedLeft { lhs.stopAccessingSecurityScopedResource() }
            if accessedRight { rhs.stopAccessingSecurityScopedResource() }
        }
        return FileManager.default.contentsEqual(atPath: lhs.path, andPath: rhs.path)
    }

    private nonisolated static func deduplicated(_ videos: [RecentVideo], maxItems: Int) -> [RecentVideo] {
        var deduplicatedVideos: [RecentVideo] = []

        for video in videos {
            guard !deduplicatedVideos.contains(where: { $0.sourceKey == video.sourceKey || matches($0, video) }) else { continue }
            deduplicatedVideos.append(video)

            if deduplicatedVideos.count == maxItems {
                break
            }
        }

        return deduplicatedVideos
    }

    private func load() {
        guard let data = userDefaults.data(forKey: storageKey) else { return }
        let loadedVideos = (try? JSONDecoder().decode([RecentVideo].self, from: data)) ?? []
        videos = loadedVideos
        guard !loadedVideos.isEmpty else { return }
        let limit = maxItems
        migration = Task.detached {
            let migrated = loadedVideos.map(Self.migratedVideo)
            return Self.deduplicated(migrated, maxItems: limit)
        }
        Task { await finishMigration() }
    }

    func finishMigration() async {
        guard let pending = migration else { return }
        let migrated = await pending.value
        guard migration != nil else { return }
        migration = nil
        // Preserve removals and position updates made while old bookmarks were being read.
        let current = Dictionary(videos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let merged = migrated.compactMap { entry -> RecentVideo? in
            guard var video = current[entry.id] else { return nil }
            video.contentFingerprint = entry.contentFingerprint
            video.sourceKey = entry.sourceKey
            return video
        }
        if videos != merged {
            videos = merged
            save()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(videos) else { return }
        userDefaults.set(data, forKey: storageKey)
    }
}

enum RecentVideoStoreError: LocalizedError {
    case fileUnavailable

    var errorDescription: String? {
        switch self {
        case .fileUnavailable:
            return String(localized: "保存済みの動画ファイルが見つかりません。")
        }
    }
}
