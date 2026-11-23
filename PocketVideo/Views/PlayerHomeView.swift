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
    @StateObject private var viewModel = PlayerViewModel()
    private enum PresentedSheet: String, Identifiable {
        case files, settings
        var id: Self { self }
    }
    @State private var presentedSheet: PresentedSheet?
    // The document picker may clear the sheet binding before it delivers the selected URL.
    @State private var sheetIsActive = false
    @State private var fileSelectionWasSuperseded = false
    @State private var isPlayerPresented = false
    @State private var hasAppeared = false
    private struct OpenRequest {
        var url: URL
        let audioStateAtSelection: PlayerViewModel.AudioInterruptionState
        let historyRequest: RecentVideoStore.PendingOpen
    }
    @State private var pendingOpen: OpenRequest?
    private enum PreparationPhase {
        case local, iCloud
    }
    @State private var preparationPhase: PreparationPhase?
    private var isPreparingFile: Bool { preparationPhase != nil }
    @State private var downloadFraction: Double?
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
                .navigationDestination(isPresented: playerPresentation) {
                    regularPlayerContent
                }
        }
        .sheet(item: $presentedSheet, onDismiss: sheetDidDismiss) { sheet in
            switch sheet {
            case .files:
                VideoFilePicker { url in
                    guard !fileSelectionWasSuperseded else { return }
                    if let url {
                        queueOpenURL(url)
                    } else {
                        presentedSheet = nil
                    }
                }
            case .settings:
                SettingsView()
                    .environmentObject(recentStore)
            }
        }
        .accessibilityHidden(isPreparingFile)
        .overlay {
            if isPreparingFile {
                filePreparationOverlay
            }
        }
        .onOpenURL { url in
            fileSelectionWasSuperseded = true
            queueOpenURL(url)
        }
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
            openPendingURLIfReady()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                openPendingURLIfReady()
            } else {
                viewModel.saveCurrentPosition()
            }
        }
    }

    private var playerPresentation: Binding<Bool> {
        Binding(get: { isPlayerPresented }, set: { presented in
            if !presented {
                cancelFilePreparation()
                viewModel.closeCurrentVideo()
            }
            isPlayerPresented = presented
        })
    }

    private var filePreparationOverlay: some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                Text(preparationPhase == .iCloud ? LocalizedStringKey("iCloudからダウンロード中") : LocalizedStringKey("動画を準備中"))
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)

                if let preparingFileName {
                    Text(preparingFileName)
                        .font(.caption)
                        .foregroundStyle(AppTextColor.supporting)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if let downloadFraction {
                    HStack(spacing: 10) {
                        ProgressView(value: downloadFraction)
                            .progressViewStyle(.linear)
                            .accessibilityLabel("ダウンロードの進捗")
                        Text(downloadFraction, format: .percent.precision(.fractionLength(0)))
                            .font(.subheadline.monospacedDigit())
                            .fixedSize()
                            .accessibilityHidden(true)
                    }
                } else {
                    ProgressView()
                        .accessibilityHidden(true)
                }

                Button("キャンセル") {
                    cancelFilePreparation()
                }
                .buttonStyle(.bordered)
                .tint(Color.primary)
            }
            .frame(maxWidth: 260)
            .padding(20)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding()
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
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

    private var toolbarButtons: some View {
        Group {
            Button {
                presentSheet(.files)
            } label: {
                Image(systemName: "folder")
            }
            .accessibilityLabel("動画を選択")

            Button {
                presentSheet(.settings)
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
        let height = min(max(naturalHeight, 180), geometry.size.height)

        return playerSurface
            .frame(width: fullWidth, height: height)
    }

    private var playerSurface: some View {
        ZStack {
            Color.black

            PlayerView(
                model: viewModel,
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
                presentSheet(.files)
            } label: {
                Label("動画を選択", systemImage: "folder")
            }
        }
    }

    @ViewBuilder
    private func recentList(showsNowPlaying: Bool) -> some View {
        Section {
            if recentStore.videos.isEmpty {
                Text("まだありません")
                    .foregroundStyle(AppTextColor.supporting)
            } else {
                ForEach(recentStore.videos) { video in
                    let isCurrent = showsNowPlaying && video.id == viewModel.currentRecentVideoID
                        && (viewModel.hasVideo || viewModel.isLoading)
                    let row = recentVideoRow(video, playbackText: playbackText(for: video, isCurrent: isCurrent))
                    if isCurrent {
                        row.accessibilityElement(children: .combine)
                    } else {
                        Button { openRecent(video) } label: { row }
                            .buttonStyle(.plain)
                            .accessibilityHint("開いて再生します")
                    }
                }
                .onDelete(perform: deleteRecent)
            }
        } header: {
            Text("最近開いた動画").foregroundStyle(Color.primary)
        }
    }

    private func recentVideoRow(_ video: RecentVideo, playbackText: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "film")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(video.title)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let playbackText {
                    Text(playbackText)
                        .font(.caption)
                        .foregroundStyle(AppTextColor.supporting)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
    }

    private func presentSheet(_ sheet: PresentedSheet) {
        fileSelectionWasSuperseded = false
        sheetIsActive = true
        presentedSheet = sheet
    }

    private func queueOpenURL(_ url: URL) {
        cancelFilePreparation()
        pendingOpen = OpenRequest(url: url, audioStateAtSelection: viewModel.audioInterruptionState,
                                  historyRequest: recentStore.beginOpening())
        if sheetIsActive {
            presentedSheet = nil
        } else {
            openPendingURLIfReady()
        }
    }

    private func sheetDidDismiss() {
        sheetIsActive = false
        openPendingURLIfReady()
    }

    private func openPendingURLIfReady() {
        guard hasAppeared, scenePhase == .active, !sheetIsActive, let request = pendingOpen else { return }
        pendingOpen = nil
        prepareAndOpen(request)
    }

    private func prepareAndOpen(_ request: OpenRequest) {
        let url = request.url

        let needsDownload = !isFileReadyToOpen(url)
        let preparationID = filePreparationID
        preparingFileName = url.lastPathComponent
        if needsDownload { preparationPhase = .iCloud }
        viewModel.clearAlert()

        filePreparationTask = Task { @MainActor in
            // Cached local videos usually open before a progress indicator is useful.
            let localIndicator = Task { @MainActor in
                guard !needsDownload else { return }
                try await Task.sleep(for: .milliseconds(250))
                guard filePreparationID == preparationID else { return }
                preparationPhase = .local
            }
            defer {
                localIndicator.cancel()
                if filePreparationID == preparationID {
                    preparationPhase = nil
                    preparingFileName = nil
                    downloadFraction = nil
                    filePreparationTask = nil
                }
            }

            do {
                var prepared = request
                if needsDownload {
                    prepared.url = try await prepareFileForPlayback(url, preparationID: preparationID)
                    try Task.checkCancellation()
                    preparationPhase = .local
                    downloadFraction = nil
                }
                try Task.checkCancellation()
                if scenePhase == .active {
                    await openSelected(prepared)
                } else {
                    pendingOpen = prepared
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
        pendingOpen = nil
        filePreparationID = UUID()
        filePreparationTask?.cancel()
        filePreparationTask = nil
        preparationPhase = nil
        preparingFileName = nil
        downloadFraction = nil
    }

    @MainActor
    private func prepareFileForPlayback(_ url: URL, preparationID: UUID) async throws -> URL {
        let didAccessSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        if isFileReadyToOpen(url) {
            return url
        }

        let document = PlaybackDownloadDocument(fileURL: url)
        let monitor = Task { @MainActor in
            while !Task.isCancelled && filePreparationID == preparationID {
                if document.documentState.contains(.progressAvailable),
                   let progress = document.progress, !progress.isIndeterminate,
                   progress.totalUnitCount > 0, (0...1).contains(progress.fractionCompleted) {
                    #if DEBUG
                    if downloadFraction == nil { print("[CloudProgress] document percentage available") }
                    #endif
                    downloadFraction = progress.fractionCompleted
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        let opened = await document.open()
        monitor.cancel()
        #if DEBUG
        if filePreparationID == preparationID {
            print("[CloudProgress] document opened=\(opened) reportedPercentage=\(downloadFraction != nil)")
        }
        #endif
        guard opened else {
            try Task.checkCancellation()
            throw CocoaError(.fileReadUnknown)
        }
        let preparedURL = document.fileURL
        let closed = await document.close()
        try Task.checkCancellation()
        guard closed else { throw CocoaError(.fileReadUnknown) }
        return preparedURL
    }

    private func openSelected(_ request: OpenRequest) async {
        do {
            viewModel.saveCurrentPosition()
            let recent = try await recentStore.addOrUpdate(url: request.url, request: request.historyRequest)
            try Task.checkCancellation()
            guard scenePhase == .active else {
                pendingOpen = request
                return
            }
            let storedURL = try recentStore.resolveURL(for: recent)
            guard viewModel.open(
                url: storedURL,
                resumePosition: recent.lastPosition,
                recentVideoID: recent.id,
                displayTitle: recent.title,
                audioStateAtSelection: request.audioStateAtSelection
            ) else {
                return
            }
            isPlayerPresented = true
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
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
        #if DEBUG
        print("[CloudProgress] iCloud=\(String(describing: resourceValues?.isUbiquitousItem)) status=\(resourceValues?.ubiquitousItemDownloadingStatus?.rawValue ?? "unknown")")
        #endif
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
            queueOpenURL(url)
        } catch {
            viewModel.showAlert(.recentVideoUnavailable)
        }
    }

    private func deleteRecent(at offsets: IndexSet) {
        offsets
            .map { recentStore.videos[$0] }
            .forEach(recentStore.remove)
    }

    private func playbackText(for video: RecentVideo, isCurrent: Bool) -> String? {
        if isCurrent {
            let position = viewModel.currentPlaybackPosition
            return String(
                format: viewModel.isPlaying ? String(localized: "再生中 %@") : String(localized: "再生位置 %@"),
                formatDuration(position)
            )
        }

        return resumeText(for: video.lastPosition)
    }

    private func resumeText(for position: TimeInterval) -> String? {
        guard position >= minimumResumeDisplayPosition else { return nil }
        return String(
            format: String(localized: "%@ から再開"),
            formatDuration(position)
        )
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

private final class PlaybackDownloadDocument: UIDocument {
    override func read(from url: URL) throws {
        // UIDocument coordinates the download. AVPlayer reads the video itself.
        try FileHandle(forReadingFrom: url).close()
    }
}

private struct VideoFilePicker: UIViewControllerRepresentable {
    let onFinish: (URL?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forOpeningContentTypes: supportedVideoContentTypes, asCopy: false)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onFinish: (URL?) -> Void

        init(onFinish: @escaping (URL?) -> Void) { self.onFinish = onFinish }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onFinish(urls.first)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onFinish(nil)
        }
    }
}
