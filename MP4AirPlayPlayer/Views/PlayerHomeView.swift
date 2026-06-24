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
                        portraitContent
                    }
                }
                .toolbar(isLandscapeVideoMode ? .hidden : .visible, for: .navigationBar)
            }
            .navigationTitle("MP4 Player")
            .navigationBarTitleDisplayMode(viewModel.hasVideo ? .inline : .large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if viewModel.hasVideo {
                        Button {
                            isFileImporterPresented = true
                        } label: {
                            Image(systemName: "folder")
                        }
                        .accessibilityLabel("動画を選択")
                    }
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

    private var portraitContent: some View {
        List {
            if viewModel.hasVideo {
                Section {
                    videoArea
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                        .listRowBackground(Color.clear)
                }
            } else {
                openVideoSection
            }

            recentList
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private var landscapePlayer: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            PlayerView(player: viewModel.player, showsPlaybackControls: true)
                .ignoresSafeArea()

            if viewModel.isLoading {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.3)
            }
        }
    }

    private var videoArea: some View {
        VStack(spacing: 12) {
            ZStack {
                Color.black

                PlayerView(player: viewModel.player, showsPlaybackControls: false)

                if viewModel.isLoading {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.3)
                }
            }
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            portraitPlaybackControls
        }
    }

    private var portraitPlaybackControls: some View {
        VStack(spacing: 10) {
            Slider(
                value: Binding(
                    get: { viewModel.currentTime },
                    set: { viewModel.seek(to: $0) }
                ),
                in: 0...max(viewModel.duration, 1)
            )
            .disabled(viewModel.duration <= 0)

            HStack {
                Text(formatTime(viewModel.currentTime))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                Spacer()

                Text(formatTime(viewModel.duration))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.caption)

            HStack(spacing: 24) {
                AirPlayRoutePicker()
                    .frame(width: 32, height: 32)

                Button {
                    viewModel.seek(by: -10)
                } label: {
                    Image(systemName: "gobackward.10")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.hasVideo)

                Button {
                    viewModel.togglePlayback()
                } label: {
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 52, height: 52)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.hasVideo)

                Button {
                    viewModel.seek(by: 10)
                } label: {
                    Image(systemName: "goforward.10")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.hasVideo)
            }
        }
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
                viewModel.open(url: storedURL, recentVideoID: recent.id)
            } catch {
                viewModel.setError("選択したファイルを取り込めませんでした。ファイルAppで端末内にダウンロードしてから、もう一度試してください。")
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
            viewModel.open(url: url, resumePosition: video.lastPosition, recentVideoID: video.id)
        } catch {
            viewModel.setError("この動画はもう利用できません。もう一度ファイルAppから選択してください。")
        }
    }

    private func deleteRecent(_ video: RecentVideo) {
        let isCurrentVideo = viewModel.currentRecentVideoID == video.id
        recentStore.remove(video, keepingStoredFile: isCurrentVideo)
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite && seconds > 0 else { return "0:00" }

        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }

        return String(format: "%d:%02d", minutes, seconds)
    }
}

private struct PlayerView: UIViewControllerRepresentable {
    let player: AVPlayer
    let showsPlaybackControls: Bool

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.videoGravity = .resizeAspect
        controller.allowsPictureInPicturePlayback = true
        controller.showsPlaybackControls = showsPlaybackControls
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        controller.player = player
        controller.showsPlaybackControls = showsPlaybackControls
    }
}

private struct AirPlayRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = true
        view.tintColor = .systemBlue
        view.activeTintColor = .systemBlue
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

#Preview {
    PlayerHomeView()
        .environmentObject(RecentVideoStore())
}
