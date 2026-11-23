import AVFoundation
import Combine
import CoreGraphics
import Foundation
import MediaPlayer

private actor PlaybackAudioSession {
    static let shared = PlaybackAudioSession()

    func activate() -> Bool {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
            return true
        } catch {
            return false
        }
    }
}

@MainActor
final class PlayerViewModel: ObservableObject {
    @Published var player = AVPlayer()
    private struct PlaybackWindow {
        weak var model: PlayerViewModel?
    }
    private static var playbackWindows: [PlaybackWindow] = []
    private static weak var systemPlaybackOwner: PlayerViewModel?
    @Published private(set) var isPlaying = false
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
    private var audioSessionInterruptionObserver: NSObjectProtocol?
    private var audioSessionRouteChangeObserver: NSObjectProtocol?
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
    private var lastSavedPosition: TimeInterval?
    private var canSaveCurrentPosition = false
    struct AudioInterruptionState {
        fileprivate(set) var currentID: UUID?
        // A selection made before a stop event must stay paused after file preparation.
        fileprivate var autoplayCancellationID: UUID?
    }

    private(set) var audioInterruptionState = AudioInterruptionState()
    private var interruptionAtSelection: UUID?
    private var wantsAutomaticPlayback = false
    private var automaticPlaybackTask: Task<Void, Never>?

