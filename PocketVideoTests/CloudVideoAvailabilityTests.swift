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
