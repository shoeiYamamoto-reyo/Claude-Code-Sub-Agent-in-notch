import Foundation
import XCTest
@testable import AgentKit

final class ProjectPathTests: XCTestCase {
    func testNormalize() {
        let home = "/Users/me"
        XCTAssertEqual(ProjectPath.normalize("/Users/me/src/app/", home: home), "/Users/me/src/app")
        XCTAssertEqual(ProjectPath.normalize("  /Users//me/./src/../app  ", home: home), "/Users/me/app")
        XCTAssertEqual(ProjectPath.normalize("~/src", home: home), "/Users/me/src")
        XCTAssertEqual(ProjectPath.normalize("~", home: home), "/Users/me")
        XCTAssertEqual(ProjectPath.normalize("/../..", home: home), "/")
        XCTAssertEqual(ProjectPath.normalize("/", home: home), "/")
        XCTAssertEqual(ProjectPath.normalize("src/../app", home: home), "app")
        XCTAssertEqual(ProjectPath.normalize("~other/x", home: home), "~other/x")
    }

    func testIsInside() {
        XCTAssertTrue(ProjectPath.isInside("/a/b", directory: "/a/b"))
        XCTAssertTrue(ProjectPath.isInside("/a/b/c", directory: "/a/b"))
        XCTAssertFalse(ProjectPath.isInside("/a/bc", directory: "/a/b"))
        XCTAssertFalse(ProjectPath.isInside("/a", directory: "/a/b"))
        XCTAssertTrue(ProjectPath.isInside("/a", directory: "/"))
    }

    func testAbbreviate() {
        XCTAssertEqual(ProjectPath.abbreviate("/Users/me/src", home: "/Users/me"), "~/src")
        XCTAssertEqual(ProjectPath.abbreviate("/Users/me", home: "/Users/me/"), "~")
        XCTAssertEqual(ProjectPath.abbreviate("/Users/meme/src", home: "/Users/me"), "/Users/meme/src")
        XCTAssertEqual(ProjectPath.abbreviate("/tmp", home: "/"), "/tmp")
    }
}

final class ProjectEnvironmentTests: XCTestCase {
    func testNormalizedDropsBlanks() {
        let environment = ProjectEnvironment(
            model: "  ",
            effort: " high ",
            permissionMode: "",
            allowedTools: ["Read", " ", " Bash(git diff *) "],
            variables: [EnvironmentVariable(name: " FOO ", value: " bar ")]
        ).normalized()
        XCTAssertNil(environment.model)
        XCTAssertEqual(environment.effort, "high")
        XCTAssertNil(environment.permissionMode)
        XCTAssertEqual(environment.allowedTools, ["Read", "Bash(git diff *)"])
        XCTAssertEqual(environment.variables.map(\.name), ["FOO"])
        // 値の空白は意味があるかもしれないので残す。
        XCTAssertEqual(environment.variables.first?.value, " bar ")
        XCTAssertFalse(environment.isDefault)
        XCTAssertTrue(ProjectEnvironment(model: " ").normalized().isDefault)
    }

    func testToolListParsing() {
        XCTAssertEqual(
            ProjectEnvironment.parseToolList("Read, Edit,\nBash(git diff *) ,,"),
            ["Read", "Edit", "Bash(git diff *)"]
        )
        XCTAssertEqual(ProjectEnvironment.parseToolList("   "), [])
        XCTAssertEqual(ProjectEnvironment.formatToolList(["Read", "Bash(npm test)"]), "Read, Bash(npm test)")
    }

    func testVariableNames() {
        for name in ["FOO", "_x", "a1_B"] {
            XCTAssertTrue(EnvironmentVariable.isValidName(name), name)
        }
        for name in ["", "1A", "A-B", "A B", "Ä", "A="] {
            XCTAssertFalse(EnvironmentVariable.isValidName(name), name)
        }
    }

    func testSecretValueIsNeverKept() throws {
        let secret = EnvironmentVariable(name: "API_KEY", value: "sk-123", isSecret: true)
        XCTAssertNil(secret.value)

        var toggled = EnvironmentVariable(name: "TOKEN", value: "abc")
        toggled.isSecret = true
        XCTAssertNil(toggled.normalized().value)

        let leaked = Data(#"{"name":"API_KEY","value":"sk-123","isSecret":true}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(EnvironmentVariable.self, from: leaked).value)
    }

    func testKeychainAccount() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        XCTAssertEqual(EnvironmentVariable.keychainAccount(projectID: id, name: "API_KEY"), "00000000-0000-0000-0000-000000000001/API_KEY")
    }
}

final class ProjectRegistryTests: XCTestCase {
    private let home = "/Users/me"
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func project(_ name: String, _ directory: String) -> Project {
        Project(name: name, directory: directory, createdAt: t0)
    }

    func testSuggestedFromFolder() {
        let suggested = Project.suggested(forDirectory: "/Users/me/src/my-app/", now: t0)
        XCTAssertEqual(suggested.name, "my-app")
        XCTAssertEqual(suggested.directory, "/Users/me/src/my-app")
        XCTAssertTrue(suggested.environment.isDefault)
    }

    func testUpsertNormalizesAndEdits() throws {
        var registry = ProjectRegistry()
        let saved = try registry.upsert(project("  App  ", "~/src/app/"), home: home)
        XCTAssertEqual(saved.name, "App")
        XCTAssertEqual(saved.directory, "/Users/me/src/app")
        XCTAssertEqual(registry.projects, [saved])

        var edited = saved
        edited.name = "App 2"
        try registry.upsert(edited, home: home)
        XCTAssertEqual(registry.projects.map(\.name), ["App 2"])
        XCTAssertEqual(registry.project(id: saved.id)?.name, "App 2")
    }

