import AgentKit
import Foundation

/// hook イベントの受信からセッション一覧・キャラクターの表情・承認までをつなぐ（ROADMAP 1-6、2-2、2-3）。
///
/// - 受信は `HookSocketServer`（AgentKit）。届いたら MainActor に移って `SessionStore` に反映する。
/// - 応答待ち（権限リクエスト・質問）は `ApprovalQueue` に入れ、ユーザーがカードのボタンを押したときだけ答える（F4-2）。
///   相手が閉じた・ターミナルで答えられた・諦め時間を過ぎたものはキューから消す。
/// - 時間で変わるもの（停止扱い、完了の表情を戻す）は、次にそれが起きる時刻にワンショットで起きるだけ。
///   イベントが無ければ何も動かない。
@MainActor
final class HookCenter {
    let model: NotchModel
    private let controller: NotchPanelController
    private var server: HookSocketServer?
    private var store = SessionStore()
    private var approvals = ApprovalQueue()
    private var wakeTask: Task<Void, Never>?
    private let capture = EventCapture()

    init(model: NotchModel, controller: NotchPanelController) {
        self.model = model
        self.controller = controller
        model.isCapturingEvents = capture.isEnabled
        model.onApprovalReply = { [weak self] id, reply in self?.respond(to: id, with: reply) }
    }

    static var socketPath: String { HookBridge.socketPath(home: NSHomeDirectory()) }

    func start() {
        let server = HookSocketServer(
            path: Self.socketPath,
            onMessage: { [weak self] message in
                Task { @MainActor in self?.receive(message) }
            },
            onRequest: { [weak self] id, message in
                Task { @MainActor in self?.receiveRequest(id: id, message: message) }
            },
            onClosed: { [weak self] id in
                Task { @MainActor in self?.requestClosed(id: id) }
            }
        )
        do {
            try server.start()
            self.server = server
            model.receiver = .listening
        } catch HookSocketServer.StartError.alreadyRunning {
            model.receiver = .failed("別の Notch Agent が受信中です")
        } catch HookSocketServer.StartError.pathTooLong {
            model.receiver = .failed("ソケットのパスが長すぎます: \(Self.socketPath)")
        } catch {
            model.receiver = .failed("受信を開始できませんでした: \(error)")
        }
    }

    func stop() {
        server?.stop()
        server = nil
    }

    var isCapturing: Bool {
        get { capture.isEnabled }
        set {
            capture.isEnabled = newValue
            model.isCapturingEvents = newValue
        }
    }

    var captureDirectory: URL { capture.directory }

    // MARK: - 承認（ユーザーの操作）

    /// カードのボタンが押された。`displayedID` は押されたカードの要求 ID（表示中のものにだけ答える）。
    func respond(to displayedID: Int, with reply: HookReply) {
        let now = Date.now
        guard case .success(let request) = approvals.resolve(displayedID: displayedID, at: now) else { return }
        server?.reply(reply, to: request.id)
        if reply.decision != .pass, !request.isQuestion {
            store.permissionAnswered(sessionID: request.sessionID, at: now)
        }
        refresh(now: now)
    }

    // MARK: - 受信

    private func receive(_ message: HookWireMessage) {
        capture.write(message.hook)
        guard let event = try? HookEvent(json: message.hook) else { return }
        let now = Date.now
        store.apply(event, environment: message.env, at: now)
        model.lastEventAt = now
        // ターミナルで答えられた・ターンが終わった要求は、応答せずに片付ける。
        for request in approvals.requestsSettled(by: event) {
            approvals.remove(id: request.id, at: now)
            server?.cancel(request.id)
        }
        refresh(now: now)
    }

    private func receiveRequest(id: Int, message: HookWireMessage) {
        capture.write(message.hook)
        let now = Date.now
        // 権限リクエストは送るだけの hook を別に登録していないので、ここでセッションにも反映する。
        if message.mode == .wait, let event = try? HookEvent(json: message.hook) {
            store.apply(event, environment: message.env, at: now)
            model.lastEventAt = now
        }
        guard let request = ApprovalRequest.make(id: id, message: message, receivedAt: now),
              approvals.enqueue(request, at: now)
        else {
            // ノッチで扱えない・溜まりすぎ → ターミナルの確認に任せる。
            server?.reply(.pass, to: id)
            refresh(now: now)
            return
        }
        controller.playAlert(request.isQuestion ? .question : .approval)
        refresh(now: now)
    }

    private func requestClosed(id: Int) {
        guard approvals.remove(id: id, at: .now) != nil else { return }
        refresh(now: .now)
    }

    private func refresh(now: Date) {
        store.expire(now: now)
        let sessions = store.sessions
        if model.sessions != sessions { model.sessions = sessions }
        if model.approvals != approvals.requests { model.approvals = approvals.requests }

        let mood: CharacterMood = approvals.isEmpty ? store.mood(now: now) : .waiting
        if model.mood != mood { controller.setMood(mood) }

        let notice = approvals.current.map { approvalText(for: $0) }
            ?? store.sessionsWaitingForApproval.first.map(Self.approvalNotice)
        if model.noticeText != notice { controller.setNotice(notice) }

        scheduleWake(now: now)
    }

    private func approvalText(for request: ApprovalRequest) -> String {
        let name = store.session(id: request.sessionID)?.displayName
            ?? request.cwd.map { ($0 as NSString).lastPathComponent }
            ?? "Claude Code"
        let more = approvals.requests.count > 1 ? "（ほか \(approvals.requests.count - 1) 件）" : ""
        switch request.kind {
        case .permission(let toolName, let summary, _, _):
            let detail = [toolName, summary].compactMap { $0 }.joined(separator: " ")
            return "\(name): \(detail) を許可しますか？\(more)"
        case .question(let questions):
            return "\(name) から質問: \(questions.first?.question ?? "")\(more)"
        }
    }

    private func scheduleWake(now: Date) {
        wakeTask?.cancel()
        wakeTask = nil
        let dates = [store.nextExpiry, store.nextMoodChange(after: now)].compactMap { $0 }
        guard let next = dates.min() else { return }
        let delay = max(0.05, next.timeIntervalSince(now))
        wakeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.refresh(now: .now)
        }
    }

    private static func approvalNotice(for session: Session) -> String {
        guard let pending = session.pendingPermission else {
            return "\(session.displayName) が承認を待っています"
        }
        let detail = [pending.toolName, pending.summary].compactMap { $0 }.joined(separator: " ")
        return "\(session.displayName) が承認待ち: \(detail)"
    }
}

/// 受信した hook の JSON をそのままファイルに残す（開発用。実ペイロードのフィクスチャ採取、spec U4）。
/// 既定はオフ。プロンプトやコマンドがそのまま残るので、共有するときは伏せること。
@MainActor
private final class EventCapture {
    private static let enabledKey = "captureHookEvents"

    let directory = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/\(HookBridge.supportDirectoryName)/captures")

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    private var sequence = 0
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    func write(_ hook: JSONValue) {
        guard isEnabled, let data = try? encoder.encode(hook) else { return }
        sequence += 1
        let name = hook["hook_event_name"]?.stringValue ?? "unknown"
        let stamp = Int(Date.now.timeIntervalSince1970 * 1000)
        let url = directory.appendingPathComponent("\(stamp)-\(sequence)-\(name).json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? data.write(to: url, options: .atomic)
    }
}
