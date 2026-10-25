import Foundation
import XCTest
@testable import AgentKit

final class HookWireMessageTests: XCTestCase {
    func testEncodesOneLineAndRoundTrips() throws {
        let message = HookWireMessage(
            mode: .event,
            env: .init(termProgram: "iTerm.app", bundleID: "com.googlecode.iterm2"),
            hook: .object(["hook_event_name": .string("Stop"), "last_assistant_message": .string("1行目\n2行目")])
        )
        let line = try message.encodedLine()
        XCTAssertEqual(line.last, UInt8(ascii: "\n"))
        XCTAssertEqual(line.filter { $0 == UInt8(ascii: "\n") }.count, 1)
        XCTAssertEqual(try HookWireMessage.decode(line: line), message)

        let object = try JSONDecoder().decode(JSONValue.self, from: line)
        XCTAssertEqual(object["v"], .number(1))
        XCTAssertEqual(object["mode"], .string("event"))
        XCTAssertEqual(object["env"]?["term_program"], .string("iTerm.app"))
        XCTAssertEqual(object["env"]?["bundle_id"], .string("com.googlecode.iterm2"))
    }

    func testEnvironmentFromProcess() {
        let env = HookWireMessage.Environment(processEnvironment: [
            "TERM_PROGRAM": "Apple_Terminal", "__CFBundleIdentifier": "", "PATH": "/usr/bin",
        ])
        XCTAssertEqual(env, .init(termProgram: "Apple_Terminal", bundleID: nil))
    }

    func testSocketPathFromEnvironment() {
        XCTAssertEqual(
            HookBridge.socketPath(environment: ["HOME": "/Users/shoei"]),
            "/Users/shoei/Library/Application Support/NotchAgent/notch.sock"
        )
        XCTAssertEqual(HookBridge.socketPath(environment: ["HOME": "/Users/shoei", "NOTCH_AGENT_SOCKET": "/tmp/x.sock"]), "/tmp/x.sock")
        XCTAssertNil(HookBridge.socketPath(environment: [:]))
    }
}
