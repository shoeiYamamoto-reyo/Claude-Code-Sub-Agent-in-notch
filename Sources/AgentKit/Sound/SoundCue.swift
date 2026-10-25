import Foundation

/// アプリが鳴らす効果音の種類（REQUIREMENTS F0-6、docs/design/sound.md）。
///
/// 音はすべてこのアプリのオリジナルで、`SoundSynthesizer` がコードから合成する（音声ファイルを持たない）。
public enum SoundCue: String, Sendable, Equatable, Hashable, CaseIterable, Codable {
    /// ノッチが展開した。
    case expand
    /// 展開したノッチが縮んだ。
    case collapse
    /// お知らせ（peek）が出た。
    case notice
    /// 権限リクエストが届いた（M2 で使う）。
    case approval
    /// `AskUserQuestion` などで回答を求められた（M2 で使う）。
    case question
    /// タスク・セッションが完了した。
    case finished
    /// エラーで止まった。
    case error

    /// 音の分類。設定でまとめてオン／オフする単位。
    public enum Category: String, Sendable, Equatable, CaseIterable, Codable {
        /// 操作への反応（開閉）。macOS の「ユーザインターフェイスのサウンドエフェクト」にも従う。
        case interface
        /// 知らせ（お知らせ、承認待ち、完了、エラー）。
        case alert
    }

    public var category: Category {
        switch self {
        case .expand, .collapse: .interface
        case .notice, .approval, .question, .finished, .error: .alert
        }
    }

    /// メニューなどに出す名前。
    public var displayName: String {
        switch self {
        case .expand: "ノッチを開く"
        case .collapse: "ノッチを閉じる"
        case .notice: "お知らせ"
        case .approval: "承認待ち"
        case .question: "質問"
        case .finished: "完了"
        case .error: "エラー"
        }
    }

    /// ノッチの表示状態が変わったときに鳴らす音。
    ///
    /// - 展開すると `expand`、展開から縮むと `collapse`。
    /// - キャラクターだけの状態からお知らせが出ると `notice`。お知らせが消えるときは鳴らさない。
    public static func forPresentationChange(
        from old: NotchPresentationState,
        to new: NotchPresentationState
    ) -> SoundCue? {
        switch (old, new) {
        case (.expanded, .expanded): nil
        case (_, .expanded): .expand
        case (.expanded, _): .collapse
        case (.character, .peek): .notice
        default: nil
        }
    }

    /// キャラクターの状態が変わったときに鳴らす音。
    ///
    /// 承認待ち（`waiting`）は peek の `notice` か、M2 の承認キューが `approval` を鳴らすので、ここでは鳴らさない
    /// （同じ出来事で 2 回鳴らないように）。
    public static func forMoodChange(from old: CharacterMood, to new: CharacterMood) -> SoundCue? {
        guard old != new else { return nil }
        switch new {
        case .done: return .finished
        case .error: return .error
        case .idle, .working, .waiting: return nil
        }
    }
}
