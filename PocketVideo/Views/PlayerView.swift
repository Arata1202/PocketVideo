import AVKit
import SwiftUI

struct PlayerView: UIViewControllerRepresentable {
    let model: PlayerViewModel
    let allowsPictureInPicture: Bool
    let isPresented: Bool

    private static var playbackSpeeds: [AVPlaybackSpeed] {
        [0.5, 0.75, 1, 1.25, 1.5, 2].map { rate in
            let label = rate.formatted(.number.precision(.fractionLength(0...2)))
            return AVPlaybackSpeed(rate: Float(rate), localizedName: "\(label)×")
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.delegate = context.coordinator
        controller.videoGravity = .resizeAspect
        controller.allowsPictureInPicturePlayback = allowsPictureInPicture
        controller.canStartPictureInPictureAutomaticallyFromInline = allowsPictureInPicture
        controller.speeds = Self.playbackSpeeds
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if isPresented, controller.player !== model.player { controller.player = model.player }
        controller.allowsPictureInPicturePlayback = allowsPictureInPicture
        controller.canStartPictureInPictureAutomaticallyFromInline = allowsPictureInPicture
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

// Observe the destination itself so scrolling the video row offscreen cannot block playback.
struct PlayerDestinationAppearance: UIViewControllerRepresentable {
    let didAppear: () -> Void

    func makeUIViewController(context: Context) -> Observer {
        let controller = Observer()
        controller.didAppear = didAppear
        return controller
    }

    func updateUIViewController(_ controller: Observer, context: Context) {}

    final class Observer: UIViewController {
        var didAppear: (() -> Void)?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            didAppear?()
        }
    }
}
