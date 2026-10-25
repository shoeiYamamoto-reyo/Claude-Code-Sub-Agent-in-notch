import Foundation

/// `AskUserQuestion` の 1 問（`docs/claude-code-spec.md` 4 章）。
public struct AskQuestion: Sendable, Equatable {
    public static let toolName = "AskUserQuestion"

    public struct Option: Sendable, Equatable {
        public var label: String
        public var description: String?
    }

    public var question: String
    public var header: String?
    public var options: [Option]
    public var multiSelect: Bool

    /// `tool_input.questions` を読む。形が想定と違えば nil（ノッチでは扱わず、ターミナルに任せる）。
    public static func parse(toolInput: JSONValue?) -> [AskQuestion]? {
        guard let items = toolInput?["questions"]?.arrayValue, (1...4).contains(items.count) else { return nil }
        var questions: [AskQuestion] = []
        for item in items {
            guard let text = item["question"]?.stringValue, !text.isEmpty,
                  let rawOptions = item["options"]?.arrayValue, !rawOptions.isEmpty
            else { return nil }
            var options: [Option] = []
            for raw in rawOptions {
                guard let label = raw["label"]?.stringValue, !label.isEmpty else { return nil }
                options.append(Option(label: label, description: raw["description"]?.stringValue))
            }
            questions.append(AskQuestion(
                question: text,
                header: item["header"]?.stringValue,
                options: options,
                multiSelect: item["multiSelect"]?.boolValue ?? false
            ))
        }
        // 回答は「質問文 → ラベル」なので、同じ質問文が 2 つあると区別できない。
        guard Set(questions.map(\.question)).count == questions.count else { return nil }
        return questions
    }

    /// 選んだラベルを回答の文字列にする（複数選択はカンマ区切り）。
    public static func answerText(for labels: [String]) -> String {
        labels.joined(separator: ", ")
    }
}

/// ノッチで答えを待っている要求 1 件（F4-1、F4-5）。
public struct ApprovalRequest: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        /// 権限リクエスト。`suggestions` があれば「常に許可」を出せる。
        case permission(toolName: String, summary: String?, detail: String?, hasSuggestions: Bool)
        case question([AskQuestion])
    }

    /// 接続ごとの ID（`HookSocketServer` が振る）。応答はこの ID に返す。
    public var id: Int
    public var kind: Kind
    public var sessionID: String
    public var cwd: String?
    /// サブエージェント内の要求なら、その種類。
    public var agentType: String?
    public var receivedAt: Date
    /// ターミナルなどで答えられたことを `PostToolUse` で見分けるための、ツール名と入力の組。
    public var inputKey: String

    /// hook のメッセージから作る。ノッチで扱えないもの（未知のモード、読めない質問）は nil。
    public static func make(id: Int, message: HookWireMessage, receivedAt: Date) -> ApprovalRequest? {
        guard let event = try? HookEvent(json: message.hook) else { return nil }
        let toolName = event.toolName ?? "?"
        let kind: Kind
        switch message.mode {
        case .wait:
            guard event.name == .permissionRequest else { return nil }
            kind = .permission(
                toolName: toolName,
                summary: ToolSummary.summarize(toolName: toolName, input: event.toolInput),
                detail: detail(toolName: toolName, input: event.toolInput),
                hasSuggestions: !(event.raw["permission_suggestions"]?.arrayValue ?? []).isEmpty
            )
        case .ask:
            guard event.name == .preToolUse, toolName == AskQuestion.toolName,
                  let questions = AskQuestion.parse(toolInput: event.toolInput)
            else { return nil }
            kind = .question(questions)
        case .event:
            return nil
        }
        return ApprovalRequest(
            id: id,
            kind: kind,
            sessionID: event.sessionID,
            cwd: event.cwd,
            agentType: event.agentID == nil ? nil : event.agentType,
            receivedAt: receivedAt,
            inputKey: inputKey(toolName: toolName, input: event.toolInput)
        )
    }

    public var isQuestion: Bool {
        if case .question = kind { return true }
        return false
    }

    /// 承認カードに出す、要約より詳しい内容（コマンド全文、ファイルのパス、URL など）。
    static func detail(toolName: String, input: JSONValue?) -> String? {
        guard let input else { return nil }
        let keys: [String] = switch toolName {
        case "Bash": ["command"]
        case "Read", "Edit", "Write", "MultiEdit": ["file_path"]
        case "NotebookEdit": ["notebook_path"]
        case "WebFetch": ["url"]
        case "WebSearch": ["query"]
        case "Agent", "Task": ["prompt", "description"]
        default: ["command", "file_path", "path", "url", "query", "description"]
        }
        guard let text = keys.lazy.compactMap({ input[$0]?.stringValue }).first(where: { !$0.isEmpty }) else { return nil }
        return text.count > 600 ? String(text.prefix(599)) + "…" : text
    }

    static func inputKey(toolName: String, input: JSONValue?) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = input.flatMap { try? encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) } ?? ""
        return "\(toolName)\u{0}\(body)"
    }
}