    init() {
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = false
        player.externalPlaybackVideoGravity = .resizeAspect
        observePlayerPlaybackState()
        observeAudioSession()
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
            releaseSystemPlaybackControls()
            stopSecurityScopedAccess()
            if let playbackEndObserver {
                NotificationCenter.default.removeObserver(playbackEndObserver)
            }
            if let playbackFailureObserver {
                NotificationCenter.default.removeObserver(playbackFailureObserver)
            }
            if let audioSessionInterruptionObserver {
                NotificationCenter.default.removeObserver(audioSessionInterruptionObserver)
            }
            if let audioSessionRouteChangeObserver {
                NotificationCenter.default.removeObserver(audioSessionRouteChangeObserver)
            }
        }
    }

    func attachStore(_ store: RecentVideoStore) {
        recentStore = store
    }

    @discardableResult
    func open(url: URL, resumePosition: TimeInterval = 0, recentVideoID: RecentVideo.ID? = nil, displayTitle: String? = nil,
              audioStateAtSelection: AudioInterruptionState? = nil) -> Bool {
        let requestID = UUID()
        cancelAutomaticPlayback()
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
        releaseSystemPlaybackControls()

        stopSecurityScopedAccess()
        isPlaying = false
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

        lastSavedPosition = nil
        currentRecentVideoID = recentVideoID
        currentVideoTitle = displayTitle ?? url.lastPathComponent
        currentPlaybackPosition = resumePosition
        lastPositionSaveAt = .distantPast
        didFinishPlayback = false
        didUseExternalPlayback = false
        canSaveCurrentPosition = false

        let selection = audioStateAtSelection ?? audioInterruptionState
        interruptionAtSelection = selection.currentID
        wantsAutomaticPlayback = selection.autoplayCancellationID == audioInterruptionState.autoplayCancellationID
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
        cancelAutomaticPlayback()
        openRequestID = UUID()
        saveCurrentPosition()
        aspectRatioLoadTask?.cancel()
        loadingIndicatorTask?.cancel()
        removePeriodicTimeObserver()
        playerItemStatusObservation?.invalidate()
        playerItemStatusObservation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
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
        releaseSystemPlaybackControls()
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
            savePositionIfChanged(0, for: id)
            return
        }

        guard seconds.isFinite else { return }
        currentPlaybackPosition = seconds
        savePositionIfChanged(seconds, for: id)
    }

    private func savePositionIfChanged(_ position: TimeInterval, for id: RecentVideo.ID) {
        // Closing or backgrounding a paused window must not overwrite another window's progress.
        guard position != lastSavedPosition else { return }
        recentStore?.updatePosition(for: id, position: position)
        lastSavedPosition = position
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
                    self.preparePlayback(item: item, resumePosition: resumePosition)
                case .failed:
                    self.handlePlayerItemFailure()
                default:
                    break
                }
            }
        }
    }

    private func preparePlayback(item: AVPlayerItem, resumePosition: TimeInterval) {
        guard player.currentItem === item else { return }

        hasVideo = true
        didFinishPlayback = false
        claimSystemPlaybackControls()
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
                    self.startAutomaticPlaybackIfReady()
                }
            }
        } else {
            canSaveCurrentPosition = true
            startAutomaticPlaybackIfReady()
        }
    }

    private func handlePlayerItemFailure() {
        cancelAutomaticPlayback()
        removePeriodicTimeObserver()
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        hasVideo = false
        currentPlaybackPosition = 0
        videoAspectRatio = nil
        canSaveCurrentPosition = false
        releaseSystemPlaybackControls()
        showAlert(playbackFailureAlert)
    }

    private var playbackFailureAlert: PlaybackAlert {
        if player.isExternalPlaybackActive || didUseExternalPlayback {
            return .airPlayPlaybackFailed
        }

        return .localPlaybackFailed
    }

    private func releaseSystemPlaybackControls() {
        Self.playbackWindows.removeAll { $0.model == nil || $0.model === self }
        guard !remoteCommandTargets.isEmpty else { return }
        removeRemoteCommandTargets()

        let remaining = Self.playbackWindows.compactMap(\.model)
        let successor = remaining.last { $0.player.timeControlStatus == .playing } ?? remaining.last
        Self.selectSystemPlaybackOwner(successor)
        if successor == nil {
            clearNowPlayingInfo()
            setRemoteCommandsEnabled(false)
        }
    }

    private func claimSystemPlaybackControls() {
        guard Self.systemPlaybackOwner !== self else { return }
        Self.systemPlaybackOwner?.removeRemoteCommandTargets()
        Self.selectSystemPlaybackOwner(self)
    }

    private static func selectSystemPlaybackOwner(_ owner: PlayerViewModel?) {
        systemPlaybackOwner = owner
        ExternalDisplayPlaybackCoordinator.shared.display(owner?.player)
        guard let owner else { return }
        playbackWindows.removeAll { $0.model == nil || $0.model === owner }
        playbackWindows.append(PlaybackWindow(model: owner))
        owner.installRemoteCommandTargets()
        owner.updateNowPlayingInfo()
    }

    private func installRemoteCommandTargets() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.skipForwardCommand.preferredIntervals = [NSNumber(value: 10)]
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
                self?.pausePlayback()
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
                    self.updateNowPlayingInfo()
                } else {
                    self.pausePlayback()
                }
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

        setRemoteCommandsEnabled(true)
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
        guard Self.systemPlaybackOwner === self else { return }
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
        savePositionIfChanged(0, for: id)
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

    private func startAutomaticPlaybackIfReady() {
        guard wantsAutomaticPlayback, canSaveCurrentPosition,
              audioInterruptionState.currentID == nil || audioInterruptionState.currentID == interruptionAtSelection,
              automaticPlaybackTask == nil, let item = player.currentItem else { return }
        automaticPlaybackTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let activated = await PlaybackAudioSession.shared.activate()
            guard !Task.isCancelled, let self, self.player.currentItem === item else { return }
            self.automaticPlaybackTask = nil
            if self.audioInterruptionState.currentID != nil {
                guard activated else { return }
                self.audioInterruptionState.currentID = nil
            }
            self.wantsAutomaticPlayback = false
            self.didFinishPlayback = false
            self.player.play()
            self.updateNowPlayingInfo()
        }
    }

    // AVKit may pause during dismissal. Resume only if no newer stop request superseded it.
    private var playbackStopRevision = 0

    func fullScreenDismissalResumeAction() -> (() -> Void)? {
        guard let item = player.currentItem, audioInterruptionState.currentID == nil,
              player.rate > 0 || player.timeControlStatus == .waitingToPlayAtSpecifiedRate else { return nil }
        let revision = playbackStopRevision
        return { [weak self, weak item] in
            guard let self, let item, self.player.currentItem === item,
                  self.playbackStopRevision == revision, !self.didFinishPlayback else { return }
            self.player.play()
        }
    }

    func pausePlayback() {
        audioInterruptionState.autoplayCancellationID = UUID()
        cancelAutomaticPlayback()
        player.pause()
        saveCurrentPosition()
        updateNowPlayingInfo(playbackRate: 0)
    }

    private func cancelAutomaticPlayback() {
        playbackStopRevision += 1
        wantsAutomaticPlayback = false
        automaticPlaybackTask?.cancel()
        automaticPlaybackTask = nil
    }

    private func observeAudioSession() {
        audioSessionInterruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.handleAudioSessionInterruption(notification)
            }
        }

        audioSessionRouteChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.handleAudioSessionRouteChange(notification)
            }
        }
    }

    private func handleAudioSessionInterruption(_ notification: Notification) {
        guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            playbackStopRevision += 1
            audioInterruptionState.currentID = UUID()
            wantsAutomaticPlayback = wantsAutomaticPlayback || player.timeControlStatus == .playing
            automaticPlaybackTask?.cancel()
            automaticPlaybackTask = nil
            player.pause()
            saveCurrentPosition()
            updateNowPlayingInfo(playbackRate: 0)
        case .ended:
            let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            guard audioInterruptionState.currentID != nil else { return }
            audioInterruptionState.currentID = nil
            if options.contains(.shouldResume) {
                startAutomaticPlaybackIfReady()
            } else {
                audioInterruptionState.autoplayCancellationID = UUID()
                cancelAutomaticPlayback()
            }
            updateNowPlayingInfo()
        @unknown default:
            break
        }
    }

    private func handleAudioSessionRouteChange(_ notification: Notification) {
        guard let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

        switch reason {
        case .oldDeviceUnavailable:
            pausePlayback()
        case .categoryChange, .override, .routeConfigurationChange:
            saveCurrentPosition()
            updateNowPlayingInfo()
        default:
            break
        }
    }

    private func observePlayerPlaybackState() {
        playerTimeControlStatusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.hasVideo else { return }

                self.isPlaying = self.player.timeControlStatus == .playing
                if self.isPlaying { self.claimSystemPlaybackControls() }
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
