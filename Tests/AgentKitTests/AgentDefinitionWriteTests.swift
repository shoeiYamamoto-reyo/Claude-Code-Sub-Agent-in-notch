import Foundation
import XCTest
@testable import AgentKit

/// ROADMAP 4-1: 定義の書き出し（frontmatter の往復）と検証。
final class AgentDefinitionWriteTests: XCTestCase {
    private let rich = """
    ---
    # レビュー担当
    name: reviewer
    description: |
      Reviews diffs.
      Use before commits.
    tools: Read, Grep, Bash(git diff *)
    skills:
      - swift
      - 'it''s'
    hooks:
      PreToolUse:
        - matcher: Bash

    mcpServers: { github: {} }
    model: opus # inline comment
    memory: project
    ---
    You are a reviewer.

    ---
    Not frontmatter.
    """

    private func definition(_ text: String) throws -> AgentDefinition {
        try AgentDefinition.parse(text).get()
    }

    // MARK: - 往復

    func testUnchangedDefinitionRendersIdentically() throws {
        XCTAssertEqual(try definition(rich).render(), rich)
        let minimal = "---\nname: a\ndescription: d\n---\nbody\n"
        XCTAssertEqual(try definition(minimal).render(), minimal)
    }

    /// このリポジトリの `.claude/agents/` も、読んで書くと同じテキストに戻る。
    func testThisRepositorysAgentsRoundTrip() throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".claude/agents")
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".md") }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let text = try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)
                .replacingOccurrences(of: "\r\n", with: "\n")
            XCTAssertEqual(try definition(text).render(), text, file)
        }
    }

    func testEditingRewritesOnlyChangedFields() throws {
        var agent = try definition(rich)
        agent.model = "sonnet"
        agent.tools = ["Read", "Grep"]
        agent.color = "blue"
        agent.body = "Be strict.\n"
        XCTAssertEqual(agent.render(), """
        ---
        # レビュー担当
        name: reviewer
        description: |
          Reviews diffs.
          Use before commits.
        tools: Read, Grep
        skills:
          - swift
          - 'it''s'
        hooks:
          PreToolUse:
            - matcher: Bash

        mcpServers: { github: {} }
        model: sonnet
        memory: project
        color: blue
        ---
        Be strict.

        """)
        // 読み戻すと同じ定義。
        let reread = try definition(agent.render())
        XCTAssertEqual(reread.model, "sonnet")
        XCTAssertEqual(reread.tools, ["Read", "Grep"])
        XCTAssertEqual(reread.color, "blue")
        XCTAssertEqual(reread.frontmatter["hooks"], .raw("  PreToolUse:\n    - matcher: Bash"))
        XCTAssertEqual(reread.frontmatter["memory"], .string("project"))
    }

    func testRemovingFieldsAndKeepingListStyle() throws {
        var agent = try definition("""
        ---
        name: a
        description: d
        tools:
          - Read
          - Grep
        model: opus
        ---
        body
        """)
        agent.model = nil
        agent.tools = ["Read", "Bash(git log, git diff)"]
        agent.description = "Runs\nchecks"
        XCTAssertEqual(agent.render(), """
        ---
        name: a
        description: |-
          Runs
          checks
        tools:
          - Read
          - Bash(git log, git diff)
        ---
        body
        """)
        let reread = try definition(agent.render())
        XCTAssertEqual(reread.description, "Runs\nchecks")
        XCTAssertEqual(reread.tools, ["Read", "Bash(git log, git diff)"])
        XCTAssertNil(reread.model)
    }

    func testNewDefinition() throws {
        let agent = AgentDefinition(
            name: "doc-writer",
            description: "Writes docs: README and guides",
            tools: ["Read", "Write"],
            model: "haiku",
            body: "You write clear docs.\n"
        )
        XCTAssertEqual(agent.render(), """
        ---
        name: doc-writer
        description: "Writes docs: README and guides"
        tools: Read, Write
        model: haiku
        ---
        You write clear docs.

        """)
        XCTAssertEqual(try definition(agent.render()).description, "Writes docs: README and guides")
        XCTAssertEqual(agent.suggestedFileName, "doc-writer.md")
        XCTAssertEqual(AgentDefinition(name: " a/b c ", description: "d", body: "").suggestedFileName, "a-b-c.md")
        XCTAssertEqual(AgentDefinition(name: "", description: "d", body: "").suggestedFileName, "agent.md")
    }

    /// そのままでは別の意味に読まれる値はクォートし、読み戻して同じ値になる。
    func testScalarsThatNeedQuotingRoundTrip() throws {
        let values = [
            "true", "No", "null", "~", "42", "3.5", "", " leading", "trailing ",
            "a: b", "ends with:", "a #b", "#tag", "- item", "[x]", "{x}", "*ref", "!tag", "|", ">", "@at", "%p", "`code`",
            #"He said "hi""#, #"it's "both""#, "tab\there", "back\\slash", "日本語: 説明",
            "line 1\n\nline 3\n", "two trailing\n\n", "  indented\n  block", "trailing space \nnext",
            #"it's "both" #tag"#, #"say "a" #b"#, "a'' #b", #"x 'y' "z" #w"#,
        ]
        for value in values {
            var frontmatter = Frontmatter()
            frontmatter.set("description", .string(value))
            frontmatter.set("tools", .list([value, "Read"]))
            let text = "---\n" + frontmatter.render() + "---\n"
            let (parsed, _) = try Frontmatter.parse(text)
            XCTAssertEqual(parsed["description"], .string(value), "\(value.debugDescription) → \(text)")
            if !value.contains("\n") {
                XCTAssertEqual(parsed["tools"], .list([value, "Read"]), "\(value.debugDescription) → \(text)")
            }
        }
    }

    func testQuotesKeepCommentMarkers() throws {
        let (frontmatter, _) = try Frontmatter.parse(#"""
        ---
        single: 'it''s #fine' # comment
        double: "say \"hi\" #fine" # comment
        ---
        """#)
        XCTAssertEqual(frontmatter["single"], .string("it's #fine"))
        XCTAssertEqual(frontmatter["double"], .string(#"say "hi" #fine"#))
    }

    func testDelimitersAreKept() throws {
        let dots = "---\nname: a\ndescription: d\n...\nbody\n"
        XCTAssertEqual(try definition(dots).render(), dots)
        let noNewline = "---\nname: a\ndescription: d\n---"
        XCTAssertEqual(try definition(noNewline).render(), noNewline)
        var edited = try definition(noNewline)
        edited.body = "body"
        XCTAssertEqual(edited.render(), "---\nname: a\ndescription: d\n---\nbody")
    }

    /// `tools: []`（ツールなし）と項目なし（親のツールを引き継ぐ）は別のもの。
    func testEmptyToolListIsKept() throws {
        let none = "---\nname: a\ndescription: d\ntools: []\n---\n"
        let agent = try definition(none)
        XCTAssertEqual(agent.tools, [])
        XCTAssertEqual(agent.render(), none)

        var cleared = try definition("---\nname: a\ndescription: d\ntools: Read\n---\n")
        cleared.tools = []
        XCTAssertEqual(cleared.render(), none)
        cleared.tools = nil
        XCTAssertEqual(cleared.render(), "---\nname: a\ndescription: d\n---\n")
    }

    func testFrontmatterSetIsNoOpForSameValue() throws {
        var (frontmatter, _) = try Frontmatter.parse("---\nmodel: opus # keep this\n---\n")
        frontmatter.set("model", .string("opus"))
        XCTAssertEqual(frontmatter.render(), "model: opus # keep this\n")
        frontmatter.set("model", nil)
        XCTAssertEqual(frontmatter.render(), "")
        frontmatter.set("model", .string("haiku"))
        XCTAssertEqual(frontmatter.render(), "model: haiku\n")
    }

    // MARK: - 検証

    func testValidation() throws {
        let valid = AgentDefinition(name: "a", description: "d", model: "claude-opus-5-5", body: "x")
        XCTAssertEqual(valid.validate(), [])

        let broken = AgentDefinition(name: "-bad", description: " ", body: "")
        XCTAssertEqual(broken.validate().filter { $0.severity == .error }.map(\.field), ["name", "description"])
        XCTAssertEqual(broken.validate().filter { $0.severity == .warning }.map(\.field), ["body"])

        XCTAssertEqual(AgentDefinition(name: "", description: "d", body: "x").validate().map(\.field), ["name"])
        XCTAssertEqual(
            AgentDefinition(name: "a", description: "d", body: "x").validate(namesInSameDirectory: ["a"]).map(\.severity),
            [.error]
        )

        let odd = AgentDefinition(
            name: "a",
            description: "d",
            tools: ["Read", "Write"],
            disallowedTools: ["Write"],
            model: "gpt",
            effort: "huge",
            permissionMode: "yolo",
            color: "magenta",
            body: "x"
        )
        let warnings = odd.validate()
        XCTAssertTrue(warnings.allSatisfy { $0.severity == .warning })
        XCTAssertEqual(warnings.map(\.field), ["model", "effort", "permissionMode", "color", "disallowedTools"])
    }
}
