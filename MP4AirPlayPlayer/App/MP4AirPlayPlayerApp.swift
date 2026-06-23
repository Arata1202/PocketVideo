import SwiftUI

@main
struct MP4AirPlayPlayerApp: App {
    @StateObject private var recentStore = RecentVideoStore()

    var body: some Scene {
        WindowGroup {
            PlayerHomeView()
                .environmentObject(recentStore)
        }
    }
}

