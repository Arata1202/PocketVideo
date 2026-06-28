import AVFoundation
import UIKit

@MainActor
final class ExternalDisplayPlaybackCoordinator {
    static let shared = ExternalDisplayPlaybackCoordinator()

    private var window: UIWindow?
    private var playerViewController: ExternalPlayerViewController?
    private weak var player: AVPlayer?
    private var isEnabled = false
    private weak var windowScene: UIWindowScene?

    private init() {}

    func update(player: AVPlayer, isEnabled: Bool) {
        self.player = player
        self.isEnabled = isEnabled
        configureOutput()
    }

    func connect(windowScene: UIWindowScene) {
        self.windowScene = windowScene
        configureOutput()
    }

    func disconnect(windowScene: UIWindowScene) {
        guard self.windowScene === windowScene else { return }
        tearDownOutput()
        self.windowScene = nil
    }

    private func configureOutput() {
        guard isEnabled, let player, let windowScene else {
            tearDownOutput()
            return
        }

        let controller: ExternalPlayerViewController
        if let existingWindow = window,
           existingWindow.windowScene === windowScene,
           let existingController = playerViewController {
            controller = existingController
        } else {
            tearDownOutput()

            controller = ExternalPlayerViewController()
            let externalWindow = UIWindow(windowScene: windowScene)
            externalWindow.rootViewController = controller
            externalWindow.windowLevel = .normal
            externalWindow.makeKeyAndVisible()

            window = externalWindow
            playerViewController = controller
        }

        controller.player = player
        controller.videoGravity = .resizeAspect
    }

    private func tearDownOutput() {
        playerViewController?.player = nil
        window?.isHidden = true
        window = nil
        playerViewController = nil
    }
}

@MainActor
final class ExternalDisplaySceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        ExternalDisplayPlaybackCoordinator.shared.connect(windowScene: windowScene)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        guard let windowScene = scene as? UIWindowScene else { return }
        ExternalDisplayPlaybackCoordinator.shared.disconnect(windowScene: windowScene)
    }
}

private final class ExternalPlayerViewController: UIViewController {
    var player: AVPlayer? {
        get { playerView.playerLayer.player }
        set { playerView.playerLayer.player = newValue }
    }

    var videoGravity: AVLayerVideoGravity {
        get { playerView.playerLayer.videoGravity }
        set { playerView.playerLayer.videoGravity = newValue }
    }

    private var playerView: ExternalPlayerView {
        view as! ExternalPlayerView
    }

    override func loadView() {
        view = ExternalPlayerView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
    }

    override var prefersHomeIndicatorAutoHidden: Bool {
        true
    }
}

private final class ExternalPlayerView: UIView {
    override static var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }
}
