import Foundation
@testable import PocketVideo
import XCTest

@MainActor
final class RecentVideoStoreTests: XCTestCase {
    private var suiteName: String!
    private var userDefaults: UserDefaults!
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        suiteName = "RecentVideoStoreTests.\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: suiteName)
        userDefaults.removePersistentDomain(forName: suiteName)

        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        userDefaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: temporaryDirectory)

        userDefaults = nil
        suiteName = nil
        temporaryDirectory = nil
    }

    func testAddOrUpdateReusesExistingItem() throws {
        let store = RecentVideoStore(userDefaults: userDefaults)
        let url = try makeVideoFile(named: "sample.mp4")

        let first = try store.addOrUpdate(url: url, position: 42)
        let updated = try store.addOrUpdate(url: url, position: 12)

        XCTAssertEqual(store.videos.count, 1)
        XCTAssertEqual(first.id, updated.id)
        XCTAssertEqual(store.videos[0].lastPosition, 12, accuracy: 0.01)
    }

    func testAddOrUpdatePreservesExistingPositionWhenPositionIsOmitted() throws {
        let store = RecentVideoStore(userDefaults: userDefaults)
        let url = try makeVideoFile(named: "sample.mp4")

        let first = try store.addOrUpdate(url: url, position: 42)
        let updated = try store.addOrUpdate(url: url)

        XCTAssertEqual(store.videos.count, 1)
        XCTAssertEqual(first.id, updated.id)
        XCTAssertEqual(store.videos[0].lastPosition, 42, accuracy: 0.01)
    }

    func testAddOrUpdateReusesExistingItemForSameContentAtDifferentPath() throws {
        let store = RecentVideoStore(userDefaults: userDefaults)
        let firstURL = try makeVideoFile(named: "sample.mp4", contents: "same video content")
        let secondURL = try makeVideoFile(named: "renamed.mp4", contents: "same video content")

        let first = try store.addOrUpdate(url: firstURL, position: 42)
        let updated = try store.addOrUpdate(url: secondURL, position: 12)

        XCTAssertEqual(store.videos.count, 1)
        XCTAssertEqual(first.id, updated.id)
        XCTAssertEqual(store.videos[0].title, "renamed.mp4")
        XCTAssertEqual(store.videos[0].lastPosition, 12, accuracy: 0.01)
    }

    func testAddOrUpdatePreservesExistingPositionForSameContentAtDifferentPathWhenPositionIsOmitted() throws {
        let store = RecentVideoStore(userDefaults: userDefaults)
        let firstURL = try makeVideoFile(named: "sample.mp4", contents: "same video content")
        let secondURL = try makeVideoFile(named: "renamed.mp4", contents: "same video content")

        let first = try store.addOrUpdate(url: firstURL, position: 42)
        let updated = try store.addOrUpdate(url: secondURL)

        XCTAssertEqual(store.videos.count, 1)
        XCTAssertEqual(first.id, updated.id)
        XCTAssertEqual(store.videos[0].title, "renamed.mp4")
        XCTAssertEqual(store.videos[0].lastPosition, 42, accuracy: 0.01)
    }

    func testKeepsMostRecentItemsWithinLimit() throws {
        let store = RecentVideoStore(userDefaults: userDefaults, maxItems: 2)

        _ = try store.addOrUpdate(url: makeVideoFile(named: "first.mp4", contents: "first video content"))
        _ = try store.addOrUpdate(url: makeVideoFile(named: "second.mp4", contents: "second video content"))
        _ = try store.addOrUpdate(url: makeVideoFile(named: "third.mp4", contents: "third video content"))

        XCTAssertEqual(store.videos.map(\.title), ["third.mp4", "second.mp4"])
    }

    func testUpdatePositionPersistsAcrossStoreInstances() throws {
        let store = RecentVideoStore(userDefaults: userDefaults)
        let video = try store.addOrUpdate(url: makeVideoFile(named: "persisted.mp4"))

        store.updatePosition(for: video.id, position: 125)

        let reloadedStore = RecentVideoStore(userDefaults: userDefaults)
        XCTAssertEqual(reloadedStore.videos.first?.id, video.id)
        XCTAssertEqual(reloadedStore.videos.first?.lastPosition ?? 0, 125, accuracy: 0.01)
    }

    func testRemoveAllPersistsEmptyState() throws {
        let store = RecentVideoStore(userDefaults: userDefaults)
        _ = try store.addOrUpdate(url: makeVideoFile(named: "sample.mp4"))

        store.removeAll()

        let reloadedStore = RecentVideoStore(userDefaults: userDefaults)
        XCTAssertTrue(reloadedStore.videos.isEmpty)
    }

    func testLoadDeduplicatesLegacyVideosWithSameContent() throws {
        let firstURL = try makeVideoFile(named: "first.mp4", contents: "same legacy video")
        let duplicateURL = try makeVideoFile(named: "duplicate.mp4", contents: "same legacy video")
        let videos = [
            RecentVideo(
                title: "first.mp4",
                sourceKey: firstURL.standardizedFileURL.path,
                bookmarkData: try bookmarkData(for: firstURL),
                lastPosition: 30
            ),
            RecentVideo(
                title: "duplicate.mp4",
                sourceKey: duplicateURL.standardizedFileURL.path,
                bookmarkData: try bookmarkData(for: duplicateURL),
                lastPosition: 75
            )
        ]
        let data = try JSONEncoder().encode(videos)
        userDefaults.set(data, forKey: "recentVideos")

        let store = RecentVideoStore(userDefaults: userDefaults)

        XCTAssertEqual(store.videos.count, 1)
        XCTAssertEqual(store.videos[0].title, "first.mp4")
        XCTAssertNotNil(store.videos[0].contentFingerprint)
    }

    private func makeVideoFile(named name: String, contents: String = "test") throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func bookmarkData(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }
}
