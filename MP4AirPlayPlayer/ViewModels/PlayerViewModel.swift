import AVFoundation
import AVKit
import Foundation
import MediaPlayer
import SwiftUI

@MainActor
final class PlayerViewModel: ObservableObject {
    @Published var player = AVPlayer()
    @Published var hasVideo = false
    @Published var isLoading = false
    @Published var showsLoadingIndicator = false
    @Published var errorMessage: String?
    @Published var currentRecentVideoID: RecentVideo.ID?
    @Published var currentVideoTitle: String?
    @Published var videoAspectRatio: CGFloat?

    private var timeObserver: Any?
    private var playbackEndObserver: NSObjectProtocol?
    private var playerItemStatusObservation: NSKeyValueObservation?
    private var aspectRatioLoadTask: Task<Void, Never>?
    private var loadingIndicatorTask: Task<Void, Never>?
    private var scopedURL: URL?
    private weak var recentStore: RecentVideoStore?
    private var lastPositionSaveAt = Date.distantPast

    init() {
        player.allowsExternalPlayback = true
        configureAudioSession()
        configureRemoteCommands()
        addPlaybackEndObserver()
    }

    deinit {
        MainActor.assumeIsolated {
            if let timeObserver {
                player.removeTimeObserver(timeObserver)
            }
            playerItemStatusObservation?.invalidate()
            aspectRatioLoadTask?.cancel()
            loadingIndicatorTask?.cancel()
            stopSecurityScopedAccess()
            if let playbackEndObserver {
                NotificationCenter.default.removeObserver(playbackEndObserver)
            }
        }
    }

    func attachStore(_ store: RecentVideoStore) {
        recentStore = store
    }

    func open(url: URL, resumePosition: TimeInterval = 0, recentVideoID: RecentVideo.ID? = nil, displayTitle: String? = nil) {
        isLoading = true
        errorMessage = nil
        aspectRatioLoadTask?.cancel()
        scheduleLoadingIndicator()

        stopSecurityScopedAccess()
        if url.startAccessingSecurityScopedResource() {
            scopedURL = url
        }

        currentRecentVideoID = recentVideoID
        currentVideoTitle = displayTitle ?? url.lastPathComponent
        lastPositionSaveAt = .distantPast

        let asset = AVURLAsset(url: url)
        aspectRatioLoadTask = Task { [weak self] in
            let aspectRatio = await Self.videoAspectRatio(from: asset) ?? (16.0 / 9.0)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self else { return }

                let item = AVPlayerItem(asset: asset)
                self.videoAspectRatio = aspectRatio
                self.observePlayerItemStatus(item)
                self.player.replaceCurrentItem(with: item)

                if resumePosition > 0 {
                    let time = CMTime(seconds: resumePosition, preferredTimescale: 600)
                    self.player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                        Task { @MainActor in
                            self?.player.play()
                            self?.updateNowPlayingInfo()
                        }
                    }
                } else {
                    self.player.play()
                    self.updateNowPlayingInfo()
                }

                self.hasVideo = true
                self.addPeriodicTimeObserver()
                self.finishLoading()
            }
        }
    }

    func closeCurrentVideo() {
        saveCurrentPosition()
        aspectRatioLoadTask?.cancel()
        loadingIndicatorTask?.cancel()
        playerItemStatusObservation?.invalidate()
        playerItemStatusObservation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        hasVideo = false
        isLoading = false
        showsLoadingIndicator = false
        currentRecentVideoID = nil
        currentVideoTitle = nil
        videoAspectRatio = nil
        lastPositionSaveAt = .distantPast
        clearNowPlayingInfo()
        stopSecurityScopedAccess()
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
        finishLoading()
    }

    private func scheduleLoadingIndicator() {
        loadingIndicatorTask?.cancel()
        showsLoadingIndicator = false

        loadingIndicatorTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self, self.isLoading else { return }
                self.showsLoadingIndicator = true
            }
        }
    }

    private func finishLoading() {
        isLoading = false
        loadingIndicatorTask?.cancel()
        showsLoadingIndicator = false
    }

    private func observePlayerItemStatus(_ item: AVPlayerItem) {
        playerItemStatusObservation?.invalidate()
        playerItemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }

            Task { @MainActor in
                self?.setError("この動画は再生できません。対応拡張子でも、動画のコーデックによっては再生できない場合があります。")
            }
        }
    }

    private func configureRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true

        commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.player.play()
                self?.updateNowPlayingInfo()
            }
            return .success
        }

        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.player.pause()
                self?.saveCurrentPosition()
                self?.updateNowPlayingInfo()
            }
            return .success
        }

        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.player.rate == 0 {
                    self.player.play()
                } else {
                    self.player.pause()
                    self.saveCurrentPosition()
                }
                self.updateNowPlayingInfo()
            }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        guard hasVideo || currentVideoTitle != nil else {
            clearNowPlayingInfo()
            return
        }

        var nowPlayingInfo: [String: Any] = [
            MPMediaItemPropertyTitle: currentVideoTitle ?? "Pocket Video",
            MPNowPlayingInfoPropertyPlaybackRate: player.rate
        ]

        let elapsedTime = player.currentTime().seconds
        if elapsedTime.isFinite {
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsedTime
        }

        if let duration = player.currentItem?.duration.seconds, duration.isFinite {
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    private func clearNowPlayingInfo() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private nonisolated static func videoAspectRatio(from asset: AVURLAsset) async -> CGFloat? {
        do {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else { return nil }
            let naturalSize = try await track.load(.naturalSize)
            let preferredTransform = try await track.load(.preferredTransform)
            let transformedSize = naturalSize.applying(preferredTransform)
            let width = abs(transformedSize.width)
            let height = abs(transformedSize.height)
            guard width > 0, height > 0 else { return nil }
            return width / height
        } catch {
            return nil
        }
    }

    private func addPeriodicTimeObserver() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }

        let interval = CMTime(seconds: 5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if Date().timeIntervalSince(self.lastPositionSaveAt) >= 5 {
                    self.saveCurrentPosition()
                    self.lastPositionSaveAt = Date()
                }
                self.updateNowPlayingInfo()
            }
        }
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
                self?.saveCurrentPosition()
            }
        }
    }
}
