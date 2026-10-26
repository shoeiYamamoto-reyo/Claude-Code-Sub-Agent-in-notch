import AgentKit
import AppKit
import Foundation

/// `claude` コマンドの場所とログインシェルの `PATH`（F6-3、ADR-0002）。
///
/// メニューバーのアプリは Finder から起動されるので、`PATH` がターミナルと違う（`~/.local/bin` などが無い）。
/// 起動時にログインシェルで `PATH` と `command -v claude` を調べ、タスクの起動に使う。
/// 時間切れなどで取れなければ、メニューから調べ直せる。
@MainActor
final class ClaudeSetup {
    private static let configuredPathKey = "claudePath"
    /// ログインシェルの調査を諦めるまでの時間。
    private static let probeTimeout: TimeInterval = 5

    let model: NotchModel
    private(set) var loginShellPath: String?
    private var probedClaude: String?

    init(model: NotchModel) {
        self.model = model
    }

    var configuredPath: String? {
        get { UserDefaults.standard.string(forKey: Self.configuredPathKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.configuredPathKey)
            refreshStatus()
        }
    }

    func executablePath() -> String? {
        ClaudeLocator.locate(configured: configuredPath, probed: probedClaude, home: NSHomeDirectory())
    }

    /// ログインシェルを調べる。起動時と、メニューの「ログインシェルを調べ直す」から呼ぶ。
    func start() {
        refreshStatus()
        guard !isProbing else { return }
        isProbing = true
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        Task {
            let result = await Self.probe(shell: shell)
            isProbing = false
            // 失敗したときは前に取れた値を残す（調べ直しで失敗しても悪くならないように）。
            if let result {
                loginShellPath = result.path
                probedClaude = result.claude
            }
            model.loginShellProbeFailed = result?.path == nil
            refreshStatus()
        }
    }

    private var isProbing = false

    /// ファイルを選んで `claude` の場所を指定する。
    func chooseExecutable() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.message = "claude コマンドの実行ファイルを選んでください（ターミナルで `command -v claude` を実行すると場所が分かります）"
        panel.prompt = "選択"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        configuredPath = url.path
    }

    func resetConfiguredPath() {
        configuredPath = nil
    }

    private func refreshStatus() {
        model.claudePath = executablePath()
    }

    /// `$SHELL -ilc` で `ClaudeLocator.probeScript` を実行する。時間内に終わらなければ nil。
    private static func probe(shell: String) async -> ClaudeLocator.ProbeResult? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-ilc", ClaudeLocator.probeScript]
            process.standardInput = FileHandle.nullDevice
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            let once = ResumeOnce(continuation)
            do {
                try process.run()
            } catch {
                once.resume(nil)
                return
            }
            // 終わるのを待たずに読み続ける（rc ファイルの出力が多くてもパイプが詰まらないように）。
            let reader = output.fileHandleForReading
            DispatchQueue.global().async {
                let data = reader.readDataToEndOfFile()
                once.resume(ClaudeLocator.parseProbe(String(decoding: data, as: UTF8.self)))
            }
            let running = UncheckedProcess(process)
            DispatchQueue.global().asyncAfter(deadline: .now() + probeTimeout) {
                // 対話シェル（-i）は SIGTERM を無視するので SIGKILL で終わらせる。
                if running.process.isRunning { kill(running.process.processIdentifier, SIGKILL) }
                once.resume(nil)
            }
        }
    }
}

/// タイムアウトの処理から終了させるために渡す。`Process` 自体はスレッドをまたいで使ってよい。
private struct UncheckedProcess: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
}

/// continuation を一度だけ再開する（終了とタイムアウトのどちらか早いほう）。
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ClaudeLocator.ProbeResult?, Never>?

    init(_ continuation: CheckedContinuation<ClaudeLocator.ProbeResult?, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: ClaudeLocator.ProbeResult?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}
