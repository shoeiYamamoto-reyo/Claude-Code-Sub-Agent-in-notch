import Foundation
import XCTest
@testable import AgentKit

final class TaskCommandTests: XCTestCase {
    private let sessionID = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
    private let projectID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    func testDefaultArgumentsAddNothingFromSettings() {
        let request = TaskRequest(projectID: projectID, agent: nil, prompt: "--help me", sessionID: sessionID)
        XCTAssertEqual(TaskCommand.arguments(for: request, environment: ProjectEnvironment()), [
            "-p",
            "--output-format", "stream-json",
            "--verbose",
            "--session-id", "6f9619ff-8b86-d011-b42d-00c04fc964ff",
        ])
    }

    func testArgumentsFromAgentAndEnvironment() {
        let request = TaskRequest(projectID: projectID, agent: " reviewer ", prompt: "Review", sessionID: sessionID)
        let environment = ProjectEnvironment(
            model: "opus",
            effort: " high ",
            permissionMode: "acceptEdits",
            allowedTools: ["Read", "Bash(git diff *)", " "]
        )
        XCTAssertEqual(TaskCommand.arguments(for: request, environment: environment, name: "Review the diff"), [
            "-p",
            "--output-format", "stream-json",
            "--verbose",
            "--session-id", "6f9619ff-8b86-d011-b42d-00c04fc964ff",
            "--agent", "reviewer",
            "--model", "opus",
            "--effort", "high",
            "--permission-mode", "acceptEdits",
            "--allowedTools", "Read,Bash(git diff *)",
            "--name", "Review the diff",
        ])
        // 空の名前・エージェントは付けない。
        let blank = TaskRequest(projectID: projectID, agent: "  ", prompt: "x", sessionID: sessionID)
        XCTAssertFalse(TaskCommand.arguments(for: blank, environment: ProjectEnvironment(), name: " ").contains("--agent"))
        XCTAssertFalse(TaskCommand.arguments(for: blank, environment: ProjectEnvironment(), name: " ").contains("--name"))
    }

    func testEnvironment() {
        let project = ProjectEnvironment(variables: [
            EnvironmentVariable(name: "NODE_ENV", value: "test"),
            EnvironmentVariable(name: "API_KEY", isSecret: true),
            EnvironmentVariable(name: "MISSING_SECRET", isSecret: true),
            EnvironmentVariable(name: "BAD-NAME", value: "x"),
            EnvironmentVariable(name: "HOME", value: "/override"),
        ])
        let result = TaskCommand.environment(
            base: ["HOME": "/Users/me", "PATH": "/usr/bin:/bin", "CLAUDECODE": "1", "LANG": "ja_JP.UTF-8"],
            loginShellPath: "/Users/me/.local/bin:/opt/homebrew/bin:/usr/bin:/bin",
            project: project,
            secrets: ["API_KEY": "sk-1", "UNRELATED": "no"]
        )
        XCTAssertEqual(result, [
            "HOME": "/override",
            "PATH": "/Users/me/.local/bin:/opt/homebrew/bin:/usr/bin:/bin",
            "LANG": "ja_JP.UTF-8",
            "NODE_ENV": "test",
            "API_KEY": "sk-1",
        ])
        // ログインシェルの PATH が取れなければアプリの PATH のまま。
        let fallback = TaskCommand.environment(base: ["PATH": "/usr/bin"], loginShellPath: nil, project: ProjectEnvironment(), secrets: [:])
        XCTAssertEqual(fallback, ["PATH": "/usr/bin"])
    }

    func testDisplayName() {
        XCTAssertEqual(TaskCommand.displayName(for: "\n  Fix the build  \nmore"), "Fix the build")
        XCTAssertEqual(TaskCommand.displayName(for: String(repeating: "あ", count: 50), limit: 10), String(repeating: "あ", count: 9) + "…")
        XCTAssertEqual(TaskCommand.displayName(for: "   "), "")
    }
}

final class ClaudeLocatorTests: XCTestCase {
    func testParseProbe() {
        let output = "Last login: today\nwelcome\n\n__NOTCH_AGENT__/a/bin:/usr/bin__NOTCH_AGENT__/a/bin/claude__NOTCH_AGENT__\n"
        XCTAssertEqual(ClaudeLocator.parseProbe(output), ClaudeLocator.ProbeResult(path: "/a/bin:/usr/bin", claude: "/a/bin/claude"))
        // command -v がエイリアスや関数を返したときは使わない。
        let alias = "\n__NOTCH_AGENT__/usr/bin__NOTCH_AGENT__alias claude=foo__NOTCH_AGENT__\n"
        XCTAssertEqual(ClaudeLocator.parseProbe(alias), ClaudeLocator.ProbeResult(path: "/usr/bin", claude: nil))
        XCTAssertEqual(ClaudeLocator.parseProbe("\n__NOTCH_AGENT____NOTCH_AGENT____NOTCH_AGENT__\n"), ClaudeLocator.ProbeResult(path: nil, claude: nil))
        XCTAssertNil(ClaudeLocator.parseProbe("zsh: command not found"))
    }

    func testCandidatesOrder() {
        XCTAssertEqual(ClaudeLocator.candidates(configured: "~/bin/claude", probed: "/opt/homebrew/bin/claude", home: "/Users/me"), [
            "/Users/me/bin/claude",
            "/opt/homebrew/bin/claude",
            "/Users/me/.local/bin/claude",
            "/Users/me/.claude/local/claude",
            "/usr/local/bin/claude",
        ])
        XCTAssertEqual(ClaudeLocator.candidates(configured: " ", probed: nil, home: "/Users/me").first, "/Users/me/.local/bin/claude")
    }

    func testLocatePicksFirstExecutable() {
        let executables: Set<String> = ["/usr/local/bin/claude", "/opt/homebrew/bin/claude"]
        XCTAssertEqual(
            ClaudeLocator.locate(configured: "/missing/claude", probed: nil, home: "/Users/me", isExecutable: executables.contains),
            "/opt/homebrew/bin/claude"
        )
        XCTAssertNil(ClaudeLocator.locate(configured: nil, probed: nil, home: "/Users/me", isExecutable: { _ in false }))
    }
}
