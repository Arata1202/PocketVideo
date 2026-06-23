import AVFoundation
import AVKit
import Foundation
import SwiftUI

@MainActor
final class PlayerViewModel: ObservableObject {
    @Published var player = AVPlayer()
    @Published var title = "No Video"
    @Published var isLoading = false
    @Published var isPlaying = false
    @Published var errorMessage: String?
    @Published var isAirPlayActive = false
    @Published var currentRecentVideoID: RecentVideo.ID?

    private var timeObserver: Any?
    private var timeControlObserver: NSKeyValueObservation?
    private var routeObserver: NSObjectProtocol?
    private var playbackEndObserver: NSObjectProtocol?
    private var scopedURL: URL?
    private weak var recentStore: RecentVideoStore?

    init() {
        configureAudioSession()
        observePlaybackState()
        addRouteObserver()
        addPlaybackEndObserver()
        updateAirPlayState()
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        stopSecurityScopedAccess()
        if let routeObserver {
            NotificationCenter.default.removeObserver(routeObserver)
        }
        if let playbackEndObserver {
            NotificationCenter.default.removeObserver(playbackEndObserver)
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

        title = url.lastPathComponent
        currentRecentVideoID = recentVideoID

        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)

        if resumePosition > 0 {
            let time = CMTime(seconds: resumePosition, preferredTimescale: 600)
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        }

        addPeriodicTimeObserver()
        isLoading = false
    }

    func playPause() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    func skip(seconds: Double) {
        let current = player.currentTime().seconds
        guard current.isFinite else { return }
        let next = max(current + seconds, 0)
        player.seek(to: CMTime(seconds: next, preferredTimescale: 600))
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

        let interval = CMTime(seconds: 5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.saveCurrentPosition()
            }
        }
    }

    private func observePlaybackState() {
        timeControlObserver = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let isPlaying = player.timeControlStatus == .playing
            Task { @MainActor in
                self?.isPlaying = isPlaying
            }
        }
    }

    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.allowAirPlay])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            errorMessage = "Audio session setup failed."
        }
    }

    private func addRouteObserver() {
        routeObserver = NotificationCenter.default.addObserver(
            name: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateAirPlayState()
            }
        }
    }

    private func addPlaybackEndObserver() {
        playbackEndObserver = NotificationCenter.default.addObserver(
            name: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isPlaying = false
                self?.saveCurrentPosition()
            }
        }
    }

    private func updateAirPlayState() {
        isAirPlayActive = AVAudioSession.sharedInstance().currentRoute.outputs.contains { output in
            output.portType == .airPlay
        }
    }
}
