import Foundation
import XCTest
@testable import AgentKit

final class OrderedJSONTests: XCTestCase {
    func testRoundTripKeepsOrderNumbersAndUnicode() throws {
        let text = """
        {
          "zeta": 1.0,
          "alpha": [1e3, -0.5, true, false, null],
          "emoji": "😀 \\ud83d\\ude00 日本語 \\"quoted\\" \\\\ \\n\\t\\u0001",
          "empty": {},
          "list": []
        }
        """
        let value = try OrderedJSON.parse(Data(text.utf8))
        XCTAssertEqual(value.members?.map(\.key), ["zeta", "alpha", "emoji", "empty", "list"])
        XCTAssertEqual(value["zeta"], .number("1.0"))
        XCTAssertEqual(value["emoji"]?.stringValue, "😀 😀 日本語 \"quoted\" \\ \n\t\u{01}")
        let formatted = value.formatted()
        XCTAssertEqual(try OrderedJSON.parse(Data(formatted.utf8)), value)
        XCTAssertTrue(formatted.contains(#""emoji": "😀 😀 日本語 \"quoted\" \\ \n\t\u0001""#))
    }

    func testFormatsLikeJSONStringify() {
        let value: OrderedJSON = .object([.init("a", .array([.number("1"), .object([.init("b", .null)])])), .init("c", .object([]))])
        XCTAssertEqual(value.formatted(), """
        {
          "a": [
            1,
            {
              "b": null
            }
          ],
          "c": {}
        }
        """)
    }

    func testRejectsBrokenJSON() {
        for text in ["{", "{\"a\" 1}", "[1,]", "{\"a\":1} x", "tru", "\"abc", "01x", "{\"a\":-}"] {
            XCTAssertThrowsError(try OrderedJSON.parse(Data(text.utf8)), text)
        }
    }

    func testSetKeepsPosition() {
        var value: OrderedJSON = .object([.init("a", .null), .init("b", .null)])
        value.set("a", .bool(true))
        value.set("c", .bool(false))
        value.set("b", nil)
        XCTAssertEqual(value, .object([.init("a", .bool(true)), .init("c", .bool(false))]))
    }

    func testDetectIndent() {
        XCTAssertEqual(OrderedJSON.detectIndent(in: "{\n    \"a\": 1\n}"), "    ")
        XCTAssertEqual(OrderedJSON.detectIndent(in: "{\n\t\"a\": 1\n}"), "\t")
        XCTAssertEqual(OrderedJSON.detectIndent(in: "{}"), "  ")
    }
}

final class HookInstallerTests: XCTestCase {
    private let hookPath = "/Users/shoei/Library/Application Support/NotchAgent/bin/notch-hook"

    private func parse(_ text: String) throws -> OrderedJSON { try OrderedJSON.parse(Data(text.utf8)) }

    /// 既存の設定（他のフック・他のキー）が失われないこと。
    func testInstallKeepsExistingSettings() throws {
        let original = try parse("""
        {
          "model": "opus",
          "env": { "API_KEY": "secret" },
          "hooks": {
            "PreToolUse": [
              { "matcher": "Bash", "hooks": [ { "type": "command", "command": "~/bin/guard.sh", "timeout": 10 } ] }
            ],
            "PostCompact": [ { "hooks": [ { "type": "command", "command": "echo compacted" } ] } ]
          },
          "permissions": { "allow": ["Bash(ls:*)"] }
        }
        """)
        let installed = try HookInstaller.install(into: original, hookPath: hookPath)

        XCTAssertEqual(installed.members?.map(\.key), ["model", "env", "hooks", "permissions"])
        XCTAssertEqual(installed["env"], original["env"])
        XCTAssertEqual(installed["permissions"], original["permissions"])
        XCTAssertEqual(installed["hooks"]?["PostCompact"], original["hooks"]?["PostCompact"])
        let preToolUse = try XCTUnwrap(installed["hooks"]?["PreToolUse"]?.arrayValue)
        XCTAssertEqual(preToolUse.count, 2)
        XCTAssertEqual(preToolUse.first, original["hooks"]?["PreToolUse"]?.arrayValue?.first)
        XCTAssertEqual(preToolUse.last?["hooks"]?.arrayValue?.first?["command"]?.stringValue, hookPath)
        XCTAssertEqual(preToolUse.last?["hooks"]?.arrayValue?.first?["args"], .array([]))
        XCTAssertEqual(preToolUse.last?["hooks"]?.arrayValue?.first?["timeout"], .number("5"))
        for event in HookInstaller.sendOnlyEvents {
            XCTAssertNotNil(installed["hooks"]?[event], event)
        }
        XCTAssertEqual(HookInstaller.status(of: original, hookPath: hookPath), .notInstalled)
        XCTAssertEqual(HookInstaller.status(of: installed, hookPath: hookPath), .installed)

        // 2 回入れても重複しない。
        XCTAssertEqual(try HookInstaller.install(into: installed, hookPath: hookPath), installed)
        // 外すと元に戻る。
        XCTAssertEqual(try HookInstaller.uninstall(from: installed), original)
    }

    func testInstallIntoEmptySettingsAndUninstallRemovesHooksKey() throws {
        let installed = try HookInstaller.install(into: .object([]), hookPath: hookPath)
        XCTAssertEqual(installed["hooks"]?.members?.count, HookInstaller.sendOnlyEvents.count)
        XCTAssertEqual(try HookInstaller.uninstall(from: installed), .object([]))
    }

    func testReplacesOutdatedEntriesAndKeepsOthersInSameGroup() throws {
        let original = try parse("""
        { "hooks": {
          "Stop": [ { "hooks": [
            { "type": "command", "command": "/old/place/notch-hook", "timeout": 10 },
            { "type": "command", "command": "say done" }
          ] } ],
          "SessionEnd": [ { "hooks": [ { "type": "command", "command": "\\"/old place/notch-hook\\" --x" } ] } ]
        } }
        """)
        XCTAssertEqual(HookInstaller.status(of: original, hookPath: hookPath), .outdated)
        let installed = try HookInstaller.install(into: original, hookPath: hookPath)
        let stop = try XCTUnwrap(installed["hooks"]?["Stop"]?.arrayValue)
        XCTAssertEqual(stop.first?["hooks"]?.arrayValue?.map { $0["command"]?.stringValue }, ["say done"])
        XCTAssertEqual(stop.last?["hooks"]?.arrayValue?.first?["command"]?.stringValue, hookPath)
        XCTAssertEqual(installed["hooks"]?["SessionEnd"]?.arrayValue?.count, 1)
        XCTAssertEqual(HookInstaller.status(of: installed, hookPath: hookPath), .installed)
        XCTAssertEqual(HookInstaller.status(of: installed, hookPath: "/elsewhere/notch-hook"), .outdated)
    }

    func testOtherHooksAfterOursStillCountAsInstalled() throws {
        var installed = try HookInstaller.install(into: .object([]), hookPath: hookPath)
        var hooks = try XCTUnwrap(installed["hooks"])
        var stop = try XCTUnwrap(hooks["Stop"]?.arrayValue)
        stop.append(.object([.init("hooks", .array([.object([.init("type", .string("command")), .init("command", .string("say hi"))])]))]))
        hooks.set("Stop", .array(stop))
        installed.set("hooks", hooks)
        XCTAssertEqual(HookInstaller.status(of: installed, hookPath: hookPath), .installed)
    }

    func testRefusesUnexpectedShapes() throws {
        XCTAssertThrowsError(try HookInstaller.install(into: .array([]), hookPath: hookPath)) {
            XCTAssertEqual($0 as? HookInstaller.PlanError, .settingsNotAnObject)
        }
        XCTAssertThrowsError(try HookInstaller.install(into: try parse(#"{"hooks": []}"#), hookPath: hookPath)) {
            XCTAssertEqual($0 as? HookInstaller.PlanError, .hooksNotAnObject)
        }
        XCTAssertThrowsError(try HookInstaller.install(into: try parse(#"{"hooks": {"Stop": {}}}"#), hookPath: hookPath)) {
            XCTAssertEqual($0 as? HookInstaller.PlanError, .eventNotAnArray("Stop"))
        }
    }

    func testRecognizesOurHandlers() throws {
        let ours = [#"{"command": "/a/b/notch-hook"}"#, #"{"command": "notch-hook --wait"}"#, #"{"command": "'/a b/notch-hook'"}"#]
        let others = [#"{"command": "/a/notch-hook-extra"}"#, #"{"command": "echo notch-hook"}"#, #"{"type": "http"}"#]
        for text in ours { XCTAssertTrue(HookInstaller.isOurHandler(try parse(text)), text) }
        for text in others { XCTAssertFalse(HookInstaller.isOurHandler(try parse(text)), text) }
    }

    func testPaths() {
        XCTAssertEqual(HookBridge.hookExecutablePath(home: "/Users/shoei"), hookPath)
        XCTAssertEqual(HookBridge.userSettingsPath(home: "/Users/shoei", environment: [:]), "/Users/shoei/.claude/settings.json")
        XCTAssertEqual(HookBridge.userSettingsPath(home: "/Users/shoei", environment: ["CLAUDE_CONFIG_DIR": "/cfg"]), "/cfg/settings.json")
    }
}

final class SafeFileWriterTests: XCTestCase {
    private var directory = ""
    private let hookPath = "/opt/notch-hook"

    override func setUpWithError() throws {
        directory = (NSTemporaryDirectory() as NSString).appendingPathComponent("safe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: directory)
    }

    private func path(_ name: String) -> String { (directory as NSString).appendingPathComponent(name) }

    private func install(_ json: OrderedJSON) throws -> OrderedJSON {
        try HookInstaller.install(into: json, hookPath: hookPath)
    }

    private func permissions(_ path: String) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber).intValue
    }

    func testCreatesMissingFileWith0600() throws {
        let settings = path("new/settings.json")
        let edit = try SafeFileWriter.prepare(path: settings, transform: install)
        XCTAssertNil(edit.originalData)
        XCTAssertTrue(edit.hasChanges)
        XCTAssertNil(try SafeFileWriter.commit(edit))
        XCTAssertEqual(FileManager.default.contents(atPath: settings), edit.newData)
        XCTAssertEqual(try permissions(settings), 0o600)
        XCTAssertTrue(edit.newText.hasSuffix("}\n"))
    }

    func testBacksUpAndKeepsPermissionsAndUntouchedText() throws {
        let settings = path("settings.json")
        let original = "{\n    \"model\": \"opus\",\n    \"cleanupPeriodDays\": 30.0\n}"
        _ = FileManager.default.createFile(atPath: settings, contents: Data(original.utf8), attributes: [.posixPermissions: 0o640])

        let edit = try SafeFileWriter.prepare(path: settings, transform: install)
        // 触っていない行は差分に出ない。
        let removed = edit.diff.filter { $0.kind == .removed }.map(\.text)
        XCTAssertEqual(removed, ["    \"cleanupPeriodDays\": 30.0"])
        XCTAssertTrue(edit.newText.contains("    \"cleanupPeriodDays\": 30.0,\n    \"hooks\": {"))
        XCTAssertFalse(edit.newText.hasSuffix("\n"))

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let backup = try XCTUnwrap(try SafeFileWriter.commit(edit, now: now))
        XCTAssertEqual(FileManager.default.contents(atPath: backup), Data(original.utf8))
        XCTAssertEqual(try permissions(settings), 0o640)
        XCTAssertEqual(try permissions(backup), 0o640)

        // 同じ時刻にもう一度書いても、バックアップは上書きしない。
        let removal = try SafeFileWriter.prepare(path: settings) { try HookInstaller.uninstall(from: $0) }
        let second = try XCTUnwrap(try SafeFileWriter.commit(removal, now: now))
        XCTAssertNotEqual(second, backup)
        XCTAssertTrue(second.hasSuffix("-2"))
        XCTAssertEqual(FileManager.default.contents(atPath: settings), Data(original.utf8))
    }

    func testRefusesWhenFileChangedAfterPreview() throws {
        let settings = path("settings.json")
        _ = FileManager.default.createFile(atPath: settings, contents: Data("{}".utf8))
        let edit = try SafeFileWriter.prepare(path: settings, transform: install)
        try Data(#"{"model":"sonnet"}"#.utf8).write(to: URL(fileURLWithPath: settings))
        XCTAssertThrowsError(try SafeFileWriter.commit(edit)) {
            XCTAssertEqual($0 as? SafeFileWriter.WriteError, .changedOnDisk)
        }
        XCTAssertEqual(FileManager.default.contents(atPath: settings), Data(#"{"model":"sonnet"}"#.utf8))
    }

    func testDoesNothingWithBrokenJSON() throws {
        let settings = path("settings.json")
        _ = FileManager.default.createFile(atPath: settings, contents: Data("{ \"model\": ".utf8))
        XCTAssertThrowsError(try SafeFileWriter.prepare(path: settings, transform: install)) { error in
            guard case .invalidJSON = error as? SafeFileWriter.WriteError else { return XCTFail("\(error)") }
        }
    }

    func testWritesThroughSymlink() throws {
        let real = path("dotfiles-settings.json")
        let link = path("settings.json")
        _ = FileManager.default.createFile(atPath: real, contents: Data("{}\n".utf8))
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)

        let edit = try SafeFileWriter.prepare(path: link, transform: install)
        XCTAssertEqual(edit.displayPath, link)
        try SafeFileWriter.commit(edit)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link), real)
        XCTAssertEqual(FileManager.default.contents(atPath: real), edit.newData)
    }

    func testNoChangeMeansNoWrite() throws {
        let settings = path("settings.json")
        _ = FileManager.default.createFile(atPath: settings, contents: Data("{ \"a\": 1 }".utf8))
        let edit = try SafeFileWriter.prepare(path: settings) { try HookInstaller.uninstall(from: $0) }
        XCTAssertFalse(edit.hasChanges)
        XCTAssertNil(try SafeFileWriter.commit(edit))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory), ["settings.json"])
    }
}

final class LineDiffTests: XCTestCase {
    func testCompareAndHunks() {
        let old = (1...10).map { "line \($0)" }.joined(separator: "\n")
        var newLines = (1...10).map { "line \($0)" }
        newLines[4] = "changed"
        newLines.append("added")
        let diff = LineDiff.compare(old, newLines.joined(separator: "\n"))
        XCTAssertEqual(diff.filter { $0.kind == .removed }.map(\.text), ["line 5"])
        XCTAssertEqual(diff.filter { $0.kind == .added }.map(\.text), ["changed", "added"])

        let hunks = LineDiff.hunks(diff, context: 1)
        XCTAssertEqual(hunks.first!, nil)
        XCTAssertEqual(hunks.compactMap { $0?.text }, ["line 4", "line 5", "changed", "line 6", "line 10", "added"])
        XCTAssertTrue(LineDiff.hunks(LineDiff.compare("a", "a")).isEmpty)
    }
}
