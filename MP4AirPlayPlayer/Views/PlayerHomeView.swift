import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct PlayerHomeView: View {
    @EnvironmentObject private var recentStore: RecentVideoStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = PlayerViewModel()
    @State private var isFileImporterPresented = false

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 18) {
                    header

                    if viewModel.hasVideo {
                        videoArea
                        playbackPanel
                    } else {
                        emptyState
                    }

                    recentList
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 24)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
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

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("MP4 AirPlay")
                    .font(.title2.weight(.semibold))
                Text("Local MP4 playback")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                isFileImporterPresented = true
            } label: {
                Label("Open Video", systemImage: "folder")
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
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

            VStack {
                HStack {
                    statusBadge
                    Spacer()
                }
                Spacer()
            }
            .padding(12)
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(.blue)

            Text("Open an MP4")
                .font(.title3.weight(.semibold))

            Text("Choose a local video from Files, then send playback to Apple TV with AirPlay.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                isFileImporterPresented = true
            } label: {
                Label("Open Video", systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var statusBadge: some View {
        Label(
            viewModel.isAirPlayActive ? "AirPlay Connected" : "Local Playback",
            systemImage: viewModel.isAirPlayActive ? "airplayvideo.circle.fill" : "iphone"
        )
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var playbackPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.title)
                        .font(.headline)
                        .lineLimit(1)

                    Text(viewModel.isAirPlayActive ? "AirPlay Connected" : "Ready to play")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                AirPlayRouteButton()
                    .frame(width: 44, height: 44)
            }

            HStack(spacing: 22) {
                Button {
                    viewModel.skip(seconds: -10)
                } label: {
                    Label("10 seconds back", systemImage: "gobackward.10")
                }
                .labelStyle(.iconOnly)
                .frame(width: 44, height: 44)

                Button {
                    viewModel.playPause()
                } label: {
                    Label(viewModel.isPlaying ? "Pause" : "Play", systemImage: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .labelStyle(.iconOnly)
                        .frame(width: 56, height: 44)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    viewModel.skip(seconds: 10)
                } label: {
                    Label("10 seconds forward", systemImage: "goforward.10")
                }
                .labelStyle(.iconOnly)
                .frame(width: 44, height: 44)
            }
            .frame(maxWidth: .infinity)
            .font(.title3)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent")
                .font(.headline)

            if recentStore.videos.isEmpty {
                Text("No recent videos")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                    .padding(.horizontal, 14)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(recentStore.videos) { video in
                        Button {
                            openRecent(video)
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(video.title)
                                        .font(.body)
                                        .lineLimit(1)

                                    if video.lastPosition > 0 {
                                        Text("Resume at \(formatTime(video.lastPosition))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Spacer()

                                Image(systemName: "play.circle")
                                    .foregroundStyle(.secondary)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let recent = try recentStore.addOrUpdate(url: url)
                viewModel.open(url: url, recentVideoID: recent.id)
            } catch {
                viewModel.setError("The selected file could not be saved for recent playback.")
            }
        case .failure:
            viewModel.setError("The selected file could not be opened.")
        }
    }

    private func openRecent(_ video: RecentVideo) {
        do {
            let url = try recentStore.resolveURL(for: video)
            viewModel.open(url: url, resumePosition: video.lastPosition, recentVideoID: video.id)
        } catch {
            viewModel.setError("The recent file is no longer available. Open it again from Files.")
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds)
        let minutes = totalSeconds / 60
        let remainingSeconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }
}

#Preview {
    PlayerHomeView()
        .environmentObject(RecentVideoStore())
}
