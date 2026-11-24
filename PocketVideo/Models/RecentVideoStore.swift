import CryptoKit
import Darwin
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
    private var pendingDigests: Set<String> = []
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
    func addOrUpdate(url: URL, position: TimeInterval? = nil, request: PendingOpen? = nil,
                     open: (RecentVideo) throws -> Bool = { _ in true }) async throws -> RecentVideo {
        let pending = request ?? beginOpening()
        await finishMigration()
        let candidate = try await Self.prepareVideo(url: url, position: position, history: videos)
        while true {
            try Task.checkCancellation()
            let revision = historyRevision
            let removed = pending.removedVideos
            if pending.wasCleared || removed.contains(where: { $0.sourceKey == candidate.sourceKey }) {
                _ = try open(candidate)
                return candidate
            }
            if !removed.isEmpty, await Self.matchID(for: candidate, in: removed) != nil {
                _ = try open(candidate)
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
                    contentDigest: candidate.contentDigest ?? existing.contentDigest, fileRevision: candidate.fileRevision,
                    bookmarkData: candidate.bookmarkData, lastPosition: position ?? existing.lastPosition
                )
            }
            guard try open(result) else { return result }
            videos.removeAll { $0.sourceKey == candidate.sourceKey || $0.id == matchID }
            videos.insert(result, at: 0)
            videos = Array(videos.prefix(maxItems))
            historyRevision += 1
            save()
            if result.contentDigest == nil { scheduleDigest(for: result, url: url) }
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

        for _ in 0..<2 {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            guard let revision = fileRevision(of: file), fileRevision(for: url) == revision else { continue }
            let bookmark = try bookmarkData(for: url)
            let path = sourceKey(for: url)
            let (sample, size) = try sampledContent(of: file)
            let cached = history.first {
                $0.fileRevision == revision && $0.contentFingerprint == sample
            }
            // A large first open needs only the sample. Verify matching candidates
            // before reusing history, and fill in the digest after opening otherwise.
            let smallFile = size <= 128 * 1024
            let needsDigest = smallFile || history.contains {
                ($0.contentFingerprint == sample || ($0.contentFingerprint == nil && $0.sourceKey == path))
                    && $0.contentDigest != nil
            }
            let digest = try cached?.contentDigest ?? (needsDigest ? fullContentDigest(of: file) : nil)
            guard revision == fileRevision(of: file), revision == fileRevision(for: url) else { continue }
            return RecentVideo(title: url.lastPathComponent, sourceKey: path, contentFingerprint: sample,
                               contentDigest: digest, fileRevision: revision, bookmarkData: bookmark,
                               lastPosition: position ?? 0)
        }
        throw CocoaError(.fileReadUnknown)
    }

    private func scheduleDigest(for video: RecentVideo, url: URL) {
        guard let revision = video.fileRevision, pendingDigests.insert(revision).inserted else { return }
        Task(priority: .utility) { [weak self] in
            let digest = await Self.verifiedDigest(at: url, revision: revision)
            guard let self else { return }
            self.pendingDigests.remove(revision)
            guard let digest,
                  let index = self.videos.firstIndex(where: { $0.fileRevision == revision }),
                  self.videos[index].contentDigest == nil else { return }
            self.videos[index].contentDigest = digest
            self.save()
        }
    }

    private nonisolated static func verifiedDigest(at url: URL, revision: String) async -> String? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard fileRevision(for: url) == revision else { return nil }
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard fileRevision(of: file) == revision else { return nil }
        let digest = try? fullContentDigest(of: file)
        return fileRevision(of: file) == revision && fileRevision(for: url) == revision ? digest : nil
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

    private nonisolated static func sampledContent(of file: FileHandle) throws -> (fingerprint: String, size: UInt64) {
        let fingerprintChunkSize = 64 * 1024

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

        return ("sampled-sha256:\(fileSize):\(digest)", fileSize)
    }

    // The inode and its status-change time also change on replacement or a timestamp-preserving edit.
    private nonisolated static func fileRevision(for url: URL) -> String? {
        var info = stat()
        let status = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return fstatat(AT_FDCWD, path, &info, 0)
        }
        guard status == 0 else { return nil }
        return revisionString(info)
    }

    private nonisolated static func fileRevision(of file: FileHandle) -> String? {
        var info = stat()
        guard fstat(file.fileDescriptor, &info) == 0 else { return nil }
        return revisionString(info)
    }

    private nonisolated static func revisionString(_ info: stat) -> String {
        "\(info.st_dev):\(info.st_ino):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
    }

    private nonisolated static func fullContentDigest(of file: FileHandle) throws -> String {
        try file.seek(toOffset: 0)
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

        guard let file = try? FileHandle(forReadingFrom: url) else { return video }
        defer { try? file.close() }
        guard let revision = fileRevision(of: file),
              let sample = try? sampledContent(of: file), fileRevision(for: url) == revision else { return video }

        var migrated = video
        migrated.sourceKey = Self.sourceKey(for: url)
        migrated.contentFingerprint = sample.fingerprint
        migrated.fileRevision = revision
        return migrated
    }

    private nonisolated static func matches(_ first: RecentVideo, _ second: RecentVideo) -> Bool {
        if let lhs = first.contentDigest, let rhs = second.contentDigest {
            return lhs == rhs
        }
        guard let fingerprint = first.contentFingerprint, fingerprint == second.contentFingerprint else { return false }
        if let revision = first.fileRevision, revision == second.fileRevision { return true }
        // Small legacy samples covered every byte. Larger samples alone cannot
        // establish that the middle of a historical file has stayed the same.
        if let size = UInt64(fingerprint.split(separator: ":").dropFirst().first ?? ""), size <= 128 * 1024 {
            return true
        }
        guard let leftRevision = first.fileRevision, let rightRevision = second.fileRevision,
              let lhs = try? resolvedBookmarkedURL(for: first),
              let rhs = try? resolvedBookmarkedURL(for: second) else { return false }
        let accessedLeft = lhs.startAccessingSecurityScopedResource()
        let accessedRight = rhs.startAccessingSecurityScopedResource()
        defer {
            if accessedLeft { lhs.stopAccessingSecurityScopedResource() }
            if accessedRight { rhs.stopAccessingSecurityScopedResource() }
        }
        guard fileRevision(for: lhs) == leftRevision, fileRevision(for: rhs) == rightRevision else { return false }
        return FileManager.default.contentsEqual(atPath: lhs.path, andPath: rhs.path)
            && fileRevision(for: lhs) == leftRevision && fileRevision(for: rhs) == rightRevision
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
        migration = Task.detached {
            loadedVideos.map(Self.migratedVideo)
        }
        Task { await finishMigration() }
    }

    func finishMigration() async {
        guard let pending = migration else { return }
        let migrated = await pending.value
        while migration != nil {
            let revision = historyRevision
            let remainingIDs = Set(videos.map(\.id))
            let limit = maxItems
            let survivors = await Task.detached {
                Self.deduplicated(migrated.filter { remainingIDs.contains($0.id) }, maxItems: limit)
            }.value
            guard migration != nil else { return }
            guard revision == historyRevision else { continue }
            migration = nil
            // Keep original identity evidence: sampling the file today cannot
            // prove which version the user watched before this launch.
            let current = Dictionary(videos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let merged = survivors.compactMap { current[$0.id] }
            if videos != merged {
                videos = merged
                save()
            }
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
