import AgentKit
import Observation

/// ノッチの表示に必要な状態。変更は `NotchPanelController` だけが行い、ビューは読むだけ。
@MainActor
@Observable
final class NotchModel {
    /// 表示している画面に合わせた寸法。画面が無いときは nil。
    var layout: NotchLayout?
    var presentation: NotchPresentationState = .character
    var mood: CharacterMood = .idle
    /// 待機中の目の動き（viewBox 単位）。待機中以外は常に中央で静止。
    var eyeMotion: EyeMotion = .resting(at: .zero)
    /// `peek` に出す文。nil なら知らせることは無い。
    var noticeText: String?
    var displayChoice: DisplayChoice = .automatic

    // MARK: - hook（ROADMAP 1-6）

    /// 新しくイベントがあった順のセッション。
    var sessions: [Session] = []
    var receiver: ReceiverStatus = .stopped
    var lastEventAt: Date?
    /// `~/.claude/settings.json` に notch-hook が登録されているか。
    var hookInstallStatus: HookInstaller.Status?
    /// 受信した hook をファイルに記録しているか（開発用）。
    var isCapturingEvents = false
}

enum ReceiverStatus: Equatable {
    case stopped
    case listening
    case failed(String)
}
