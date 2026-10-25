import AgentKit
import Foundation

/// hook イベントの受信からセッション一覧・キャラクターの表情までをつなぐ（ROADMAP 1-6）。
///
/// - 受信は `HookSocketServer`（AgentKit）。届いたら MainActor に移って `SessionStore` に反映する。
/// - 時間で変わるもの（停止扱い、完了の表情を戻す）は、次にそれが起きる時刻にワンショットで起きるだけ。
///   イベントが無ければ何も動かない。
@MainActor
final class HookCenter {
    let model: NotchModel
    private let controller: NotchPanelController
    private var server: HookSocketServer?
    private var store = SessionStore()
    private var wakeTask: Task<Void, Never>?
    private let capture = EventCapture()

    init(model: NotchModel, controller: NotchPanelController) {
        self.model = model
        self.controller = controller
        model.isCapturingEvents = capture.isEnabled
    }

    static var socketPath: String { HookBridge.socketPath(home: NSHomeDirectory()) }

    func start() {
        let server = HookSocketServer(path: Self.socketPath) { [weak self] message in
            Task { @MainActor in self?.receive(message) }
        }
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

    private func receive(_ message: HookWireMessage) {
        capture.write(message.hook)
        guard let event = try? HookEvent(json: message.hook) else { return }
        let now = Date.now
        store.apply(event, environment: message.env, at: now)
        model.lastEventAt = now
        refresh(now: now)
    }

    private func refresh(now: Date) {
        store.expire(now: now)
        let sessions = store.sessions
        if model.sessions != sessions { model.sessions = sessions }

        let mood = store.mood(now: now)
        if model.mood != mood { controller.setMood(mood) }

        let notice = store.sessionsWaitingForApproval.first.map(Self.approvalNotice)
        if model.noticeText != notice { controller.setNotice(notice) }

        scheduleWake(now: now)
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