    func testValidation() {
        var registry = ProjectRegistry()
        XCTAssertNoThrow(try registry.upsert(project("A", "/src/a"), home: home))

        var bad = project(" ", "src/b")
        bad.environment.variables = [
            EnvironmentVariable(name: "OK"),
            EnvironmentVariable(name: "OK"),
            EnvironmentVariable(name: "NO-PE"),
        ]
        XCTAssertThrowsError(try registry.upsert(bad, home: home)) { error in
            XCTAssertEqual((error as? ProjectRegistry.ValidationError)?.issues, [
                .emptyName,
                .relativeDirectory,
                .duplicateVariableName("OK"),
                .invalidVariableName("NO-PE"),
            ])
        }

        XCTAssertThrowsError(try registry.upsert(project("B", "/src/a/"), home: home)) { error in
            XCTAssertEqual((error as? ProjectRegistry.ValidationError)?.issues, [.duplicateDirectory(existing: "A")])
        }
        XCTAssertEqual(registry.projects.count, 1)
    }

    func testRemove() throws {
        var registry = ProjectRegistry()
        let a = try registry.upsert(project("A", "/src/a"), home: home)
        let b = try registry.upsert(project("B", "/src/b"), home: home)
        XCTAssertEqual(registry.remove(id: a.id), a)
        XCTAssertNil(registry.remove(id: a.id))
        XCTAssertEqual(registry.projects, [b])
    }

    func testProjectContainingPathPrefersInnermost() throws {
        var registry = ProjectRegistry()
        let outer = try registry.upsert(project("Mono", "/src/mono"), home: home)
        let inner = try registry.upsert(project("Web", "/src/mono/apps/web"), home: home)
        XCTAssertEqual(registry.project(containing: "/src/mono/apps/web/components"), inner)
        XCTAssertEqual(registry.project(containing: "/src/mono/apps/api"), outer)
        XCTAssertEqual(registry.project(containing: "/src/mono/"), outer)
        XCTAssertNil(registry.project(containing: "/src/monorepo"))
        XCTAssertNil(registry.project(containing: "/elsewhere"))
    }
}

final class ProjectRegistryFileTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ProjectRegistryFileTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func sampleRegistry() throws -> ProjectRegistry {
        var registry = ProjectRegistry()
        try registry.upsert(Project(
            name: "App",
            directory: "/Users/me/src/app",
            environment: ProjectEnvironment(
                model: "opus",
                effort: "high",
                permissionMode: "acceptEdits",
                allowedTools: ["Read", "Bash(npm test)"],
                variables: [
                    EnvironmentVariable(name: "NODE_ENV", value: "development"),
                    EnvironmentVariable(name: "API_KEY", value: "sk-secret", isSecret: true),
                ]
            ),
            // ISO 8601 は秒までなので、往復で同じになるように秒ちょうどにする。
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        ))
        try registry.upsert(Project(name: "Docs", directory: "/Users/me/docs", createdAt: Date(timeIntervalSince1970: 1_800_000_100)))
        return registry
    }

    func testMissingFileIsEmpty() throws {
        let path = directory.appendingPathComponent("projects.json").path
        XCTAssertEqual(try ProjectRegistryFile.load(from: path), ProjectRegistry())
    }

    func testSaveAndLoadRoundTrip() throws {
        let path = directory.appendingPathComponent("nested/projects.json").path
        let registry = try sampleRegistry()
        try ProjectRegistryFile.save(registry, to: path)
        XCTAssertEqual(try ProjectRegistryFile.load(from: path), registry)

        let text = String(decoding: FileManager.default.contents(atPath: path) ?? Data(), as: UTF8.self)
        XCTAssertFalse(text.contains("sk-secret"), "秘密の値をファイルに書かない")
        XCTAssertTrue(text.contains(#""version" : 1"#))
        XCTAssertTrue(text.hasSuffix("\n"))

        let mode = (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(mode, 0o600)

        // もう一度保存しても同じ内容（キーの順番が安定している）。
        try ProjectRegistryFile.save(try ProjectRegistryFile.load(from: path), to: path)
        XCTAssertEqual(String(decoding: FileManager.default.contents(atPath: path) ?? Data(), as: UTF8.self), text)
    }

    func testDecodesMinimalAndUnknownFields() throws {
        let json = """
        {
          "version": 1,
          "futureField": true,
          "projects": [
            { "id": "00000000-0000-0000-0000-000000000001", "name": "A", "directory": "/a", "color": "red" }
          ]
        }
        """
        let registry = try ProjectRegistryFile.decode(Data(json.utf8))
        XCTAssertEqual(registry.projects.count, 1)
        XCTAssertEqual(registry.projects[0].name, "A")
        XCTAssertTrue(registry.projects[0].environment.isDefault)
    }

    func testRejectsBrokenFiles() {
        func loadError(_ json: String) -> ProjectRegistryFile.LoadError? {
            do {
                _ = try ProjectRegistryFile.decode(Data(json.utf8))
                return nil
            } catch {
                return error
            }
        }
        XCTAssertEqual(loadError(#"{"version": 2, "projects": []}"#), .newerVersion(2))
        guard case .invalid = loadError("not json") else { return XCTFail() }
        guard case .invalid = loadError(#"{"projects": []}"#) else { return XCTFail() }
        guard case .invalid(let detail) = loadError(#"{"version": 1, "projects": [{"id": "x", "name": "A", "directory": "/a"}]}"#) else {
            return XCTFail()
        }
        XCTAssertTrue(detail.contains("projects"), detail)
    }

    func testDefaultPath() {
        XCTAssertEqual(
            ProjectRegistryFile.path(home: "/Users/me/"),
            "/Users/me/Library/Application Support/NotchAgent/projects.json"
        )
    }
}
