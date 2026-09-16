import AVKit
import SwiftUI

struct PlayerView: UIViewControllerRepresentable {
    let player: AVPlayer
    let allowsPictureInPicture: Bool
    let presentsFullScreen: Bool

    private static let playbackSpeeds = [
        AVPlaybackSpeed(rate: 0.5, localizedName: "0.5×"),
        AVPlaybackSpeed(rate: 0.75, localizedName: "0.75×"),
        AVPlaybackSpeed(rate: 1, localizedName: "1×"),
        AVPlaybackSpeed(rate: 1.25, localizedName: "1.25×"),
        AVPlaybackSpeed(rate: 1.5, localizedName: "1.5×"),
        AVPlaybackSpeed(rate: 2, localizedName: "2×"),
    ]

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> PlayerContainerViewController {
        let playerViewController = context.coordinator.playerViewController
        configure(playerViewController)

        let container = PlayerContainerViewController(playerViewController: playerViewController)
        container.onFullScreenDismissed = context.coordinator.handleFullScreenDismissal
        context.coordinator.container = container
        container.setFullScreen(presentsFullScreen)
        return container
    }

    func updateUIViewController(_ container: PlayerContainerViewController, context: Context) {
        let playerViewController = context.coordinator.playerViewController
        if playerViewController.player !== player {
            playerViewController.player = player
        }
        playerViewController.delegate = context.coordinator
        playerViewController.videoGravity = .resizeAspect
        playerViewController.allowsPictureInPicturePlayback = allowsPictureInPicture
        playerViewController.canStartPictureInPictureAutomaticallyFromInline = allowsPictureInPicture
        playerViewController.showsPlaybackControls = true
        container.setFullScreen(presentsFullScreen)
    }

    static func dismantleUIViewController(_ container: PlayerContainerViewController, coordinator: Coordinator) {
        container.prepareForRemoval()
        coordinator.playerViewController.delegate = nil
        coordinator.container = nil
    }

    private func configure(_ controller: AVPlayerViewController) {
        controller.player = player
        controller.videoGravity = .resizeAspect
        controller.allowsPictureInPicturePlayback = allowsPictureInPicture
        controller.canStartPictureInPictureAutomaticallyFromInline = allowsPictureInPicture
        controller.showsPlaybackControls = true
        controller.speeds = Self.playbackSpeeds
    }

    @MainActor
    final class Coordinator: NSObject, @MainActor AVPlayerViewControllerDelegate {
        let playerViewController = AVPlayerViewController()
        weak var container: PlayerContainerViewController?
        private var shouldResumeAfterFullScreen = false

        override init() {
            super.init()
            playerViewController.delegate = self
        }

        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            willBeginFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
        ) {
            shouldResumeAfterFullScreen = playerViewController.player.map(Self.isPlaybackIntended) ?? false
            container?.nativeFullScreenWillBegin()
            Self.requestOrientation(.landscape, for: playerViewController)

            coordinator.animate(alongsideTransition: nil) { [weak self] context in
                if context.isCancelled {
                    self?.container?.nativeFullScreenDidEnd()
                }
            }
        }

        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
        ) {
            let player = playerViewController.player
            let shouldResume = shouldResumeAfterFullScreen
            shouldResumeAfterFullScreen = false
            Self.requestOrientation(.portrait, for: playerViewController)

            coordinator.animate(alongsideTransition: nil) { [weak self, weak player] context in
                if !context.isCancelled {
                    self?.container?.nativeFullScreenDidEnd()
                }
                guard !context.isCancelled, shouldResume else { return }
                DispatchQueue.main.async {
                    if player?.currentItem != nil {
                        player?.play()
                    }
                }
            }
        }

        func handleFullScreenDismissal() {
            Self.requestOrientation(.portrait, for: playerViewController)
        }

        private static func isPlaybackIntended(_ player: AVPlayer) -> Bool {
            player.rate > 0 || player.timeControlStatus == .playing || player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        }

        private static func requestOrientation(
            _ orientations: UIInterfaceOrientationMask,
            for playerViewController: AVPlayerViewController
        ) {
            guard UIDevice.current.userInterfaceIdiom == .phone,
                  let windowScene = playerViewController.view.window?.windowScene else { return }
            windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations))
        }
    }
}

@MainActor
final class PlayerContainerViewController: UIViewController {
    let playerViewController: AVPlayerViewController
    var onFullScreenDismissed: (() -> Void)?

    private var wantsFullScreen = false
    private var presentedPlayerFullScreen = false
    private var nativeFullScreen = false
    private var isDismissingPlayer = false

    init(playerViewController: AVPlayerViewController) {
        self.playerViewController = playerViewController
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        embedPlayer()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        if presentedPlayerFullScreen,
           playerViewController.presentingViewController == nil,
           playerViewController.parent == nil {
            wantsFullScreen = false
            presentedPlayerFullScreen = false
            isDismissingPlayer = false
            embedPlayer()
            onFullScreenDismissed?()
            return
        }

        updateFullScreenPresentation()
    }

    func setFullScreen(_ fullScreen: Bool) {
        guard wantsFullScreen != fullScreen else { return }
        wantsFullScreen = fullScreen
        updateFullScreenPresentation()
    }

    func nativeFullScreenWillBegin() {
        if !presentedPlayerFullScreen {
            nativeFullScreen = true
        }
    }

    func nativeFullScreenDidEnd() {
        nativeFullScreen = false
    }

    func prepareForRemoval() {
        if presentedViewController === playerViewController {
            dismiss(animated: false)
        }
        playerViewController.willMove(toParent: nil)
        playerViewController.view.removeFromSuperview()
        playerViewController.removeFromParent()
    }

    private func updateFullScreenPresentation() {
        guard UIDevice.current.userInterfaceIdiom == .phone,
              isViewLoaded,
              view.window != nil else { return }

        if wantsFullScreen {
            presentPlayerFullScreenIfNeeded()
        } else if presentedPlayerFullScreen, !isDismissingPlayer {
            isDismissingPlayer = true
            dismiss(animated: true) { [weak self] in
                guard let self else { return }
                self.presentedPlayerFullScreen = false
                self.isDismissingPlayer = false
                self.embedPlayer()
                self.onFullScreenDismissed?()
            }
        }
    }

    private func presentPlayerFullScreenIfNeeded() {
        guard !nativeFullScreen,
              !presentedPlayerFullScreen,
              playerViewController.parent === self else { return }

        presentedPlayerFullScreen = true
        playerViewController.willMove(toParent: nil)
        playerViewController.view.removeFromSuperview()
        playerViewController.removeFromParent()
        playerViewController.modalPresentationStyle = .fullScreen

        present(playerViewController, animated: true)
    }

    private func embedPlayer() {
        guard playerViewController.parent !== self else { return }

        addChild(playerViewController)
        view.addSubview(playerViewController.view)
        playerViewController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            playerViewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            playerViewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            playerViewController.view.topAnchor.constraint(equalTo: view.topAnchor),
            playerViewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        playerViewController.didMove(toParent: self)
    }
}
