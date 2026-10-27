import XCTest
@testable import AgentKit

/// 「エージェント」タブのキャラの色（docs/design/agent-characters.md）。
final class AgentAppearanceTests: XCTestCase {
    func testEveryColorValueHasAPalette() {
        XCTAssertEqual(Set(AgentAppearance.palettes.keys), Set(AgentDefinition.colorValues))
        XCTAssertEqual(AgentAppearance.palette(color: " red "), AgentAppearance.palettes["red"])
    }

    func testWhiteIsOnlyForTheNotch() {
        let all = Array(AgentAppearance.palettes.values) + [AgentAppearance.uncolored, AgentAppearance.unreadable]
        XCTAssertFalse(all.contains(CharacterSpec.notchPalette))
        XCTAssertEqual(Set(all.map(\.body)).count, all.count, "色ごとに体の色が違う")
    }

    func testFallbacks() {
        XCTAssertEqual(AgentAppearance.palette(color: nil), AgentAppearance.uncolored)
        XCTAssertEqual(AgentAppearance.palette(color: "magenta"), AgentAppearance.uncolored)

        let readable = AgentCatalog.Entry(
            path: "/a/.claude/agents/a.md", scope: .user, directory: "/a/.claude/agents",
            result: .success(AgentDefinition(name: "a", description: "d", color: "blue", body: ""))
        )
        XCTAssertEqual(AgentAppearance.palette(for: readable), AgentAppearance.palettes["blue"])
        var unreadable = readable
        unreadable.result = .failure(.missingName)
        XCTAssertEqual(AgentAppearance.palette(for: unreadable), AgentAppearance.unreadable)
    }
}
