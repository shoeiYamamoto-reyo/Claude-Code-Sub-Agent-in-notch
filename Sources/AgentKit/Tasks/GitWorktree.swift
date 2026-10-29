import Foundation

/// 同じプロジェクトで並行して動くタスクの作業場所を git worktree で分ける（ROADMAP 5-6、F2-5）。
///
/// worktree はプロジェクトのフォルダの `.claude/worktrees/notch-<ID の先頭 8 文字>` に作り、
/// ブランチ `notch/<ID の先頭 8 文字>` を今の HEAD から切る（Claude Code の `--worktree` と同じ置き場所）。
/// プロジェクトのフォルダの中に置くので、hook のセッションも同じプロジェクトとして扱われる。
/// 消すときは `git worktree remove`（変更が残っていれば git が断る）。ブランチは消さない。
public enum GitWorktree {
    public static let directoryName = ".claude/worktrees"
    public static let defaultGit = "/usr/bin/git"

    public struct Plan: Sendable, Equatable {
        /// worktree の場所。
        public var path: String
        public var branch: String
        /// タスクを動かすフォルダ（プロジェクトがリポジトリの一部なら、worktree の中の同じ場所）。
        public var workingDirectory: String
    }

    public enum Failure: Error, Sendable, Equatable {
        case notRepository(String)
        case gitFailed(String)

        public var message: String {
            switch self {
            case .notRepository(let directory):
                "\(directory) は git のリポジトリではないため、worktree で分けられません。"
            case .gitFailed(let detail):
                "git が失敗しました: \(detail)"
            }
        }
    }

    /// 動いているタスク・セッションのフォルダのどれかが、このプロジェクトのフォルダ（worktree の置き場所を除く）にあるか。
    public static func isBusy(projectDirectory: String, busyDirectories: [String]) -> Bool {
        let worktrees = (projectDirectory as NSString).appendingPathComponent(directoryName)
        return busyDirectories.contains { directory in
            ProjectPath.isInside(directory, directory: projectDirectory)
                && !ProjectPath.isInside(directory, directory: worktrees)
        }
    }

    /// - Parameter prefix: `git rev-parse --show-prefix` の出力（プロジェクトのフォルダのリポジトリ内での位置。`sub/dir/` か空）。
    public static func plan(projectDirectory: String, prefix: String, sessionID: UUID) -> Plan {
        let short = String(sessionID.uuidString.lowercased().prefix(8))
        let path = ((projectDirectory as NSString).appendingPathComponent(directoryName) as NSString)
            .appendingPathComponent("notch-\(short)")
        let relative = prefix.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return Plan(
            path: path,
            branch: "notch/\(short)",
            workingDirectory: relative.isEmpty ? path : (path as NSString).appendingPathComponent(relative)
        )
    }

    public static func addArguments(_ plan: Plan) -> [String] {
        ["worktree", "add", "-b", plan.branch, plan.path, "HEAD"]
    }

    /// worktree を作る。時間がかかることがあるので、メインスレッドでは呼ばない。
    public static func create(projectDirectory: String, sessionID: UUID, git: String = defaultGit) throws(Failure) -> Plan {
        let prefix: String
        do {
            prefix = try run(git: git, ["rev-parse", "--show-prefix"], in: projectDirectory)
        } catch {
            throw .notRepository(projectDirectory)
        }
        let plan = plan(projectDirectory: projectDirectory, prefix: prefix, sessionID: sessionID)
        try run(git: git, addArguments(plan), in: projectDirectory)
        return plan
    }

    /// worktree を消す。変更やまだ追跡していないファイルが残っていれば git が断る（`--force` は付けない）。
    public static func remove(path: String, git: String = defaultGit) throws(Failure) {
        try run(git: git, ["worktree", "remove", path], in: (path as NSString).deletingLastPathComponent)
    }

    /// git を実行して標準出力を返す。終了コードが 0 でなければ標準エラーの内容で失敗にする。
    @discardableResult
    static func run(git: String, _ arguments: [String], in directory: String) throws(Failure) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        // 認証やエディタの入力を待って止まらないようにする。
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw .gitFailed(error.localizedDescription)
        }
        // 出力が大きくても詰まらないよう、終わるのを待つ前に読む。
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw .gitFailed(detail.isEmpty ? "終了コード \(process.terminationStatus)" : detail)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
