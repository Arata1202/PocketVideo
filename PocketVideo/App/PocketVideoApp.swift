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
            return "自動"
        case .light:
            return "ライト"
        case .dark:
            return "ダーク"
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

@main
struct PocketVideoApp: App {
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
