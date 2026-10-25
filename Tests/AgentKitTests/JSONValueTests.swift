import Foundation
import XCTest
@testable import AgentKit

final class JSONValueTests: XCTestCase {
    func testDecodesHookPayloadKeepingUnknownFields() throws {
        let json = """
        {
          "session_id": "abc123",
          "hook_event_name": "PreToolUse",
          "tool_input": { "command": "npm test", "timeout": 120000, "run_in_background": false },
          "future_field": [1, null, "x"]
        }
        """
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))

        XCTAssertEqual(value["session_id"]?.stringValue, "abc123")
        XCTAssertEqual(value["tool_input"]?["command"]?.stringValue, "npm test")
        XCTAssertEqual(value["tool_input"]?["timeout"]?.numberValue, 120000)
        XCTAssertEqual(value["tool_input"]?["run_in_background"]?.boolValue, false)
        XCTAssertEqual(value["future_field"], .array([.number(1), .null, .string("x")]))
    }

    func testKeepsBoolsAndNumbersApart() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(#"[true, 1, 0, false]"#.utf8))
        XCTAssertEqual(value, .array([.bool(true), .number(1), .number(0), .bool(false)]))
    }

    func testRoundTrips() throws {
        let original: JSONValue = .object([
            "a": .string("あ"),
            "b": .array([.bool(true), .null, .number(1.5)]),
            "c": .object([:]),
        ])
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), original)
    }

    func testSubscriptOnNonObjectIsNil() {
        XCTAssertNil(JSONValue.string("x")["key"])
        XCTAssertNil(JSONValue.array([])["key"])
    }
}
