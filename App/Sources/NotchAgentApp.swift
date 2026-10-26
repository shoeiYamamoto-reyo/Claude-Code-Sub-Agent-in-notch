import AgentKit
import AppKit
import SwiftUI

/// メニューバー常駐（Dock 非表示）のアプリ。ノッチのパネルは `NotchPanelController` が持つ。
@main
struct NotchAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Notch Agent", systemImage: "circle.dotted") {
            MenuContent(
                model: appDelegate.model,
                controller: appDelegate.controller,
                hookCenter: appDelegate.hookCenter,
                hookSetup: appDelegate.hookSetup,
                projectCenter: appDelegate.projectCenter
            )
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = NotchModel()
    lazy var controller = NotchPanelController(model: model)
    lazy var hookCenter = HookCenter(model: model, controller: controller)
    lazy var hookSetup = HookSetup(model: model)
    lazy var projectCenter = ProjectCenter(model: model)

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
        hookCenter.start()
        hookSetup.refreshStatus()
        projectCenter.load()
        model.onInstallHooks = { [weak self] in self?.hookSetup.beginInstall() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hookCenter.stop()
    }
}

/// メニューバーのメニュー。M1 の間は表示確認用の項目を置く。
private struct MenuContent: View {
    let model: NotchModel
    let controller: NotchPanelController
    let hookCenter: HookCenter
    let hookSetup: HookSetup
    let projectCenter: ProjectCenter

    var body: some View {
        Text("Notch Agent（開発中）")
        Text(receiverText)
            .foregroundStyle(.secondary)
        Divider()
        Text(installText)
        Button(model.hookInstallStatus == .installed ? "hooks を再インストール…" : "hooks をインストール…") {
            hookSetup.beginInstall()
        }
        Button("hooks をアンインストール…") {
            hookSetup.beginUninstall()
        }
        .disabled(model.hookInstallStatus == .notInstalled)
        Divider()
        Button("プロジェクトを追加…") {
            projectCenter.beginAdd()
        }
        if !model.projects.projects.isEmpty {
            Menu("プロジェクトを編集") {
                ForEach(model.projects.projects) { project in
                    Button(project.name) { projectCenter.beginEdit(project.id) }
                }
            }
        }
        Menu("開発用") {
            Button(checked("受信したイベントを記録", model.isCapturingEvents)) {
                hookCenter.isCapturing.toggle()
            }
            Button("記録フォルダを開く") {
                try? FileManager.default.createDirectory(at: hookCenter.captureDirectory, withIntermediateDirectories: true)
                NSWorkspace.shared.open(hookCenter.captureDirectory)
            }
        }
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

    private var receiverText: String {
        switch model.receiver {
        case .listening:
            let count = model.sessions.count
            return count == 0 ? "受信中（セッションなし）" : "受信中（セッション \(count) 件）"
        case .stopped:
            return "受信停止中"
        case .failed(let reason):
            return "受信エラー: \(reason)"
        }
    }

    private var installText: String {
        switch model.hookInstallStatus {
        case .installed: "hooks: インストール済み"
        case .outdated: "hooks: 更新が必要"
        case .notInstalled: "hooks: 未インストール"
        case nil: "hooks: settings.json を読めません"
        }
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
