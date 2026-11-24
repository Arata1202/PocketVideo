import Foundation
import XCTest
@testable import PocketVideo

final class CloudVideoAvailabilityTests: XCTestCase {
    func testOpeningPolicyOnlyAllowsStalePlaybackAfterConsent() {
        for consent in [false, true] {
            XCTAssertEqual(CloudVideoAvailability.unknown.needsDownload(allowsLocalCopy: consent), !consent)
            XCTAssertFalse(CloudVideoAvailability(isUbiquitous: false, status: nil).needsDownload(allowsLocalCopy: consent))
            XCTAssertFalse(CloudVideoAvailability(isUbiquitous: true, status: .current).needsDownload(allowsLocalCopy: consent))
            XCTAssertEqual(CloudVideoAvailability(isUbiquitous: true, status: .downloaded).needsDownload(allowsLocalCopy: consent), !consent)
            XCTAssertTrue(CloudVideoAvailability(isUbiquitous: true, status: .notDownloaded).needsDownload(allowsLocalCopy: consent))
            XCTAssertTrue(CloudVideoAvailability(isUbiquitous: true, status: nil).needsDownload(allowsLocalCopy: consent))
        }
    }

    func testLocalFileOpensWhenCloudMetadataIsNotApplicable() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try CloudVideoAvailability.read(at: url), .local)
    }

    @MainActor
    func testStalledUpdateOffersLocalCopyOnceAndContinuesWaiting() async throws {
        var offers = 0
        var checks = 0
        try await CloudVideoAvailability.waitForCurrent(idleTimeout: .zero, pollInterval: .zero, offerLocalCopy: { offers += 1 }) {
            checks += 1
            return (checks == 4 ? .current : .downloaded, true, nil)
        }
        XCTAssertEqual(offers, 1)
        XCTAssertEqual(checks, 4)
    }

    func testActiveTransferWaitsForLatestVersion() async throws {
        var checks = 0
        try await CloudVideoAvailability.waitForCurrent(idleTimeout: .zero, pollInterval: .zero) {
            checks += 1
            return (checks == 3 ? .current : .downloaded, true, nil)
        }
        XCTAssertEqual(checks, 3)
    }

    func testOfflineAndIdleDownloadsFinishWithAnError() async {
        for failure in [URLError.Code.notConnectedToInternet, .timedOut] {
            do {
                try await CloudVideoAvailability.waitForCurrent(idleTimeout: .zero) {
                    (.downloaded, false, failure == .timedOut ? nil : URLError(failure))
                }
                XCTFail("A stale copy must not be opened automatically")
            } catch {
                XCTAssertEqual((error as? URLError)?.code, failure)
            }
        }
    }

    @MainActor
    func testCancellingDocumentPreparationReleasesWaiterAndClosesLateOpen() async throws {
        let document = DelayedDocument(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("video.mp4"))
        let task = Task { try await document.prepare() }
        await fulfillment(of: [document.started], timeout: 2)
        task.cancel()
        do {
            try await task.value
            XCTFail("Cancelled preparation completed successfully")
        } catch is CancellationError {}
        document.completeOpen?(true)
        await fulfillment(of: [document.closed], timeout: 2)
    }

    func testCancellingWaitDoesNotOfferFallback() async {
        let task = Task {
            try await CloudVideoAvailability.waitForCurrent { (.downloaded, true, nil) }
        }
        task.cancel()
        do {
            try await task.value
            XCTFail("Cancelled download wait finished successfully")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}

private final class DelayedDocument: PlaybackDownloadDocument {
    let started = XCTestExpectation(description: "Provider received open")
    let closed = XCTestExpectation(description: "Late document closed")
    var completeOpen: ((Bool) -> Void)?

    override func open(completionHandler: ((Bool) -> Void)? = nil) {
        completeOpen = completionHandler
        started.fulfill()
    }

    override func close(completionHandler: ((Bool) -> Void)? = nil) {
        completionHandler?(true)
        closed.fulfill()
    }
}
