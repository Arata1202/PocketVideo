import Foundation

struct PlaybackAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String

    static var fileAccessFailed: PlaybackAlert {
        PlaybackAlert(
            title: "ファイルにアクセスできません",
            message: "ファイルAppからもう一度選択してください。"
        )
    }

    static var fileImportFailed: PlaybackAlert {
        PlaybackAlert(
            title: "ファイルを開けませんでした",
            message: "別のファイルを選ぶか、ファイルAppで状態を確認してください。"
        )
    }

    static var filePreparationFailed: PlaybackAlert {
        PlaybackAlert(
            title: "動画を準備できませんでした",
            message: "ファイルAppでダウンロード状況を確認してから、もう一度試してください。"
        )
    }

    static var fileOpenFailed: PlaybackAlert {
        PlaybackAlert(
            title: "ファイルを開けませんでした",
            message: "ファイルAppで端末内にダウンロードしてから、もう一度試してください。"
        )
    }

    static var recentVideoUnavailable: PlaybackAlert {
        PlaybackAlert(
            title: "動画を利用できません",
            message: "履歴から削除しました。もう一度ファイルAppから選択してください。"
        )
    }

    static var airPlayPlaybackFailed: PlaybackAlert {
        PlaybackAlert(
            title: "AirPlayで再生できませんでした",
            message: "接続先の機器では、この動画をAirPlayで直接再生できない可能性があります。iPhoneのコントロールセンターから「画面ミラーリング」を選んで再生してください。"
        )
    }

    static var localPlaybackFailed: PlaybackAlert {
        PlaybackAlert(
            title: "動画を再生できませんでした",
            message: "ファイルが壊れているか、iPhoneで再生できない形式の可能性があります。"
        )
    }
}
