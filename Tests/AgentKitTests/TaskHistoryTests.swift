import Foundation
import XCTest
@testable import AgentKit

/// ROADMAP 5-4: タスクの履歴（F3-8）と定義ごとの利用回数（F5-6）。
final class TaskHistoryTests: XCTestCase {
    private let project = UUID()
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(_ id: UUID = UUID(), agent: String? = "reviewer", project: UUID? = nil, at offset: TimeInterval = 0) -> TaskHistoryEntry {
        TaskHistoryEntry(
            id: id,
            projectID: project ?? self.project,
            projectName: "app",
            agent: agent,
            prompt: "review",
            startedAt: start.addingTimeInterval(offset)
        )
    }

    func testBeginFollowUpAndFinish() throws {
        var history = TaskHistory()
        let first = UUID()
        let second = UUID()
        history.begin(entry(first))
        history.begin(entry(second, at: 10))
        XCTAssertEqual(history.entries.map(\.id), [second, first])

        let edits = [FileChange(path: "/a", edits: [FileEdit(path: "/a", kind: .edit, added: 3, removed: 1, hunks: [])])]
        history.finish(id: first, with: TaskHistoryOutcome(
            outcome: .finished, endedAt: start.addingTimeInterval(20), summary: "  done  ", costUSD: 0.5, fileChanges: edits
        ))
        var finished = try XCTUnwrap(history.entry(id: first))
        XCTAssertEqual(finished.outcome, .finished)
        XCTAssertEqual(finished.summary, "done")
        XCTAssertEqual(finished.costUSD, 0.5)
        XCTAssertEqual(finished.filesChanged, 1)
        XCTAssertEqual(finished.linesAdded, 3)
        XCTAssertEqual(finished.linesRemoved, 1)

        // 続けると先頭に移り、コストは積み上がる。応答が無ければ前の要約を残す。
        history.beginFollowUp(id: first, prompt: "again")
        XCTAssertEqual(history.entries.map(\.id), [first, second])
        XCTAssertEqual(history.entry(id: first)?.outcome, .running)
        XCTAssertNil(history.entry(id: first)?.endedAt)
        history.finish(id: first, with: TaskHistoryOutcome(
            outcome: .failed, endedAt: start.addingTimeInterval(30), detail: "exit 1", costUSD: 0.25
        ))
        finished = try XCTUnwrap(history.entry(id: first))
        XCTAssertEqual(finished.followUps, ["again"])
        XCTAssertEqual(finished.outcome, .failed)
        XCTAssertEqual(finished.detail, "exit 1")
        XCTAssertEqual(finished.summary, "done")
        XCTAssertEqual(finished.costUSD, 0.75)
        XCTAssertEqual(finished.filesChanged, 1)

        // 記録の無い ID は無視する。
        history.finish(id: UUID(), with: TaskHistoryOutcome(outcome: .finished, endedAt: start))
        history.beginFollowUp(id: UUID(), prompt: "x")
        XCTAssertEqual(history.entries.count, 2)
    }

    func testOldEntriesAndLongTextsAreTrimmed() {
        var history = TaskHistory()
        for index in 0..<(TaskHistory.maxEntries + 5) {
            history.begin(entry(at: TimeInterval(index)))
        }
        XCTAssertEqual(history.entries.count, TaskHistory.maxEntries)
        XCTAssertEqual(history.entries.first?.startedAt, start.addingTimeInterval(TimeInterval(TaskHistory.maxEntries + 4)))

        let long = TaskHistoryEntry(
            id: UUID(), projectID: project, projectName: "app", agent: nil,
            prompt: String(repeating: "あ", count: 5000), startedAt: start
        )
        XCTAssertEqual(long.prompt.count, TaskHistory.maxPromptLength + 1)
        XCTAssertTrue(long.prompt.hasSuffix("…"))
    }

    func testRunningEntriesBecomeInterruptedOnLoad() {
        var history = TaskHistory(entries: [entry(), entry()])
        history.finish(id: history.entries[1].id, with: TaskHistoryOutcome(outcome: .stopped, endedAt: start))
        XCTAssertTrue(history.markRunningAsInterrupted())
        XCTAssertEqual(history.entries.map(\.outcome), [.interrupted, .stopped])
        XCTAssertFalse(history.markRunningAsInterrupted())
    }

