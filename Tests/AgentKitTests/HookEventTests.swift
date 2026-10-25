import Foundation
import XCTest
@testable import AgentKit

final class HookEventTests: XCTestCase {
    func testDecodesEveryFixture() throws {
        let files = try Fixtures.hookFiles()
        XCTAssertGreaterThanOrEqual(files.count, 16)
        for file in files {
            let event = try HookEvent(data: Data(contentsOf: file))
            let expectedName = file.deletingPathExtension().lastPathComponent.split(separator: "-").first.map(String.init)
            XCTAssertEqual(event.name.rawValue, expectedName, file.lastPathComponent)
            XCTAssertEqual(event.sessionID, "8f2c6c1e-0b7a-4d4e-9a51-1d3f0f6a2b10", file.lastPathComponent)
        }
    }

    func testKnownNamesRoundTrip() {
        for raw in ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse",
                    "PostToolUseFailure", "Notification", "SubagentStart", "SubagentStop", "Stop", "StopFailure"] {
            let name = HookEventName(rawValue: raw)
            XCTAssertNotEqual(name, .unknown(raw))
            XCTAssertEqual(name.rawValue, raw)
        }
    }

    func testUnknownEventKeepsAllFields() throws {
        let event = try Fixtures.hookEvent("PreCompact-unknown")
        XCTAssertEqual(event.name, .unknown("PreCompact"))
        XCTAssertEqual(event.raw["some_future_field"]?["nested"], .array([.number(1), .number(2.5), .bool(true), .null]))
    }

    func testToolEventFields() throws {
        let event = try Fixtures.hookEvent("PreToolUse-Bash")
        XCTAssertEqual(event.name, .preToolUse)
        XCTAssertEqual(event.cwd, "/Users/shoei/dev/notch")
        XCTAssertEqual(event.permissionMode, "default")
        XCTAssertEqual(event.toolName, "Bash")
        XCTAssertEqual(event.toolUseID, "toolu_01ABC123")
        XCTAssertEqual(event.toolInput?["command"]?.stringValue, "npm test")
        XCTAssertNil(event.agentID)
    }

    func testSubagentFields() throws {
        let start = try Fixtures.hookEvent("SubagentStart")
        XCTAssertEqual(start.agentID, "a7c1e2")
        XCTAssertEqual(start.agentType, "code-reviewer")
        let stop = try Fixtures.hookEvent("SubagentStop")
        XCTAssertEqual(stop.lastAssistantMessage, "LGTM")
        let inside = try Fixtures.hookEvent("PreToolUse-InSubagent")
        XCTAssertEqual(inside.agentID, "a7c1e2")
    }

    func testSessionAndStopFields() throws {
        let start = try Fixtures.hookEvent("SessionStart")
        XCTAssertEqual(start.source, "startup")
        XCTAssertEqual(start.model, "claude-opus-5-5")
        XCTAssertEqual(start.sessionTitle, "notch app")
        XCTAssertEqual(try Fixtures.hookEvent("Stop").lastAssistantMessage, "テストを追加しました。")
        XCTAssertEqual(try Fixtures.hookEvent("SessionEnd").reason, "prompt_input_exit")
        let notification = try Fixtures.hookEvent("Notification")
        XCTAssertEqual(notification.notificationType, "permission_prompt")
        XCTAssertEqual(notification.message, "Claude needs your permission to use Bash")
        XCTAssertEqual(try Fixtures.hookEvent("UserPromptSubmit").prompt, "テストを追加して")
    }

    func testEmptyStringsReadAsNil() throws {
        let event = try HookEvent(json: .object([
            "hook_event_name": .string("SubagentStop"),
            "session_id": .string("s"),
            "agent_type": .string(""),
        ]))
        XCTAssertNil(event.agentType)
    }

    func testRejectsPayloadsWithoutRequiredFields() {
        XCTAssertThrowsError(try HookEvent(json: .array([]))) {
            XCTAssertEqual($0 as? HookEventError, .notAnObject)
        }
        XCTAssertThrowsError(try HookEvent(json: .object(["session_id": .string("s")]))) {
            XCTAssertEqual($0 as? HookEventError, .missingField("hook_event_name"))
        }
        XCTAssertThrowsError(try HookEvent(json: .object(["hook_event_name": .string("Stop")]))) {
            XCTAssertEqual($0 as? HookEventError, .missingField("session_id"))
        }
        XCTAssertThrowsError(try HookEvent(data: Data("not json".utf8)))
    }
}
