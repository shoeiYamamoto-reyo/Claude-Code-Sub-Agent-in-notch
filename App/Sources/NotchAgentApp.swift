import AgentKit
import AppKit
import SwiftUI

/// メニューバー常駐（Dock 非表示）のアプリ。M0 時点では空の骨組み。
/// ノッチのパネルは ROADMAP 1-1、キャラクターは 1-2 で追加する。
@main
struct NotchAgentApp: App {
    var body: some Scene {
        MenuBarExtra("Notch Agent", systemImage: "circle.dotted") {
            Text("Notch Agent（開発中）")
            Text("プロトコル v\(HookBridge.protocolVersion)")
                .foregroundStyle(.secondary)
            Divider()
            Button("終了") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
