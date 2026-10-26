import AgentKit
import Foundation
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
    /// ノッチでの応答を待っている要求（先頭が表示中）。M2。
    var approvals: [ApprovalRequest] = []
    /// 承認カードのボタンが押されたときの処理（`HookCenter.respond`）。
    @ObservationIgnored var onApprovalReply: ((_ requestID: Int, _ reply: HookReply) -> Void)?
    /// ノッチの「hooks をインストール…」ボタン（`HookSetup.beginInstall`）。メニューバーのアイコンがノッチに隠れる画面向け。
    @ObservationIgnored var onInstallHooks: (() -> Void)?
    /// 受信した hook をファイルに記録しているか（開発用）。
    var isCapturingEvents = false

    // MARK: - プロジェクト（ROADMAP 3-1）

    /// 登録したプロジェクト。変更は `ProjectCenter` だけが行う。
    var projects = ProjectRegistry()
    /// 保存ファイルを読めなかったときの説明。この間は登録・編集できない。
    var projectLoadError: String?
    /// 「プロジェクトを追加…」（`ProjectCenter.beginAdd`）。
    @ObservationIgnored var onAddProject: (() -> Void)?
    /// プロジェクトの行を押したとき（`ProjectCenter.beginEdit`）。
    @ObservationIgnored var onEditProject: ((Project.ID) -> Void)?
    /// 未登録のフォルダで動いているセッションの「登録」（F1-4、`ProjectCenter.beginAdd(directory:)`）。
    @ObservationIgnored var onRegisterFolder: ((String) -> Void)?

    // MARK: - サブエージェント定義（ROADMAP 3-2）

    /// 最後に読んだ定義の一覧。まだ読んでいなければ nil。変更は `AgentLibrary` だけが行う。
    var agentOverview: AgentOverview?
    /// 「エージェント」タブを開いたとき（`AgentLibrary.refresh`）。
    @ObservationIgnored var onRefreshAgents: (() -> Void)?

    // MARK: - タスク（ROADMAP 3-3）

    /// アプリから始めたタスク（新しい順）。変更は `TaskRunner` だけが行う。
    var tasks: [TaskRun] = []
    /// 見つかった `claude` の場所。nil なら未検出。
    var claudePath: String?
    /// 「タスクを開始…」（`TaskLauncher.open`）。プロジェクトを決めて開くときはその ID。
    @ObservationIgnored var onStartTask: ((Project.ID?) -> Void)?
    /// 実行中のタスクの「停止」（`TaskRunner.stop`）。
    @ObservationIgnored var onStopTask: ((UUID) -> Void)?
    /// タスクの行を押したとき（`TaskResultViewer.show`）。
    @ObservationIgnored var onShowTask: ((UUID) -> Void)?
    /// 終わったタスクに追加の指示を渡して続ける。続けられなければ理由を返す（`TaskRunner.continueTask`、ROADMAP 3-6）。
    @ObservationIgnored var onContinueTask: ((_ id: UUID, _ prompt: String) -> String?)?

    // MARK: - クイック入力（ROADMAP 3-5）

    /// ノッチで指示を入力しているか。この間はパネルがキー入力を受け、マウスが離れても縮まない。
    var isQuickInputActive = false
    /// 入力中の指示。縮んでも消さない（開始したら空にする）。
    var quickInputDraft = ""
    /// 入力を始めるショートカットの表示（登録できなければ nil）。
    var quickInputShortcut: String?
    /// 最後にタスクを始めたプロジェクト（次の既定値）。変更は `TaskLauncher` だけが行う。
    var lastTaskProjectID: Project.ID?
    /// 入力欄を押したとき・ショートカット（`NotchPanelController.beginQuickInput`）。
    @ObservationIgnored var onBeginQuickInput: (() -> Void)?
    /// Esc・開始したあと（`NotchPanelController.endQuickInput`）。
    @ObservationIgnored var onEndQuickInput: (() -> Void)?
    /// 「開始」。始められなければ理由を返す（`TaskLauncher.start`）。
    @ObservationIgnored var onQuickStart: ((_ projectID: Project.ID, _ agent: String?, _ prompt: String) -> String?)?
}

enum ReceiverStatus: Equatable {
    case stopped
    case listening
    case failed(String)
}
