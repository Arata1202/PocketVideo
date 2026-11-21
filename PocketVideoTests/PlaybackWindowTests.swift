import AVFoundation
import UIKit
import XCTest
@testable import PocketVideo

@MainActor
final class PlaybackWindowTests: XCTestCase {
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

    func testExternalOutputSwitchesBackAndClosesAfterLastPlayer() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let existingWindows = Set(scene.windows.map(ObjectIdentifier.init))
        let output = ExternalDisplayPlaybackCoordinator.shared
        let first = AVPlayer()
        let second = AVPlayer()
        output.connect(windowScene: scene)
        defer {
            output.update(player: second, isEnabled: false)
            output.update(player: first, isEnabled: false)
            output.disconnect(windowScene: scene)
        }
        output.update(player: first, isEnabled: true)
        let window = try XCTUnwrap(scene.windows.first { !existingWindows.contains(ObjectIdentifier($0)) })
        let layer = try XCTUnwrap(window.rootViewController?.view.layer as? AVPlayerLayer)
        output.update(player: second, isEnabled: true)
        XCTAssertTrue(layer.player === second)
        output.update(player: second, isEnabled: false)
        XCTAssertFalse(window.isHidden)
        XCTAssertTrue(layer.player === first)
        output.update(player: first, isEnabled: false)
        XCTAssertTrue(window.isHidden)
        XCTAssertNil(layer.player)
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
