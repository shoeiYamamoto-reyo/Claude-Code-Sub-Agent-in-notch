import Foundation

/// hook イベントを順に受けて、セッションとサブエージェントの状態をまとめる（ROADMAP 1-5）。
///
/// 値型で、時刻は引数で受け取る（テストで時間を進められるように）。タイマーは持たない。
/// 「一定時間音沙汰が無い」の判定は、呼び出し側が `nextExpiry` の時刻に `expire(now:)` を呼ぶ。
public struct SessionStore: Sendable, Equatable {
    public static let maxRecentTools = 30

    /// 作業中のまま、この時間イベントが無ければ「停止」にする（`Stop` の取りこぼし。F3-5）。
    public var stalledAfter: TimeInterval
    /// この時間イベントが無いセッションは一覧から消す（`SessionEnd` が来ないことがあるため）。
    public var forgetAfter: TimeInterval
    /// 完了・エラーをキャラクターの表情に出しておく時間。
    public var moodHoldDuration: TimeInterval

    private var byID: [String: Session] = [:]
    private var toolSequence = 0

    public init(stalledAfter: TimeInterval = 30 * 60, forgetAfter: TimeInterval = 12 * 60 * 60, moodHoldDuration: TimeInterval = 20) {
        self.stalledAfter = stalledAfter
        self.forgetAfter = forgetAfter
        self.moodHoldDuration = moodHoldDuration
    }

    /// 新しくイベントがあった順。
    public var sessions: [Session] {
        byID.values.sorted { ($0.lastEventAt, $0.id) > ($1.lastEventAt, $1.id) }
    }

    public func session(id: String) -> Session? { byID[id] }

    // MARK: - イベントの反映

    public mutating func apply(_ event: HookEvent, environment: HookWireMessage.Environment? = nil, at now: Date) {
        if event.name == .sessionEnd {
            byID[event.sessionID] = nil
            return
        }

        var session = byID[event.sessionID] ?? Session(
            id: event.sessionID, status: .waitingForInput, startedAt: now, lastEventAt: now,
            subagents: [], recentTools: []
        )
        session.lastEventAt = now
        if let cwd = event.cwd { session.cwd = cwd }
        if let path = event.transcriptPath { session.transcriptPath = path }
        if let mode = event.permissionMode { session.permissionMode = mode }
        if let terminal = environment?.termProgram { session.terminal = terminal }
        if let agentID = event.agentID, event.name != .subagentStart, event.name != .subagentStop, event.name != .stop {
            touchSubagent(id: agentID, type: event.agentType, in: &session, at: now)
        }

        switch event.name {
        case .sessionStart:
            if let model = event.model { session.model = model }
            if let title = event.sessionTitle { session.title = title }
            if event.source == "clear" {
                session.subagents = []
                session.recentTools = []
                session.lastPrompt = nil
                session.lastAssistantMessage = nil
            }
            if event.source != "compact" {
                session.status = .waitingForInput
                session.pendingPermission = nil
                session.lastError = nil
            }

        case .userPromptSubmit:
            endRunningTools(in: &session, agentID: nil, at: now)
            session.lastPrompt = event.prompt.flatMap { ToolSummary.oneLine($0, maxLength: 200) }
            session.status = .working
            session.pendingPermission = nil
            session.lastError = nil

        case .preToolUse:
            let tool = startTool(event, at: now)
            appendTool(tool, to: &session)
            if let agentID = event.agentID {
                updateSubagent(id: agentID, in: &session) { $0.currentTool = tool }
            } else if session.status != .waitingForApproval {
                session.status = .working
            }

        case .permissionRequest:
            let toolName = event.toolName ?? "?"
            session.pendingPermission = PendingPermission(
                toolName: toolName,
                summary: ToolSummary.summarize(toolName: toolName, input: event.toolInput),
                agentID: event.agentID,
                requestedAt: now
            )
            session.status = .waitingForApproval

        case .postToolUse, .postToolUseFailure:
            let failed = event.name == .postToolUseFailure
            if let toolUseID = event.toolUseID, let index = session.recentTools.lastIndex(where: { $0.id == toolUseID }) {
                session.recentTools[index].status = failed ? .failed : .succeeded
                session.recentTools[index].endedAt = now
            }
            if let agentID = event.agentID {
                updateSubagent(id: agentID, in: &session) { subagent in
                    if subagent.currentTool?.id == event.toolUseID { subagent.currentTool = nil }
                }
            }
            // ツールが動いた = 承認待ちは（ターミナルなどで）解決した。
            if let pending = session.pendingPermission, pending.agentID == event.agentID {
                session.pendingPermission = nil
            }
            if session.pendingPermission == nil, event.agentID == nil || session.status == .waitingForApproval {
                session.status = .working
            }

        case .notification:
            switch event.notificationType {
            case "permission_prompt":
                if session.status == .working { session.status = .waitingForApproval }
            case "idle_prompt":
                if session.status == .working || session.status == .stalled { session.status = .waitingForInput }
            default:
                break
            }

        case .subagentStart:
            if let agentID = event.agentID {
                if session.subagents.contains(where: { $0.id == agentID }) {
                    touchSubagent(id: agentID, type: event.agentType, in: &session, at: now)
                } else {
                    session.subagents.append(Subagent(
                        id: agentID, type: event.agentType ?? "agent", status: .running,
                        startedAt: now, lastEventAt: now
                    ))
                }
            }

        case .subagentStop:
            // 対応する SubagentStart が無いもの（Claude Code 内部のエージェント）は無視する。
            if let agentID = event.agentID {
                updateSubagent(id: agentID, in: &session) { subagent in
                    subagent.status = .done
                    subagent.endedAt = now
                    subagent.lastEventAt = now
                    subagent.currentTool = nil
                    if let message = event.lastAssistantMessage { subagent.lastAssistantMessage = message }
                }
                endRunningTools(in: &session, agentID: agentID, at: now)
            }

        case .stop:
            endRunningTools(in: &session, agentID: nil, at: now)
            session.status = .done
            session.pendingPermission = nil
            if let message = event.lastAssistantMessage { session.lastAssistantMessage = message }

        case .stopFailure:
            endRunningTools(in: &session, agentID: nil, at: now)
            session.status = .error
            session.pendingPermission = nil
            session.lastError = event.raw["error_details"]?.stringValue ?? event.raw["error"]?.stringValue

        case .sessionEnd, .unknown:
            break
        }

        byID[session.id] = session
    }

