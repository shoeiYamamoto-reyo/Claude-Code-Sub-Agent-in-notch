import AgentKit
import AppKit
import Foundation

/// アプリから始めたタスク 1 つ分の表示用の状態。
struct TaskRun: Identifiable, Equatable {
    enum State: Equatable {
        case running
        /// 停止を頼んだ（SIGINT を送った）。
        case stopping
        case finished
        case stopped
        case failed(String)

        var displayName: String {
            switch self {
            case .running: "実行中"
            case .stopping: "停止中"
            case .finished: "完了"
            case .stopped: "停止"
            case .failed: "エラー"
            }
        }
    }

    /// `--session-id` と同じ。hook のセッションと結び付く。
    let id: UUID
    let projectID: UUID
    let projectName: String
    let agent: String?
    let prompt: String
    let startedAt: Date
    var endedAt: Date?
    var state: State
    /// stream-json の出力を書いたファイル（結果の表示は M3-4）。
    let outputPath: String

    var isActive: Bool { state == .running || state == .stopping }

    /// hook から見たセッション ID（小文字）。
    var sessionID: String { id.uuidString.lowercased() }
}

/// `claude -p` を子プロセスで起動・停止する（ROADMAP 3-3、ADR-0002）。
///
/// - コマンドと環境変数の組み立ては `TaskCommand`（AgentKit）。指示文は標準入力で渡す。
/// - 出力は読み捨てずに `~/Library/Application Support/NotchAgent/tasks/<session-id>.jsonl` に書く
///   （パイプを詰まらせないため。表示は M3-4）。標準エラーは最後の数 KB だけ覚えてエラー表示に使う。
/// - 停止は SIGINT（ターンを終わらせて記録を残す）→ 5 秒で終わらなければ SIGTERM。
/// - アプリの終了時は動いているタスクに SIGTERM を送る（待たない）。
@MainActor
final class TaskRunner {
    let model: NotchModel
    private let claude: ClaudeSetup
    private var processes: [UUID: Process] = [:]
    private var stopTimers: [UUID: Task<Void, Never>] = [:]
    private var stderrTails: [UUID: StderrTail] = [:]

    /// 一覧に残す終わったタスクの数。
    private static let keepFinished = 10

    init(model: NotchModel, claude: ClaudeSetup) {
        self.model = model
        self.claude = claude
        model.onStopTask = { [weak self] id in self?.stop(id) }
    }

    static var outputDirectory: URL {
        URL(fileURLWithPath: HookBridge.socketPath(home: NSHomeDirectory()))
            .deletingLastPathComponent()
            .appendingPathComponent("tasks", isDirectory: true)
    }

    /// タスクを始める。始められなければ理由を返す。
    func start(_ request: TaskRequest, project: Project) -> String? {
        guard let executable = claude.executablePath() else {
            return "claude コマンドが見つかりません。メニューバーの「claude の場所を指定…」で指定してください。"
        }
        var secrets: [String: String] = [:]
        for variable in project.environment.variables where variable.isSecret {
            do {
                if let value = try ProjectSecrets.value(projectID: project.id, name: variable.name) {
                    secrets[variable.name] = value
                }
            } catch {
                return error.localizedDescription
            }
        }

        let outputURL = Self.outputDirectory.appendingPathComponent("\(request.sessionID.uuidString.lowercased()).jsonl")
        let output: FileHandle
        do {
            try FileManager.default.createDirectory(at: Self.outputDirectory, withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                return "出力ファイルを作れませんでした: \(outputURL.path)"
            }
            output = try FileHandle(forWritingTo: outputURL)
        } catch {
            return error.localizedDescription
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = TaskCommand.arguments(
            for: request,
            environment: project.environment,
            name: TaskCommand.displayName(for: request.prompt)
        )
        process.environment = TaskCommand.environment(
            base: ProcessInfo.processInfo.environment,
            loginShellPath: claude.loginShellPath,
            project: project.environment,
            secrets: secrets
        )
        process.currentDirectoryURL = URL(fileURLWithPath: project.directory, isDirectory: true)
        let input = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        let id = request.sessionID
        let tail = StderrTail()
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                tail.append(data)
            }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            let signaled = process.terminationReason == .uncaughtSignal
            Task { @MainActor in self?.finished(id, status: status, signaled: signaled) }
        }

        do {
            try process.run()
        } catch {
            try? output.close()
            errors.fileHandleForReading.readabilityHandler = nil
            return "claude を起動できませんでした: \(error.localizedDescription)"
        }
        try? output.close()

        // 指示文を渡して閉じる。大きくても詰まらないよう別スレッドで書く。
        let prompt = Data(request.prompt.utf8)
        let writer = input.fileHandleForWriting
        DispatchQueue.global(qos: .userInitiated).async {
            try? writer.write(contentsOf: prompt)
            try? writer.close()
        }

        processes[id] = process
        stderrTails[id] = tail
        model.tasks.insert(TaskRun(
            id: id,
            projectID: project.id,
            projectName: project.name,
            agent: request.agent,
            prompt: request.prompt,
            startedAt: Date(),
            state: .running,
            outputPath: outputURL.path
        ), at: 0)
        trimFinished()
        return nil
    }

    func stop(_ id: UUID) {
        guard let process = processes[id], process.isRunning else { return }
        process.interrupt()
        update(id) { $0.state = .stopping }
        stopTimers[id]?.cancel()
        stopTimers[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(TaskCommand.interruptGracePeriod))
            guard !Task.isCancelled, let self, let process = self.processes[id], process.isRunning else { return }
            process.terminate()
        }
    }

    /// アプリの終了時。待たずに SIGTERM を送る（hook の SessionEnd は claude 側が走らせる）。
    func terminateAll() {
        for process in processes.values where process.isRunning {
            process.terminate()
        }
    }

    // MARK: - 内部

    private func finished(_ id: UUID, status: Int32, signaled: Bool) {
        processes[id] = nil
        stopTimers.removeValue(forKey: id)?.cancel()
        let stderr = stderrTails.removeValue(forKey: id)?.text ?? ""
        update(id) { run in
            run.endedAt = Date()
            if run.state == .stopping {
                run.state = .stopped
            } else if !signaled, status == 0 {
                run.state = .finished
            } else {
                let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                let fallback = signaled ? "シグナル \(status) で終了しました" : "終了コード \(status)"
                run.state = .failed(detail.isEmpty ? fallback : String(detail.suffix(300)))
            }
        }
    }

    private func update(_ id: UUID, _ change: (inout TaskRun) -> Void) {
        guard let index = model.tasks.firstIndex(where: { $0.id == id }) else { return }
        change(&model.tasks[index])
    }

    private func trimFinished() {
        var finishedCount = 0
        model.tasks.removeAll { run in
            guard !run.isActive else { return false }
            finishedCount += 1
            return finishedCount > Self.keepFinished
        }
    }
}

/// 標準エラーの最後の部分だけを持つ（別スレッドから追記される）。
private final class StderrTail: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit = 4096

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
        if data.count > limit { data = data.suffix(limit) }
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
