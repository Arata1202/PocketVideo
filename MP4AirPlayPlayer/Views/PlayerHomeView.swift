import AVKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

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
            allowedContentTypes: [.mpeg4Movie, .movie],
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

            if viewModel.isLoading {
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
                        RecentVideoRow(video: video, isCurrent: viewModel.currentRecentVideoID == video.id)
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

private struct RecentVideoRow: View {
    @EnvironmentObject private var recentStore: RecentVideoStore
    let video: RecentVideo
    let isCurrent: Bool
    @State private var thumbnail: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            thumbnailView
                .frame(width: 96, height: 54)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(video.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)

                if isCurrent {
                    Text("再生中")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isCurrent {
                Image(systemName: "play.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 58)
        .contentShape(Rectangle())
        .task(id: video.id) {
            await loadThumbnail()
        }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        ZStack {
            Color.black

            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "film")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
    }

    @MainActor
    private func loadThumbnail() async {
        thumbnail = nil
        guard let url = try? recentStore.resolveURL(for: video) else { return }
        thumbnail = await VideoThumbnailGenerator.makeThumbnail(for: url)
    }
}

private enum VideoThumbnailGenerator {
    static func makeThumbnail(for url: URL) async -> UIImage? {
        let didAccessSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 180)

        return await withCheckedContinuation { continuation in
            let time = CMTime(seconds: 0.5, preferredTimescale: 600)
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, _, result, _ in
                _ = generator

                guard result == .succeeded, let image else {
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: UIImage(cgImage: image))
            }
        }
    }
}

private struct PlayerView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.videoGravity = .resizeAspect
        controller.allowsPictureInPicturePlayback = true
        controller.showsPlaybackControls = true
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        controller.player = player
        controller.showsPlaybackControls = true
    }
}

#Preview {
    PlayerHomeView()
        .environmentObject(RecentVideoStore())
}
