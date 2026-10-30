import Foundation
import XCTest
@testable import AgentKit

/// ROADMAP 5-8: サブエージェントのキャラの見た目（F5-8）。
final class AgentLookTests: XCTestCase {
    func testStandardGeometryMatchesTheSpec() {
        let geometry = CharacterGeometry.standard
        XCTAssertEqual(geometry.bodySegments, CharacterSpec.bodySegments)
        XCTAssertEqual(geometry.leftEye, CharacterSpec.leftEye)
        XCTAssertEqual(geometry.rightEye, CharacterSpec.rightEye)
        XCTAssertEqual(geometry.shadowRadii, CharacterSpec.shadowRadii)
        XCTAssertEqual(geometry.top, CGPoint(x: 70, y: 22))
    }

    func testShapesScaleFromTheBottomAndStayInsideTheViewBox() {
        let tall = CharacterGeometry(shape: .tall)
        // 底は動かず、てっぺんは上がる。
        XCTAssertEqual(tall.bodySegments[3], .line(to: CGPoint(x: 70 + (32 - 70) * 0.86, y: 88)))
        XCTAssertLessThan(tall.top.y, 22)
        XCTAssertLessThan(tall.leftEye.y, CharacterSpec.leftEye.y)
        // 目の間は細くなる。
        XCTAssertLessThan(tall.rightEye.x - tall.leftEye.x, CharacterSpec.rightEye.x - CharacterSpec.leftEye.x)

        for shape in AgentLook.Shape.allCases {
            let geometry = CharacterGeometry(shape: shape)
            for segment in geometry.bodySegments {
                let points: [CGPoint] = switch segment {
                case .move(let point), .line(let point): [point]
                case .curve(let point, let control1, let control2): [point, control1, control2]
                }
                for point in points {
                    XCTAssertTrue((0...CharacterSpec.viewBoxWidth).contains(point.x), "\(shape) \(point)")
                    // 小物を載せる余白を残す。
                    XCTAssertTrue((8...CharacterSpec.viewBoxHeight).contains(point.y), "\(shape) \(point)")
                }
            }
        }
    }

    func testLibraryForgetsStandardLooks() {
        var library = AgentLookLibrary()
        let path = "/u/.claude/agents/reviewer.md"
        XCTAssertEqual(library.look(for: path), .standard)
        let look = AgentLook(eyes: .sleepy, shape: .wide, accessory: .hat)
        library.set(look, for: path)
        XCTAssertEqual(library.look(for: path), look)
        library.set(.standard, for: path)
        XCTAssertTrue(library.looks.isEmpty)
        XCTAssertTrue(AgentLookLibrary(looks: [path: .standard]).looks.isEmpty)
    }

    func testFileRoundTripAndErrors() throws {
        let directory = (NSTemporaryDirectory() as NSString).appendingPathComponent("looks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = (directory as NSString).appendingPathComponent(AgentLookFile.fileName)

        XCTAssertEqual(try AgentLookFile.load(from: path), AgentLookLibrary())

        var library = AgentLookLibrary()
        library.set(AgentLook(eyes: .big, accessory: .sprout), for: "/p/.claude/agents/a.md")
        try AgentLookFile.save(library, to: path)
        XCTAssertEqual(try AgentLookFile.load(from: path), library)
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)

        XCTAssertThrowsError(try AgentLookFile.decode(Data(#"{"version": 2, "looks": {}}"#.utf8))) { error in
            XCTAssertEqual(error as? ProjectRegistryFile.LoadError, .newerVersion(2))
        }
        XCTAssertThrowsError(try AgentLookFile.decode(Data("[]".utf8))) { error in
            guard case .invalid = error as? ProjectRegistryFile.LoadError else { return XCTFail("\(error)") }
        }
    }

    func testUnknownValuesFallBackToDefaults() throws {
        let json = #"{"version": 1, "looks": {"/a.md": {"eyes": "laser", "shape": "tall"}}}"#
        let library = try AgentLookFile.decode(Data(json.utf8))
        XCTAssertEqual(library.look(for: "/a.md"), AgentLook(eyes: .round, shape: .tall, accessory: .none))
    }
}