    // MARK: - 時間による片付け

    /// 次に `expire(now:)` を呼ぶべき時刻。何も起きないなら nil。
    public var nextExpiry: Date? {
        var dates: [Date] = []
        for session in byID.values {
            dates.append(session.lastEventAt + forgetAfter)
            if session.status == .working || session.status == .waitingForApproval {
                dates.append(session.lastEventAt + stalledAfter)
            }
            for subagent in session.subagents where subagent.status == .running {
                dates.append(subagent.lastEventAt + stalledAfter)
            }
        }
        return dates.min()
    }

    /// 長く音沙汰の無いセッションを「停止」にし、さらに古いものを消す。変化があれば true。
    @discardableResult
    public mutating func expire(now: Date) -> Bool {
        let before = byID
        for (id, var session) in byID {
            if now.timeIntervalSince(session.lastEventAt) >= forgetAfter {
                byID[id] = nil
                continue
            }
            if (session.status == .working || session.status == .waitingForApproval),
               now.timeIntervalSince(session.lastEventAt) >= stalledAfter {
                session.status = .stalled
                session.pendingPermission = nil
            }
            for index in session.subagents.indices where session.subagents[index].status == .running
                && now.timeIntervalSince(session.subagents[index].lastEventAt) >= stalledAfter {
                session.subagents[index].status = .stalled
                session.subagents[index].currentTool = nil
            }
            byID[id] = session
        }
        return byID != before
    }

    // MARK: - キャラクターと通知

    /// 全セッションをまとめたキャラクターの表情。
    public func mood(now: Date) -> CharacterMood {
        let all = byID.values
        if all.contains(where: { $0.status == .waitingForApproval }) { return .waiting }
        if all.contains(where: \.isActive) { return .working }
        if let latest = all.max(by: { $0.lastEventAt < $1.lastEventAt }),
           now.timeIntervalSince(latest.lastEventAt) < moodHoldDuration {
            if latest.status == .error { return .error }
            if latest.status == .done { return .done }
        }
        return .idle
    }

    /// `mood(now:)` が時間の経過だけで変わる次の時刻。
    public func nextMoodChange(after now: Date) -> Date? {
        guard let latest = byID.values.max(by: { $0.lastEventAt < $1.lastEventAt }),
              latest.status == .done || latest.status == .error
        else { return nil }
        let date = latest.lastEventAt + moodHoldDuration
        return date > now ? date : nil
    }

    /// 承認を待っているセッション（古い順）。
    public var sessionsWaitingForApproval: [Session] {
        byID.values
            .filter { $0.status == .waitingForApproval }
            .sorted { ($0.pendingPermission?.requestedAt ?? $0.lastEventAt) < ($1.pendingPermission?.requestedAt ?? $1.lastEventAt) }
    }

    // MARK: - 内部

    private mutating func startTool(_ event: HookEvent, at now: Date) -> ToolActivity {
        let id: String
        if let toolUseID = event.toolUseID {
            id = toolUseID
        } else {
            toolSequence += 1
            id = "local-\(toolSequence)"
        }
        let toolName = event.toolName ?? "?"
        return ToolActivity(
            id: id,
            toolName: toolName,
            summary: ToolSummary.summarize(toolName: toolName, input: event.toolInput),
            agentID: event.agentID,
            status: .running,
            startedAt: now
        )
    }

    private func appendTool(_ tool: ToolActivity, to session: inout Session) {
        session.recentTools.removeAll { $0.id == tool.id }
        session.recentTools.append(tool)
        if session.recentTools.count > Self.maxRecentTools {
            session.recentTools.removeFirst(session.recentTools.count - Self.maxRecentTools)
        }
    }

    /// ターンが終わったのに結果が来ていないツール（拒否・中断）を「中断」にする。
    private func endRunningTools(in session: inout Session, agentID: String?, at now: Date) {
        for index in session.recentTools.indices
        where session.recentTools[index].status == .running && session.recentTools[index].agentID == agentID {
            session.recentTools[index].status = .interrupted
            session.recentTools[index].endedAt = now
        }
    }

    /// サブエージェント内のイベント。`SubagentStart` を取りこぼしていたら（アプリの起動前に始まったなど）ここで足す。
    private func touchSubagent(id: String, type: String?, in session: inout Session, at now: Date) {
        if let index = session.subagents.firstIndex(where: { $0.id == id }) {
            session.subagents[index].lastEventAt = now
            if session.subagents[index].status == .stalled { session.subagents[index].status = .running }
        } else {
            session.subagents.append(Subagent(
                id: id, type: type ?? "agent", status: .running, startedAt: now, lastEventAt: now
            ))
        }
    }

    private func updateSubagent(id: String, in session: inout Session, _ body: (inout Subagent) -> Void) {
        guard let index = session.subagents.firstIndex(where: { $0.id == id }) else { return }
        body(&session.subagents[index])
    }
}
