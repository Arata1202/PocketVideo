import AVKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private let supportedVideoContentTypes = ["mp4", "mov", "m4v", "3gp", "3g2"]
    .compactMap { UTType(filenameExtension: $0) }

private enum AppLinks {
    static let support = URL(string: "https://realunivlog.com/")!
    static let privacyPolicy = URL(string: "https://realunivlog.com/privacy")!
}

struct PlayerHomeView: View {
    @EnvironmentObject private var recentStore: RecentVideoStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = PlayerViewModel()
    @State private var isFileImporterPresented = false
    @State private var isPlayerPresented = false
    @State private var isSettingsPresented = false

    var body: some View {
        NavigationStack {
            homeContent
                .navigationTitle("Pocket Video")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(Color(uiColor: .systemBackground), for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        toolbarButtons
                    }
                }
                .navigationDestination(isPresented: $isPlayerPresented) {
                    playerContent
                        .onDisappear {
                            if !isPlayerPresented {
                                viewModel.closeCurrentVideo()
                            }
                        }
                }
        }
        .sheet(isPresented: $isSettingsPresented) {
            SettingsView()
                .environmentObject(recentStore)
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: supportedVideoContentTypes,
            allowsMultipleSelection: false,
            onCompletion: handleFileImport
        )
        .onOpenURL(perform: openSelectedURL)
        .alert("動画を開けませんでした", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .onAppear {
            viewModel.attachStore(recentStore)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                viewModel.saveCurrentPosition()
            }
        }
    }

    private var homeContent: some View {
        List {
            openVideoSection
            recentList
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemBackground))
    }

    private var playerContent: some View {
        GeometryReader { geometry in
            List {
                videoArea(in: geometry)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.black)

                recentList
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemBackground))
        }
        .navigationTitle(viewModel.currentVideoTitle ?? "Pocket Video")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color(uiColor: .systemBackground), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                toolbarButtons
            }
        }
    }

    private var toolbarButtons: some View {
        Group {
            Button {
                isFileImporterPresented = true
            } label: {
                Image(systemName: "folder")
            }
            .accessibilityLabel("動画を選択")

            Button {
                isSettingsPresented = true
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("設定")
        }
    }

    private func videoArea(in geometry: GeometryProxy) -> some View {
        let aspectRatio = min(max(viewModel.videoAspectRatio ?? (16.0 / 9.0), 0.45), 2.4)
        let fullWidth = geometry.size.width
        let naturalHeight = fullWidth / aspectRatio
        let height = max(naturalHeight, 180)

        return playerSurface
            .frame(width: fullWidth, height: height)
    }

    private var playerSurface: some View {
        ZStack {
            Color.black

            PlayerView(player: viewModel.player)

            if viewModel.showsLoadingIndicator {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.3)
            }
        }
        .background(Color.black)
    }

    private var openVideoSection: some View {
        Section {
            Button {
                isFileImporterPresented = true
            } label: {
                Label("動画を選択", systemImage: "folder")
            }
        }
    }

    @ViewBuilder
    private var recentList: some View {
        Section("最近開いた動画") {
            if recentStore.videos.isEmpty {
                Text("まだありません")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(recentStore.videos) { video in
                    Button {
                        openRecent(video)
                    } label: {
                        recentVideoRow(video)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(accessibilityLabel(for: video))
                    .accessibilityHint("開いて再生します")
                }
                .onDelete(perform: deleteRecent)
            }
        }
    }

    private func recentVideoRow(_ video: RecentVideo) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "film")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 3) {
                Text(video.title)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let playbackText = playbackText(for: video) {
                    Text(playbackText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            openSelectedURL(url)
        case .failure(let error):
            if let cocoaError = error as? CocoaError, cocoaError.code == .userCancelled {
                return
            }
            viewModel.setError("選択したファイルを開けませんでした。")
        }
    }

    private func openSelectedURL(_ url: URL) {
        do {
            viewModel.saveCurrentPosition()
            let recent = try recentStore.addOrUpdate(url: url)
            let storedURL = try recentStore.resolveURL(for: recent)
            guard viewModel.open(
                url: storedURL,
                resumePosition: recent.lastPosition,
                recentVideoID: recent.id,
                displayTitle: recent.title
            ) else {
                recentStore.remove(recent)
                return
            }
            isPlayerPresented = true
        } catch {
            viewModel.setError("選択したファイルを開けませんでした。ファイルAppで端末内にダウンロードしてから、もう一度試してください。")
        }
    }

    private func openRecent(_ video: RecentVideo) {
        do {
            let url = try recentStore.resolveURL(for: video)
            guard viewModel.open(url: url, resumePosition: video.lastPosition, recentVideoID: video.id, displayTitle: video.title) else {
                recentStore.remove(video)
                return
            }
            isPlayerPresented = true
        } catch {
            recentStore.remove(video)
            viewModel.setError("この動画はもう利用できません。履歴から削除しました。もう一度ファイルAppから選択してください。")
        }
    }

    private func deleteRecent(at offsets: IndexSet) {
        offsets
            .map { recentStore.videos[$0] }
            .forEach(recentStore.remove)
    }

    private func playbackText(for video: RecentVideo) -> String? {
        if viewModel.hasVideo, video.id == viewModel.currentRecentVideoID {
            return "再生中 \(formatDuration(viewModel.currentPlaybackPosition))"
        }

        return resumeText(for: video.lastPosition)
    }

    private func accessibilityLabel(for video: RecentVideo) -> String {
        if let playbackText = playbackText(for: video) {
            return "\(video.title), \(playbackText)"
        }

        return video.title
    }

    private func resumeText(for position: TimeInterval) -> String? {
        guard position >= 5 else { return nil }
        return "\(formatDuration(position)) から再開"
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(Int(seconds), 0)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }

        return String(format: "%d:%02d", minutes, seconds)
    }
}

private struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var recentStore: RecentVideoStore
    @AppStorage("appAppearance") private var appAppearance = AppAppearance.system.rawValue
    @State private var isClearRecentConfirmationPresented = false

    var body: some View {
        NavigationStack {
            Form {
                Section("テーマ") {
                    Picker("テーマ", selection: $appAppearance) {
                        ForEach(AppAppearance.allCases) { appearance in
                            Text(appearance.title)
                                .tag(appearance.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Button("履歴をすべて削除", role: .destructive) {
                        isClearRecentConfirmationPresented = true
                    }
                    .disabled(recentStore.videos.isEmpty)
                }

                Section("アプリ情報") {
                    LabeledContent("対応形式", value: "MP4, MOV, M4V, 3GP, 3G2")
                    LabeledContent("バージョン", value: appVersion)
                }

                Section("サポート") {
                    Link(destination: AppLinks.support) {
                        Label("サポート", systemImage: "questionmark.circle")
                    }

                    Link(destination: AppLinks.privacyPolicy) {
                        Label("プライバシーポリシー", systemImage: "hand.raised")
                    }
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完了") {
                        dismiss()
                    }
                }
            }
        }
        .alert("履歴をすべて削除しますか？", isPresented: $isClearRecentConfirmationPresented) {
            Button("キャンセル", role: .cancel) {}
            Button("削除", role: .destructive) {
                recentStore.removeAll()
            }
        } message: {
            Text("最近開いた動画の履歴だけを削除します。元の動画ファイルは削除されません。")
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return version ?? "-"
    }
}

private struct PlayerView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.delegate = context.coordinator
        controller.videoGravity = .resizeAspect
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.showsPlaybackControls = true
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        controller.player = player
        controller.delegate = context.coordinator
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.showsPlaybackControls = true
    }

    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            willBeginFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
        ) {
            guard UIDevice.current.userInterfaceIdiom != .pad else { return }

            AppOrientationLock.supportedOrientations = .allButUpsideDown
            playerViewController.setNeedsUpdateOfSupportedInterfaceOrientations()
        }

        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
        ) {
            guard UIDevice.current.userInterfaceIdiom != .pad else { return }

            coordinator.animate(alongsideTransition: nil) { _ in
                AppOrientationLock.supportedOrientations = .portrait
                playerViewController.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
        }
    }
}
