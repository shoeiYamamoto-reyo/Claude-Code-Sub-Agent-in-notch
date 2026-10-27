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
                projectCenter: appDelegate.projectCenter,
                taskLauncher: appDelegate.taskLauncher,
                claudeSetup: appDelegate.claudeSetup
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
    lazy var agentLibrary = AgentLibrary(model: model)
    lazy var agentEditor = AgentEditor(model: model)
    lazy var claudeSetup = ClaudeSetup(model: model)
    lazy var taskRunner = TaskRunner(model: model, claude: claudeSetup)
    lazy var taskLauncher = TaskLauncher(model: model, runner: taskRunner)
    lazy var taskResultViewer = TaskResultViewer(model: model)
    let quickInputHotKey = QuickInputHotKey()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
        hookCenter.start()
        hookSetup.refreshStatus()
        projectCenter.load()
        // 定義は「エージェント」タブを開いたときに読む（ここでは受け口だけ用意する）。
        _ = agentLibrary
        _ = agentEditor
        claudeSetup.start()
        _ = taskLauncher
        _ = taskResultViewer
        model.onInstallHooks = { [weak self] in self?.hookSetup.beginInstall() }
        model.onBeginQuickInput = { [weak self] in self?.controller.beginQuickInput() }
        model.onEndQuickInput = { [weak self] in self?.controller.endQuickInput(collapse: true) }
        agentEditor.onBegin = { [weak self] in self?.controller.beginAgentEditing() }
        agentEditor.onEnd = { [weak self] in self?.controller.endAgentEditing() }
        quickInputHotKey.onPress = { [weak self] in
            guard let self else { return }
            // プロジェクトが無ければ、先に登録してもらう。
            if self.model.projects.projects.isEmpty {
                self.projectCenter.beginAdd()
            } else {
                self.controller.beginQuickInput()
            }
        }
        quickInputHotKey.register()
        model.quickInputShortcut = quickInputHotKey.isRegistered ? QuickInputHotKey.displayName : nil
    }

    func applicationWillTerminate(_ notification: Notification) {
        taskRunner.terminateAll()
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
    let taskLauncher: TaskLauncher
    let claudeSetup: ClaudeSetup

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
        Button("タスクを開始…") {
            taskLauncher.open()
        }
        .disabled(model.projects.projects.isEmpty)
        Text(model.claudePath.map { "claude: \($0)" } ?? "claude: 見つかりません")
        Button("claude の場所を指定…") {
            claudeSetup.chooseExecutable()
        }
        if claudeSetup.configuredPath != nil {
            Button("claude の場所を自動検出に戻す") {
                claudeSetup.resetConfiguredPath()
            }
        }
        if model.loginShellProbeFailed {
            Text("ログインシェルの PATH を取得できませんでした")
            Button("ログインシェルを調べ直す") {
                claudeSetup.start()
            }
        }
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
