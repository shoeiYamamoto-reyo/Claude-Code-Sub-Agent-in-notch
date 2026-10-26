import Foundation
import XCTest
@testable import AgentKit

final class SessionStoreTests: XCTestCase {
    private let sessionID = "8f2c6c1e-0b7a-4d4e-9a51-1d3f0f6a2b10"
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(_ name: String, session: String = "s1", _ fields: [String: JSONValue] = [:]) -> HookEvent {
        var object = fields
        object["hook_event_name"] = .string(name)
        object["session_id"] = .string(session)
        return try! HookEvent(json: .object(object))
    }

    /// 実ペイロード形式のフィクスチャを順に流し、各時点の状態を確かめる。
    func testFixtureSequence() throws {
        struct Step {
            let fixture: String
            let status: SessionStatus?
            let mood: CharacterMood
            let check: ((Session?) -> Void)?
            init(_ fixture: String, _ status: SessionStatus?, _ mood: CharacterMood, check: ((Session?) -> Void)? = nil) {
                self.fixture = fixture
                self.status = status
                self.mood = mood
                self.check = check
            }
        }
        let steps: [Step] = [
            Step("SessionStart", .waitingForInput, .idle) { session in
                XCTAssertEqual(session?.model, "claude-opus-5-5")
                XCTAssertEqual(session?.displayName, "notch app")
                XCTAssertEqual(session?.terminal, "iTerm.app")
            },
            Step("UserPromptSubmit", .working, .working) { XCTAssertEqual($0?.lastPrompt, "テストを追加して") },
            Step("PreToolUse-Bash", .working, .working) { session in
                XCTAssertEqual(session?.recentTools.last?.summary, "npm test")
                XCTAssertEqual(session?.recentTools.last?.status, .running)
            },
            Step("PermissionRequest", .waitingForApproval, .waiting) { session in
                XCTAssertEqual(session?.pendingPermission?.toolName, "Bash")
                XCTAssertEqual(session?.pendingPermission?.summary, "rm -rf build")
            },
            Step("PostToolUse-Bash", .working, .working) { session in
                XCTAssertNil(session?.pendingPermission)
                XCTAssertEqual(session?.recentTools.first { $0.id == "toolu_01ABC123" }?.status, .succeeded)
            },
            Step("PreToolUse-Agent", .working, .working) {
                XCTAssertEqual($0?.recentTools.last?.summary, "code-reviewer: Review the diff")
            },
            Step("SubagentStart", .working, .working) { session in
                XCTAssertEqual(session?.subagents.map(\.type), ["code-reviewer"])
                XCTAssertEqual(session?.runningSubagents.count, 1)
            },
            Step("PreToolUse-InSubagent", .working, .working) { session in
                XCTAssertEqual(session?.subagents.first?.currentTool?.summary, "App.swift")
                XCTAssertEqual(session?.recentTools.last?.agentID, "a7c1e2")
            },
            Step("SubagentStop", .working, .working) { session in
                XCTAssertEqual(session?.subagents.first?.status, .done)
                XCTAssertEqual(session?.subagents.first?.lastAssistantMessage, "LGTM")
                XCTAssertNil(session?.subagents.first?.currentTool)
                // 結果が来なかったサブエージェントのツールは「中断」。
                XCTAssertEqual(session?.recentTools.first { $0.id == "toolu_01READ" }?.status, .interrupted)
            },
            Step("PostToolUse-Agent", .working, .working),
            Step("Stop", .done, .done) { XCTAssertEqual($0?.lastAssistantMessage, "テストを追加しました。") },
            Step("SessionEnd", nil, .idle) { XCTAssertNil($0) },
        ]

        var store = SessionStore()
        for (index, step) in steps.enumerated() {
            let now = t0 + TimeInterval(index)
            store.apply(try Fixtures.hookEvent(step.fixture), environment: .init(termProgram: "iTerm.app"), at: now)
            let session = store.session(id: sessionID)
            XCTAssertEqual(session?.status, step.status, step.fixture)
            XCTAssertEqual(store.mood(now: now), step.mood, step.fixture)
            step.check?(session)
        }
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testEventsBeforeSessionStartCreateTheSession() {
        var store = SessionStore()
        store.apply(event("PreToolUse", ["cwd": .string("/Users/shoei/dev/app"), "tool_name": .string("Bash"),
                                         "tool_input": .object(["command": .string("ls")])]), at: t0)
        let session = store.session(id: "s1")
        XCTAssertEqual(session?.status, .working)
        XCTAssertEqual(session?.displayName, "app")
    }

    func testUnknownEventOnlyTouchesTheSession() {
        var store = SessionStore()
        store.apply(event("SessionStart"), at: t0)
        store.apply(event("PreCompact", ["trigger": .string("auto")]), at: t0 + 5)
        XCTAssertEqual(store.session(id: "s1")?.status, .waitingForInput)
        XCTAssertEqual(store.session(id: "s1")?.lastEventAt, t0 + 5)
    }

    func testSubagentStopWithoutStartIsIgnored() {
        var store = SessionStore()
        store.apply(event("SubagentStop", ["agent_id": .string("internal"), "agent_type": .string("")]), at: t0)
        XCTAssertEqual(store.session(id: "s1")?.subagents, [])
    }

    func testToolEventInsideUnknownSubagentAddsIt() {
        var store = SessionStore()
        store.apply(event("PreToolUse", ["agent_id": .string("a1"), "agent_type": .string("architect"),
                                         "tool_name": .string("Grep"), "tool_use_id": .string("t1"),
                                         "tool_input": .object(["pattern": .string("HookEvent")])]), at: t0)
        let session = store.session(id: "s1")
        XCTAssertEqual(session?.subagents.map(\.id), ["a1"])
        XCTAssertEqual(session?.subagents.first?.type, "architect")
        XCTAssertEqual(session?.subagents.first?.currentTool?.summary, "HookEvent")
        // サブエージェント内のツールでは、セッション本体の状態は変えない。
        XCTAssertEqual(session?.status, .waitingForInput)
        XCTAssertEqual(store.mood(now: t0), .working)
    }

    func testBackgroundSubagentKeepsCharacterWorkingAfterStop() {
        var store = SessionStore()
        store.apply(event("UserPromptSubmit"), at: t0)
        store.apply(event("SubagentStart", ["agent_id": .string("a1"), "agent_type": .string("researcher")]), at: t0 + 1)
        store.apply(event("Stop"), at: t0 + 2)
        store.apply(event("PostToolUse", ["agent_id": .string("a1"), "tool_name": .string("Read")]), at: t0 + 3)
        XCTAssertEqual(store.session(id: "s1")?.status, .done)
        XCTAssertEqual(store.mood(now: t0 + 3), .working)
        store.apply(event("SubagentStop", ["agent_id": .string("a1")]), at: t0 + 4)
        XCTAssertEqual(store.mood(now: t0 + 4), .done)
    }

    func testDeniedToolIsInterruptedWhenTurnEnds() {
        var store = SessionStore()
        store.apply(event("PreToolUse", ["tool_name": .string("Bash"), "tool_use_id": .string("t1")]), at: t0)
        store.apply(event("PermissionRequest", ["tool_name": .string("Bash")]), at: t0 + 1)
        store.apply(event("Stop"), at: t0 + 2)
        let session = store.session(id: "s1")
        XCTAssertEqual(session?.recentTools.first?.status, .interrupted)
        XCTAssertNil(session?.pendingPermission)
        XCTAssertEqual(session?.status, .done)
    }

    func testDenialInTerminalIsClearedByNextStep() {
        var store = SessionStore()
        store.apply(event("PreToolUse", ["tool_name": .string("Bash"), "tool_use_id": .string("t1")]), at: t0)
        store.apply(event("PermissionRequest", ["tool_name": .string("Bash")]), at: t0 + 1)
        // サブエージェントのツールでは本体の承認待ちは消えない。
        store.apply(event("PreToolUse", ["agent_id": .string("a1"), "tool_name": .string("Read")]), at: t0 + 2)
        XCTAssertEqual(store.session(id: "s1")?.status, .waitingForApproval)
        // 本体が次のツールに進んだら片付いたとみなす。
        store.apply(event("PreToolUse", ["tool_name": .string("Read"), "tool_use_id": .string("t2")]), at: t0 + 3)
        XCTAssertEqual(store.session(id: "s1")?.status, .working)
        XCTAssertNil(store.session(id: "s1")?.pendingPermission)

        // 拒否して放置 → idle_prompt で入力待ちへ。
        store.apply(event("PermissionRequest", ["tool_name": .string("Bash")]), at: t0 + 4)
        store.apply(event("Notification", ["notification_type": .string("idle_prompt")]), at: t0 + 64)
        XCTAssertEqual(store.session(id: "s1")?.status, .waitingForInput)
        XCTAssertNil(store.session(id: "s1")?.pendingPermission)
    }

    func testPermissionAnsweredInNotch() {
        var store = SessionStore()
        store.apply(event("PermissionRequest", ["tool_name": .string("Bash")]), at: t0)
        store.permissionAnswered(sessionID: "s1", at: t0 + 1)
        XCTAssertEqual(store.session(id: "s1")?.status, .working)
        XCTAssertNil(store.session(id: "s1")?.pendingPermission)
        // 承認待ちでなければ何もしない。
        store.apply(event("Stop"), at: t0 + 2)
        store.permissionAnswered(sessionID: "s1", at: t0 + 3)
        XCTAssertEqual(store.session(id: "s1")?.status, .done)
        store.permissionAnswered(sessionID: "unknown", at: t0 + 3)
    }

    func testStopFailureShowsError() {
        var store = SessionStore()
        store.apply(event("UserPromptSubmit"), at: t0)
        store.apply(event("StopFailure", ["error": .string("rate_limit"), "error_details": .string("429")]), at: t0 + 1)
        XCTAssertEqual(store.session(id: "s1")?.status, .error)
        XCTAssertEqual(store.session(id: "s1")?.lastError, "429")
        XCTAssertEqual(store.mood(now: t0 + 1), .error)
        // 次のプロンプトでエラーは消える。
        store.apply(event("UserPromptSubmit"), at: t0 + 2)
        XCTAssertNil(store.session(id: "s1")?.lastError)
    }

    func testNotifications() {
        var store = SessionStore()
        store.apply(event("UserPromptSubmit"), at: t0)
        store.apply(event("Notification", ["notification_type": .string("permission_prompt")]), at: t0 + 1)
        XCTAssertEqual(store.session(id: "s1")?.status, .waitingForApproval)
        store.apply(event("Stop"), at: t0 + 2)
        store.apply(event("Notification", ["notification_type": .string("idle_prompt")]), at: t0 + 60)
        XCTAssertEqual(store.session(id: "s1")?.status, .done)
        store.apply(event("UserPromptSubmit"), at: t0 + 61)
        store.apply(event("Notification", ["notification_type": .string("idle_prompt")]), at: t0 + 121)
        XCTAssertEqual(store.session(id: "s1")?.status, .waitingForInput)
    }

    func testClearResetsHistoryButCompactDoesNot() {
        var store = SessionStore()
        store.apply(event("UserPromptSubmit", ["prompt": .string("hi")]), at: t0)
        store.apply(event("PreToolUse", ["tool_name": .string("Read")]), at: t0 + 1)
        store.apply(event("SessionStart", ["source": .string("compact")]), at: t0 + 2)
        XCTAssertEqual(store.session(id: "s1")?.status, .working)
        XCTAssertEqual(store.session(id: "s1")?.recentTools.count, 1)
        store.apply(event("SessionStart", ["source": .string("clear")]), at: t0 + 3)
        XCTAssertEqual(store.session(id: "s1")?.status, .waitingForInput)
        XCTAssertEqual(store.session(id: "s1")?.recentTools, [])
        XCTAssertNil(store.session(id: "s1")?.lastPrompt)
    }

    func testRecentToolsAreCapped() {
        var store = SessionStore()
        for index in 0..<(SessionStore.maxRecentTools + 5) {
            store.apply(event("PreToolUse", ["tool_name": .string("Read"), "tool_use_id": .string("t\(index)")]), at: t0)
        }
        let tools = store.session(id: "s1")?.recentTools ?? []
        XCTAssertEqual(tools.count, SessionStore.maxRecentTools)
        XCTAssertEqual(tools.last?.id, "t\(SessionStore.maxRecentTools + 4)")
    }

    func testSilentSessionsStallThenDisappear() {
        var store = SessionStore(stalledAfter: 60, forgetAfter: 600)
        store.apply(event("UserPromptSubmit", session: "busy"), at: t0)
        store.apply(event("SubagentStart", session: "busy", ["agent_id": .string("a1")]), at: t0)
        store.apply(event("Stop", session: "finished"), at: t0)
        XCTAssertEqual(store.nextExpiry, t0 + 60)

        XCTAssertFalse(store.expire(now: t0 + 59))
        XCTAssertTrue(store.expire(now: t0 + 60))
        XCTAssertEqual(store.session(id: "busy")?.status, .stalled)
        XCTAssertEqual(store.session(id: "busy")?.subagents.first?.status, .stalled)
        XCTAssertEqual(store.session(id: "finished")?.status, .done)
        XCTAssertEqual(store.mood(now: t0 + 60), .idle)
        XCTAssertEqual(store.nextExpiry, t0 + 600)

        // 停止扱いのセッションにイベントが来たら戻る。
        store.apply(event("PreToolUse", session: "busy", ["tool_name": .string("Read")]), at: t0 + 100)
        XCTAssertEqual(store.session(id: "busy")?.status, .working)

        store.expire(now: t0 + 600)
        XCTAssertNil(store.session(id: "finished"))
        XCTAssertNotNil(store.session(id: "busy"))
    }

    func testDoneMoodFadesToIdle() {
        var store = SessionStore(moodHoldDuration: 20)
        store.apply(event("Stop"), at: t0)
        XCTAssertEqual(store.mood(now: t0 + 19), .done)
        XCTAssertEqual(store.nextMoodChange(after: t0 + 1), t0 + 20)
        XCTAssertEqual(store.mood(now: t0 + 20), .idle)
        XCTAssertNil(store.nextMoodChange(after: t0 + 20))
    }

    func testSessionsAreSortedByRecentActivity() {
        var store = SessionStore()
        store.apply(event("SessionStart", session: "a"), at: t0)
        store.apply(event("SessionStart", session: "b"), at: t0 + 1)
        store.apply(event("UserPromptSubmit", session: "a"), at: t0 + 2)
        XCTAssertEqual(store.sessions.map(\.id), ["a", "b"])
        store.apply(event("PermissionRequest", session: "b", ["tool_name": .string("Bash")]), at: t0 + 3)
        XCTAssertEqual(store.sessionsWaitingForApproval.map(\.id), ["b"])
    }
}

final class ToolSummaryTests: XCTestCase {
    func testSummaries() {
        let cases: [(String, JSONValue, String?)] = [
            ("Bash", .object(["command": .string("  \n npm test\nsecond")]), "npm test"),
            ("Read", .object(["file_path": .string("/a/b/File.swift")]), "File.swift"),
            ("Edit", .object(["file_path": .string("/a/README.md")]), "README.md"),
            ("Grep", .object(["pattern": .string("TODO")]), "TODO"),
            ("Agent", .object(["subagent_type": .string("architect")]), "architect"),
            ("WebSearch", .object(["query": .string("swift sockets")]), "swift sockets"),
            ("mcp__github__get_me", .object([:]), nil),
            ("CustomTool", .object(["path": .string("/x")]), "/x"),
        ]
        for (tool, input, expected) in cases {
            XCTAssertEqual(ToolSummary.summarize(toolName: tool, input: input), expected, tool)
        }
        XCTAssertNil(ToolSummary.summarize(toolName: "Bash", input: nil))
    }

    func testLongTextIsTruncated() {
        let summary = ToolSummary.oneLine(String(repeating: "a", count: 500))
        XCTAssertEqual(summary?.count, ToolSummary.maxLength)
        XCTAssertEqual(summary?.last, "…")
    }
}
