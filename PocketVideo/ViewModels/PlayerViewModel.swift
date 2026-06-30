import AVFoundation
import Combine
import CoreGraphics
import Foundation
import MediaPlayer

@MainActor
final class PlayerViewModel: ObservableObject {
    @Published var player = AVPlayer()
    @Published var hasVideo = false
    @Published var isLoading = false
    @Published var showsLoadingIndicator = false
    @Published var playbackAlert: PlaybackAlert?
    @Published var currentRecentVideoID: RecentVideo.ID?
    @Published var currentVideoTitle: String?
    @Published var currentPlaybackPosition: TimeInterval = 0
    @Published var videoAspectRatio: CGFloat?

    private struct RemoteCommandTarget {
        let command: MPRemoteCommand
        let target: Any
    }

    private var timeObserver: Any?
    private var playbackEndObserver: NSObjectProtocol?
    private var playbackFailureObserver: NSObjectProtocol?
    private var playerItemStatusObservation: NSKeyValueObservation?
    private var playerTimeControlStatusObservation: NSKeyValueObservation?
    private var externalPlaybackObservation: NSKeyValueObservation?
    private var aspectRatioLoadTask: Task<Void, Never>?
    private var loadingIndicatorTask: Task<Void, Never>?
    private var remoteCommandTargets: [RemoteCommandTarget] = []
    private var scopedURL: URL?
    private weak var recentStore: RecentVideoStore?
    private var lastPositionSaveAt = Date.distantPast
    private let positionSaveInterval: TimeInterval = 1
    private var didFinishPlayback = false
    private var didUseExternalPlayback = false
    private var openRequestID = UUID()
    private var canSaveCurrentPosition = false

    init() {
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = false
        player.externalPlaybackVideoGravity = .resizeAspect
        configureAudioSession()
        configureRemoteCommands()
        observePlayerPlaybackState()
        addPlaybackObservers()
    }

    deinit {
        MainActor.assumeIsolated {
            if let timeObserver {
                player.removeTimeObserver(timeObserver)
            }
            playerItemStatusObservation?.invalidate()
            playerTimeControlStatusObservation?.invalidate()
            externalPlaybackObservation?.invalidate()
            aspectRatioLoadTask?.cancel()
            loadingIndicatorTask?.cancel()
            removeRemoteCommandTargets()
            stopSecurityScopedAccess()
            if let playbackEndObserver {
                NotificationCenter.default.removeObserver(playbackEndObserver)
            }
            if let playbackFailureObserver {
                NotificationCenter.default.removeObserver(playbackFailureObserver)
            }
        }
    }

    func attachStore(_ store: RecentVideoStore) {
        recentStore = store
    }

    @discardableResult
    func open(url: URL, resumePosition: TimeInterval = 0, recentVideoID: RecentVideo.ID? = nil, displayTitle: String? = nil) -> Bool {
        let requestID = UUID()
        openRequestID = requestID
        saveCurrentPosition()
        isLoading = true
        playbackAlert = nil
        aspectRatioLoadTask?.cancel()
        scheduleLoadingIndicator()
        removePeriodicTimeObserver()
        playerItemStatusObservation?.invalidate()
        playerItemStatusObservation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        clearNowPlayingInfo()
        setRemoteCommandsEnabled(false)

        stopSecurityScopedAccess()
        hasVideo = false
        currentRecentVideoID = nil
        currentVideoTitle = nil
        currentPlaybackPosition = 0
        lastPositionSaveAt = .distantPast
        didFinishPlayback = false
        didUseExternalPlayback = false
        canSaveCurrentPosition = false

        if url.startAccessingSecurityScopedResource() {
            scopedURL = url
        } else if !FileManager.default.isReadableFile(atPath: url.path) {
            showAlert(.fileAccessFailed)
            return false
        }

        currentRecentVideoID = recentVideoID
        currentVideoTitle = displayTitle ?? url.lastPathComponent
        currentPlaybackPosition = resumePosition
        lastPositionSaveAt = .distantPast
        didFinishPlayback = false
        didUseExternalPlayback = false
        canSaveCurrentPosition = false

        let asset = AVURLAsset(url: url)
        aspectRatioLoadTask = Task { [weak self] in
            let aspectRatio = await Self.videoAspectRatio(from: asset) ?? (16.0 / 9.0)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self, self.openRequestID == requestID else { return }

                let item = AVPlayerItem(asset: asset)
                item.externalMetadata = Self.metadataItems(title: self.currentVideoTitle ?? url.lastPathComponent)
                self.videoAspectRatio = aspectRatio
                self.observePlayerItemStatus(item, resumePosition: resumePosition)
                self.player.replaceCurrentItem(with: item)
            }
        }

