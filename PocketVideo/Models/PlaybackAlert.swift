import Foundation

struct PlaybackAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String

    static var fileAccessFailed: PlaybackAlert {
        PlaybackAlert(
            title: String(localized: "ファイルにアクセスできません"),
            message: String(localized: "ファイルアプリからもう一度選択してください。")
        )
    }

    static var fileImportFailed: PlaybackAlert {
        PlaybackAlert(
            title: String(localized: "ファイルを開けませんでした"),
            message: String(localized: "別のファイルを選ぶか、ファイルアプリで状態を確認してください。")
        )
    }

    static var filePreparationFailed: PlaybackAlert {
        PlaybackAlert(
            title: String(localized: "動画を準備できませんでした"),
            message: String(localized: "ファイルアプリでダウンロード状況を確認してから、もう一度試してください。")
        )
    }

    static var fileOpenFailed: PlaybackAlert {
        PlaybackAlert(
            title: String(localized: "ファイルを開けませんでした"),
            message: String(localized: "ファイルアプリで端末内にダウンロードしてから、もう一度試してください。")
        )
    }

    static var recentVideoUnavailable: PlaybackAlert {
        PlaybackAlert(
            title: String(localized: "動画を利用できません"),
            message: String(localized: "履歴から削除しました。もう一度ファイルアプリから選択してください。")
        )
    }

    static var airPlayPlaybackFailed: PlaybackAlert {
        PlaybackAlert(
            title: String(localized: "AirPlayで再生できませんでした"),
            message: String(localized: "接続先の機器または動画のコーデックが、AirPlayの直接再生に対応していない可能性があります。画面ミラーリングで再生できる場合があります。")
        )
    }

    static var localPlaybackFailed: PlaybackAlert {
        PlaybackAlert(
            title: String(localized: "動画を再生できませんでした"),
            message: String(localized: "ファイルが壊れているか、この端末で再生できない形式の可能性があります。")
        )
    }
}
