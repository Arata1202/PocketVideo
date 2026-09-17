import SwiftUI
import UIKit

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            return String(localized: "自動")
        case .light:
            return String(localized: "ライト")
        case .dark:
            return String(localized: "ダーク")
        }
    }

    var userInterfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system:
            return .unspecified
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        if UIDevice.current.userInterfaceIdiom == .pad {
            return .all
        }

        return .allButUpsideDown
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: nil,
            sessionRole: connectingSceneSession.role
        )

        if connectingSceneSession.role == .windowExternalDisplayNonInteractive {
            configuration.delegateClass = ExternalDisplaySceneDelegate.self
        }

        return configuration
    }
}

@main
struct PocketVideoApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var recentStore = RecentVideoStore()
    @AppStorage("appAppearance") private var appAppearance = AppAppearance.system.rawValue

    var body: some Scene {
        WindowGroup {
            PlayerHomeView()
                .environmentObject(recentStore)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear {
                    applyAppearance()
                }
                .onChange(of: appAppearance) { _, _ in
                    applyAppearance()
                }
        }
    }

    private func applyAppearance() {
        let style = AppAppearance(rawValue: appAppearance)?.userInterfaceStyle ?? .unspecified

        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .forEach { window in
                window.overrideUserInterfaceStyle = style
            }
    }
}
