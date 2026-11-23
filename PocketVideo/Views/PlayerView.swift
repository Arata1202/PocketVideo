import AVKit
import SwiftUI

struct PlayerView: UIViewControllerRepresentable {
    let model: PlayerViewModel
    private var player: AVPlayer { model.player }
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
        Coordinator(model: model)
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
        private let model: PlayerViewModel

        init(model: PlayerViewModel) {
            self.model = model
        }

        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
        ) {
            guard let resume = model.fullScreenDismissalResumeAction() else { return }
            coordinator.animate(alongsideTransition: nil) { context in
                guard !context.isCancelled else { return }
                DispatchQueue.main.async { resume() }
            }
        }
    }
}
