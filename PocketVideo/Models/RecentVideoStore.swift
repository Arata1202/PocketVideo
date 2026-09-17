import CryptoKit
import Foundation

@MainActor
final class RecentVideoStore: ObservableObject {
    @Published private(set) var videos: [RecentVideo] = []

    private let storageKey = "recentVideos"
    private let maxItems: Int
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard, maxItems: Int = 10) {
        self.userDefaults = userDefaults
        self.maxItems = maxItems
        load()
    }

    func addOrUpdate(url: URL, position: TimeInterval? = nil) throws -> RecentVideo {
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

        if let index = videos.firstIndex(where: {
            $0.matches(sourceKey: sourceKey, contentFingerprint: contentFingerprint)
        }) {
            var updated = videos.remove(at: index)
            updated.title = title
            updated.sourceKey = sourceKey
            updated.contentFingerprint = contentFingerprint
            updated.bookmarkData = bookmarkData
            if let position {
                updated.lastPosition = position
            }
            updated.updatedAt = Date()

            videos.removeAll { $0.matches(sourceKey: sourceKey, contentFingerprint: contentFingerprint) }
            videos.insert(updated, at: 0)
            save()
            return videos[0]
        }

        let video = RecentVideo(
            title: title,
            sourceKey: sourceKey,
            contentFingerprint: contentFingerprint,
            bookmarkData: bookmarkData,
            lastPosition: position ?? 0
        )
        videos.insert(video, at: 0)
        videos = Array(videos.prefix(maxItems))
        save()
        return video
    }

    func updatePosition(for videoID: RecentVideo.ID, position: TimeInterval) {
        guard let index = videos.firstIndex(where: { $0.id == videoID }) else { return }
        videos[index].lastPosition = position
        videos[index].updatedAt = Date()
        save()
    }

    func remove(_ video: RecentVideo) {
        guard let index = videos.firstIndex(where: { $0.id == video.id }) else { return }
        videos.remove(at: index)
        save()
    }

    func removeAll() {
        videos.removeAll()
        save()
    }

    func resolveURL(for video: RecentVideo) throws -> URL {
        let url = try resolvedBookmarkedURL(for: video)

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

    private func resolvedBookmarkedURL(for video: RecentVideo) throws -> URL {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: video.bookmarkData,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        if isStale {
            throw RecentVideoStoreError.staleBookmark
        }

        return url
    }

    private static func bookmarkData(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private static func sourceKey(for url: URL) -> String {
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

    private func migratedVideo(_ video: RecentVideo) -> RecentVideo {
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

    private static func deduplicated(_ videos: [RecentVideo], maxItems: Int) -> [RecentVideo] {
        var deduplicatedVideos: [RecentVideo] = []

        for video in videos {
            guard !deduplicatedVideos.contains(where: { $0.matches(video) }) else { continue }
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
        let migratedVideos = loadedVideos.map(migratedVideo)
        videos = Self.deduplicated(migratedVideos, maxItems: maxItems)

        if videos != loadedVideos {
            save()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(videos) else { return }
        userDefaults.set(data, forKey: storageKey)
    }
}

enum RecentVideoStoreError: LocalizedError {
    case staleBookmark
    case fileUnavailable

    var errorDescription: String? {
        switch self {
        case .staleBookmark:
            return String(localized: "保存済みのファイル参照が無効です。")
        case .fileUnavailable:
            return String(localized: "保存済みの動画ファイルが見つかりません。")
        }
    }
}

private extension RecentVideo {
    func matches(_ other: RecentVideo) -> Bool {
        matches(sourceKey: other.sourceKey, contentFingerprint: other.contentFingerprint)
    }

    func matches(sourceKey: String, contentFingerprint: String?) -> Bool {
        if let contentFingerprint, let existingFingerprint = self.contentFingerprint {
            return existingFingerprint == contentFingerprint
        }

        return self.sourceKey == sourceKey
    }
}
