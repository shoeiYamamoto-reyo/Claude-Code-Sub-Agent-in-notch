import Foundation
import XCTest
@testable import AgentKit

final class StreamJSONTests: XCTestCase {
    private func fixtureLines(_ name: String) throws -> [String] {
        let url = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/stream-json/\(name).jsonl")
        return try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
    }

    func testTranscriptFromFixture() throws {
        var transcript = TaskTranscript()
        for line in try fixtureLines("task-with-subagent") {
            transcript.consume(line)
        }
        XCTAssertEqual(transcript.sessionID, "6f9619ff-8b86-d011-b42d-00c04fc964ff")
        XCTAssertEqual(transcript.model, "claude-sonnet-5-5")
        XCTAssertEqual(transcript.cwd, "/Users/me/src/app")
        // 拒否された Write は含めず、サブエージェントの Write は含める。
        XCTAssertEqual(transcript.changedFiles, [
            "/Users/me/src/app/README.md",
            "/Users/me/src/app/Tests/AppTests.swift",
        ])
        XCTAssertEqual(transcript.toolUseCount, 5)
        XCTAssertNil(transcript.currentTool)
        XCTAssertEqual(transcript.lastAssistantText, "README の見出しを直し、テストを追加しました。")
        XCTAssertEqual(transcript.result, TaskResult(
            subtype: "success",
            isError: false,
            text: "README の見出しを直し、テストを追加しました。",
            costUSD: 0.0821,
            durationMilliseconds: 42150,
            turns: 6
        ))
        XCTAssertEqual(transcript.unreadableLines, 0)
    }

    func testSubagentTextDoesNotReplaceMainResponse() throws {
        var transcript = TaskTranscript()
        let lines = try fixtureLines("task-with-subagent")
        // サブエージェントの応答（7 行目）まで。
        for line in lines.prefix(7) { transcript.consume(line) }
        XCTAssertEqual(transcript.lastAssistantText, "README を確認します。")
        // メインで動いているのは Agent ツール。
        XCTAssertEqual(transcript.currentTool?.name, "Agent")
        XCTAssertNil(transcript.result)
    }

    func testErrorResultAndUnknownLines() {
        var transcript = TaskTranscript()
        transcript.consume("not json")
        transcript.consume("   ")
        transcript.consume(#"{"type":"future_thing","x":1}"#)
        transcript.consume(#"{"type":"result","subtype":"error_max_turns","num_turns":3}"#)
        XCTAssertEqual(transcript.unreadableLines, 1)
        XCTAssertEqual(transcript.result?.isError, true)
        XCTAssertEqual(transcript.result?.subtype, "error_max_turns")
        XCTAssertNil(transcript.lastAssistantText)
        XCTAssertEqual(StreamJSONEvent.decode(#"{"type":"future_thing"}"#), .unknown(type: "future_thing"))
        XCTAssertNil(StreamJSONEvent.decode("{"))
    }

    func testEditWithoutResultIsNotCounted() {
        var transcript = TaskTranscript()
        transcript.consume(#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/a"}}]},"parent_tool_use_id":null}"#)
        XCTAssertEqual(transcript.changedFiles, [])
        XCTAssertEqual(transcript.currentTool?.name, "Edit")
        transcript.consume(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]},"parent_tool_use_id":null}"#)
        transcript.consume(#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Edit","input":{"file_path":"/a"}}]},"parent_tool_use_id":null}"#)
        transcript.consume(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","content":"ok"}]},"parent_tool_use_id":null}"#)
        XCTAssertEqual(transcript.changedFiles, ["/a"])
    }

    func testFollowUpKeepsHistoryAndClearsResult() throws {
        var transcript = TaskTranscript()
        for line in try fixtureLines("task-with-subagent") { transcript.consume(line) }
        transcript.beginFollowUp()
        XCTAssertNil(transcript.result)
        XCTAssertNil(transcript.currentTool)
        XCTAssertEqual(transcript.lastAssistantText, "README の見出しを直し、テストを追加しました。")
        XCTAssertEqual(transcript.changedFiles.count, 2)
        XCTAssertEqual(transcript.toolUseCount, 5)

        transcript.consume(#"{"type":"assistant","message":{"content":[{"type":"text","text":"続きをやります。"},{"type":"tool_use","id":"f1","name":"Write","input":{"file_path":"/Users/me/src/app/CHANGELOG.md"}}]},"parent_tool_use_id":null}"#)
        XCTAssertEqual(transcript.currentTool?.name, "Write")
        transcript.consume(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"f1","content":"ok"}]},"parent_tool_use_id":null}"#)
        transcript.consume(#"{"type":"result","subtype":"success","is_error":false,"result":"CHANGELOG も更新しました。","num_turns":2}"#)
        XCTAssertEqual(transcript.changedFiles.last, "/Users/me/src/app/CHANGELOG.md")
        XCTAssertEqual(transcript.changedFiles.count, 3)
        XCTAssertEqual(transcript.toolUseCount, 6)
        XCTAssertEqual(transcript.lastAssistantText, "CHANGELOG も更新しました。")
        XCTAssertEqual(transcript.result?.turns, 2)
    }
}

final class LineBufferTests: XCTestCase {
    func testSplitsChunksIntoLines() {
        var buffer = LineBuffer()
        XCTAssertEqual(buffer.append(Data("{\"a\":".utf8)), [])
        XCTAssertEqual(buffer.append(Data("1}\n{\"b\":2}\n{\"c\"".utf8)), [#"{"a":1}"#, #"{"b":2}"#])
        XCTAssertEqual(buffer.append(Data(":3}\n\n".utf8)), [#"{"c":3}"#, ""])
        XCTAssertNil(buffer.flush())
        _ = buffer.append(Data("tail".utf8))
        XCTAssertEqual(buffer.flush(), "tail")
        XCTAssertNil(buffer.flush())
    }

    func testMultibyteSplitAcrossChunks() {
        var buffer = LineBuffer()
        let bytes = Array("日本語\n".utf8)
        XCTAssertEqual(buffer.append(Data(bytes[0..<4])), [])
        XCTAssertEqual(buffer.append(Data(bytes[4...])), ["日本語"])
    }

    func testDropsOverlongLine() {
        var buffer = LineBuffer(maxLineBytes: 4)
        XCTAssertEqual(buffer.append(Data("123456".utf8)), [])
        XCTAssertEqual(buffer.append(Data("ab\n".utf8)), ["ab"])
    }
}
