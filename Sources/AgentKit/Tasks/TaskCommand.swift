import Foundation

/// アプリから始めるタスク 1 つ分（F2-1、ADR-0002）。
public struct TaskRequest: Sendable, Equatable {
    public var projectID: UUID
    /// 使うサブエージェントの `name`。nil なら「おまかせ」（`--agent` を付けない）。
    public var agent: String?
    public var prompt: String
    /// `--session-id` に渡す ID。hook のイベントと結び付けるため、アプリが決める。
    public var sessionID: UUID

    public init(projectID: UUID, agent: String?, prompt: String, sessionID: UUID = UUID()) {
        self.projectID = projectID
        self.agent = agent
        self.prompt = prompt
        self.sessionID = sessionID
    }
}

/// `claude -p` の起動コマンドと環境変数を組み立てる（ADR-0002「起動コマンド」）。実行はアプリ側。
///
/// 指示文は引数ではなく標準入力で渡す（`-` で始まる指示がオプションと取り違えられず、長さの制限も受けない）。
public enum TaskCommand {
    /// 停止のとき、SIGINT の後に SIGTERM を送るまで待つ時間。
    public static let interruptGracePeriod: TimeInterval = 5

    public static func arguments(for request: TaskRequest, environment: ProjectEnvironment, name: String? = nil) -> [String] {
        let environment = environment.normalized()
        var arguments = [
            "-p",
            "--output-format", "stream-json",
            // stream-json と -p の組み合わせでは必須（docs/claude-code-spec.md 5 章）。
            "--verbose",
            "--session-id", request.sessionID.uuidString.lowercased(),
        ]
        if let agent = request.agent?.trimmingCharacters(in: .whitespaces), !agent.isEmpty {
            arguments += ["--agent", agent]
        }
        if let model = environment.model { arguments += ["--model", model] }
        if let effort = environment.effort { arguments += ["--effort", effort] }
        if let mode = environment.permissionMode { arguments += ["--permission-mode", mode] }
        if !environment.allowedTools.isEmpty {
            // 1 つの値にまとめて渡す（`Bash(git diff *)` のように空白を含むものがあるため、カンマ区切り）。
            arguments += ["--allowedTools", environment.allowedTools.joined(separator: ",")]
        }
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            arguments += ["--name", name]
        }
        return arguments
    }

    /// 子プロセスの環境変数。アプリの環境に、ログインシェルの `PATH` とプロジェクトの変数を重ねる。
    ///
    /// - Parameter secrets: 秘密の変数の値（Keychain から読んだもの）。無いものは渡さない。
    public static func environment(
        base: [String: String],
        loginShellPath: String?,
        project: ProjectEnvironment,
        secrets: [String: String]
    ) -> [String: String] {
        var result = base
        if let loginShellPath, !loginShellPath.isEmpty {
            result["PATH"] = loginShellPath
        }
        // 親が Claude Code の中で動いていると、子の claude が入れ子のセッションと判断して起動を断ることがある。
        result.removeValue(forKey: "CLAUDECODE")
        for variable in project.normalized().variables where EnvironmentVariable.isValidName(variable.name) {
            if variable.isSecret {
                if let value = secrets[variable.name] { result[variable.name] = value }
            } else {
                result[variable.name] = variable.value ?? ""
            }
        }
        return result
    }

    /// 一覧に出す短い名前（`--name`）。指示の 1 行目を縮める。
    public static func displayName(for prompt: String, limit: Int = 40) -> String {
        let firstLine = prompt
            .split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        guard firstLine.count > limit else { return firstLine }
        return String(firstLine.prefix(limit - 1)) + "…"
    }
}

/// `claude` の実行ファイルの場所（F6-3）。設定値 → ログインシェルの `command -v claude` → よくある場所の順。
public enum ClaudeLocator {
    public static let executableName = "claude"

    /// ログインシェルで `PATH` と `command -v claude` を調べるコマンド（`$SHELL -ilc` に渡す）。
    /// rc ファイルの出力に混ざっても取り出せるよう、区切りの印で囲む。
    public static let probeScript = #"printf '\n__NOTCH_AGENT__%s__NOTCH_AGENT__%s__NOTCH_AGENT__\n' "$PATH" "$(command -v claude 2>/dev/null)""#

    public struct ProbeResult: Sendable, Equatable {
        public var path: String?
        public var claude: String?
    }

    /// `probeScript` の出力を読む。印が見つからなければ nil。
    public static func parseProbe(_ output: String) -> ProbeResult? {
        let marker = "__NOTCH_AGENT__"
        let parts = output.components(separatedBy: marker)
        // [前の出力, PATH, claude, 後ろ]
        guard parts.count >= 4 else { return nil }
        let path = parts[parts.count - 3]
        let claude = parts[parts.count - 2]
        return ProbeResult(
            path: path.isEmpty ? nil : path,
            claude: claude.hasPrefix("/") ? claude : nil
        )
    }

    /// 探す順の候補（重複なし）。
    public static func candidates(configured: String?, probed: String?, home: String) -> [String] {
        let home = ProjectPath.normalize(home, home: home)
        var result: [String] = []
        for candidate in [
            configured.map { ProjectPath.normalize($0, home: home) },
            probed,
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ] {
            if let candidate, !candidate.isEmpty, !result.contains(candidate) {
                result.append(candidate)
            }
        }
        return result
    }

    public static func locate(
        configured: String?,
        probed: String?,
        home: String,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        candidates(configured: configured, probed: probed, home: home).first(where: isExecutable)
    }
}
