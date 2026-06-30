import SwiftUI
import UIKit
import UniformTypeIdentifiers

private let supportedVideoContentTypes = ["mp4", "mov", "m4v", "3gp", "3g2"]
    .compactMap { UTType(filenameExtension: $0) }
private let minimumResumeDisplayPosition: TimeInterval = 1

struct PlayerHomeView: View {
    @EnvironmentObject private var recentStore: RecentVideoStore
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("allowsPictureInPicture") private var allowsPictureInPicture = true
    @AppStorage("allowsExternalDisplayPlayback") private var allowsExternalDisplayPlayback = true
    @StateObject private var viewModel = PlayerViewModel()
    @State private var isFileImporterPresented = false
    @State private var isPlayerPresented = false
    @State private var isSettingsPresented = false
    @State private var hasAppeared = false
    @State private var pendingOpenURL: URL?
    @State private var isPreparingFile = false
    @State private var preparingFileName: String?
    @State private var filePreparationTask: Task<Void, Never>?
    @State private var filePreparationID = UUID()

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
                    regularPlayerContent
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
        .overlay {
            if isPreparingFile {
                filePreparationOverlay
            }
        }
        .onOpenURL(perform: queueOpenURL)
        .alert(item: $viewModel.playbackAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .onAppear {
            hasAppeared = true
            viewModel.attachStore(recentStore)
            updateExternalDisplayPlayback()
            openPendingURLIfReady()
        }
        .onChange(of: viewModel.hasVideo) { _, _ in
            updateExternalDisplayPlayback()
        }
        .onChange(of: allowsExternalDisplayPlayback) { _, _ in
            updateExternalDisplayPlayback()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                openPendingURLIfReady()
            } else {
                viewModel.saveCurrentPosition()
            }
        }
    }

    private var filePreparationOverlay: some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                ProgressView()

                Text("動画を準備中…")
                    .font(.headline)

                Text("iCloudから取得しています")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let preparingFileName {
                    Text(preparingFileName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Button("キャンセル") {
                    cancelFilePreparation()
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: 260)
            .padding(20)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding()
        }
    }

    private var homeContent: some View {
        List {
            openVideoSection
            recentList(showsNowPlaying: false)
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemBackground))
    }

    private var regularPlayerContent: some View {
        GeometryReader { geometry in
            List {
                videoArea(in: geometry)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.black)

                recentList(showsNowPlaying: true)
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

    private func updateExternalDisplayPlayback() {
        ExternalDisplayPlaybackCoordinator.shared.update(
            player: viewModel.player,
            isEnabled: viewModel.hasVideo && allowsExternalDisplayPlayback
        )
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

            PlayerView(
                player: viewModel.player,
                allowsPictureInPicture: allowsPictureInPicture
            )

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
    private func recentList(showsNowPlaying: Bool) -> some View {
        Section("最近開いた動画") {
            if recentStore.videos.isEmpty {
                Text("まだありません")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(recentStore.videos) { video in
                    Button {
                        openRecent(video)
                    } label: {
                        recentVideoRow(video, showsNowPlaying: showsNowPlaying)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(accessibilityLabel(for: video, showsNowPlaying: showsNowPlaying))
                    .accessibilityHint("開いて再生します")
                }
                .onDelete(perform: deleteRecent)
            }
        }
    }

    private func recentVideoRow(_ video: RecentVideo, showsNowPlaying: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "film")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 3) {
                Text(video.title)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let playbackText = playbackText(for: video, showsNowPlaying: showsNowPlaying) {
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
            queueOpenURL(url)
        case .failure(let error):
            if let cocoaError = error as? CocoaError, cocoaError.code == .userCancelled {
                return
            }
            viewModel.showAlert(.fileImportFailed)
        }
    }

    private func queueOpenURL(_ url: URL) {
        pendingOpenURL = url
        openPendingURLIfReady()
    }

    private func openPendingURLIfReady() {
        guard hasAppeared, scenePhase == .active, let url = pendingOpenURL else { return }
        pendingOpenURL = nil
        prepareAndOpenURL(url)
    }

    private func prepareAndOpenURL(_ url: URL) {
        filePreparationTask?.cancel()
        filePreparationID = UUID()
        filePreparationTask = nil
        isPreparingFile = false
        preparingFileName = nil

        if isFileReadyToOpen(url) {
            openSelectedURL(url)
            return
        }

        let preparationID = UUID()
        filePreparationID = preparationID
        preparingFileName = url.lastPathComponent
        isPreparingFile = true
        viewModel.clearAlert()

        filePreparationTask = Task { @MainActor in
            defer {
                if filePreparationID == preparationID {
                    isPreparingFile = false
                    preparingFileName = nil
                    filePreparationTask = nil
                }
            }

            do {
                let preparedURL = try await prepareFileForPlayback(url)
                guard !Task.isCancelled, filePreparationID == preparationID else { return }
                if scenePhase == .active {
                    openSelectedURL(preparedURL)
                } else {
                    pendingOpenURL = preparedURL
                }
            } catch is CancellationError {
                return
            } catch {
                guard filePreparationID == preparationID else { return }
                viewModel.showAlert(.filePreparationFailed)
            }
        }
    }

    private func cancelFilePreparation() {
        filePreparationID = UUID()
        filePreparationTask?.cancel()
        filePreparationTask = nil
        isPreparingFile = false
        preparingFileName = nil
    }

    private func prepareFileForPlayback(_ url: URL) async throws -> URL {
        let didAccessSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        if isFileReadyToOpen(url) {
            return url
        }

        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
        } catch {
            guard isFileReadyToOpen(url) else { throw error }
        }

        while true {
            try Task.checkCancellation()

            if isFileReadyToOpen(url) {
                return url
            }

            try await Task.sleep(nanoseconds: 500_000_000)
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
            viewModel.showAlert(.fileOpenFailed)
        }
    }

    private func isFileReadyToOpen(_ url: URL) -> Bool {
        let didAccessSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let resourceValues = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ])
        guard resourceValues?.isUbiquitousItem == true else { return true }

        switch resourceValues?.ubiquitousItemDownloadingStatus {
        case .current, .downloaded:
            return true
        default:
            return false
        }
    }

    private func openRecent(_ video: RecentVideo) {
        do {
            let url = try recentStore.resolveURL(for: video)
            prepareAndOpenURL(url)
        } catch {
            recentStore.remove(video)
            viewModel.showAlert(.recentVideoUnavailable)
        }
    }

    private func deleteRecent(at offsets: IndexSet) {
        offsets
            .map { recentStore.videos[$0] }
            .forEach(recentStore.remove)
    }

    private func playbackText(for video: RecentVideo, showsNowPlaying: Bool) -> String? {
        if showsNowPlaying, viewModel.hasVideo, video.id == viewModel.currentRecentVideoID {
            return "再生中 \(formatDuration(viewModel.currentPlaybackPosition))"
        }

        return resumeText(for: video.lastPosition)
    }

    private func accessibilityLabel(for video: RecentVideo, showsNowPlaying: Bool) -> String {
        if let playbackText = playbackText(for: video, showsNowPlaying: showsNowPlaying) {
            return "\(video.title), \(playbackText)"
        }

        return video.title
    }

    private func resumeText(for position: TimeInterval) -> String? {
        guard position >= minimumResumeDisplayPosition else { return nil }
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
