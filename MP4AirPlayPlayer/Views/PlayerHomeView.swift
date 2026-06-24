import AVKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private let supportedVideoContentTypes = ["mp4", "mov", "m4v", "3gp", "3g2"]
    .compactMap { UTType(filenameExtension: $0) }

struct PlayerHomeView: View {
    @EnvironmentObject private var recentStore: RecentVideoStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = PlayerViewModel()
    @State private var isFileImporterPresented = false

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let isLandscapeVideoMode = geometry.size.width > geometry.size.height && viewModel.hasVideo

                Group {
                    if isLandscapeVideoMode {
                        landscapePlayer
                    } else {
                        portraitContent(in: geometry)
                    }
                }
                .toolbar(isLandscapeVideoMode ? .hidden : .visible, for: .navigationBar)
            }
            .navigationTitle(viewModel.currentVideoTitle ?? "Pocket Video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(uiColor: .systemBackground), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if viewModel.hasVideo {
                        Button {
                            viewModel.closeCurrentVideo()
                        } label: {
                            Label("ホーム", systemImage: "chevron.left")
                        }
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isFileImporterPresented = true
                    } label: {
                        Image(systemName: "folder")
                    }
                    .accessibilityLabel("動画を選択")
                }
            }
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: supportedVideoContentTypes,
            allowsMultipleSelection: false,
            onCompletion: handleFileImport
        )
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

    private func portraitContent(in geometry: GeometryProxy) -> some View {
        Group {
            if viewModel.hasVideo {
                VStack(spacing: 0) {
                    videoArea(in: geometry)

                    List {
                        recentList
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            } else {
                List {
                    openVideoSection
                    recentList
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private var landscapePlayer: some View {
        playerSurface
            .ignoresSafeArea()
    }

    private func videoArea(in geometry: GeometryProxy) -> some View {
        let aspectRatio = min(max(viewModel.videoAspectRatio ?? (16.0 / 9.0), 0.45), 2.4)
        let fullWidth = geometry.size.width
        let naturalHeight = fullWidth / aspectRatio
        let maxHeight = geometry.size.height * 0.72
        let height = min(max(naturalHeight, 180), maxHeight)

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
                        HStack(spacing: 12) {
                            Image(systemName: "film")
                                .foregroundStyle(.secondary)

                            Text(video.title)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            deleteRecent(video)
                        } label: {
                            Label("削除", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let recent = try recentStore.addOrUpdate(url: url)
                let storedURL = try recentStore.resolveURL(for: recent)
                viewModel.open(url: storedURL, recentVideoID: recent.id, displayTitle: recent.title)
            } catch {
                viewModel.setError("選択したファイルを開けませんでした。ファイルAppで端末内にダウンロードしてから、もう一度試してください。")
            }
        case .failure(let error):
            if let cocoaError = error as? CocoaError, cocoaError.code == .userCancelled {
                return
            }
            viewModel.setError("選択したファイルを開けませんでした。")
        }
    }

    private func openRecent(_ video: RecentVideo) {
        do {
            let url = try recentStore.resolveURL(for: video)
            viewModel.open(url: url, resumePosition: video.lastPosition, recentVideoID: video.id, displayTitle: video.title)
        } catch {
            viewModel.setError("この動画はもう利用できません。もう一度ファイルAppから選択してください。")
        }
    }

    private func deleteRecent(_ video: RecentVideo) {
        recentStore.remove(video)
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
        controller.videoGravity = .resizeAspect
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.showsPlaybackControls = true
        context.coordinator.attach(to: controller)
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.showsPlaybackControls = true
    }

    final class Coordinator {
        private weak var controller: AVPlayerViewController?
        private var didBecomeActiveObserver: NSObjectProtocol?

        deinit {
            if let didBecomeActiveObserver {
                NotificationCenter.default.removeObserver(didBecomeActiveObserver)
            }
        }

        func attach(to controller: AVPlayerViewController) {
            self.controller = controller

            guard didBecomeActiveObserver == nil else { return }
            didBecomeActiveObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.stopPictureInPicture()
            }
        }

        private func stopPictureInPicture() {
            guard let controller else { return }

            controller.allowsPictureInPicturePlayback = false
            DispatchQueue.main.async {
                controller.allowsPictureInPicturePlayback = true
                controller.canStartPictureInPictureAutomaticallyFromInline = true
            }
        }
    }
}

#Preview {
    PlayerHomeView()
        .environmentObject(RecentVideoStore())
}
