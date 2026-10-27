import Foundation
import XCTest
@testable import AgentKit

/// ROADMAP 5-3: ファイル編集の差分（+N −M）と詳細。
final class FileEditTests: XCTestCase {
    func testEditCountsChangedLines() throws {
        let edit = try XCTUnwrap(FileEdit.from(toolName: "Edit", input: .object([
            "file_path": .string("/a.swift"),
            "old_string": .string("let a = 1\nlet b = 2\nlet c = 3"),
            "new_string": .string("let a = 1\nlet b = 20\nlet b2 = 21\nlet c = 3"),
        ])))
        XCTAssertEqual(edit.path, "/a.swift")
        XCTAssertEqual(edit.kind, .edit)
        XCTAssertEqual(edit.added, 2)
        XCTAssertEqual(edit.removed, 1)
        XCTAssertEqual(edit.hunks.count, 1)
        XCTAssertEqual(edit.hunks[0].compactMap { $0 }.filter { $0.kind == .removed }.map(\.text), ["let b = 2"])
        XCTAssertFalse(edit.isTruncated)
    }

    func testMultiEditWriteAndNotebook() throws {
        let multi = try XCTUnwrap(FileEdit.from(toolName: "MultiEdit", input: .object([
            "file_path": .string("/b"),
            "edits": .array([
                .object(["old_string": .string("x"), "new_string": .string("y")]),
                .object(["old_string": .string("p\nq"), "new_string": .string("p")]),
            ]),
        ])))
        XCTAssertEqual(multi.added, 1)
        XCTAssertEqual(multi.removed, 2)
        XCTAssertEqual(multi.hunks.count, 2)

        let write = try XCTUnwrap(FileEdit.from(toolName: "Write", input: .object([
            "file_path": .string("/c"), "content": .string("1\n2\n3\n"),
        ])))
        XCTAssertEqual(write.kind, .write)
        XCTAssertEqual(write.added, 3)
        XCTAssertEqual(write.removed, 0)

        let notebook = try XCTUnwrap(FileEdit.from(toolName: "NotebookEdit", input: .object([
            "notebook_path": .string("/n.ipynb"), "new_source": .string("print(1)"),
        ])))
        XCTAssertEqual(notebook.kind, .notebook)
        XCTAssertEqual(notebook.added, 1)
    }

    func testOtherToolsAndMissingPathsAreIgnored() {
        XCTAssertNil(FileEdit.from(toolName: "Bash", input: .object(["command": .string("ls")])))
        XCTAssertNil(FileEdit.from(toolName: "Edit", input: .object(["old_string": .string("a")])))
        XCTAssertNil(FileEdit.from(toolName: "Edit", input: nil))
    }

    func testLargeWriteKeepsCountsButTruncatesDetail() throws {
        let content = (1...1000).map { "line \($0)" }.joined(separator: "\n")
        let write = try XCTUnwrap(FileEdit.from(toolName: "Write", input: .object([
            "file_path": .string("/big"), "content": .string(content),
        ])))
        XCTAssertEqual(write.added, 1000)
        XCTAssertTrue(write.isTruncated)
        XCTAssertLessThanOrEqual(write.hunks.flatMap { $0 }.count, FileEdit.maxStoredLines)
    }

    func testChangesAreGroupedByFile() {
        var changes: [FileChange] = []
        let one = FileEdit(path: "/a", kind: .edit, added: 2, removed: 1, hunks: [])
        let two = FileEdit(path: "/b", kind: .write, added: 5, removed: 0, hunks: [])
        FileChange.record(one, in: &changes)
        FileChange.record(two, in: &changes)
        FileChange.record(one, in: &changes, keepingEdits: 1)
        XCTAssertEqual(changes.map(\.path), ["/a", "/b"])
        XCTAssertEqual(changes[0].added, 4)
        XCTAssertEqual(changes[0].removed, 2)
        XCTAssertEqual(changes[0].edits.count, 1)
        XCTAssertEqual(changes[0].countsText, "+4 −2")
        let totals = FileChange.totals(changes)
        XCTAssertEqual(totals.added, 9)
        XCTAssertEqual(totals.removed, 2)
    }

    func testTranscriptCountsOnlySuccessfulEdits() throws {
        var transcript = TaskTranscript()
        transcript.apply(.assistant(texts: [], toolUses: [
            .init(id: "t1", name: "Edit", input: .object([
                "file_path": .string("/a"), "old_string": .string("a"), "new_string": .string("b\nc"),
            ])),
            .init(id: "t2", name: "Write", input: .object(["file_path": .string("/b"), "content": .string("x")])),
        ], parentToolUseID: nil))
        transcript.apply(.toolResults([.init(toolUseID: "t1", isError: false), .init(toolUseID: "t2", isError: true)], parentToolUseID: nil))
        XCTAssertEqual(transcript.changedFiles, ["/a"])
        XCTAssertEqual(transcript.fileChanges.first?.added, 2)
        XCTAssertEqual(transcript.fileChanges.first?.removed, 1)
    }

    func testSessionRecordsEditsFromHooks() {
        var store = SessionStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func event(_ name: String, _ fields: [String: JSONValue]) -> HookEvent {
            var object = fields
            object["hook_event_name"] = .string(name)
            object["session_id"] = .string("s1")
            return try! HookEvent(json: .object(object))
        }
        let input: JSONValue = .object(["file_path": .string("/a"), "old_string": .string("a"), "new_string": .string("b")])
        store.apply(event("PostToolUse", ["tool_name": .string("Edit"), "tool_use_id": .string("u1"), "tool_input": input]), at: now)
        store.apply(event("PostToolUseFailure", ["tool_name": .string("Edit"), "tool_use_id": .string("u2"), "tool_input": input]), at: now)
        XCTAssertEqual(store.session(id: "s1")?.fileChanges.map(\.countsText), ["+1 −1"])
        store.apply(event("SessionStart", ["source": .string("clear")]), at: now)
        XCTAssertEqual(store.session(id: "s1")?.fileChanges, [])
    }
}
