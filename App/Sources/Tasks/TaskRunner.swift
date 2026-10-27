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
    /// 最初の指示。
    let prompt: String
    /// 続けて渡した指示（`--resume`、ROADMAP 3-6）。古い順。
    var followUps: [String] = []
    let startedAt: Date
    var endedAt: Date?
    var state: State
    /// stream-json の出力を書いたファイル。
    let outputPath: String
    /// 出力を読みながらまとめた結果（M3-4）。
    var transcript = TaskTranscript()
    /// 履歴から開き直したとき、出力ファイルが消えていれば履歴に残した最後の応答（ROADMAP 5-4）。
    var restoredSummary: String?

    var isActive: Bool { state == .running || state == .stopping }

    /// hook から見たセッション ID（小文字）。
    var sessionID: String { id.uuidString.lowercased() }
}

/// `claude -p` を子プロセスで起動・停止する（ROADMAP 3-3、ADR-0002）。
///
/// - コマンドと環境変数の組み立ては `TaskCommand`（AgentKit）。指示文は標準入力で渡す。
/// - 出力は `~/Library/Application Support/NotchAgent/tasks/<session-id>.jsonl` に書きながら、
///   行ごとに `TaskTranscript`（AgentKit）でまとめる（最後の応答、変更ファイル、コスト。M3-4）。標準エラーは最後の数 KB だけ覚えてエラー表示に使う。
/// - 終わったタスクは、追加の指示で同じセッションを続けられる（`--resume`、ROADMAP 3-6）。一覧の行と出力ファイルは同じものを使い続ける。
/// - 停止は SIGINT（ターンを終わらせて記録を残す）→ 5 秒で終わらなければ SIGTERM → さらに 5 秒で SIGKILL。
///   シグナルは子のプロセスグループに送る（Bash ツールから起動したものも残さない）。
/// - アプリの終了時は動いているタスクに SIGTERM を送る（待たない）。
/// - 出力ファイルは起動時に古いものを消す（`TaskOutputRetention`）。
/// - 始めた・続けた・終わったときに履歴に残す（`TaskHistoryStore`、ROADMAP 5-4）。一覧から消えたタスクは、
///   履歴から出力ファイルを読み直して一覧に戻せる（`showHistory`）。
@MainActor
final class TaskRunner {
    let model: NotchModel
    private let claude: ClaudeSetup
    private let history: TaskHistoryStore
    private var processes: [UUID: Process] = [:]
    private var stopTimers: [UUID: Task<Void, Never>] = [:]
    private var stderrTails: [UUID: StderrTail] = [:]
    /// 履歴から出力ファイルを読み直している最中のタスク。
    private var restoring: Set<UUID> = []

    /// 一覧に残す終わったタスクの数。
    private static let keepFinished = 10

    init(model: NotchModel, claude: ClaudeSetup, history: TaskHistoryStore) {
        self.model = model
        self.claude = claude
        self.history = history
        model.onStopTask = { [weak self] id in self?.stop(id) }
        model.onContinueTask = { [weak self] id, prompt in
            guard let self else { return "続けられません。" }
            return self.continueTask(id, prompt: prompt)
        }
        model.onShowHistoryEntry = { [weak self] id in self?.showHistory(id) }
        Self.removeOldOutputs()
    }

    static var outputDirectory: URL {
        URL(fileURLWithPath: HookBridge.socketPath(home: NSHomeDirectory()))
            .deletingLastPathComponent()
            .appendingPathComponent("tasks", isDirectory: true)
    }

    /// タスクを始める。始められなければ理由を返す。
    func start(_ request: TaskRequest, project: Project) -> String? {
        if let problem = launch(request, project: project) { return problem }
        let run = TaskRun(
            id: request.sessionID,
            projectID: project.id,
            projectName: project.name,
            agent: request.agent,
            prompt: request.prompt,
            startedAt: Date(),
            state: .running,
            outputPath: Self.outputURL(for: request.sessionID).path
        )
        model.tasks.insert(run, at: 0)
        trimFinished()
        history.begin(run)
        return nil
    }

