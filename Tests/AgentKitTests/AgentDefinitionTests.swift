import Foundation
import XCTest
@testable import AgentKit

final class FrontmatterTests: XCTestCase {
    func testScalarsListsAndBody() throws {
        let text = """
        ---
        # comment
        name: reviewer
        description: "Reviews diffs: correctness \\"and\\" style"
        tools: Read, Grep, Bash(git diff *)
        skills:
          - swift
          - 'it''s'
        disallowedTools: [Write, "Edit"]
        model: opus # inline comment
        color: 'blue'
        empty:
        ---
        You are a reviewer.

        ---
        Not frontmatter.
        """
        let (frontmatter, body) = try Frontmatter.parse(text)
        XCTAssertEqual(frontmatter.entries.map(\.key), ["name", "description", "tools", "skills", "disallowedTools", "model", "color", "empty"])
        XCTAssertEqual(frontmatter["name"], .string("reviewer"))
        XCTAssertEqual(frontmatter["description"], .string(#"Reviews diffs: correctness "and" style"#))
        XCTAssertEqual(frontmatter["tools"], .string("Read, Grep, Bash(git diff *)"))
        XCTAssertEqual(frontmatter["skills"], .list(["swift", "it's"]))
        XCTAssertEqual(frontmatter["disallowedTools"], .list(["Write", "Edit"]))
        XCTAssertEqual(frontmatter["model"], .string("opus"))
        XCTAssertEqual(frontmatter["color"], .string("blue"))
        XCTAssertEqual(frontmatter["empty"], .string(""))
        XCTAssertEqual(body, "You are a reviewer.\n\n---\nNot frontmatter.")
    }

    func testMultilineStrings() throws {
        let text = """
        ---
        literal: |
          line 1
            indented

          line 3
        folded: >-
          one
          two

          three
        plain: first part
          continues here
        hash: "a # not a comment"
        ---
        """
        let (frontmatter, body) = try Frontmatter.parse(text)
        XCTAssertEqual(frontmatter["literal"], .string("line 1\n  indented\n\nline 3\n"))
        XCTAssertEqual(frontmatter["folded"], .string("one two\nthree"))
        XCTAssertEqual(frontmatter["plain"], .string("first part continues here"))
        XCTAssertEqual(frontmatter["hash"], .string("a # not a comment"))
        XCTAssertEqual(body, "")
    }

    func testNestedMapsAreKeptRaw() throws {
        let text = """
        ---
        name: a
        hooks:
          PreToolUse:
            - matcher: Bash
        mcpServers: { github: {} }
        ---
        """
        let (frontmatter, _) = try Frontmatter.parse(text)
        XCTAssertEqual(frontmatter["hooks"], .raw("  PreToolUse:\n    - matcher: Bash"))
        XCTAssertEqual(frontmatter["mcpServers"], .raw("{ github: {} }"))
        XCTAssertEqual(frontmatter["name"], .string("a"))
    }

    func testBOMAndCRLF() throws {
        let (frontmatter, body) = try Frontmatter.parse("\u{FEFF}---\r\nname: a\r\n---\r\nbody\r\n")
        XCTAssertEqual(frontmatter["name"], .string("a"))
        XCTAssertEqual(body, "body\n")
    }

    func testErrors() {
        func error(_ text: String) -> Frontmatter.ParseError? {
            do {
                _ = try Frontmatter.parse(text)
                return nil
            } catch {
                return error
            }
        }
        XCTAssertEqual(error("name: a\n---\n"), .missingOpeningDelimiter)
        XCTAssertEqual(error("\n---\nname: a\n---\n"), .missingOpeningDelimiter)
        XCTAssertEqual(error("---\nname: a\n"), .missingClosingDelimiter)
        XCTAssertEqual(error("---\nname: a\nthis is not yaml\n---\n"), .invalidLine(3))
        XCTAssertEqual(error("---\n  indented: a\n---\n"), .invalidLine(2))
        XCTAssertEqual(error("---\ntools: [Read, Edit\n---\n"), .invalidLine(2))
    }
}

final class AgentDefinitionTests: XCTestCase {
    func testParsesDefinition() throws {
        let text = """
        ---
        name: test-runner
        description: Runs tests.
        tools:
          - Read
          - Bash
        model: haiku
        effort: low
        permissionMode: acceptEdits
        futureField: 42
        ---
        Run the tests.
        """
        let definition = try AgentDefinition.parse(text).get()
        XCTAssertEqual(definition.name, "test-runner")
        XCTAssertEqual(definition.description, "Runs tests.")
        XCTAssertEqual(definition.tools, ["Read", "Bash"])
        XCTAssertNil(definition.disallowedTools)
        XCTAssertEqual(definition.model, "haiku")
        XCTAssertEqual(definition.effort, "low")
        XCTAssertEqual(definition.permissionMode, "acceptEdits")
        XCTAssertNil(definition.color)
        XCTAssertEqual(definition.body, "Run the tests.")
        XCTAssertEqual(definition.frontmatter["futureField"], .string("42"))
    }

    func testToolStrings() {
        XCTAssertEqual(AgentDefinition.toolList(.string("Read, Grep ,, Edit")), ["Read", "Grep", "Edit"])
        XCTAssertNil(AgentDefinition.toolList(.string(" ")))
        XCTAssertNil(AgentDefinition.toolList(nil))
    }

    func testSkippedDefinitions() {
        func problem(_ text: String) -> AgentDefinition.Problem? {
            if case .failure(let problem) = AgentDefinition.parse(text) { return problem }
            return nil
        }
        XCTAssertEqual(problem("no frontmatter"), .frontmatter(.missingOpeningDelimiter))
        XCTAssertEqual(problem("---\ndescription: d\n---\n"), .missingName)
        XCTAssertEqual(problem("---\nname: \"\"\ndescription: d\n---\n"), .missingName)
        XCTAssertEqual(problem("---\nname: -x\ndescription: d\n---\n"), .invalidName("-x"))
        XCTAssertEqual(problem("---\nname: \"a:b\"\ndescription: d\n---\n"), .invalidName("a:b"))
        XCTAssertEqual(problem("---\nname: [a]\ndescription: d\n---\n"), .missingName)
        XCTAssertEqual(problem("---\nname: a\n---\n"), .missingDescription)
        XCTAssertNil(problem("---\nname: a\ndescription: d\n---\n"))
    }

    /// このリポジトリの `.claude/agents/` を実際に読む（ROADMAP 3-2 の完了条件）。
    func testReadsThisRepositorysAgents() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = repository.appendingPathComponent(".claude/agents")
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".md") }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let text = try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)
            let definition = try AgentDefinition.parse(text).get()
            XCTAssertEqual(definition.name + ".md", file)
            XCTAssertFalse(definition.description.isEmpty, file)
            XCTAssertNotNil(definition.tools, file)
            XCTAssertNotNil(definition.model, file)
            XCTAssertFalse(definition.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, file)
        }
        let architect = try AgentDefinition.parse(String(contentsOf: directory.appendingPathComponent("architect.md"), encoding: .utf8)).get()
        XCTAssertEqual(architect.tools, ["Read", "Grep", "Glob", "WebFetch", "WebSearch", "Write", "Edit"])
        XCTAssertEqual(architect.model, "opus")
    }
}

