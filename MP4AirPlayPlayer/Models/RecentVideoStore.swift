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
        let importedURL = try importVideo(from: url)
        let bookmarkData: Data
        do {
            bookmarkData = try importedURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            try? FileManager.default.removeItem(at: importedURL)
            throw error
        }

        let title = url.lastPathComponent
        let sourceKey = Self.sourceKey(for: url)

        if let index = videos.firstIndex(where: { $0.sourceKey == sourceKey }) {
            removeStoredFile(for: videos[index])
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
        videos.dropFirst(maxItems).forEach(removeStoredFile)
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
        let url = try URL(resolvingBookmarkData: video.bookmarkData, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
        if isStale {
            throw RecentVideoStoreError.staleBookmark
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            throw RecentVideoStoreError.fileUnavailable
        }
        return url
    }

    private func importVideo(from sourceURL: URL) throws -> URL {
        let didAccessSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScope {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let directoryURL = try importedVideosDirectory()
        let destinationURL = uniqueDestinationURL(in: directoryURL, originalName: sourceURL.lastPathComponent)

        var coordinationError: NSError?
        var copyError: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: sourceURL, options: [], error: &coordinationError) { readableURL in
            do {
                try FileManager.default.copyItem(at: readableURL, to: destinationURL)
            } catch {
                copyError = error
            }
        }

        if let coordinationError {
            throw coordinationError
        }

        if let copyError {
            throw copyError
        }

        return destinationURL
    }

    private func importedVideosDirectory() throws -> URL {
        let directoryURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("ImportedVideos", isDirectory: true)

        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    private func uniqueDestinationURL(in directoryURL: URL, originalName: String) -> URL {
        let fallbackName = "Video.mp4"
        let safeName = originalName.isEmpty ? fallbackName : originalName
        return directoryURL.appendingPathComponent("\(UUID().uuidString)-\(safeName)")
    }

    private func removeStoredFile(for video: RecentVideo) {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: video.bookmarkData,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return
        }

        try? FileManager.default.removeItem(at: url)
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
    case fileUnavailable

    var errorDescription: String? {
        switch self {
        case .staleBookmark:
            return "The saved file reference is no longer valid."
        case .fileUnavailable:
            return "The saved video file is no longer available."
        }
    }
}
