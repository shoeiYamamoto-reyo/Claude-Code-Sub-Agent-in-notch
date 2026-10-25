import Foundation
import XCTest
@testable import AgentKit

/// 中継 CLI の応答待ち（ROADMAP 2-1）: 許可・拒否・時間切れ・アプリ終了。
final class HookRelayWaitTests: XCTestCase {
    private var socketPath = ""

    override func setUp() {
        super.setUp()
        socketPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("na-\(UUID().uuidString.prefix(8)).sock")
    }

    override func tearDown() {
        unlink(socketPath)
        super.tearDown()
    }

    private let permissionPayload = Data(#"""
    {"session_id":"s1","hook_event_name":"PermissionRequest","tool_name":"Bash",
     "tool_input":{"command":"rm -rf build"},
     "permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"rm -rf build"}],"behavior":"allow","destination":"localSettings"}]}
    """#.utf8)

    private let questionPayload = Data(#"""
    {"session_id":"s1","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_use_id":"t1",
     "tool_input":{"questions":[{"question":"Which framework?","header":"Framework","multiSelect":false,
       "options":[{"label":"React","description":"r"},{"label":"Vue","description":"v"}]}]}}
    """#.utf8)

    /// 応答待ちの要求に `reply` で答えるサーバーを立てる。
    private func startServer(
        waitGiveUp: TimeInterval = 115,
        closed: Received<Int>? = nil,
        respond: @escaping @Sendable (Int, HookWireMessage, HookSocketServer) -> Void
    ) throws -> HookSocketServer {
        let box = ServerBox()
        let server = HookSocketServer(
            path: socketPath,
            waitGiveUp: waitGiveUp,
            onMessage: { _ in },
            onRequest: { id, message in
                // reply は内部キューで sync するので、別のキューから呼ぶ。
                DispatchQueue.global().async { respond(id, message, box.server!) }
            },
            onClosed: { id in closed?.append(id) }
        )
        box.server = server
        try server.start()
        return server
    }

    private func run(_ payload: Data, _ arguments: [String], responseTimeout: Int? = nil) -> HookRelay.Outcome {
        HookRelay.run(
            arguments: arguments,
            input: payload,
            environment: ["NOTCH_AGENT_SOCKET": socketPath],
            responseTimeoutMilliseconds: responseTimeout
        )
    }

    private func json(_ outcome: HookRelay.Outcome) throws -> JSONValue {
        guard case .answered(let data) = outcome else {
            XCTFail("応答が無い: \(outcome)")
            return .null
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    func testAllow() throws {
        let server = try startServer { id, message, server in
            XCTAssertEqual(message.mode, .wait)
            server.reply(HookReply(decision: .allow), to: id)
        }
        defer { server.stop() }
        let output = try json(run(permissionPayload, ["--wait"]))
        XCTAssertEqual(output["hookSpecificOutput"]?["hookEventName"], .string("PermissionRequest"))
        XCTAssertEqual(output["hookSpecificOutput"]?["decision"], .object(["behavior": .string("allow")]))
    }

    func testDenyWithMessage() throws {
        let server = try startServer { id, _, server in
            server.reply(HookReply(decision: .deny, message: "やめて"), to: id)
        }
        defer { server.stop() }
        let decision = try json(run(permissionPayload, ["--wait"]))["hookSpecificOutput"]?["decision"]
        XCTAssertEqual(decision, .object(["behavior": .string("deny"), "message": .string("やめて")]))
    }

    func testAlwaysReturnsSuggestions() throws {
        let server = try startServer { id, _, server in
            server.reply(HookReply(decision: .always), to: id)
        }
        defer { server.stop() }
        let decision = try json(run(permissionPayload, ["--wait"]))["hookSpecificOutput"]?["decision"]
        XCTAssertEqual(decision?["behavior"], .string("allow"))
        XCTAssertEqual(decision?["updatedPermissions"]?.arrayValue?.first?["destination"], .string("localSettings"))
    }

    func testPassPrintsNothing() throws {
        let server = try startServer { id, _, server in server.reply(.pass, to: id) }
        defer { server.stop() }
        XCTAssertEqual(run(permissionPayload, ["--wait"]), .skipped(.noDecision))
    }

    /// アプリが応答せずに閉じた（アプリ終了・キャンセル）→ すぐに何も出さずに終わる。
    func testAppClosingWithoutReplyEndsQuickly() throws {
        let server = try startServer { id, _, server in server.cancel(id) }
        defer { server.stop() }
        let clock = ContinuousClock()
        var outcome: HookRelay.Outcome?
        let elapsed = clock.measure { outcome = run(permissionPayload, ["--wait"]) }
        XCTAssertEqual(outcome, .skipped(.noDecision))
        XCTAssertLessThan(elapsed, .seconds(1))
    }

    func testAppQuittingWhileWaitingEndsQuickly() throws {
        _ = try startServer { _, _, server in
            Thread.sleep(forTimeInterval: 0.1)
            server.stop()
        }
        let clock = ContinuousClock()
        var outcome: HookRelay.Outcome?
        let elapsed = clock.measure { outcome = run(permissionPayload, ["--wait"]) }
        XCTAssertEqual(outcome, .skipped(.noDecision))
        XCTAssertLessThan(elapsed, .seconds(2))
    }

    /// 中継側の時間切れ → 何も出さずに終わり、アプリには「閉じた」が届く。
    func testRelayTimeoutNotifiesApp() throws {
        let closed = Received<Int>()
        let expectation = expectation(description: "closed")
        let server = try startServer(closed: closed) { _, _, _ in }
        defer { server.stop() }
        XCTAssertEqual(run(permissionPayload, ["--wait"], responseTimeout: 200), .skipped(.noDecision))
        DispatchQueue.global().async {
            while closed.values.isEmpty { Thread.sleep(forTimeInterval: 0.01) }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }

    /// アプリ側の諦め時間を過ぎたら、応答せずに閉じる。
    func testAppGivesUp() throws {
        let closed = Received<Int>()
        let server = try startServer(waitGiveUp: 0.2, closed: closed) { _, _, _ in }
        defer { server.stop() }
        XCTAssertEqual(run(permissionPayload, ["--wait"]), .skipped(.noDecision))
        XCTAssertEqual(closed.values.count, 1)
        // 閉じた後の応答は届かない。
        XCTAssertFalse(server.reply(HookReply(decision: .allow), to: closed.values[0]))
    }

    func testNoAppMeansNoDecisionWithin100ms() {
        let clock = ContinuousClock()
        var outcome: HookRelay.Outcome?
        let elapsed = clock.measure { outcome = run(permissionPayload, ["--wait"]) }
        XCTAssertEqual(outcome, .skipped(.noDecision))
        XCTAssertLessThan(elapsed, .milliseconds(100))
    }

    func testAnswerQuestion() throws {
        let server = try startServer { id, message, server in
            XCTAssertEqual(message.mode, .ask)
            server.reply(HookReply(decision: .answer, answers: ["Which framework?": "Vue"]), to: id)
        }
        defer { server.stop() }
        let output = try json(run(questionPayload, ["--ask"]))["hookSpecificOutput"]
        XCTAssertEqual(output?["hookEventName"], .string("PreToolUse"))
        XCTAssertEqual(output?["permissionDecision"], .string("allow"))
        XCTAssertEqual(output?["updatedInput"]?["answers"], .object(["Which framework?": .string("Vue")]))
        XCTAssertEqual(output?["updatedInput"]?["questions"]?.arrayValue?.count, 1)
    }

    func testAskIgnoresOtherTools() {
        let payload = Data(#"{"session_id":"s1","hook_event_name":"PreToolUse","tool_name":"Bash"}"#.utf8)
        XCTAssertEqual(run(payload, ["--ask"]), .skipped(.notAQuestion))
    }

    /// 承認の応答をモードに合わない形で返しても、何も出さない。
    func testMismatchedDecisionsPrintNothing() {
        let hook = try! JSONDecoder().decode(JSONValue.self, from: permissionPayload)
        XCTAssertNil(HookDecisionOutput.output(mode: .wait, hook: hook, reply: HookReply(decision: .answer, answers: ["a": "b"])))
        XCTAssertNil(HookDecisionOutput.output(mode: .ask, hook: hook, reply: HookReply(decision: .allow)))
        XCTAssertNil(HookDecisionOutput.output(mode: .event, hook: hook, reply: HookReply(decision: .allow)))
        let question = try! JSONDecoder().decode(JSONValue.self, from: questionPayload)
        XCTAssertNil(HookDecisionOutput.output(mode: .ask, hook: question, reply: HookReply(decision: .answer, answers: [:])))
        // 理由が無い拒否は既定の文。
        let deny = HookDecisionOutput.output(mode: .wait, hook: hook, reply: HookReply(decision: .deny))!
        XCTAssertTrue(String(decoding: deny, as: UTF8.self).contains(HookDecisionOutput.defaultDenyMessage))
        // 提案が無い「常に許可」はただの許可。
        let plain = try! JSONDecoder().decode(JSONValue.self, from: Data(#"{"tool_name":"Bash"}"#.utf8))
        let always = HookDecisionOutput.output(mode: .wait, hook: plain, reply: HookReply(decision: .always))!
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: always)["hookSpecificOutput"]?["decision"],
                       .object(["behavior": .string("allow")]))
    }
}

final class ApprovalQueueTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func message(_ mode: HookWireMessage.Mode, _ fields: [String: JSONValue]) -> HookWireMessage {
        var object = fields
        object["session_id"] = object["session_id"] ?? .string("s1")
        return HookWireMessage(mode: mode, env: .init(), hook: .object(object))
    }

    private func permission(id: Int, session: String = "s1", command: String = "ls") -> ApprovalRequest {
        ApprovalRequest.make(id: id, message: message(.wait, [
            "session_id": .string(session),
            "hook_event_name": .string("PermissionRequest"),
            "tool_name": .string("Bash"),
            "tool_input": .object(["command": .string(command)]),
        ]), receivedAt: t0)!
    }

    func testMakeRequests() {
        let request = permission(id: 1, command: "rm -rf build")
        XCTAssertEqual(request.kind, .permission(toolName: "Bash", summary: "rm -rf build", detail: "rm -rf build", hasSuggestions: false))
        XCTAssertFalse(request.isQuestion)

        let question = ApprovalRequest.make(id: 2, message: message(.ask, [
            "hook_event_name": .string("PreToolUse"),
            "tool_name": .string("AskUserQuestion"),
            "agent_id": .string("a1"), "agent_type": .string("architect"),
            "tool_input": .object(["questions": .array([.object([
                "question": .string("Q?"), "multiSelect": .bool(true),
                "options": .array([.object(["label": .string("A")]), .object(["label": .string("B")])]),
            ])])]),
        ]), receivedAt: t0)
        XCTAssertEqual(question?.agentType, "architect")
        guard case .question(let questions)? = question?.kind else { return XCTFail() }
        XCTAssertEqual(questions.first?.options.map(\.label), ["A", "B"])
        XCTAssertEqual(questions.first?.multiSelect, true)

        // 扱えないもの
        XCTAssertNil(ApprovalRequest.make(id: 3, message: message(.event, ["hook_event_name": .string("PermissionRequest")]), receivedAt: t0))
        XCTAssertNil(ApprovalRequest.make(id: 4, message: message(.ask, [
            "hook_event_name": .string("PreToolUse"), "tool_name": .string("AskUserQuestion"),
            "tool_input": .object(["questions": .array([])]),
        ]), receivedAt: t0))
    }

    func testParseRejectsOddQuestions() {
        func parse(_ questions: [JSONValue]) -> [AskQuestion]? {
            AskQuestion.parse(toolInput: .object(["questions": .array(questions)]))
        }
        let ok: JSONValue = .object(["question": .string("Q"), "options": .array([.object(["label": .string("A")])])])
        XCTAssertNotNil(parse([ok]))
        XCTAssertNil(parse([ok, ok]))  // 同じ質問文
        XCTAssertNil(parse(Array(repeating: ok, count: 5)))
        XCTAssertNil(parse([.object(["question": .string("Q"), "options": .array([])])]))
        XCTAssertNil(parse([.object(["question": .string("Q"), "options": .array([.object(["description": .string("x")])])])]))
        XCTAssertEqual(AskQuestion.answerText(for: ["A", "B"]), "A, B")
    }

    func testOnlyTheDisplayedCardCanBeAnsweredAfterTheGuard() {
        var queue = ApprovalQueue(capacity: 5, clickGuard: 0.4)
        XCTAssertTrue(queue.enqueue(permission(id: 1), at: t0))
        XCTAssertTrue(queue.enqueue(permission(id: 2), at: t0 + 0.1))
        XCTAssertEqual(queue.current?.id, 1)

        XCTAssertEqual(queue.resolve(displayedID: 1, at: t0 + 0.2), .failure(.tooSoon))
        XCTAssertEqual(queue.resolve(displayedID: 2, at: t0 + 1), .failure(.notCurrent))
        XCTAssertEqual(try? queue.resolve(displayedID: 1, at: t0 + 1).get().id, 1)

        // 次のカードに切り替わった直後のクリックは受け付けない。
        XCTAssertEqual(queue.current?.id, 2)
        XCTAssertEqual(queue.resolve(displayedID: 2, at: t0 + 1.1), .failure(.tooSoon))
        XCTAssertEqual(try? queue.resolve(displayedID: 2, at: t0 + 1.5).get().id, 2)
        XCTAssertTrue(queue.isEmpty)
        XCTAssertNil(queue.currentShownAt)
    }

    func testCapacityAndRemoval() {
        var queue = ApprovalQueue(capacity: 2)
        XCTAssertTrue(queue.enqueue(permission(id: 1), at: t0))
        XCTAssertFalse(queue.enqueue(permission(id: 1), at: t0))
        XCTAssertTrue(queue.enqueue(permission(id: 2), at: t0))
        XCTAssertFalse(queue.enqueue(permission(id: 3), at: t0))

        XCTAssertEqual(queue.remove(id: 2, at: t0 + 1)?.id, 2)
        XCTAssertEqual(queue.currentShownAt, t0)
        XCTAssertEqual(queue.remove(id: 1, at: t0 + 2)?.id, 1)
        XCTAssertNil(queue.remove(id: 1, at: t0 + 2))
    }

    func testRequestsSettledByHookEvents() throws {
        var queue = ApprovalQueue()
        _ = queue.enqueue(permission(id: 1, command: "ls"), at: t0)
        _ = queue.enqueue(permission(id: 2, command: "pwd"), at: t0)
        _ = queue.enqueue(permission(id: 3, session: "other", command: "ls"), at: t0)

        let post = try HookEvent(json: .object([
            "session_id": .string("s1"), "hook_event_name": .string("PostToolUse"),
            "tool_name": .string("Bash"), "tool_input": .object(["command": .string("ls")]),
        ]))
        XCTAssertEqual(queue.requestsSettled(by: post).map(\.id), [1])

        let stop = try HookEvent(json: .object(["session_id": .string("s1"), "hook_event_name": .string("Stop")]))
        XCTAssertEqual(queue.requestsSettled(by: stop).map(\.id), [1, 2])

        let pre = try HookEvent(json: .object(["session_id": .string("s1"), "hook_event_name": .string("PreToolUse")]))
        XCTAssertEqual(queue.requestsSettled(by: pre), [])
    }
}

/// 別スレッドから足される値の受け取り先。
final class Received<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    func append(_ value: Value) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class ServerBox: @unchecked Sendable {
    var server: HookSocketServer?
}
