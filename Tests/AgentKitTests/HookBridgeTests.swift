import XCTest
@testable import AgentKit

final class HookBridgeTests: XCTestCase {
    func testSocketPathUnderApplicationSupport() {
        XCTAssertEqual(
            HookBridge.socketPath(home: "/Users/shoei"),
            "/Users/shoei/Library/Application Support/NotchAgent/notch.sock"
        )
        XCTAssertEqual(
            HookBridge.socketPath(home: "/Users/shoei/"),
            "/Users/shoei/Library/Application Support/NotchAgent/notch.sock"
        )
    }

    func testTypicalPathFitsInSocketAddress() {
        XCTAssertTrue(HookBridge.fitsInSocketAddress(HookBridge.socketPath(home: "/Users/shoei")))
    }

    func testTooLongPathIsRejected() {
        let home = "/Users/" + String(repeating: "a", count: 80)
        XCTAssertFalse(HookBridge.fitsInSocketAddress(HookBridge.socketPath(home: home)))
    }
}
