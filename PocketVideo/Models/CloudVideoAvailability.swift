import Foundation

enum CloudVideoAvailability {
    case local, current, stale, pending, unknown

    init(isUbiquitous: Bool, status: URLUbiquitousItemDownloadingStatus?) {
        guard isUbiquitous else { self = .local; return }
        switch status {
        case .current: self = .current
        case .downloaded: self = .stale
        default: self = .pending
        }
    }

    func needsDownload(allowsLocalCopy: Bool) -> Bool {
        self == .pending || ((self == .stale || self == .unknown) && !allowsLocalCopy)
    }

    // URL caches resource values. Each observation must see the provider's latest state.
    private static func resourceValues(at url: URL) throws -> URLResourceValues {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        return try fresh.resourceValues(forKeys: [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemIsDownloadingKey, .ubiquitousItemDownloadingErrorKey
        ])
    }

    static func read(at url: URL) throws -> Self {
        let values = try resourceValues(at: url)
        // Ordinary local files can omit the optional iCloud resource key.
        let status = values.ubiquitousItemDownloadingStatus
        let ubiquitous = values.isUbiquitousItem ?? (status != nil || FileManager.default.isUbiquitousItem(at: url))
        return Self(isUbiquitous: ubiquitous, status: status)
    }

    static func downloadLatest(at url: URL, offerLocalCopy: @escaping @MainActor () -> Void) async throws {
        try Task.checkCancellation()
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
        try await waitForCurrent(offerLocalCopy: offerLocalCopy) {
            let values = try resourceValues(at: url)
            return (values.ubiquitousItemDownloadingStatus, values.ubiquitousItemIsDownloading == true,
                    values.ubiquitousItemDownloadingError)
        }
    }

    // An offline request can remain queued without an error. Bound idle time,
    // while giving active transfers as much time as they need.
    static func waitForCurrent(
        idleTimeout: Duration = .seconds(30),
        pollInterval: Duration = .milliseconds(500),
        offerLocalCopy: @MainActor () -> Void = {},
        observe: () throws -> (status: URLUbiquitousItemDownloadingStatus?, downloading: Bool, error: Error?)
    ) async throws {
        let clock = ContinuousClock()
        let started = clock.now
        var idleSince = started
        var offeredLocalCopy = false
        while true {
            try Task.checkCancellation()
            let state = try observe()
            if state.status == .current { return }
            if let error = state.error { throw error }
            if !offeredLocalCopy, state.status == .downloaded, started.duration(to: clock.now) >= idleTimeout {
                offeredLocalCopy = true
                await offerLocalCopy()
            }
            if state.downloading {
                idleSince = clock.now
            } else if idleSince.duration(to: clock.now) >= idleTimeout {
                throw URLError(.timedOut)
            }
            try await Task.sleep(for: pollInterval)
        }
    }
}
