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
    @Published var currentPlaybackPosition: TimeInterval = 0
    @Published var videoAspectRatio: CGFloat?

    private var timeObserver: Any?
    private var playbackEndObserver: NSObjectProtocol?
    private var playerItemStatusObservation: NSKeyValueObservation?
    private var aspectRatioLoadTask: Task<Void, Never>?
    private var loadingIndicatorTask: Task<Void, Never>?
    private var scopedURL: URL?
    private weak var recentStore: RecentVideoStore?
    private var lastPositionSaveAt = Date.distantPast
    private var didFinishPlayback = false

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
        saveCurrentPosition()
        isLoading = true
        errorMessage = nil
        aspectRatioLoadTask?.cancel()
        scheduleLoadingIndicator()
        removePeriodicTimeObserver()
        player.pause()

        stopSecurityScopedAccess()
        if url.startAccessingSecurityScopedResource() {
            scopedURL = url
        }

        currentRecentVideoID = recentVideoID
        currentVideoTitle = displayTitle ?? url.lastPathComponent
        currentPlaybackPosition = resumePosition
        lastPositionSaveAt = .distantPast
        didFinishPlayback = false

        let asset = AVURLAsset(url: url)
        aspectRatioLoadTask = Task { [weak self] in
            let aspectRatio = await Self.videoAspectRatio(from: asset) ?? (16.0 / 9.0)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self else { return }

                let item = AVPlayerItem(asset: asset)
                item.externalMetadata = Self.metadataItems(title: self.currentVideoTitle ?? url.lastPathComponent)
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
        removePeriodicTimeObserver()
        playerItemStatusObservation?.invalidate()
        playerItemStatusObservation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        hasVideo = false
        isLoading = false
        showsLoadingIndicator = false
        currentRecentVideoID = nil
        currentVideoTitle = nil
        currentPlaybackPosition = 0
        videoAspectRatio = nil
        lastPositionSaveAt = .distantPast
        didFinishPlayback = false
        clearNowPlayingInfo()
        stopSecurityScopedAccess()
    }

    func saveCurrentPosition() {
        guard let id = currentRecentVideoID else { return }
        if didFinishPlayback {
            currentPlaybackPosition = 0
            recentStore?.updatePosition(for: id, position: 0)
            return
        }

        let seconds = player.currentTime().seconds
        guard seconds.isFinite else { return }
        currentPlaybackPosition = seconds
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
        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.preferredIntervals = [NSNumber(value: 10)]
        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.preferredIntervals = [NSNumber(value: 10)]

        commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.didFinishPlayback = false
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
                    self.didFinishPlayback = false
                    self.player.play()
                } else {
                    self.player.pause()
                    self.saveCurrentPosition()
                }
                self.updateNowPlayingInfo()
            }
            return .success
        }

        commandCenter.skipForwardCommand.addTarget { [weak self] event in
            guard let event = event as? MPSkipIntervalCommandEvent else { return .commandFailed }

            Task { @MainActor in
                self?.skip(by: event.interval)
            }
            return .success
        }

        commandCenter.skipBackwardCommand.addTarget { [weak self] event in
            guard let event = event as? MPSkipIntervalCommandEvent else { return .commandFailed }

            Task { @MainActor in
                self?.skip(by: -event.interval)
            }
            return .success
        }
    }

    private func updateNowPlayingInfo(elapsedTime overrideElapsedTime: TimeInterval? = nil, playbackRate overridePlaybackRate: Float? = nil) {
        guard hasVideo || currentVideoTitle != nil else {
            clearNowPlayingInfo()
            return
        }

        var nowPlayingInfo: [String: Any] = [
            MPMediaItemPropertyTitle: currentVideoTitle ?? "Pocket Video",
            MPNowPlayingInfoPropertyPlaybackRate: overridePlaybackRate ?? player.rate
        ]

        let elapsedTime = overrideElapsedTime ?? player.currentTime().seconds
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

    private func skip(by interval: TimeInterval) {
        let currentSeconds = player.currentTime().seconds
        guard currentSeconds.isFinite else { return }

        var targetSeconds = max(currentSeconds + interval, 0)
        if let duration = player.currentItem?.duration.seconds, duration.isFinite {
            targetSeconds = min(targetSeconds, duration)
        }
        let targetTime = CMTime(seconds: targetSeconds, preferredTimescale: 600)

        player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                self?.didFinishPlayback = false
                self?.currentPlaybackPosition = targetSeconds
                self?.saveCurrentPosition()
                self?.updateNowPlayingInfo()
            }
        }
    }

    private static func metadataItems(title: String) -> [AVMetadataItem] {
        let titleItem = AVMutableMetadataItem()
        titleItem.identifier = .commonIdentifierTitle
        titleItem.value = title as NSString
        titleItem.extendedLanguageTag = "und"
        return [titleItem]
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
        removePeriodicTimeObserver()

        let interval = CMTime(seconds: 1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.updateCurrentPlaybackPosition()
                if Date().timeIntervalSince(self.lastPositionSaveAt) >= 5 {
                    self.saveCurrentPosition()
                    self.lastPositionSaveAt = Date()
                }
                self.updateNowPlayingInfo()
            }
        }
    }

    private func updateCurrentPlaybackPosition() {
        guard !didFinishPlayback else { return }
        let seconds = player.currentTime().seconds
        guard seconds.isFinite else { return }
        currentPlaybackPosition = seconds
    }

    private func markPlaybackCompleted() {
        guard let id = currentRecentVideoID else { return }
        didFinishPlayback = true
        currentPlaybackPosition = 0
        recentStore?.updatePosition(for: id, position: 0)
        updateNowPlayingInfo(elapsedTime: 0, playbackRate: 0)
    }

    private func removePeriodicTimeObserver() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
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
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self, notification.object as? AVPlayerItem === self.player.currentItem else { return }
                self.markPlaybackCompleted()
            }
        }
    }
}
