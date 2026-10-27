import Foundation
import XCTest
@testable import AgentKit

/// ROADMAP 4-2: 定義の保存は計画（差分）を作るだけで、確認して `commit` するまで書かない。
final class AgentFileStoreTests: XCTestCase {
    private var directory: String!

    override func setUpWithError() throws {
        directory = (NSTemporaryDirectory() as NSString).appendingPathComponent("agents-\(UUID().uuidString)/.claude/agents")
    }

    override func tearDownWithError() throws {
        let root = ((directory as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        try? FileManager.default.removeItem(atPath: root)
    }

    private func path(_ name: String) -> String {
        (directory as NSString).appendingPathComponent(name)
    }

    private func write(_ text: String, to name: String) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: path(name)))
    }

    private func catalog() -> [AgentCatalog.Entry] {
        let home = ((directory as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        return AgentCatalog.load(projectDirectory: nil, home: home).entries
    }

    func testNewDefinitionIsWrittenOnlyOnCommit() throws {
        var agent = AgentFileStore.template(name: "doc-writer")
        agent.description = "Writes docs"
        let plan = AgentFileStore.plan(agent, existingPath: nil, originalData: nil, directory: directory, entries: [])
        XCTAssertTrue(plan.isNew)
        XCTAssertEqual(plan.path, path("doc-writer.md"))
        XCTAssertEqual(plan.errors, [])
        let edit = try XCTUnwrap(plan.edit)
        XCTAssertNil(edit.originalData)
        XCTAssertTrue(edit.diff.allSatisfy { $0.kind == .added })
        // 計画だけではフォルダもファイルも作らない。
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory))

        XCTAssertNil(try SafeFileWriter.commit(edit))
        let written = try String(contentsOfFile: plan.path, encoding: .utf8)
        XCTAssertEqual(written, agent.render())
        let mode = try FileManager.default.attributesOfItem(atPath: plan.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o644)
        XCTAssertEqual(catalog().compactMap(\.definition?.name), ["doc-writer"])
    }

    func testEditingKeepsUnknownFieldsAndBacksUp() throws {
        let original = "---\nname: a\ndescription: d\nhooks:\n  Stop: []\n---\nbody\n"
        try write(original, to: "a.md")
        let entry = try XCTUnwrap(catalog().first)
        var agent = try XCTUnwrap(entry.definition)
        agent.model = "haiku"

        let plan = AgentFileStore.plan(
            agent, existingPath: entry.path, originalData: Data(original.utf8), directory: directory, entries: catalog()
        )
        let edit = try XCTUnwrap(plan.edit)
        XCTAssertFalse(plan.isNew)
        XCTAssertEqual(edit.diff.filter { $0.kind != .same }.map(\.text), ["model: haiku"])

        let backup = try XCTUnwrap(try SafeFileWriter.commit(edit, now: Date(timeIntervalSince1970: 0)))
        XCTAssertEqual(try String(contentsOfFile: backup, encoding: .utf8), original)
        XCTAssertEqual(
            try String(contentsOfFile: entry.path, encoding: .utf8),
            "---\nname: a\ndescription: d\nhooks:\n  Stop: []\nmodel: haiku\n---\nbody\n"
        )
        // バックアップは .md ではないので、定義として読まれない。
        XCTAssertEqual(catalog().count, 1)
    }

    func testFileChangedWhileEditingIsNotOverwritten() throws {
        let original = "---\nname: a\ndescription: d\n---\nbody\n"
        try write(original, to: "a.md")
        var agent = try XCTUnwrap(catalog().first?.definition)
        agent.body = "mine\n"
        let plan = AgentFileStore.plan(
            agent, existingPath: path("a.md"), originalData: Data(original.utf8), directory: directory, entries: catalog()
        )
        try write("---\nname: a\ndescription: theirs\n---\n", to: "a.md")
        XCTAssertThrowsError(try SafeFileWriter.commit(XCTUnwrap(plan.edit))) { error in
            XCTAssertEqual(error as? SafeFileWriter.WriteError, .changedOnDisk)
        }
        XCTAssertEqual(try String(contentsOfFile: path("a.md"), encoding: .utf8), "---\nname: a\ndescription: theirs\n---\n")
    }

    func testErrorsPreventSaving() throws {
        try write("---\nname: taken\ndescription: d\n---\n", to: "other.md")
        try write("---\nname: x\ndescription: d\n---\n", to: "doc.md")

        // 同じフォルダに同じ name。
        var duplicate = AgentFileStore.template(name: "taken")
        duplicate.description = "d"
        var plan = AgentFileStore.plan(duplicate, existingPath: nil, originalData: nil, directory: directory, entries: catalog())
        XCTAssertNil(plan.edit)
        XCTAssertEqual(plan.errors.map(\.field), ["name"])

        // name は空いていても、ファイル名がぶつかる。
        var clash = AgentFileStore.template(name: "doc")
        clash.description = "d"
        plan = AgentFileStore.plan(clash, existingPath: nil, originalData: nil, directory: directory, entries: catalog())
        XCTAssertNil(plan.edit)
        XCTAssertEqual(plan.errors.map(\.field), ["name"])

        // 自分自身の name は重なりに数えない。
        let own = try XCTUnwrap(catalog().first { $0.path == path("other.md") })
        var renamed = try XCTUnwrap(own.definition)
        renamed.description = "changed"
        plan = AgentFileStore.plan(renamed, existingPath: own.path, originalData: Data(), directory: directory, entries: catalog())
        XCTAssertEqual(plan.errors, [])
        XCTAssertNotNil(plan.edit)

        // 警告だけなら保存できる。
        var warned = AgentFileStore.template(name: "new")
        warned.description = "d"
        warned.color = "magenta"
        plan = AgentFileStore.plan(warned, existingPath: nil, originalData: nil, directory: directory, entries: catalog())
        XCTAssertEqual(plan.warnings.map(\.field), ["color"])
        XCTAssertNotNil(plan.edit)
    }

    func testCRLFFilesStayCRLF() throws {
        let original = "---\r\nname: a\r\ndescription: d\r\n---\r\nbody\r\n"
        var agent = try AgentDefinition.parse(original).get()
        agent.model = "opus"
        let plan = AgentFileStore.plan(
            agent, existingPath: path("a.md"), originalData: Data(original.utf8), directory: directory, entries: []
        )
        let edit = try XCTUnwrap(plan.edit)
        XCTAssertEqual(edit.newText, "---\r\nname: a\r\ndescription: d\r\nmodel: opus\r\n---\r\nbody\r\n")
        XCTAssertEqual(edit.diff.filter { $0.kind != .same }.count, 1)
    }

    func testWatchedDirectoriesAreOnlyExistingAgentFolders() {
        let existing: Set<String> = ["/Users/me/.claude/agents", "/Users/me/work/.claude/agents", "/Users/me/work/app/.claude/agents"]
        let watched = AgentFileStore.watchedDirectories(
            projectDirectories: ["/Users/me/work/app", "/Users/me/work/app", "/Users/me/other"],
            home: "/Users/me",
            isDirectory: existing.contains
        )
        XCTAssertEqual(watched, existing.sorted())
    }
}
