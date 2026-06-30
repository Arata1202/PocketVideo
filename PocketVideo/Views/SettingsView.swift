import SwiftUI

private enum AppLinks {
    static let support = URL(string: "https://realunivlog.com/")!
    static let privacyPolicy = URL(string: "https://realunivlog.com/privacy")!
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var recentStore: RecentVideoStore
    @AppStorage("appAppearance") private var appAppearance = AppAppearance.system.rawValue
    @AppStorage("allowsPictureInPicture") private var allowsPictureInPicture = true
    @AppStorage("allowsExternalDisplayPlayback") private var allowsExternalDisplayPlayback = true
    @State private var isClearRecentConfirmationPresented = false

    var body: some View {
        NavigationStack {
            Form {
                Section("再生") {
                    Toggle("ピクチャインピクチャを許可", isOn: $allowsPictureInPicture)
                    Toggle("外部画面で動画を表示", isOn: $allowsExternalDisplayPlayback)
                }

                Section("表示") {
                    Picker("テーマ", selection: $appAppearance) {
                        ForEach(AppAppearance.allCases) { appearance in
                            Text(appearance.title)
                                .tag(appearance.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("履歴") {
                    Button("履歴をすべて削除", role: .destructive) {
                        isClearRecentConfirmationPresented = true
                    }
                    .disabled(recentStore.videos.isEmpty)
                }

                Section("サポート") {
                    Link(destination: AppLinks.support) {
                        Label("サポート", systemImage: "questionmark.circle")
                    }

                    Link(destination: AppLinks.privacyPolicy) {
                        Label("プライバシーポリシー", systemImage: "hand.raised")
                    }
                }

                Section("アプリ情報") {
                    LabeledContent("対応形式", value: "MP4, MOV, M4V, 3GP, 3G2")
                    LabeledContent("バージョン", value: appVersion)
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