    /// 終わったタスクに追加の指示を渡し、同じセッションで続ける（ROADMAP 3-6、F2-4）。続けられなければ理由を返す。
    ///
    /// エージェントは最初と同じもの、環境は今のプロジェクトの設定を付け直す（`TaskCommand.arguments`）。
    func continueTask(_ id: UUID, prompt: String) -> String? {
        guard let run = model.tasks.first(where: { $0.id == id }) else { return "このタスクは一覧から消えました。" }
        guard !run.isActive else { return "まだ動いています。終わってから続けてください。" }
        guard let project = model.projects.project(id: run.projectID) else {
            return "プロジェクト「\(run.projectName)」が見つかりません（削除された可能性があります）。"
        }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "追加の指示を入力してください。" }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: project.directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            return "作業フォルダがありません: \(project.directory)"
        }
        let request = TaskRequest(projectID: project.id, agent: run.agent, prompt: trimmed, sessionID: id, resume: true)
        if let problem = launch(request, project: project) { return problem }
        // 動いているものとして一覧の先頭に移す。出力を読む前（同じ MainActor の中）に結果の区切りを入れる。
        guard let index = model.tasks.firstIndex(where: { $0.id == id }) else { return nil }
        var continued = model.tasks.remove(at: index)
        continued.followUps.append(trimmed)
        continued.state = .running
        continued.endedAt = nil
        continued.transcript.beginFollowUp()
        continued.restoredSummary = nil
        model.tasks.insert(continued, at: 0)
        history.beginFollowUp(id, prompt: trimmed)
        return nil
    }

    private static func outputURL(for sessionID: UUID) -> URL {
        outputDirectory.appendingPathComponent("\(sessionID.uuidString.lowercased()).jsonl")
    }

    /// 子プロセスを起動する。続き（`request.resume`）なら出力ファイルに追記する。
    private func launch(_ request: TaskRequest, project: Project) -> String? {
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

        let outputURL = Self.outputURL(for: request.sessionID)
        let output: FileHandle
        let append = request.resume && FileManager.default.fileExists(atPath: outputURL.path)
        do {
            try FileManager.default.createDirectory(at: Self.outputDirectory, withIntermediateDirectories: true)
            if !append {
                guard FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    return "出力ファイルを作れませんでした: \(outputURL.path)"
                }
            }
            output = try FileHandle(forWritingTo: outputURL)
            if append { try output.seekToEnd() }
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
            secrets: secrets,
            executable: executable
        )
        process.currentDirectoryURL = URL(fileURLWithPath: project.directory, isDirectory: true)
        let input = Pipe()
        let stdout = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = stdout
        process.standardError = errors

        let id = request.sessionID
        // 出力はそのままファイルに書き、行ごとに MainActor で結果にまとめる。
        let reader = TaskOutputReader(file: output)
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            let lines: [String]
            if data.isEmpty {
                handle.readabilityHandler = nil
                lines = reader.finish()
            } else {
                lines = reader.append(data)
            }
            guard !lines.isEmpty else { return }
            Task { @MainActor in self?.consume(id, lines: lines) }
        }
        let tail = StderrTail()
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                tail.markClosed()
            } else {
                tail.append(data)
            }
        }
        process.terminationHandler = { [weak self] process in
            // 終了の通知が標準エラーの最後の読み取りより先に来ることがあるので、読み終わるまで少し待つ
            // （すぐ失敗したときほど、エラーの文面が抜けやすい）。
            tail.waitUntilClosed(timeout: 1)
            let status = process.terminationStatus
            let signaled = process.terminationReason == .uncaughtSignal
            Task { @MainActor in self?.finished(id, status: status, signaled: signaled) }
        }

        do {
            try process.run()
        } catch {
            _ = reader.finish()
            stdout.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            // 新しく作った空のファイルだけ消す（続きなら、それまでの出力を残す）。
            if !append { try? FileManager.default.removeItem(at: outputURL) }
            return "claude を起動できませんでした: \(error.localizedDescription)"
        }

        // 指示文を渡して閉じる。大きくても詰まらないよう別スレッドで書く。
        let prompt = Data(request.prompt.utf8)
        let writer = input.fileHandleForWriting
        // claude が読み切る前に終わったとき、SIGPIPE でアプリごと落ちないよう EPIPE のエラーで返させる。
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        DispatchQueue.global(qos: .userInitiated).async {
            try? writer.write(contentsOf: prompt)
            try? writer.close()
        }

        processes[id] = process
        stderrTails[id] = tail
        return nil
    }

    /// 履歴の行を押したとき。一覧にあればそのまま結果を開き、無ければ出力ファイルを読み直して一覧に戻してから開く
    /// （続けられるようにするため）。出力ファイルは別スレッドで読む。
    func showHistory(_ id: UUID) {
        if model.tasks.contains(where: { $0.id == id }) {
            model.onShowTask?(id)
            return
        }
        guard let entry = model.taskHistory.entry(id: id), entry.outcome != .running, !restoring.contains(id) else { return }
        restoring.insert(id)
        let outputURL = Self.outputURL(for: id)
        Task {
            let transcript = await Task.detached(priority: .userInitiated) { Self.readTranscript(at: outputURL) }.value
            restoring.remove(id)
            guard !model.tasks.contains(where: { $0.id == id }) else {
                model.onShowTask?(id)
                return
            }
            var run = TaskRun(
                id: entry.id,
                projectID: entry.projectID,
                projectName: entry.projectName,
                agent: entry.agent,
                prompt: entry.prompt,
                followUps: entry.followUps,
                startedAt: entry.startedAt,
                endedAt: entry.endedAt,
                state: Self.state(for: entry, transcript: transcript),
                outputPath: outputURL.path,
                transcript: transcript ?? TaskTranscript()
            )
            if transcript?.lastAssistantText == nil { run.restoredSummary = entry.summary }
            // 動いているものの後ろ、始めた順の位置に入れる。
            let index = model.tasks.firstIndex { !$0.isActive && $0.startedAt < run.startedAt } ?? model.tasks.endIndex
            model.tasks.insert(run, at: index)
            model.onShowTask?(id)
        }
    }

    func stop(_ id: UUID) {
        guard let process = processes[id], process.isRunning else { return }
        Self.send(SIGINT, to: process)
        update(id) { $0.state = .stopping }
        stopTimers[id]?.cancel()
        stopTimers[id] = Task { [weak self] in
            // SIGINT → SIGTERM → SIGKILL。応答しなくなっていても「停止中」のまま残さない。
            for (signal, wait) in [(SIGTERM, TaskCommand.interruptGracePeriod), (SIGKILL, TaskCommand.terminateGracePeriod)] {
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled, let process = self?.processes[id], process.isRunning else { return }
                Self.send(signal, to: process)
            }
        }
    }

    /// アプリの終了時。待たずに SIGTERM を送る（hook の SessionEnd は claude 側が走らせる）。
    func terminateAll() {
        for process in processes.values where process.isRunning {
            Self.send(SIGTERM, to: process)
        }
    }

    // MARK: - 内部

    /// 子のプロセスグループにシグナルを送る。`Process` は子を新しいグループの先頭にするので、
    /// claude が起動した孫にも届く。グループを持っていなければ子だけに送る。
    private static func send(_ signal: Int32, to process: Process) {
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        if getpgid(pid) == pid {
            killpg(pid, signal)
        } else {
            kill(pid, signal)
        }
    }

    /// 古い出力ファイルを消す（`TaskOutputRetention`）。起動時、まだタスクが無いうちに別スレッドで行う。
    private static func removeOldOutputs() {
        let directory = outputDirectory
        Task.detached(priority: .utility) {
            let manager = FileManager.default
            guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return }
            let files = names.filter { $0.hasSuffix(".jsonl") }.compactMap { name -> TaskOutputRetention.File? in
                let path = directory.appendingPathComponent(name).path
                guard let modified = (try? manager.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return nil }
                return TaskOutputRetention.File(path: path, modifiedAt: modified)
            }
            for path in TaskOutputRetention.filesToDelete(files, now: Date()) {
                try? manager.removeItem(atPath: path)
            }
        }
    }

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
        if let run = model.tasks.first(where: { $0.id == id }) { history.finish(run) }
    }

    /// 出力ファイルを読み直す。無ければ nil。
    nonisolated private static func readTranscript(at url: URL) -> TaskTranscript? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        var transcript = TaskTranscript()
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            transcript.consume(String(decoding: line, as: UTF8.self))
        }
        return transcript
    }

    private static func state(for entry: TaskHistoryEntry, transcript: TaskTranscript?) -> TaskRun.State {
        switch entry.outcome {
        case .running, .finished:
            return .finished
        case .error:
            // 出力が残っていれば `result` からエラーと分かる。
            return transcript?.result?.isError == true ? .finished : .failed(entry.detail ?? "エラー")
        case .stopped:
            return .stopped
        case .failed:
            return .failed(entry.detail ?? "エラー")
        case .interrupted:
            return .failed("アプリが終了したため、結果が分かりません")
        }
    }

    private func consume(_ id: UUID, lines: [String]) {
        update(id) { run in
            for line in lines { run.transcript.consume(line) }
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

/// 標準出力をファイルに書きながら行に分ける（読み取りのスレッドから呼ばれる）。
private final class TaskOutputReader: @unchecked Sendable {
    private let lock = NSLock()
    private let file: FileHandle
    private var buffer = LineBuffer()
    private var isFinished = false

    init(file: FileHandle) {
        self.file = file
    }

    func append(_ data: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return [] }
        try? file.write(contentsOf: data)
        return buffer.append(data)
    }

    /// 出力の終わり。残りの行を返してファイルを閉じる。
    func finish() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return [] }
        isFinished = true
        try? file.close()
        return buffer.flush().map { [$0] } ?? []
    }
}

/// 標準エラーの最後の部分だけを持つ（別スレッドから追記される）。
private final class StderrTail: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit = 4096
    private let closed = DispatchSemaphore(value: 0)

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
        if data.count > limit { data = data.suffix(limit) }
    }

    /// 標準エラーを最後まで読んだ（EOF）。
    func markClosed() {
        closed.signal()
    }

    /// EOF まで待つ。孫プロセスが標準エラーを開いたままのこともあるので、待つのは `timeout` 秒まで。
    func waitUntilClosed(timeout: TimeInterval) {
        if closed.wait(timeout: .now() + timeout) == .success { closed.signal() }
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
