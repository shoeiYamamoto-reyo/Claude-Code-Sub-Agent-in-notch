import Foundation

/// セッションの状態（F3-1）。
public enum SessionStatus: String, Sendable, Equatable, CaseIterable {
    /// 起動直後、または入力を待っている（`Notification` の `idle_prompt`）。
    case waitingForInput
    /// プロンプトを受けて作業中。
    case working
    /// 権限の確認を待っている。
    case waitingForApproval
    /// 応答が終わった（`Stop`）。
    case done
    /// API エラーなどでターンが終わった（`StopFailure`）。
    case error
    /// 作業中のまま長く音沙汰が無い（`Stop` の取りこぼし、ターミナルの強制終了など。F3-5）。
    case stalled

    public var displayName: String {
        switch self {
        case .waitingForInput: "入力待ち"
        case .working: "実行中"
        case .waitingForApproval: "承認待ち"
        case .done: "完了"
        case .error: "エラー"
        case .stalled: "停止"
        }
    }
}

/// ツール呼び出し 1 回分（F3-3）。
public struct ToolActivity: Sendable, Equatable, Identifiable {
    public enum Status: String, Sendable, Equatable {
        case running
        case succeeded
        case failed
        /// 結果が来ないままターンが終わった（拒否・中断）。
        case interrupted
    }

    public var id: String
    public var toolName: String
    /// コマンドやファイル名など、1 行で見せる要約。
    public var summary: String?
    /// サブエージェント内の呼び出しならその ID。
    public var agentID: String?
    public var status: Status
    public var startedAt: Date
    public var endedAt: Date?
}

/// セッション内のサブエージェント（F3-2）。
public struct Subagent: Sendable, Equatable, Identifiable {
    public enum Status: String, Sendable, Equatable {
        case running
        case done
        case stalled
    }

    public var id: String
    /// エージェントの種類（定義の `name`）。
    public var type: String
    public var status: Status
    public var startedAt: Date
    public var endedAt: Date?
    public var lastEventAt: Date
    public var lastAssistantMessage: String?
    /// 実行中のツール（直近のもの）。
    public var currentTool: ToolActivity?
}

/// 承認を待っているツール呼び出し（M1 では表示だけ。応答は M2）。
public struct PendingPermission: Sendable, Equatable {
    public var toolName: String
    public var summary: String?
    public var agentID: String?
    public var requestedAt: Date
}

/// Claude Code のセッション 1 つ分。
public struct Session: Sendable, Equatable, Identifiable {
    public var id: String
    public var cwd: String?
    public var transcriptPath: String?
    public var model: String?
    public var title: String?
    public var permissionMode: String?
    /// hook を呼んだ端末（`TERM_PROGRAM`）。
    public var terminal: String?
    public var status: SessionStatus
    public var startedAt: Date
    public var lastEventAt: Date
    public var lastPrompt: String?
    public var lastAssistantMessage: String?
    public var lastError: String?
    public var pendingPermission: PendingPermission?
    /// 開始順。
    public var subagents: [Subagent]
    /// 新しいものが末尾。`SessionStore.maxRecentTools` 件まで。
    public var recentTools: [ToolActivity]

    /// 表示用の名前: タイトル、なければ作業フォルダ名。
    public var displayName: String {
        if let title, !title.isEmpty { return title }
        if let cwd, !cwd.isEmpty {
            let name = (cwd as NSString).lastPathComponent
            return name.isEmpty ? cwd : name
        }
        return String(id.prefix(8))
    }

    public var runningSubagents: [Subagent] { subagents.filter { $0.status == .running } }

    /// セッション本体かサブエージェントのどちらかが動いているか。
    public var isActive: Bool {
        status == .working || status == .waitingForApproval || !runningSubagents.isEmpty
    }
}