    func testUsageCountsPerAgentAndProject() {
        var history = TaskHistory()
        let other = UUID()
        let outcomes: [(String?, UUID, TaskHistoryEntry.Outcome)] = [
            ("reviewer", project, .finished),
            ("reviewer", project, .error),
            ("reviewer", other, .finished),
            ("reviewer", project, .stopped),
            ("writer", project, .finished),
            (nil, project, .finished),
        ]
        for (index, item) in outcomes.enumerated() {
            let id = UUID()
            history.begin(entry(id, agent: item.0, project: item.1, at: TimeInterval(index)))
            history.finish(id: id, with: TaskHistoryOutcome(outcome: item.2, endedAt: start))
        }
        let all = history.usage(agent: "reviewer")
        XCTAssertEqual(all.runs, 4)
        XCTAssertEqual(all.succeeded, 2)
        XCTAssertEqual(all.failed, 1)
        XCTAssertEqual(all.successRate ?? 0, 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(all.lastUsedAt, start.addingTimeInterval(3))

        let inProject = history.usage(agent: "reviewer", projectIDs: [project])
        XCTAssertEqual(inProject.runs, 3)
        XCTAssertEqual(inProject.succeeded, 1)

        XCTAssertEqual(history.usage(agent: "nobody"), AgentUsage())
        XCTAssertNil(AgentUsage().successRate)
    }

    func testFileRoundTripAndErrors() throws {
        let directory = (NSTemporaryDirectory() as NSString).appendingPathComponent("history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = (directory as NSString).appendingPathComponent(TaskHistoryFile.fileName)

        XCTAssertEqual(try TaskHistoryFile.load(from: path), TaskHistory())

        var history = TaskHistory()
        history.begin(entry())
        history.finish(id: history.entries[0].id, with: TaskHistoryOutcome(outcome: .finished, endedAt: start, summary: "ok", costUSD: 0.1))
        try TaskHistoryFile.save(history, to: path)
        XCTAssertEqual(try TaskHistoryFile.load(from: path), history)
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)

        XCTAssertThrowsError(try TaskHistoryFile.decode(Data(#"{"version": 99, "entries": []}"#.utf8))) { error in
            XCTAssertEqual(error as? ProjectRegistryFile.LoadError, .newerVersion(99))
        }
        XCTAssertThrowsError(try TaskHistoryFile.decode(Data("not json".utf8))) { error in
            guard case .invalid = error as? ProjectRegistryFile.LoadError else { return XCTFail("\(error)") }
        }
    }

    func testWorktreeIsKeptAndCanBeForgotten() throws {
        var history = TaskHistory()
        let id = UUID()
        history.begin(TaskHistoryEntry(
            id: id, projectID: project, projectName: "app", agent: nil, prompt: "p", startedAt: start,
            workingDirectory: "/app/.claude/worktrees/notch-1", worktreePath: "/app/.claude/worktrees/notch-1", worktreeBranch: "notch/1"
        ))
        let decoded = try TaskHistoryFile.decode(TaskHistoryFile.encode(history))
        XCTAssertEqual(decoded.entry(id: id)?.worktreeBranch, "notch/1")
        history.worktreeRemoved(id: id)
        XCTAssertNil(history.entry(id: id)?.worktreePath)
        XCTAssertEqual(history.entry(id: id)?.workingDirectory, "/app/.claude/worktrees/notch-1")
        // 前の形式（worktree の項目が無い）も読める。
        let old = #"{"version": 1, "entries": [{"id": "\#(UUID().uuidString)", "projectID": "\#(project.uuidString)", "projectName": "a", "prompt": "p", "followUps": [], "startedAt": "2027-01-15T08:00:00Z", "outcome": "finished", "filesChanged": 0, "linesAdded": 0, "linesRemoved": 0}]}"#
        XCTAssertNil(try TaskHistoryFile.decode(Data(old.utf8)).entries.first?.worktreePath)
    }
}