/// 承認待ちのキュー（ROADMAP 2-2）。値型で、時刻は引数で受け取る。
///
/// 守ること（F4-2）: 応答はユーザーの明示的な操作でだけ作る。キューは「どの要求に応答してよいか」を判定するだけで、
/// 自分から許可を作ることはない。
public struct ApprovalQueue: Sendable, Equatable {
    /// これ以上溜まったら、新しい要求はノッチで扱わずターミナルに任せる（coucou と同じ 5 件）。
    public var capacity: Int
    /// カードが切り替わってからこの時間は、クリックを受け付けない（切り替わった直後の誤クリック対策）。
    public var clickGuard: TimeInterval

    public private(set) var requests: [ApprovalRequest] = []
    /// 先頭の要求が画面に出始めた時刻。
    public private(set) var currentShownAt: Date?

    public init(capacity: Int = 5, clickGuard: TimeInterval = 0.4) {
        self.capacity = capacity
        self.clickGuard = clickGuard
    }

    /// 画面に出している要求（先頭）。
    public var current: ApprovalRequest? { requests.first }

    public var isEmpty: Bool { requests.isEmpty }

    /// 足す。いっぱいなら false（呼び出し側は `pass` を返す）。
    public mutating func enqueue(_ request: ApprovalRequest, at now: Date) -> Bool {
        guard requests.count < capacity, !requests.contains(where: { $0.id == request.id }) else { return false }
        requests.append(request)
        if requests.count == 1 { currentShownAt = now }
        return true
    }

    public enum ResolveError: Error, Equatable {
        /// 押されたカードはもう先頭ではない（切り替わった・片付いた）。
        case notCurrent
        /// カードが出た直後で、まだ押せない。
        case tooSoon
    }

    /// ユーザーが `displayedID` のカードで操作した。応答してよければその要求を取り出して返す。
    public mutating func resolve(displayedID: Int, at now: Date) -> Result<ApprovalRequest, ResolveError> {
        guard let current, current.id == displayedID else { return .failure(.notCurrent) }
        if let shownAt = currentShownAt, now.timeIntervalSince(shownAt) < clickGuard { return .failure(.tooSoon) }
        removeFirst(at: now)
        return .success(current)
    }

    /// 接続が切れた・アプリ側で諦めたなど、応答せずに消す。
    @discardableResult
    public mutating func remove(id: Int, at now: Date) -> ApprovalRequest? {
        guard let index = requests.firstIndex(where: { $0.id == id }) else { return nil }
        if index == 0 { return removeFirst(at: now) }
        return requests.remove(at: index)
    }

    /// hook イベントから、もう答えが出た要求を見つける（ターミナルで答えられた場合）。
    /// - `PostToolUse` / `PostToolUseFailure`: 同じセッション・同じツールと入力の要求。
    /// - `Stop` / `StopFailure` / `SessionEnd` / `UserPromptSubmit`: そのセッションの要求すべて。
    public func requestsSettled(by event: HookEvent) -> [ApprovalRequest] {
        let sameSession = requests.filter { $0.sessionID == event.sessionID }
        switch event.name {
        case .postToolUse, .postToolUseFailure:
            let key = ApprovalRequest.inputKey(toolName: event.toolName ?? "?", input: event.toolInput)
            return sameSession.filter { $0.inputKey == key }
        case .stop, .stopFailure, .sessionEnd, .userPromptSubmit:
            return sameSession
        default:
            return []
        }
    }

    @discardableResult
    private mutating func removeFirst(at now: Date) -> ApprovalRequest {
        let removed = requests.removeFirst()
        currentShownAt = requests.isEmpty ? nil : now
        return removed
    }
}
