import Foundation
import XCTest
@testable import AgentKit

/// ROADMAP 5-5: 指示のテンプレート（F2-6）。
final class PromptTemplateTests: XCTestCase {
    func testUpsertNormalizesAndSortsByName() throws {
        var library = PromptTemplateLibrary()
        let review = try library.upsert(PromptTemplate(name: "  review ", prompt: "Review the diff\n\n", agent: "  "))
        XCTAssertEqual(review.name, "review")
        XCTAssertEqual(review.prompt, "Review the diff")
        XCTAssertNil(review.agent)
        try library.upsert(PromptTemplate(name: "Add tests", prompt: "Add tests", agent: "test-engineer"))
        try library.upsert(PromptTemplate(name: "changelog", prompt: "Write it"))
        XCTAssertEqual(library.templates.map(\.name), ["Add tests", "changelog", "review"])

        // 同じ ID なら置き換え（名前を変えると並びも変わる）。
        var renamed = review
        renamed.name = "a review"
        try library.upsert(renamed)
        XCTAssertEqual(library.templates.map(\.name), ["a review", "Add tests", "changelog"])
        XCTAssertEqual(library.template(id: review.id)?.name, "a review")

        XCTAssertEqual(library.remove(id: review.id)?.name, "a review")
        XCTAssertNil(library.remove(id: review.id))
        XCTAssertEqual(library.templates.count, 2)
    }

    func testValidation() throws {
        var library = PromptTemplateLibrary()
        try library.upsert(PromptTemplate(name: "Review", prompt: "x"))
        XCTAssertThrowsError(try library.upsert(PromptTemplate(name: " ", prompt: " \n"))) { error in
            XCTAssertEqual((error as? PromptTemplateLibrary.ValidationError)?.issues, [.emptyName, .emptyPrompt])
        }
        XCTAssertThrowsError(try library.upsert(PromptTemplate(name: "review", prompt: "y"))) { error in
            XCTAssertEqual((error as? PromptTemplateLibrary.ValidationError)?.issues, [.duplicateName])
        }
        XCTAssertEqual(library.templates.count, 1)
    }

    func testAvailableTemplatesForProject() throws {
        let app = UUID()
        let other = UUID()
        var library = PromptTemplateLibrary()
        try library.upsert(PromptTemplate(name: "any", prompt: "a"))
        try library.upsert(PromptTemplate(name: "app only", prompt: "b", projectID: app))
        try library.upsert(PromptTemplate(name: "other only", prompt: "c", projectID: other))
        XCTAssertEqual(library.available(for: app).map(\.name), ["any", "app only"])
        XCTAssertEqual(library.available(for: nil).count, 3)
    }

    func testFileRoundTrip() throws {
        let directory = (NSTemporaryDirectory() as NSString).appendingPathComponent("templates-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = (directory as NSString).appendingPathComponent(PromptTemplateFile.fileName)
        XCTAssertEqual(try PromptTemplateFile.load(from: path), PromptTemplateLibrary())

        var library = PromptTemplateLibrary()
        try library.upsert(PromptTemplate(name: "review", prompt: "Review\nthe diff", agent: "code-reviewer", projectID: UUID()))
        try PromptTemplateFile.save(library, to: path)
        XCTAssertEqual(try PromptTemplateFile.load(from: path), library)
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)

        XCTAssertThrowsError(try PromptTemplateFile.decode(Data(#"{"version": 2, "templates": []}"#.utf8))) { error in
            XCTAssertEqual(error as? ProjectRegistryFile.LoadError, .newerVersion(2))
        }
    }
}
