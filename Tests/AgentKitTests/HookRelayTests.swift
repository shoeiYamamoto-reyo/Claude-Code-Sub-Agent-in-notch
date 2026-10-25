import Foundation
import XCTest
@testable import AgentKit

/// 中継 CLI とアプリ側ソケットの結合テスト（ROADMAP 1-4、1-6）。
final class HookRelayTests: XCTestCase {
    private var socketPath = ""

    override func setUp() {
        super.setUp()
        // sun_path の長さ制限があるので短いパスにする。
        socketPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("na-\(UUID().uuidString.prefix(8)).sock")
    }

    override func tearDown() {
        unlink(socketPath)
        super.tearDown()
    }

    private let stopPayload = Data(#"{"session_id":"s1","hook_event_name":"Stop","last_assistant_message":"done"}"#.utf8)

    private func run(_ input: Data, arguments: [String] = []) -> HookRelay.Outcome {
        HookRelay.run(arguments: arguments, input: input, environment: ["NOTCH_AGENT_SOCKET": socketPath, "TERM_PROGRAM": "vscode"])
    }

    func testExitsWithin100msWhenSocketIsMissing() {
        let clock = ContinuousClock()
        var outcome: HookRelay.Outcome?
        let elapsed = clock.measure { outcome = run(stopPayload) }
        XCTAssertEqual(outcome, .skipped(.unreachable))
        XCTAssertLessThan(elapsed, .milliseconds(100))
    }

    func testExitsWithin100msWhenSocketFileIsStale() throws {
        _ = FileManager.default.createFile(atPath: socketPath, contents: Data())
        let clock = ContinuousClock()
        var outcome: HookRelay.Outcome?
        let elapsed = clock.measure { outcome = run(stopPayload) }
        XCTAssertEqual(outcome, .skipped(.unreachable))
        XCTAssertLessThan(elapsed, .milliseconds(100))
    }

    func testSkipsInputThatIsNotAJSONObject() {
        XCTAssertEqual(run(Data()), .skipped(.emptyInput))
        XCTAssertEqual(run(Data("hello".utf8)), .skipped(.invalidJSON))
        XCTAssertEqual(run(Data("[1,2]".utf8)), .skipped(.invalidJSON))
        XCTAssertEqual(run(Data(count: HookBridge.maxMessageBytes + 1)), .skipped(.tooLarge))
        XCTAssertEqual(
            HookRelay.run(arguments: [], input: stopPayload, environment: [:]),
            .skipped(.noSocketPath)
        )
    }

    func testModeFromArguments() {
        XCTAssertEqual(HookRelay.mode(arguments: []), .event)
        XCTAssertEqual(HookRelay.mode(arguments: ["--wait"]), .wait)
        XCTAssertEqual(HookRelay.mode(arguments: ["--ask"]), .ask)
    }

    func testRelayedEventReachesServer() throws {
        let received = Received()
        let expectation = expectation(description: "received")
        let server = HookSocketServer(path: socketPath) { message in
            received.append(message)
            expectation.fulfill()
        }
        try server.start()
        defer { server.stop() }

        XCTAssertEqual(run(stopPayload), .sent)
        wait(for: [expectation], timeout: 2)

        let message = try XCTUnwrap(received.messages.first)
        XCTAssertEqual(message.mode, .event)
        XCTAssertEqual(message.env.termProgram, "vscode")
        let event = try HookEvent(json: message.hook)
        XCTAssertEqual(event.name, .stop)
        XCTAssertEqual(event.lastAssistantMessage, "done")
    }

    func testServerHandlesManyConnectionsAndIgnoresGarbage() throws {
        let received = Received()
        let expectation = expectation(description: "received")
        expectation.expectedFulfillmentCount = 10
        let server = HookSocketServer(path: socketPath) { message in
            received.append(message)
            expectation.fulfill()
        }
        try server.start()
        defer { server.stop() }

        XCTAssertTrue(UnixSocketClient.send(Data("garbage\n".utf8), to: socketPath, timeoutMilliseconds: 300))
        let wrongVersion = try HookWireMessage(v: 99, mode: .event, env: .init(), hook: .object([:])).encodedLine()
        XCTAssertTrue(UnixSocketClient.send(wrongVersion, to: socketPath, timeoutMilliseconds: 300))
        for index in 0..<9 {
            let payload = Data(#"{"session_id":"s\#(index)","hook_event_name":"PreToolUse"}"#.utf8)
            XCTAssertEqual(run(payload), .sent)
        }
        // 改行なしで閉じた 1 行も受け取る。
        var withoutNewline = try HookWireMessage(mode: .event, env: .init(), hook: .object(["session_id": .string("last")])).encodedLine()
        withoutNewline.removeLast()
        XCTAssertTrue(UnixSocketClient.send(withoutNewline, to: socketPath, timeoutMilliseconds: 300))

        wait(for: [expectation], timeout: 3)
        XCTAssertEqual(received.messages.count, 10)
    }

    func testSecondServerOnSamePathIsRejected() throws {
        let first = HookSocketServer(path: socketPath) { _ in }
        try first.start()
        let second = HookSocketServer(path: socketPath) { _ in }
        XCTAssertThrowsError(try second.start()) {
            XCTAssertEqual($0 as? HookSocketServer.StartError, .alreadyRunning)
        }
        first.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
        // 古いソケットファイルが残っていても起動できる。
        _ = FileManager.default.createFile(atPath: socketPath, contents: Data())
        XCTAssertNoThrow(try second.start())
        second.stop()
    }

    func testTooLongPathIsRejected() {
        let server = HookSocketServer(path: "/tmp/" + String(repeating: "x", count: 120)) { _ in }
        XCTAssertThrowsError(try server.start()) {
            XCTAssertEqual($0 as? HookSocketServer.StartError, .pathTooLong)
        }
    }

    /// 実行ファイルそのもの: アプリが無くても何も出力せず exit 0 で終わる。
    func testExecutableExitsSilentlyWithoutApp() throws {
        let binary = productsDirectory.appendingPathComponent("notch-hook")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw XCTSkip("notch-hook がビルドされていない: \(binary.path)")
        }
        let process = Process()
        process.executableURL = binary
        process.environment = ["NOTCH_AGENT_SOCKET": socketPath, "HOME": NSTemporaryDirectory()]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let clock = ContinuousClock()
        let start = clock.now
        try process.run()
        stdin.fileHandleForWriting.write(stopPayload)
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        let elapsed = start.duration(to: clock.now)

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(stdout.fileHandleForReading.readDataToEndOfFile(), Data())
        XCTAssertEqual(stderr.fileHandleForReading.readDataToEndOfFile(), Data())
        // プロセスの起動時間を含むので余裕を持たせる（関数単体の 100 ms は上のテストで見る）。
        XCTAssertLessThan(elapsed, .seconds(1))
    }

    private var productsDirectory: URL {
        #if os(macOS)
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            return bundle.bundleURL.deletingLastPathComponent()
        }
        #endif
        return Bundle.main.bundleURL
    }
}

/// 別スレッドから呼ばれるハンドラの受け取り先。
private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [HookWireMessage] = []

    func append(_ message: HookWireMessage) {
        lock.lock()
        storage.append(message)
        lock.unlock()
    }

    var messages: [HookWireMessage] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
