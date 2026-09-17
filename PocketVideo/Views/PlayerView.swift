import AVKit
import SwiftUI

struct PlayerView: UIViewControllerRepresentable {
    let player: AVPlayer
    let allowsPictureInPicture: Bool

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

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.delegate = context.coordinator
        controller.videoGravity = .resizeAspect
        controller.allowsPictureInPicturePlayback = allowsPictureInPicture
        controller.canStartPictureInPictureAutomaticallyFromInline = allowsPictureInPicture
        controller.showsPlaybackControls = true
        controller.speeds = Self.playbackSpeeds
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player {
            controller.player = player
        }
        controller.delegate = context.coordinator
        controller.videoGravity = .resizeAspect
        controller.allowsPictureInPicturePlayback = allowsPictureInPicture
        controller.canStartPictureInPictureAutomaticallyFromInline = allowsPictureInPicture
        controller.showsPlaybackControls = true
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        controller.delegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, @MainActor AVPlayerViewControllerDelegate {
        private var shouldResumeAfterFullScreen = false

        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            willBeginFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
        ) {
            shouldResumeAfterFullScreen = playerViewController.player.map(Self.isPlaybackIntended) ?? false
        }

        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
        ) {
            let player = playerViewController.player
            let shouldResume = shouldResumeAfterFullScreen
            shouldResumeAfterFullScreen = false

            coordinator.animate(alongsideTransition: nil) { [weak player] context in
                guard !context.isCancelled, shouldResume else { return }
                DispatchQueue.main.async {
                    if player?.currentItem != nil {
                        player?.play()
                    }
                }
            }
        }

        private static func isPlaybackIntended(_ player: AVPlayer) -> Bool {
            player.rate > 0 || player.timeControlStatus == .playing || player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        }
    }
}
