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
            .navigationTitle("MP4プレイヤー")
            .toolbar {
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

    private var portraitContent: some View {
        List {
            Section {
                if viewModel.hasVideo {
                    videoArea
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                        .listRowBackground(Color.clear)
                } else {
                    emptyState
                }
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

            VideoPlayer(player: viewModel.player)
                .ignoresSafeArea()

            if viewModel.isLoading {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.3)
            }
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

            Text("MP4を開く")
                .font(.headline)

            Button {
                isFileImporterPresented = true
            } label: {
                Label("動画を選択", systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var recentList: some View {
        if !recentStore.videos.isEmpty {
            Section("最近開いた動画") {
                ForEach(recentStore.videos) { video in
                    Button {
                        openRecent(video)
                    } label: {
                        HStack(spacing: 12) {
                            Text(video.title)
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            Spacer()

                            Image(systemName: "play.circle")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
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
}

#Preview {
    PlayerHomeView()
        .environmentObject(RecentVideoStore())
}
