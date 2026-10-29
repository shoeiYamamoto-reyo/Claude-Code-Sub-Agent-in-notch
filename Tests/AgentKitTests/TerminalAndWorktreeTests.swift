import Foundation
import XCTest
@testable import AgentKit

/// ROADMAP 5-6: ターミナルで開く（F2-7）と git worktree での並行実行（F2-5）。
final class TerminalAndWorktreeTests: XCTestCase {
    func testShellQuote() {
        XCTAssertEqual(ShellQuote.quote("plain"), "'plain'")
        XCTAssertEqual(ShellQuote.quote("it's $HOME"), #"'it'\''s $HOME'"#)
        XCTAssertEqual(ShellQuote.quote(""), "''")
    }

    func testResumeArgumentsCarryAgentAndEnvironment() {
        let id = UUID(uuidString: "6F1C2B3A-0000-4000-8000-000000000001")!
        var environment = ProjectEnvironment()
        environment.model = "opus"
        environment.permissionMode = "acceptEdits"
        environment.allowedTools = ["Bash(git diff *)", "Read"]
        XCTAssertEqual(
            TerminalLaunch.resumeArguments(sessionID: id, agent: " reviewer ", environment: environment),
            [
                "--resume", "6f1c2b3a-0000-4000-8000-000000000001",
                "--agent", "reviewer",
                "--model", "opus",
                "--permission-mode", "acceptEdits",
                "--allowedTools", "Bash(git diff *),Read",
            ]
        )
        XCTAssertEqual(TerminalLaunch.resumeArguments(sessionID: id, agent: nil, environment: ProjectEnvironment()).count, 2)
    }

    func testScriptQuotesEverythingAndRemovesItself() throws {
        let script = TerminalLaunch.script(
            directory: "/Users/me/my app",
            executable: "/opt/homebrew/bin/claude",
            arguments: ["--resume", "abc"],
            path: "/opt/homebrew/bin:/usr/bin",
            environment: ["B_VAR": "x'y", "A_VAR": "1", "bad name": "z"],
            omittedSecrets: ["TOKEN"]
        )
        let lines = script.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "#!/bin/sh")
        XCTAssertTrue(lines.contains(#"rm -f -- "$0""#))
        XCTAssertTrue(lines.contains("export PATH='/opt/homebrew/bin:/usr/bin'"))
        let exports = lines.filter { $0.hasPrefix("export A_VAR") || $0.hasPrefix("export B_VAR") }
        XCTAssertEqual(exports, ["export A_VAR='1'", #"export B_VAR='x'\''y'"#])
        XCTAssertFalse(script.contains("bad name"))
        XCTAssertTrue(script.contains("TOKEN"))
        XCTAssertEqual(lines.suffix(2), [
            "cd -- '/Users/me/my app' || exit 1",
            "exec '/opt/homebrew/bin/claude' '--resume' 'abc'",
        ])
    }

    func testBusyProjectIgnoresItsWorktrees() {
        let project = "/Users/me/app"
        XCTAssertTrue(GitWorktree.isBusy(projectDirectory: project, busyDirectories: ["/Users/me/app/src"]))
        XCTAssertTrue(GitWorktree.isBusy(projectDirectory: project, busyDirectories: [project]))
        XCTAssertFalse(GitWorktree.isBusy(projectDirectory: project, busyDirectories: ["/Users/me/app/.claude/worktrees/notch-1"]))
        XCTAssertFalse(GitWorktree.isBusy(projectDirectory: project, busyDirectories: ["/Users/me/other", "/Users/me/application"]))
    }

    func testPlanKeepsProjectSubdirectory() {
        let id = UUID(uuidString: "ABCDEF12-0000-4000-8000-000000000001")!
        let root = GitWorktree.plan(projectDirectory: "/r", prefix: "\n", sessionID: id)
        XCTAssertEqual(root.path, "/r/.claude/worktrees/notch-abcdef12")
        XCTAssertEqual(root.branch, "notch/abcdef12")
        XCTAssertEqual(root.workingDirectory, root.path)
        XCTAssertEqual(GitWorktree.addArguments(root), ["worktree", "add", "-b", "notch/abcdef12", root.path, "HEAD"])

        let nested = GitWorktree.plan(projectDirectory: "/r/packages/app", prefix: "packages/app/\n", sessionID: id)
        XCTAssertEqual(nested.workingDirectory, "/r/packages/app/.claude/worktrees/notch-abcdef12/packages/app")
    }

    func testCreateAndRemoveWithRealGit() throws {
        let git = GitWorktree.defaultGit
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: git), "git がありません")
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("worktree-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let project = (root as NSString).appendingPathComponent("sub")
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        try "hello\n".write(toFile: (project as NSString).appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try GitWorktree.run(git: git, ["init", "-q"], in: root)
        try GitWorktree.run(git: git, ["add", "."], in: root)
        try GitWorktree.run(git: git, ["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", "init"], in: root)

        // リポジトリでないフォルダは断る。
        let outside = (NSTemporaryDirectory() as NSString).appendingPathComponent("plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: outside) }
        XCTAssertThrowsError(try GitWorktree.create(projectDirectory: outside, sessionID: UUID(), git: git)) { error in
            XCTAssertEqual(error as? GitWorktree.Failure, .notRepository(outside))
        }

        let plan = try GitWorktree.create(projectDirectory: project, sessionID: UUID(), git: git)
        XCTAssertTrue(plan.workingDirectory.hasSuffix("/sub"))
        XCTAssertEqual(
            try String(contentsOfFile: (plan.workingDirectory as NSString).appendingPathComponent("file.txt"), encoding: .utf8),
            "hello\n"
        )

        // 変更が残っていれば消さない。
        try "changed\n".write(toFile: (plan.workingDirectory as NSString).appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try GitWorktree.remove(path: plan.path, git: git))
        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.path))

        try GitWorktree.run(git: git, ["checkout", "--", "."], in: plan.path)
        try GitWorktree.remove(path: plan.path, git: git)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.path))
    }
}
