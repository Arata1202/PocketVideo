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

    func testAddOrUpdateReusesExistingItem() async throws {
        let store = RecentVideoStore(userDefaults: userDefaults)
        let url = try makeVideoFile(named: "sample.mp4")

        let first = try await store.addOrUpdate(url: url, position: 42)
        let updated = try await store.addOrUpdate(url: url, position: 12)

        XCTAssertEqual(store.videos.count, 1)
        XCTAssertEqual(first.id, updated.id)
        XCTAssertEqual(store.videos[0].lastPosition, 12, accuracy: 0.01)
    }

    func testAddOrUpdatePreservesExistingPositionWhenPositionIsOmitted() async throws {
        let store = RecentVideoStore(userDefaults: userDefaults)
        let url = try makeVideoFile(named: "sample.mp4")

        let first = try await store.addOrUpdate(url: url, position: 42)
        let updated = try await store.addOrUpdate(url: url)

        XCTAssertEqual(store.videos.count, 1)
        XCTAssertEqual(first.id, updated.id)
        XCTAssertEqual(store.videos[0].lastPosition, 42, accuracy: 0.01)
    }

    func testAddOrUpdateReusesExistingItemForSameContentAtDifferentPath() async throws {
        let store = RecentVideoStore(userDefaults: userDefaults)
        let firstURL = try makeVideoFile(named: "sample.mp4", contents: "same video content")
        let secondURL = try makeVideoFile(named: "renamed.mp4", contents: "same video content")

        let first = try await store.addOrUpdate(url: firstURL, position: 42)
        let updated = try await store.addOrUpdate(url: secondURL, position: 12)

        XCTAssertEqual(store.videos.count, 1)
        XCTAssertEqual(first.id, updated.id)
        XCTAssertEqual(store.videos[0].title, "renamed.mp4")
        XCTAssertEqual(store.videos[0].lastPosition, 12, accuracy: 0.01)
    }

    func testAddOrUpdatePreservesExistingPositionForSameContentAtDifferentPathWhenPositionIsOmitted() async throws {
        let store = RecentVideoStore(userDefaults: userDefaults)
        let firstURL = try makeVideoFile(named: "sample.mp4", contents: "same video content")
        let secondURL = try makeVideoFile(named: "renamed.mp4", contents: "same video content")

        let first = try await store.addOrUpdate(url: firstURL, position: 42)
        let updated = try await store.addOrUpdate(url: secondURL)

        XCTAssertEqual(store.videos.count, 1)
        XCTAssertEqual(first.id, updated.id)
        XCTAssertEqual(store.videos[0].title, "renamed.mp4")
        XCTAssertEqual(store.videos[0].lastPosition, 42, accuracy: 0.01)
    }

    func testDifferentMiddleContentKeepsSeparateHistoryAndPositions() async throws {
        let firstURL = temporaryDirectory.appendingPathComponent("first.mov")
        let secondURL = temporaryDirectory.appendingPathComponent("second.mov")
        var bytes = Data(repeating: 0, count: 192 * 1024)
        try bytes.write(to: firstURL)
        bytes[96 * 1024] = 1
        try bytes.write(to: secondURL)

        let store = RecentVideoStore(userDefaults: userDefaults)
        let first = try await store.addOrUpdate(url: firstURL, position: 12)
        let second = try await store.addOrUpdate(url: secondURL)

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(second.lastPosition, 0)
        let reloaded = RecentVideoStore(userDefaults: userDefaults)
        XCTAssertEqual(reloaded.videos.map(\.lastPosition), [0, 12])
    }

    func testOverwritingFileReplacesItsHistoryAndResetsPosition() async throws {
        let url = try makeVideoFile(named: "edited.mp4", contents: "first cut")
        let store = RecentVideoStore(userDefaults: userDefaults)
        let original = try await store.addOrUpdate(url: url, position: 20)
        try Data("new cut".utf8).write(to: url)
        let replacement = try await store.addOrUpdate(url: url)
        XCTAssertNotEqual(original.id, replacement.id)
        XCTAssertEqual(store.videos, [replacement])
        XCTAssertEqual(replacement.lastPosition, 0)
    }

    func testOnlyChangingModificationDatePreservesPositionAfterRelaunch() async throws {
        let url = try makeVideoFile(named: "touched.mov")
        let first = try await RecentVideoStore(userDefaults: userDefaults).addOrUpdate(url: url, position: 5)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: url.path)
        let store = RecentVideoStore(userDefaults: userDefaults)
        let reopened = try await store.addOrUpdate(url: url)
        XCTAssertEqual(reopened.id, first.id)
        XCTAssertEqual(reopened.lastPosition, 5)
    }

    func testChangingOnlyMiddleFramesAtSamePathResetsPosition() async throws {
        let url = temporaryDirectory.appendingPathComponent("edited.mov")
        var bytes = Data(repeating: 0, count: 192 * 1024)
        try bytes.write(to: url)
        let savedDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: savedDate], ofItemAtPath: url.path)
        let store = RecentVideoStore(userDefaults: userDefaults)
        let first = try await store.addOrUpdate(url: url, position: 5)
        bytes[96 * 1024] = 1
        try bytes.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: savedDate], ofItemAtPath: url.path)
        let reopened = try await store.addOrUpdate(url: url)
        XCTAssertNotEqual(reopened.id, first.id)
        XCTAssertEqual(reopened.lastPosition, 0)
        XCTAssertEqual(store.videos, [reopened])
    }

    func testClearWinsOverEarlierOpenAndAllowsLaterOpen() async throws {
        let url = try makeVideoFile(named: "download.mov")
        let store = RecentVideoStore(userDefaults: userDefaults)
        _ = try await store.addOrUpdate(url: url, position: 5)
        let earlierOpen = store.beginOpening()
        store.removeAll()
        let playback = try await store.addOrUpdate(url: url, request: earlierOpen)
        store.updatePosition(for: playback.id, position: 2)
        XCTAssertTrue(store.videos.isEmpty)
        XCTAssertTrue(RecentVideoStore(userDefaults: userDefaults).videos.isEmpty)
        let laterOpen = try await store.addOrUpdate(url: url)
        XCTAssertEqual(store.videos, [laterOpen])
        XCTAssertEqual(laterOpen.lastPosition, 0)
    }

    func testRenamedFileReopensWithFreshBookmarkAndSavedPosition() async throws {
        let oldURL = try makeVideoFile(named: "before.mp4")
        let newURL = temporaryDirectory.appendingPathComponent("after.mp4")
        let store = RecentVideoStore(userDefaults: userDefaults)
        let original = try await store.addOrUpdate(url: oldURL, position: 5)
        try FileManager.default.moveItem(at: oldURL, to: newURL)
        let renamed = try await store.addOrUpdate(url: store.resolveURL(for: original))
        XCTAssertEqual(renamed.id, original.id)
        let reloaded = RecentVideoStore(userDefaults: userDefaults)
        let saved = try XCTUnwrap(reloaded.videos.first)
        XCTAssertEqual(saved.title, "after.mp4")
        XCTAssertEqual(saved.lastPosition, 5)
        var stale = false
        let resolved = try URL(resolvingBookmarkData: saved.bookmarkData, bookmarkDataIsStale: &stale)
        XCTAssertEqual(resolved.lastPathComponent, newURL.lastPathComponent)
        XCTAssertFalse(stale)
    }

    func testIndividualDeletionOnlySuppressesEarlierOpensOfThatVideo() async throws {
        let url = try makeVideoFile(named: "movie.mp4", contents: "movie")
        let copy = try makeVideoFile(named: "copy.mp4", contents: "movie")
        let other = try makeVideoFile(named: "other.mp4", contents: "other")
        let store = RecentVideoStore(userDefaults: userDefaults)
        let row = try await store.addOrUpdate(url: url, position: 5)
        let earlierOpen = store.beginOpening()
        let earlierCopy = store.beginOpening()
        let earlierOther = store.beginOpening()
        store.remove(row)
        let unrelated = try await store.addOrUpdate(url: other, request: earlierOther)
        let explicitlyReopened = try await store.addOrUpdate(url: url, position: 2)
        let late = try await store.addOrUpdate(url: url, request: earlierOpen)
        store.updatePosition(for: late.id, position: 8)
        _ = try await store.addOrUpdate(url: copy, request: earlierCopy)
        XCTAssertEqual(store.videos, [explicitlyReopened, unrelated])
        XCTAssertEqual(store.videos.first?.lastPosition, 2)
    }

    func testConcurrentOpensShareOneHistoryEntry() async throws {
        let url = try makeVideoFile(named: "shared.mov")
        let store = RecentVideoStore(userDefaults: userDefaults)
        async let fromFirstWindow = store.addOrUpdate(url: url)
        async let fromSecondWindow = store.addOrUpdate(url: url)
        let (first, second) = try await (fromFirstWindow, fromSecondWindow)
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(store.videos.count, 1)
    }

    func testKeepsMostRecentItemsWithinLimit() async throws {
        let store = RecentVideoStore(userDefaults: userDefaults, maxItems: 2)

        _ = try await store.addOrUpdate(url: makeVideoFile(named: "first.mp4", contents: "first video content"))
        _ = try await store.addOrUpdate(url: makeVideoFile(named: "second.mp4", contents: "second video content"))
        _ = try await store.addOrUpdate(url: makeVideoFile(named: "third.mp4", contents: "third video content"))

        XCTAssertEqual(store.videos.map(\.title), ["third.mp4", "second.mp4"])
    }

    func testUpdatePositionPersistsAcrossStoreInstances() async throws {
        let store = RecentVideoStore(userDefaults: userDefaults)
        let video = try await store.addOrUpdate(url: makeVideoFile(named: "persisted.mp4"))

        store.updatePosition(for: video.id, position: 125)

        let reloadedStore = RecentVideoStore(userDefaults: userDefaults)
        XCTAssertEqual(reloadedStore.videos.first?.id, video.id)
        XCTAssertEqual(reloadedStore.videos.first?.lastPosition ?? 0, 125, accuracy: 0.01)
    }

    func testRemoveAllPersistsEmptyState() async throws {
        let store = RecentVideoStore(userDefaults: userDefaults)
        _ = try await store.addOrUpdate(url: makeVideoFile(named: "sample.mp4"))

        store.removeAll()

        let reloadedStore = RecentVideoStore(userDefaults: userDefaults)
        XCTAssertTrue(reloadedStore.videos.isEmpty)
    }

    func testLoadDeduplicatesLegacyVideosWithSameContent() async throws {
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

        await store.finishMigration()
        XCTAssertEqual(store.videos.count, 1)
        XCTAssertEqual(store.videos[0].title, "first.mp4")
        XCTAssertEqual(store.videos[0].lastPosition, 30)
    }

    func testUnopenedRequestDoesNotEvictHistory() async throws {
        let store = RecentVideoStore(userDefaults: userDefaults, maxItems: 1)
        let original = try await store.addOrUpdate(url: makeVideoFile(named: "first.mp4"))
        _ = try await store.addOrUpdate(url: makeVideoFile(named: "other.mp4", contents: "other")) { _ in false }
        XCTAssertEqual(store.videos, [original])
    }

    func testFirstLargeOpenDoesNotWaitForFullDigest() async throws {
        let url = temporaryDirectory.appendingPathComponent("large.mp4")
        try Data(repeating: 1, count: 512 * 1024).write(to: url)
        let store = RecentVideoStore(userDefaults: userDefaults)
        let entry = try await store.addOrUpdate(url: url)
        XCTAssertNil(entry.contentDigest)
        for _ in 0..<100 where store.videos.first?.contentDigest == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(store.videos.first?.contentDigest)
    }

    func testDeletionDuringMigrationPreservesOtherDuplicate() async throws {
        let firstURL = try makeVideoFile(named: "first.mp4")
        let copyURL = try makeVideoFile(named: "copy.mp4")
        let entries = try [firstURL, copyURL].map {
            RecentVideo(title: $0.lastPathComponent, sourceKey: $0.path,
                        bookmarkData: try bookmarkData(for: $0), lastPosition: 15)
        }
        userDefaults.set(try JSONEncoder().encode(entries), forKey: "recentVideos")
        let store = RecentVideoStore(userDefaults: userDefaults)
        store.remove(entries[0])
        await store.finishMigration()
        XCTAssertEqual(store.videos, [entries[1]])
    }

    func testReusedLegacyPathWithoutIdentityDoesNotTransferPosition() async throws {
        let url = try makeVideoFile(named: "legacy.mp4")
        let old = RecentVideo(title: "legacy.mp4", sourceKey: url.path,
                              bookmarkData: try bookmarkData(for: url), lastPosition: 20)
        userDefaults.set(try JSONEncoder().encode([old]), forKey: "recentVideos")
        try Data("replacement".utf8).write(to: url)
        let store = RecentVideoStore(userDefaults: userDefaults)
        let opened = try await store.addOrUpdate(url: url)
        XCTAssertNotEqual(opened.id, old.id)
        XCTAssertEqual(opened.lastPosition, 0)
    }

    func testLegacySamplePreservesProvenContentOnly() async throws {
        for size in [32, 192 * 1024] {
            let url = temporaryDirectory.appendingPathComponent("legacy-\(size).mp4")
            var data = Data(repeating: 0, count: size)
            try data.write(to: url)
            let firstStore = RecentVideoStore(userDefaults: userDefaults)
            let saved = try await firstStore.addOrUpdate(url: url, position: 15)
            var legacy = saved
            legacy.contentDigest = nil
            legacy.fileRevision = nil
            userDefaults.set(try JSONEncoder().encode([legacy]), forKey: "recentVideos")
            if size > 128 * 1024 {
                data[size / 2] = 1
                try data.write(to: url)
            }
            let store = RecentVideoStore(userDefaults: userDefaults)
            let reopened = try await store.addOrUpdate(url: url)
            if size == 32 {
                XCTAssertEqual(reopened.id, saved.id)
                XCTAssertEqual(reopened.lastPosition, 15)
            } else {
                XCTAssertNotEqual(reopened.id, saved.id)
                XCTAssertEqual(reopened.lastPosition, 0)
            }
        }
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
