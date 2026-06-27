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

    func addOrUpdate(url: URL, position: TimeInterval = 0) throws -> RecentVideo {
        let bookmarkData = try bookmarkData(for: url)
        let title = url.lastPathComponent
        let sourceKey = Self.sourceKey(for: url)

        if let index = videos.firstIndex(where: { $0.sourceKey == sourceKey }) {
            videos[index].bookmarkData = bookmarkData
            videos[index].lastPosition = position
            videos[index].updatedAt = Date()
            let updated = videos.remove(at: index)
            videos.insert(updated, at: 0)
            save()
            return videos[0]
        }

        let video = RecentVideo(title: title, sourceKey: sourceKey, bookmarkData: bookmarkData, lastPosition: position)
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

    private func bookmarkData(for url: URL) throws -> Data {
        let didAccessSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        return try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private static func sourceKey(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    private func load() {
        guard let data = userDefaults.data(forKey: storageKey) else { return }
        videos = (try? JSONDecoder().decode([RecentVideo].self, from: data)) ?? []
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
            return "保存済みのファイル参照が無効です。"
        case .fileUnavailable:
            return "保存済みの動画ファイルが見つかりません。"
        }
    }
}
