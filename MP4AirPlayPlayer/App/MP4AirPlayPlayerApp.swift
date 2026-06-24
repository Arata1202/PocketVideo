import SwiftUI

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

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}

@main
struct MP4AirPlayPlayerApp: App {
    @StateObject private var recentStore = RecentVideoStore()
    @AppStorage("appAppearance") private var appAppearance = AppAppearance.system.rawValue

    var body: some Scene {
        WindowGroup {
            PlayerHomeView()
                .environmentObject(recentStore)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .preferredColorScheme(AppAppearance(rawValue: appAppearance)?.colorScheme)
        }
    }
}
