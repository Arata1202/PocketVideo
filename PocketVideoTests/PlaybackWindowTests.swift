import AVFoundation
import Combine
import MediaPlayer
import UIKit
import XCTest
@testable import PocketVideo

@MainActor
final class PlaybackWindowTests: XCTestCase {
    func testPlaybackControlsBecomeAvailableAtRestoredPosition() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        let model = PlayerViewModel()
        defer {
            model.closeCurrentVideo()
            try? FileManager.default.removeItem(at: url)
        }
        try writeTestMedia(to: url)
        let ready = expectation(description: "Player is available to the native controls")
        let observation = model.$hasVideo.filter { $0 }.first().sink { _ in
            XCTAssertEqual(model.player.currentTime().seconds, 6, accuracy: 0.1)
            ready.fulfill()
        }
        defer { observation.cancel() }

        XCTAssertTrue(model.open(url: url, resumePosition: 6))
        await fulfillment(of: [ready], timeout: 10)
    }

    func testClosingPreviouslyPausedWindowPreservesLatestPosition() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeTestMedia(to: url)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RecentVideoStore(userDefaults: defaults)
        let video = try await store.addOrUpdate(url: url)
        let first = PlayerViewModel()
        let second = PlayerViewModel()
        defer {
            first.closeCurrentVideo()
            second.closeCurrentVideo()
        }
        for (model, position) in [(first, 2.0), (second, 9.0)] {
            model.attachStore(store)
            XCTAssertTrue(model.open(url: url, resumePosition: position, recentVideoID: video.id))
            for _ in 0..<80 where !(model.player.currentTime().seconds > position + 0.1) {
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertGreaterThan(model.player.currentTime().seconds, position)
            model.player.pause()
            model.saveCurrentPosition()
        }
        second.closeCurrentVideo()
        let latest = try XCTUnwrap(store.videos.first?.lastPosition)
        first.closeCurrentVideo()
        XCTAssertGreaterThan(latest, 9)
        XCTAssertEqual(store.videos.first?.lastPosition, latest)
    }

    func testUntouchedPausedWindowPreservesOtherWindowsProgress() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeTestMedia(to: url)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RecentVideoStore(userDefaults: defaults)
        let row = try await store.addOrUpdate(url: url, position: 2)
        let model = PlayerViewModel()
        model.attachStore(store)
        for start in [0.0, 2.0] {
            let selection = model.audioInterruptionState
            model.pausePlayback()
            XCTAssertTrue(model.open(url: url, resumePosition: start, recentVideoID: row.id,
                                     audioStateAtSelection: selection))
            store.updatePosition(for: row.id, position: 9)
            for _ in 0..<80 where !model.hasVideo { try await Task.sleep(for: .milliseconds(50)) }
            try await Task.sleep(for: .milliseconds(150))
            let item = try XCTUnwrap(model.player.currentItem)
            NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
            XCTAssertEqual(model.player.timeControlStatus, .paused)
            model.closeCurrentVideo()
            XCTAssertEqual(store.videos.first?.lastPosition, 9)
        }
    }

    func testOpeningHistoryAtOrPastEndPlaysFromStart() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        let model = PlayerViewModel()
        defer {
            model.closeCurrentVideo()
            try? FileManager.default.removeItem(at: url)
        }
        try writeTestMedia(to: url)
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        for position in [duration, duration + 1] {
            XCTAssertTrue(model.open(url: url, resumePosition: position))
            for _ in 0..<80 {
                if model.isPlaying && model.player.currentTime().seconds > 0.1 { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertTrue(model.isPlaying)
            XCTAssertGreaterThan(model.player.currentTime().seconds, 0)
            XCTAssertLessThan(model.player.currentTime().seconds, 2)
            model.closeCurrentVideo()
        }
    }

    func testRemoteReplayAfterNaturalEndRestartsAndSavesTheNewPosition() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        let model = PlayerViewModel()
        defer {
            model.closeCurrentVideo()
            try? FileManager.default.removeItem(at: url)
        }
        try writeTestMedia(to: url)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RecentVideoStore(userDefaults: defaults)
        let video = try await store.addOrUpdate(url: url, position: 11)
        model.attachStore(store)
        XCTAssertTrue(model.open(url: url, resumePosition: 11, recentVideoID: video.id))
        for _ in 0..<100 where store.videos.first?.lastPosition != 0 {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(store.videos.first?.lastPosition, 0)
        XCTAssertGreaterThan(model.player.currentTime().seconds, 11)
        await model.skip(by: 10)
        XCTAssertEqual(store.videos.first?.lastPosition, 0)
        await model.resumePlayback()
        for _ in 0..<50 where !(model.player.currentTime().seconds > 0.1) {
            try await Task.sleep(for: .milliseconds(100))
        }
        model.closeCurrentVideo()
        let position = try XCTUnwrap(store.videos.first?.lastPosition)
        XCTAssertGreaterThan(position, 0)
        XCTAssertLessThan(position, 2)
    }

    func testExternalOutputSwitchesBackAndClosesAfterLastPlayer() async throws {
        try await verifyPlaybackRouting(closeSelectedFirst: true)
    }

    func testClosingBackgroundWindowKeepsSelectedPlayerAcrossReconnect() async throws {
        try await verifyPlaybackRouting(closeSelectedFirst: false)
    }

    func testHeadphoneDisconnectSupersedesPendingFullScreenResume() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        let model = PlayerViewModel()
        defer {
            model.closeCurrentVideo()
            try? FileManager.default.removeItem(at: url)
        }
        try writeTestMedia(to: url)
        XCTAssertTrue(model.open(url: url))
        for _ in 0..<80 where !model.isPlaying { try await Task.sleep(for: .milliseconds(100)) }
        let resume = try XCTUnwrap(model.fullScreenDismissalResumeAction())
        NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: AVAudioSession.sharedInstance(),
                                        userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
        resume()
        XCTAssertEqual(model.player.rate, 0)
    }

    func testInterruptionResumesUnlessAudioOutputWasDisconnected() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        let model = PlayerViewModel()
        defer {
            model.closeCurrentVideo()
            try? FileManager.default.removeItem(at: url)
        }
        try writeTestMedia(to: url)
        XCTAssertTrue(model.open(url: url))
        let session = AVAudioSession.sharedInstance()
        let center = NotificationCenter.default
        for disconnectOutput in [false, true] {
            for _ in 0..<80 where !model.isPlaying { try await Task.sleep(for: .milliseconds(100)) }
            XCTAssertTrue(model.isPlaying)
            center.post(name: AVAudioSession.interruptionNotification, object: session,
                        userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
            for _ in 0..<80 where model.isPlaying { try await Task.sleep(for: .milliseconds(100)) }
            XCTAssertFalse(model.isPlaying)
            if disconnectOutput {
                center.post(name: AVAudioSession.routeChangeNotification, object: session,
                            userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
            }
            center.post(name: AVAudioSession.interruptionNotification, object: session, userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue
            ])
        }
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(model.player.timeControlStatus, .paused)
    }

    func testInterruptionDuringPreparationDefersAutoplayUntilAllowed() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        let model = PlayerViewModel()
        defer {
            model.closeCurrentVideo()
            try? FileManager.default.removeItem(at: url)
        }
        try writeTestMedia(to: url)
        let session = AVAudioSession.sharedInstance()
        let center = NotificationCenter.default
        for (position, allowResume) in [(0.0, true), (3.0, true), (3.0, false)] {
            XCTAssertTrue(model.open(url: url, resumePosition: position))
            center.post(name: AVAudioSession.interruptionNotification, object: session,
                        userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
            for _ in 0..<80 {
                if model.hasVideo && model.player.currentTime().seconds >= position { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertTrue(model.hasVideo)
            XCTAssertGreaterThanOrEqual(model.player.currentTime().seconds, position)
            XCTAssertEqual(model.player.timeControlStatus, .paused)
            center.post(name: AVAudioSession.interruptionNotification, object: session, userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                AVAudioSessionInterruptionOptionKey: allowResume ? AVAudioSession.InterruptionOptions.shouldResume.rawValue : 0
            ])
            if allowResume {
                for _ in 0..<80 where !model.isPlaying { try await Task.sleep(for: .milliseconds(100)) }
                XCTAssertTrue(model.isPlaying)
            } else {
                try await Task.sleep(for: .milliseconds(350))
                XCTAssertEqual(model.player.timeControlStatus, .paused)
            }
        }
    }

    func testExplicitSelectionCanRecoverWithoutInterruptionEnd() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        let model = PlayerViewModel()
        defer {
            model.closeCurrentVideo()
            try? FileManager.default.removeItem(at: url)
        }
        try writeTestMedia(to: url)
        func beginInterruption() {
            NotificationCenter.default.post(name: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        }
        beginInterruption()
        let earlierSelection = model.audioInterruptionState
        beginInterruption()
        XCTAssertTrue(model.open(url: url, audioStateAtSelection: earlierSelection))
        for _ in 0..<80 where !model.hasVideo { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(model.hasVideo)
        XCTAssertEqual(model.player.timeControlStatus, .paused)

        let newSelection = model.audioInterruptionState
        XCTAssertTrue(model.open(url: url, audioStateAtSelection: newSelection))
        for _ in 0..<80 where !model.isPlaying { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(model.isPlaying)
        XCTAssertNil(model.audioInterruptionState.currentID)
    }

    func testDelayedOpenHonorsInterruptionEndUntilUserSelectsAgain() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        let model = PlayerViewModel()
        defer {
            model.closeCurrentVideo()
            try? FileManager.default.removeItem(at: url)
        }
        try writeTestMedia(to: url)
        let session = AVAudioSession.sharedInstance()
        let center = NotificationCenter.default
        for allowResume in [false, true] {
            let selection = model.audioInterruptionState
            center.post(name: AVAudioSession.interruptionNotification, object: session,
                        userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
            center.post(name: AVAudioSession.interruptionNotification, object: session, userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                AVAudioSessionInterruptionOptionKey: allowResume ? AVAudioSession.InterruptionOptions.shouldResume.rawValue : 0
            ])
            XCTAssertTrue(model.open(url: url, audioStateAtSelection: selection))
            if !allowResume {
                for _ in 0..<80 where !model.hasVideo { try await Task.sleep(for: .milliseconds(100)) }
                XCTAssertTrue(model.hasVideo)
                try await Task.sleep(for: .milliseconds(350))
                XCTAssertEqual(model.player.timeControlStatus, .paused)
                XCTAssertTrue(model.open(url: url, audioStateAtSelection: model.audioInterruptionState))
            }
            for _ in 0..<80 where !model.isPlaying { try await Task.sleep(for: .milliseconds(100)) }
            XCTAssertTrue(model.isPlaying)
            model.closeCurrentVideo()
        }
    }

    func testPauseDuringFilePreparationPreventsAutoplayUntilNextSelection() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        let model = PlayerViewModel()
        defer {
            model.closeCurrentVideo()
            try? FileManager.default.removeItem(at: url)
        }
        try writeTestMedia(to: url)
        XCTAssertTrue(model.open(url: url))
        for _ in 0..<80 where !model.isPlaying { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(model.isPlaying)

        let pendingSelection = model.audioInterruptionState
        model.pausePlayback()
        XCTAssertTrue(model.open(url: url, audioStateAtSelection: pendingSelection))
        for _ in 0..<80 where !model.hasVideo { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(model.hasVideo)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(model.player.timeControlStatus, .paused)

        XCTAssertTrue(model.open(url: url, audioStateAtSelection: model.audioInterruptionState))
        for _ in 0..<80 where !model.isPlaying { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(model.isPlaying)
    }

    func testDelayedOpenAfterOutputDisconnectWaitsForNewSelection() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        let model = PlayerViewModel()
        defer {
            model.closeCurrentVideo()
            try? FileManager.default.removeItem(at: url)
        }
        try writeTestMedia(to: url)
        let selection = model.audioInterruptionState
        NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
        XCTAssertTrue(model.open(url: url, audioStateAtSelection: selection))
        for _ in 0..<80 where !model.hasVideo { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(model.hasVideo)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(model.player.timeControlStatus, .paused)

        XCTAssertTrue(model.open(url: url, audioStateAtSelection: model.audioInterruptionState))
        for _ in 0..<80 where !model.isPlaying { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(model.isPlaying)
    }

    private func verifyPlaybackRouting(closeSelectedFirst: Bool) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let existingWindows = Set(scene.windows.map(ObjectIdentifier.init))
        let output = ExternalDisplayPlaybackCoordinator.shared
        let first = PlayerViewModel()
        let second = PlayerViewModel()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer {
            first.closeCurrentVideo()
            second.closeCurrentVideo()
            output.disconnect(windowScene: scene)
            try? FileManager.default.removeItem(at: url)
        }
        try writeTestMedia(to: url)
        output.connect(windowScene: scene)

        func currentLayer() throws -> AVPlayerLayer {
            let outputLayers = scene.windows.compactMap { window -> AVPlayerLayer? in
                guard !window.isHidden, !existingWindows.contains(ObjectIdentifier(window)) else { return nil }
                return window.rootViewController?.viewIfLoaded?.layer as? AVPlayerLayer
            }
            XCTAssertEqual(outputLayers.count, 1)
            return try XCTUnwrap(outputLayers.first)
        }
        func checkOwner(_ model: PlayerViewModel, title: String) throws {
            XCTAssertTrue(try currentLayer().player === model.player)
            XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, title)
            XCTAssertTrue(MPRemoteCommandCenter.shared().pauseCommand.isEnabled)
        }
        for (model, title) in [(first, "First"), (second, "Second")] {
            XCTAssertTrue(model.open(url: url, displayTitle: title))
            for _ in 0..<80 where !model.isPlaying { try await Task.sleep(for: .milliseconds(100)) }
            XCTAssertTrue(model.isPlaying)
            try checkOwner(model, title: title)
        }
        let remaining = closeSelectedFirst ? first : second
        let title = closeSelectedFirst ? "First" : "Second"
        if closeSelectedFirst { second.closeCurrentVideo() } else { first.closeCurrentVideo() }
        try checkOwner(remaining, title: title)
        let previousLayer = try currentLayer()
        output.disconnect(windowScene: scene)
        XCTAssertNil(previousLayer.player)
        output.connect(windowScene: scene)
        try checkOwner(remaining, title: title)
        let finalLayer = try currentLayer()
        remaining.closeCurrentVideo()
        XCTAssertNil(finalLayer.player)
        XCTAssertFalse(MPRemoteCommandCenter.shared().pauseCommand.isEnabled)
    }

    private func writeTestMedia(to url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96000))
        buffer.frameLength = buffer.frameCapacity
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        samples.update(repeating: 0, count: Int(buffer.frameLength))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
