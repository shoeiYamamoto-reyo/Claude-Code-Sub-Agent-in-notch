import Foundation

/// POSIX シェルの引数として安全に渡すためのクォート。
public enum ShellQuote {
    /// 単一引用符で囲む。中の `'` は `'\''` にする。
    public static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}

/// アプリから始めたセッションをターミナルで開き、続きを手で操作する（ROADMAP 5-6、F2-7）。
///
/// AppleScript は使わず（オートメーションの許可が要るため）、`.command` ファイルを書いて開く。
/// ファイルは開いたシェルが最初に消す。秘密の環境変数はファイルに書かない。
public enum TerminalLaunch {
    /// 対話モードの `claude` で同じセッションを再開する引数。`-p` の起動と同じエージェント・環境の指定を付け直す。
    public static func resumeArguments(sessionID: UUID, agent: String?, environment: ProjectEnvironment) -> [String] {
        let environment = environment.normalized()
        var arguments = ["--resume", sessionID.uuidString.lowercased()]
        if let agent = agent?.trimmingCharacters(in: .whitespaces), !agent.isEmpty {
            arguments += ["--agent", agent]
        }
        if let model = environment.model { arguments += ["--model", model] }
        if let effort = environment.effort { arguments += ["--effort", effort] }
        if let mode = environment.permissionMode { arguments += ["--permission-mode", mode] }
        if !environment.allowedTools.isEmpty {
            arguments += ["--allowedTools", environment.allowedTools.joined(separator: ",")]
        }
        return arguments
    }

    /// `.command` ファイルの中身。
    /// - Parameters:
    ///   - path: `PATH`。nil なら端末のシェルのものを使う。
    ///   - environment: プロジェクトの秘密でない変数。
    ///   - omittedSecrets: 渡さなかった秘密の変数の名前（コメントで知らせる）。
    public static func script(
        directory: String,
        executable: String,
        arguments: [String],
        path: String?,
        environment: [String: String],
        omittedSecrets: [String] = []
    ) -> String {
        var lines = [
            "#!/bin/sh",
            "# Notch Agent: Claude Code のセッションを続けるためのファイル（開くと消えます）。",
            #"rm -f -- "$0""#,
            "unset CLAUDECODE",
        ]
        if let path, !path.isEmpty {
            lines.append("export PATH=\(ShellQuote.quote(path))")
        }
        for name in environment.keys.sorted() where EnvironmentVariable.isValidName(name) {
            lines.append("export \(name)=\(ShellQuote.quote(environment[name] ?? ""))")
        }
        if !omittedSecrets.isEmpty {
            lines.append("# 秘密の環境変数は渡していません: \(omittedSecrets.sorted().joined(separator: ", "))")
        }
        lines.append("cd -- \(ShellQuote.quote(directory)) || exit 1")
        lines.append((["exec", ShellQuote.quote(executable)] + arguments.map(ShellQuote.quote)).joined(separator: " "))
        return lines.joined(separator: "\n") + "\n"
    }
}
