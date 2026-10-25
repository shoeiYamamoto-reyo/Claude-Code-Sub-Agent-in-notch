import AgentKit
import AppKit
import SwiftUI

/// メニューバー常駐（Dock 非表示）のアプリ。ノッチのパネルは `NotchPanelController` が持つ。
@main
struct NotchAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Notch Agent", systemImage: "circle.dotted") {
            MenuContent(model: appDelegate.model, controller: appDelegate.controller)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = NotchModel()
    lazy var controller = NotchPanelController(model: model)

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
    }
}

/// メニューバーのメニュー。M1 の間は表示確認用の項目を置く。
private struct MenuContent: View {
    let model: NotchModel
    let controller: NotchPanelController

    var body: some View {
        Text("Notch Agent（開発中）")
        Text("プロトコル v\(HookBridge.protocolVersion)")
            .foregroundStyle(.secondary)
        Divider()
        Menu("キャラクターの状態（確認用）") {
            ForEach(CharacterMood.allCases, id: \.self) { mood in
                Button(checked(mood.displayName, model.mood == mood)) {
                    controller.setMood(mood)
                }
            }
        }
        Button(checked("お知らせ（peek）を試す", model.noticeText != nil)) {
            controller.setNotice(model.noticeText == nil ? "承認待ちのお知らせの例です（確認用）" : nil)
        }
        SoundMenu(sound: controller.sound)
        Menu("表示する画面") {
            ForEach(DisplayChoice.allCases, id: \.self) { choice in
                Button(checked(choice.displayName, model.displayChoice == choice)) {
                    controller.setDisplayChoice(choice)
                }
            }
        }
        Divider()
        Button("終了") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func checked(_ title: String, _ isOn: Bool) -> String {
        isOn ? "✓ \(title)" : "    \(title)"
    }
}

extension DisplayChoice {
    var displayName: String {
        switch self {
        case .automatic: "自動（ノッチのある画面）"
        case .main: "メインの画面"
        }
    }
}
