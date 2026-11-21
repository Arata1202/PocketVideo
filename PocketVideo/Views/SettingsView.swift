import SwiftUI

private enum AppLinks {
    static let contact = URL(string: "https://realunivlog.com/contact")!
    static let github = URL(string: "https://github.com/Arata1202/PocketVideo")!
    static let privacyPolicy = URL(string: "https://realunivlog.com/privacy")!
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var recentStore: RecentVideoStore
    @AppStorage("appAppearance") private var appAppearance = AppAppearance.system.rawValue
    @AppStorage("allowsPictureInPicture") private var allowsPictureInPicture = true
    @ScaledMetric(relativeTo: .body) private var githubIconSize: CGFloat = 24
    @State private var isClearRecentConfirmationPresented = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("ピクチャ・イン・ピクチャを許可", isOn: $allowsPictureInPicture)
                } header: {
                    Text("再生").foregroundStyle(Color.primary)
                }

                Section {
                    if dynamicTypeSize.isAccessibilitySize {
                        themePicker.pickerStyle(.inline)
                    } else {
                        themePicker.pickerStyle(.segmented)
                    }
                } header: {
                    Text("表示").foregroundStyle(Color.primary)
                }

                Section {
                    Button(role: .destructive) {
                        isClearRecentConfirmationPresented = true
                    } label: {
                        Text("履歴をすべて削除").foregroundStyle(AppTextColor.red)
                    }
                    .disabled(recentStore.videos.isEmpty)
                } header: {
                    Text("履歴").foregroundStyle(Color.primary)
                }

                Section {
                    Link(destination: AppLinks.contact) {
                        Label("お問い合わせ", systemImage: "envelope")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                    }

                    Link(destination: AppLinks.privacyPolicy) {
                        Label("プライバシーポリシー", systemImage: "hand.raised")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                    }

                    Link(destination: AppLinks.github) {
                        Label {
                            Text("GitHub")
                        } icon: {
                            Image("GitHubMark")
                                .resizable()
                                .scaledToFit()
                                .frame(width: githubIconSize, height: githubIconSize)
                                .foregroundStyle(.primary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                    }
                } header: {
                    Text("サポート").foregroundStyle(Color.primary)
                }

                Section {
                    LabeledContent("対応形式") {
                        Text(verbatim: "MP4, MOV, M4V, 3GP, 3G2").foregroundStyle(Color.primary)
                    }
                    Text("同じ拡張子でも、コーデックによってはこの端末で再生できない場合があります。")
                        .font(.caption)
                        .foregroundStyle(AppTextColor.supporting)
                    LabeledContent("バージョン") {
                        Text(verbatim: appVersion).foregroundStyle(Color.primary)
                    }
                } header: {
                    Text("アプリ情報").foregroundStyle(Color.primary)
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") {
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

    private var themePicker: some View {
        Picker("テーマ", selection: $appAppearance) {
            ForEach(AppAppearance.allCases) { appearance in
                Text(appearance.title).tag(appearance.rawValue)
            }
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return version ?? "-"
    }
}