        return true
    }

    func closeCurrentVideo() {
        openRequestID = UUID()
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
        didUseExternalPlayback = false
        canSaveCurrentPosition = false
        clearNowPlayingInfo()
        setRemoteCommandsEnabled(false)
        stopSecurityScopedAccess()
    }

    func saveCurrentPosition() {
        guard let id = currentRecentVideoID else { return }
        guard canSaveCurrentPosition else { return }
        let seconds = player.currentTime().seconds

        if didFinishPlayback, seconds.isFinite, !isAtPlaybackEnd(seconds) {
            didFinishPlayback = false
        }

        if didFinishPlayback {
            currentPlaybackPosition = 0
            recentStore?.updatePosition(for: id, position: 0)
            return
        }

        guard seconds.isFinite else { return }
        currentPlaybackPosition = seconds
        recentStore?.updatePosition(for: id, position: seconds)
    }

    private func stopSecurityScopedAccess() {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
    }

    func clearAlert() {
        playbackAlert = nil
    }

    func showAlert(_ alert: PlaybackAlert) {
        playbackAlert = alert
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

    private func observePlayerItemStatus(_ item: AVPlayerItem, resumePosition: TimeInterval) {
        playerItemStatusObservation?.invalidate()
        var didStartPlayback = false

        playerItemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self, weak item] observedItem, _ in
            Task { @MainActor in
                guard let self, let item, observedItem === item, self.player.currentItem === item else { return }

                switch observedItem.status {
                case .readyToPlay:
                    guard !didStartPlayback else { return }
                    didStartPlayback = true
                    self.startPlayback(item: item, resumePosition: resumePosition)
                case .failed:
                    self.handlePlayerItemFailure()
                default:
                    break
                }
            }
        }
    }

    private func startPlayback(item: AVPlayerItem, resumePosition: TimeInterval) {
        guard player.currentItem === item else { return }

        hasVideo = true
        didFinishPlayback = false
        setRemoteCommandsEnabled(true)
        addPeriodicTimeObserver()
        finishLoading()

        if resumePosition > 0 {
            let time = CMTime(seconds: resumePosition, preferredTimescale: 600)
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.hasVideo, self.player.currentItem === item else { return }
                    self.canSaveCurrentPosition = true
                    let seconds = self.player.currentTime().seconds
                    self.currentPlaybackPosition = seconds.isFinite ? seconds : resumePosition
                    self.player.play()
                    self.updateNowPlayingInfo()
                }
            }
        } else {
            canSaveCurrentPosition = true
            player.play()
            updateNowPlayingInfo()
        }
    }

    private func handlePlayerItemFailure() {
        removePeriodicTimeObserver()
        player.pause()
        player.replaceCurrentItem(with: nil)
        hasVideo = false
        currentPlaybackPosition = 0
        videoAspectRatio = nil
        canSaveCurrentPosition = false
        clearNowPlayingInfo()
        setRemoteCommandsEnabled(false)
        showAlert(playbackFailureAlert)
    }

    private var playbackFailureAlert: PlaybackAlert {
        if player.isExternalPlaybackActive || didUseExternalPlayback {
            return .airPlayPlaybackFailed
        }

        return .localPlaybackFailed
    }

    private func configureRemoteCommands() {
        removeRemoteCommandTargets()

        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.preferredIntervals = [NSNumber(value: 10)]
        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.preferredIntervals = [NSNumber(value: 10)]

        let playTarget = commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.didFinishPlayback = false
                self?.player.play()
                self?.updateNowPlayingInfo()
            }
            return .success
        }
        remoteCommandTargets.append(RemoteCommandTarget(command: commandCenter.playCommand, target: playTarget))

        let pauseTarget = commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.player.pause()
                self?.saveCurrentPosition()
                self?.updateNowPlayingInfo()
            }
            return .success
        }
        remoteCommandTargets.append(RemoteCommandTarget(command: commandCenter.pauseCommand, target: pauseTarget))

        let togglePlayPauseTarget = commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
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
        remoteCommandTargets.append(RemoteCommandTarget(command: commandCenter.togglePlayPauseCommand, target: togglePlayPauseTarget))

        let skipForwardTarget = commandCenter.skipForwardCommand.addTarget { [weak self] event in
            guard let event = event as? MPSkipIntervalCommandEvent else { return .commandFailed }

            Task { @MainActor in
                self?.skip(by: event.interval)
            }
            return .success
        }
        remoteCommandTargets.append(RemoteCommandTarget(command: commandCenter.skipForwardCommand, target: skipForwardTarget))

        let skipBackwardTarget = commandCenter.skipBackwardCommand.addTarget { [weak self] event in
            guard let event = event as? MPSkipIntervalCommandEvent else { return .commandFailed }

            Task { @MainActor in
                self?.skip(by: -event.interval)
            }
            return .success
        }
        remoteCommandTargets.append(RemoteCommandTarget(command: commandCenter.skipBackwardCommand, target: skipBackwardTarget))

        setRemoteCommandsEnabled(false)
    }

    private func setRemoteCommandsEnabled(_ isEnabled: Bool) {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.isEnabled = isEnabled
        commandCenter.pauseCommand.isEnabled = isEnabled
        commandCenter.togglePlayPauseCommand.isEnabled = isEnabled
        commandCenter.skipForwardCommand.isEnabled = isEnabled
        commandCenter.skipBackwardCommand.isEnabled = isEnabled
    }

    private func removeRemoteCommandTargets() {
        remoteCommandTargets.forEach { target in
            target.command.removeTarget(target.target)
        }
        remoteCommandTargets.removeAll()
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
                if Date().timeIntervalSince(self.lastPositionSaveAt) >= self.positionSaveInterval {
                    self.saveCurrentPosition()
                    self.lastPositionSaveAt = Date()
                }
                self.updateNowPlayingInfo()
            }
        }
    }

    private func updateCurrentPlaybackPosition() {
        guard !didFinishPlayback else { return }
        guard canSaveCurrentPosition else { return }
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

    private func isAtPlaybackEnd(_ seconds: TimeInterval) -> Bool {
        guard let duration = player.currentItem?.duration.seconds, duration.isFinite else {
            return true
        }

        return duration - seconds <= 0.25
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

    private func observePlayerPlaybackState() {
        playerTimeControlStatusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.hasVideo else { return }

                if self.player.timeControlStatus == .paused {
                    self.saveCurrentPosition()
                }
                self.updateNowPlayingInfo()
            }
        }

        externalPlaybackObservation = player.observe(\.isExternalPlaybackActive, options: [.initial, .new]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self else { return }
                if player.isExternalPlaybackActive {
                    self.didUseExternalPlayback = true
                }
            }
        }
    }

    private func addPlaybackObservers() {
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

        playbackFailureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self, notification.object as? AVPlayerItem === self.player.currentItem else { return }
                self.handlePlayerItemFailure()
            }
        }
    }
}
