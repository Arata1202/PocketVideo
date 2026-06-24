import AVFoundation
import AVKit
import Foundation
import SwiftUI

@MainActor
final class PlayerViewModel: ObservableObject {
    @Published var player = AVPlayer()
    @Published var hasVideo = false
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var currentRecentVideoID: RecentVideo.ID?
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0

    private var timeObserver: Any?
    private var playbackEndObserver: NSObjectProtocol?
    private var scopedURL: URL?
    private weak var recentStore: RecentVideoStore?
    private var lastPositionSaveAt = Date.distantPast

    init() {
        player.allowsExternalPlayback = true
        configureAudioSession()
        addPlaybackEndObserver()
    }

    deinit {
        MainActor.assumeIsolated {
            if let timeObserver {
                player.removeTimeObserver(timeObserver)
            }
            stopSecurityScopedAccess()
            if let playbackEndObserver {
                NotificationCenter.default.removeObserver(playbackEndObserver)
            }
        }
    }

    func attachStore(_ store: RecentVideoStore) {
        recentStore = store
    }

    func open(url: URL, resumePosition: TimeInterval = 0, recentVideoID: RecentVideo.ID? = nil) {
        isLoading = true
        errorMessage = nil

        stopSecurityScopedAccess()
        if url.startAccessingSecurityScopedResource() {
            scopedURL = url
        }

        hasVideo = true
        currentRecentVideoID = recentVideoID
        currentTime = 0
        duration = 0
        isPlaying = false
        lastPositionSaveAt = .distantPast

        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)

        if resumePosition > 0 {
            let time = CMTime(seconds: resumePosition, preferredTimescale: 600)
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        }

        addPeriodicTimeObserver()
        isLoading = false
    }

    func togglePlayback() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    func seek(by seconds: TimeInterval) {
        let targetSeconds = max(0, min(currentTime + seconds, duration))
        seek(to: targetSeconds)
    }

    func seek(to seconds: TimeInterval) {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = seconds
    }

    func saveCurrentPosition() {
        guard let id = currentRecentVideoID else { return }
        let seconds = player.currentTime().seconds
        guard seconds.isFinite else { return }
        recentStore?.updatePosition(for: id, position: seconds)
    }

    private func stopSecurityScopedAccess() {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
    }

    func setError(_ message: String) {
        errorMessage = message
        isLoading = false
    }

    private func addPeriodicTimeObserver() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }

        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.syncPlaybackState()
                if Date().timeIntervalSince(self.lastPositionSaveAt) >= 5 {
                    self.saveCurrentPosition()
                    self.lastPositionSaveAt = Date()
                }
            }
        }
    }

    private func syncPlaybackState() {
        let seconds = player.currentTime().seconds
        if seconds.isFinite {
            currentTime = seconds
        }

        let itemDuration = player.currentItem?.duration.seconds ?? 0
        if itemDuration.isFinite {
            duration = itemDuration
        }

        isPlaying = player.timeControlStatus == .playing
    }

    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.allowAirPlay])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // Playback can still be attempted even if the session is not ready at launch.
            // File-open errors are the only failures surfaced through the video alert.
        }
    }

    private func addPlaybackEndObserver() {
        playbackEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isPlaying = false
                self?.saveCurrentPosition()
            }
        }
    }
}
