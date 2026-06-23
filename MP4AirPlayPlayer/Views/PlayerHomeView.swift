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
            appBackground

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
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
                .padding(.top, 8)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.hidden)
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

    private var appBackground: some View {
        LinearGradient(
            colors: [
                Color(red: 0.77, green: 0.88, blue: 1.00),
                Color(red: 0.96, green: 0.97, blue: 1.00),
                Color(red: 0.87, green: 0.96, blue: 0.93)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            LinearGradient(
                colors: [
                    .white.opacity(0.52),
                    .white.opacity(0.18),
                    .clear
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("MP4 AirPlay")
                    .font(.title3.weight(.semibold))
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
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.glassProminent)
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
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.white.opacity(0.45), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(
                        LinearGradient(
                            colors: [.blue, .cyan],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .shadow(color: .blue.opacity(0.24), radius: 10, y: 4)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Open an MP4")
                        .font(.headline)

                    Text("Choose a local video from Files.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }

            Button {
                isFileImporterPresented = true
            } label: {
                Label("Open Video", systemImage: "folder")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 46)
            }
            .buttonStyle(.glassProminent)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .glassCard(cornerRadius: 12)
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
        .overlay {
            Capsule()
                .stroke(.white.opacity(0.45), lineWidth: 1)
        }
    }

    private var playbackPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                .frame(width: 42, height: 42)
                .buttonStyle(.glass)

                Button {
                    viewModel.playPause()
                } label: {
                    Label(viewModel.isPlaying ? "Pause" : "Play", systemImage: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .labelStyle(.iconOnly)
                        .frame(width: 54, height: 42)
                }
                .buttonStyle(.glassProminent)

                Button {
                    viewModel.skip(seconds: 10)
                } label: {
                    Label("10 seconds forward", systemImage: "goforward.10")
                }
                .labelStyle(.iconOnly)
                .frame(width: 42, height: 42)
                .buttonStyle(.glass)
            }
            .frame(maxWidth: .infinity)
            .font(.title3)
        }
        .padding(14)
        .glassCard()
    }

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent")
                .font(.headline)

            if recentStore.videos.isEmpty {
                Label("No recent videos", systemImage: "clock")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
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
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .glassCard(cornerRadius: 8, material: .thinMaterial)
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

private extension View {
    func glassCard(cornerRadius: CGFloat = 8, material: Material = .regularMaterial) -> some View {
        background(material, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(.white.opacity(0.5), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.08), radius: 14, y: 6)
    }
}

private struct GlassButtonStyle: ButtonStyle {
    var isProminent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isProminent ? .white : .primary)
            .background {
                background
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.white.opacity(isProminent ? 0.32 : 0.55), lineWidth: 1)
            }
            .shadow(
                color: isProminent ? .blue.opacity(0.24) : .black.opacity(0.08),
                radius: configuration.isPressed ? 4 : 10,
                y: configuration.isPressed ? 2 : 5
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }

    @ViewBuilder
    private var background: some View {
        if isProminent {
            LinearGradient(
                colors: [Color.blue, Color.cyan],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            Rectangle()
                .fill(.ultraThinMaterial)
        }
    }
}

private extension ButtonStyle where Self == GlassButtonStyle {
    static var glass: GlassButtonStyle {
        GlassButtonStyle()
    }

    static var glassProminent: GlassButtonStyle {
        GlassButtonStyle(isProminent: true)
    }
}
