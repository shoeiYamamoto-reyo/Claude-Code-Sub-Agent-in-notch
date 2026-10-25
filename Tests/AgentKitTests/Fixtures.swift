import Foundation
import XCTest
@testable import AgentKit

/// テスト用のフィクスチャ（`Fixtures/`）を読む。
enum Fixtures {
    static var hooksDirectory: URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures/hooks")
    }

    static func hookFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: hooksDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func hookEvent(_ name: String) throws -> HookEvent {
        try HookEvent(data: Data(contentsOf: hooksDirectory.appendingPathComponent("\(name).json")))
    }
}