final class AgentCatalogTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentCatalogTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ relative: String, name: String?, description: String = "d") throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var text = "---\n"
        if let name { text += "name: \(name)\n" }
        text += "description: \(description)\n---\nbody\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func testProjectDirectoriesStopAtHome() {
        XCTAssertEqual(
            AgentCatalog.projectAgentDirectories(for: "/Users/me/src/app/", home: "/Users/me"),
            ["/Users/me/src/app/.claude/agents", "/Users/me/src/.claude/agents"]
        )
        XCTAssertEqual(AgentCatalog.projectAgentDirectories(for: "/Users/me", home: "/Users/me"), [])
        XCTAssertEqual(
            AgentCatalog.projectAgentDirectories(for: "/opt/work", home: "/Users/me"),
            ["/opt/work/.claude/agents", "/opt/.claude/agents", "/.claude/agents"]
        )
        XCTAssertEqual(AgentCatalog.userAgentDirectory(home: "/Users/me/"), "/Users/me/.claude/agents")
    }

    func testLoadsAndResolvesPriority() throws {
        let home = root.appendingPathComponent("home").path
        try write("home/.claude/agents/reviewer.md", name: "reviewer", description: "user reviewer")
        try write("home/.claude/agents/writer.md", name: "writer")
        try write("home/.claude/agents/notes.txt", name: "ignored")
        try write("home/src/.claude/agents/reviewer.md", name: "reviewer", description: "parent reviewer")
        try write("home/src/app/.claude/agents/team/reviewer-v2.md", name: "reviewer", description: "project reviewer")
        try write("home/src/app/.claude/agents/broken.md", name: nil)
        try write("home/src/app/.claude/agents/tester.md", name: "tester")

        let catalog = AgentCatalog.load(projectDirectory: "\(home)/src/app", home: home)
        let projectAgents = "\(home)/src/app/.claude/agents"

        XCTAssertEqual(catalog.entries.map { $0.path.replacingOccurrences(of: home, with: "~") }, [
            "~/src/app/.claude/agents/broken.md",
            "~/src/app/.claude/agents/team/reviewer-v2.md",
            "~/src/app/.claude/agents/tester.md",
            "~/src/.claude/agents/reviewer.md",
            "~/.claude/agents/reviewer.md",
            "~/.claude/agents/writer.md",
        ])
        XCTAssertEqual(catalog.entries[0].problem, .missingName)
        XCTAssertEqual(catalog.entries[3].shadowedBy, "\(projectAgents)/team/reviewer-v2.md")
        XCTAssertEqual(catalog.entries[4].shadowedBy, "\(projectAgents)/team/reviewer-v2.md")
        XCTAssertEqual(catalog.entries(in: .user).count, 2)

        let effective = catalog.effective
        XCTAssertEqual(effective.map(\.name), ["reviewer", "tester", "writer"])
        XCTAssertEqual(effective.first?.description, "project reviewer")
    }

    func testUserOnlyAndMissingFolders() throws {
        let home = root.appendingPathComponent("home").path
        XCTAssertEqual(AgentCatalog.load(projectDirectory: nil, home: home), AgentCatalog())
        try write("home/.claude/agents/a.md", name: "a")
        let catalog = AgentCatalog.load(projectDirectory: nil, home: home)
        XCTAssertEqual(catalog.effective.map(\.name), ["a"])
        XCTAssertEqual(catalog.entries.first?.scope, .user)
    }
}
