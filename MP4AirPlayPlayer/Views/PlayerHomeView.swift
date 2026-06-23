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
            .navigationTitle("MP4 AirPlay")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isFileImporterPresented = true
                    } label: {
                        Image(systemName: "folder")
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
        .alert("Could not open video", isPresented: Binding(
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
        ZStack {
            Color(uiColor: .systemGroupedBackground)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if viewModel.hasVideo {
                        videoArea
                        playbackPanel
                    } else {
                        emptyState
                    }

                    recentList
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var landscapePlayer: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            VideoPlayer(player: viewModel.player)
                .ignoresSafeArea()

            if viewModel.isLoading {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.3)
            }

            VStack {
                HStack {
                    Spacer()

                    AirPlayRouteButton()
                        .frame(width: 44, height: 44)
                        .padding(6)
                        .background(.ultraThinMaterial, in: Circle())
                }

                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
    }

    private var videoArea: some View {
        ZStack {
            Color.black

            VideoPlayer(player: viewModel.player)

            if viewModel.isLoading {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.3)
            }

            if viewModel.isAirPlayActive {
                VStack {
                    HStack {
                        airPlayBadge
                        Spacer()
                    }
                    Spacer()
                }
                .padding(12)
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(uiColor: .separator).opacity(0.18), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 42, weight: .regular))
                .foregroundStyle(.blue)

            Text("Open an MP4")
                .font(.headline)

            Button {
                isFileImporterPresented = true
            } label: {
                Label("Open Video", systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
        .nativeCard()
    }

    private var airPlayBadge: some View {
        Label("AirPlay", systemImage: "airplayvideo.circle.fill")
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(Color(uiColor: .separator).opacity(0.18), lineWidth: 1)
        }
    }

    private var playbackPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Text(viewModel.title)
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                AirPlayRouteButton()
                    .frame(width: 44, height: 44)
            }

            transportControls()
            .frame(maxWidth: .infinity)
            .font(.title3)
        }
        .padding(14)
        .nativeCard()
    }

    @ViewBuilder
    private var recentList: some View {
        if !recentStore.videos.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Recent")
                    .font(.headline)

                LazyVStack(spacing: 8) {
                    ForEach(recentStore.videos) { video in
                        Button {
                            openRecent(video)
                        } label: {
                            HStack(spacing: 12) {
                                Text(video.title)
                                    .font(.body)
                                    .lineLimit(1)

                                Spacer()

                                Image(systemName: "play.circle")
                                    .foregroundStyle(.secondary)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .nativeCard(cornerRadius: 12)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func transportControls(spacing: CGFloat = 22, playWidth: CGFloat = 54, buttonHeight: CGFloat = 42) -> some View {
        HStack(spacing: spacing) {
            Button {
                viewModel.skip(seconds: -10)
            } label: {
                Label("10 seconds back", systemImage: "gobackward.10")
            }
            .labelStyle(.iconOnly)
            .frame(width: 42, height: buttonHeight)
            .buttonStyle(.bordered)

            Button {
                viewModel.playPause()
            } label: {
                Label(viewModel.isPlaying ? "Pause" : "Play", systemImage: viewModel.isPlaying ? "pause.fill" : "play.fill")
                    .labelStyle(.iconOnly)
                    .frame(width: playWidth, height: buttonHeight)
            }
            .buttonStyle(.borderedProminent)

            Button {
                viewModel.skip(seconds: 10)
            } label: {
                Label("10 seconds forward", systemImage: "goforward.10")
            }
            .labelStyle(.iconOnly)
            .frame(width: 42, height: buttonHeight)
            .buttonStyle(.bordered)
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let recent = try recentStore.addOrUpdate(url: url)
                let storedURL = try recentStore.resolveURL(for: recent)
                viewModel.open(url: storedURL, displayTitle: recent.title, recentVideoID: recent.id)
            } catch {
                viewModel.setError("The selected file could not be imported for playback. Make sure it is downloaded locally in Files, then try again.")
            }
        case .failure(let error):
            if let cocoaError = error as? CocoaError, cocoaError.code == .userCancelled {
                return
            }
            viewModel.setError("The selected file could not be opened.")
        }
    }

    private func openRecent(_ video: RecentVideo) {
        do {
            let url = try recentStore.resolveURL(for: video)
            viewModel.open(url: url, displayTitle: video.title, resumePosition: video.lastPosition, recentVideoID: video.id)
        } catch {
            viewModel.setError("The recent file is no longer available. Open it again from Files.")
        }
    }

}

#Preview {
    PlayerHomeView()
        .environmentObject(RecentVideoStore())
}

private extension View {
    func nativeCard(cornerRadius: CGFloat = 12) -> some View {
        background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color(uiColor: .separator).opacity(0.12), lineWidth: 1)
            }
    }
}
