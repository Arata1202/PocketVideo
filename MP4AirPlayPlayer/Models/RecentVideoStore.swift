import Foundation

@MainActor
final class RecentVideoStore: ObservableObject {
    @Published private(set) var videos: [RecentVideo] = []

    private let storageKey = "recentVideos"
    private let maxItems = 10

    init() {
        load()
    }

    func addOrUpdate(url: URL, position: TimeInterval = 0) throws -> RecentVideo {
        let bookmarkData = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
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

    func resolveURL(for video: RecentVideo) throws -> URL {
        var isStale = false
        let url = try URL(resolvingBookmarkData: video.bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
        if isStale {
            throw RecentVideoStoreError.staleBookmark
        }
        return url
    }

    private static func sourceKey(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return }
        videos = (try? JSONDecoder().decode([RecentVideo].self, from: data)) ?? []
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(videos) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

enum RecentVideoStoreError: LocalizedError {
    case staleBookmark

    var errorDescription: String? {
        "The saved file reference is no longer valid."
    }
}
