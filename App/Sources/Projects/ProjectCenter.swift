import AgentKit
import AppKit
import SwiftUI

/// プロジェクトの登録・編集・削除（ROADMAP 3-1、F1-1 / F1-2 / F1-4）。
///
/// - 一覧は `~/Library/Application Support/NotchAgent/projects.json`（`ProjectRegistryFile`）。
///   読めなかったときは上書きしないよう、保存を止めてノッチにその旨を出す。
/// - 秘密の環境変数の値は Keychain（`ProjectSecrets`）に置き、JSON には書かない。
/// - ノッチのパネルはキー入力を受けないので、編集は普通のウインドウで行う。
@MainActor
final class ProjectCenter {
    let model: NotchModel
    private var registry = ProjectRegistry()
    private var window: NSWindow?

    init(model: NotchModel) {
        self.model = model
        model.onAddProject = { [weak self] in self?.beginAdd() }
        model.onEditProject = { [weak self] id in self?.beginEdit(id) }
        model.onRegisterFolder = { [weak self] path in self?.beginAdd(directory: path) }
    }

    var filePath: String { ProjectRegistryFile.path(home: NSHomeDirectory()) }

    func load() {
        do {
            registry = try ProjectRegistryFile.load(from: filePath)
            model.projectLoadError = nil
        } catch {
            registry = ProjectRegistry()
            model.projectLoadError = error.message
        }
        model.projects = registry
    }

    /// フォルダを選んでから登録画面を開く。
    func beginAdd() {
        guard checkWritable() else { return }
        guard let directory = chooseFolder(startingAt: nil) else { return }
        beginAdd(directory: directory)
    }

    /// 決まったフォルダで登録画面を開く。既に登録済みならそのプロジェクトの編集画面にする。
    func beginAdd(directory: String) {
        guard checkWritable() else { return }
        let normalized = ProjectPath.normalize(directory)
        if let existing = registry.projects.first(where: { $0.directory == normalized }) {
            beginEdit(existing.id)
            return
        }
        showEditor(ProjectDraft(project: Project.suggested(forDirectory: normalized), isNew: true))
    }

    func beginEdit(_ id: Project.ID) {
        guard checkWritable(), let project = registry.project(id: id) else { return }
        var draft = ProjectDraft(project: project, isNew: false)
        for index in draft.variables.indices where draft.variables[index].isSecret {
            draft.variables[index].hasStoredSecret = ProjectSecrets.exists(projectID: project.id, name: draft.variables[index].name)
        }
        showEditor(draft)
    }

    // MARK: - 内部

    private func showEditor(_ draft: ProjectDraft) {
        let view = ProjectEditorView(
            draft: draft,
            onChooseFolder: { [weak self] current in self?.chooseFolder(startingAt: current) },
            onCancel: { [weak self] in self?.closeWindow() },
            onDelete: { [weak self] in self?.confirmRemove(draft.id) },
            onSave: { [weak self] draft in self?.save(draft) ?? [] }
        )
        showWindow(title: draft.isNew ? "プロジェクトを登録" : "プロジェクトを編集", content: view)
    }

    /// 保存する。問題があればその説明を返し、ウインドウは開いたままにする。
    private func save(_ draft: ProjectDraft) -> [String] {
        let previous = registry.project(id: draft.id)
        var updated = registry
        let project: Project
        do {
            project = try updated.upsert(draft.makeProject())
        } catch {
            return error.issues.map(\.message)
        }

        let secrets = draft.variables.filter { $0.isSecret && !$0.trimmedName.isEmpty }
        let missing = secrets.filter { $0.value.isEmpty && !$0.hasUsableStoredSecret }.map(\.trimmedName)
        if !missing.isEmpty {
            return missing.map { "秘密の環境変数「\($0)」の値を入力してください。" }
        }

        do {
            for variable in secrets where !variable.value.isEmpty {
                try ProjectSecrets.set(variable.value, projectID: project.id, name: variable.trimmedName)
            }
            try ProjectRegistryFile.save(updated, to: filePath)
        } catch {
            return [error.localizedDescription]
        }

        // 秘密でなくなった・消した変数の値を Keychain から消す。
        let kept = Set(secrets.map(\.trimmedName))
        for variable in previous?.environment.variables ?? [] where variable.isSecret && !kept.contains(variable.name) {
            ProjectSecrets.remove(projectID: project.id, name: variable.name)
        }

        registry = updated
        model.projects = registry
        closeWindow()
        return []
    }

    private func confirmRemove(_ id: Project.ID) {
        guard let project = registry.project(id: id) else {
            closeWindow()
            return
        }
        let alert = NSAlert()
        alert.messageText = "「\(project.name)」の登録を削除しますか？"
        alert.informativeText = "フォルダの中身には触りません。このプロジェクトの環境設定と、Keychain に保存した秘密の値を削除します。"
        alert.addButton(withTitle: "削除")
        alert.addButton(withTitle: "キャンセル")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var updated = registry
        updated.remove(id: id)
        do {
            try ProjectRegistryFile.save(updated, to: filePath)
        } catch {
            showAlert(title: "削除できませんでした", text: error.localizedDescription)
            return
        }
        for variable in project.environment.variables where variable.isSecret {
            ProjectSecrets.remove(projectID: project.id, name: variable.name)
        }
        registry = updated
        model.projects = registry
        closeWindow()
    }

    /// 保存ファイルを読めなかったときは、上書きして消してしまわないよう編集させない。
    private func checkWritable() -> Bool {
        guard let error = model.projectLoadError else { return true }
        showAlert(
            title: "プロジェクトを保存できません",
            text: "\(error)\n\nファイル: \(filePath)\n直すか別の場所に移してから、アプリを起動し直してください。"
        )
        return false
    }

    private func chooseFolder(startingAt current: String?) -> String? {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "選択"
        panel.message = "プロジェクトの作業フォルダを選んでください"
        if let current, !current.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: ProjectPath.normalize(current))
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }

    private func showWindow<Content: View>(title: String, content: Content) {
        closeWindow()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content)
        window.center()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func closeWindow() {
        window?.close()
        window = nil
    }

    private func showAlert(title: String, text: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}

/// 編集中のプロジェクト。入力欄の文字列のまま持ち、保存するときに `Project` にする。
struct ProjectDraft {
    struct Variable: Identifiable {
        var id: UUID
        var name: String
        /// 秘密の変数では、新しく入力した値（空なら Keychain の値をそのまま使う）。
        var value: String
        var isSecret: Bool
        /// Keychain に値が保存済みか（編集を始めたときの名前で調べる）。
        var hasStoredSecret = false
        private let originalName: String

        init(id: UUID = UUID(), name: String = "", value: String = "", isSecret: Bool = false) {
            self.id = id
            self.name = name
            self.value = value
            self.isSecret = isSecret
            self.originalName = name
        }

        var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

        /// 名前を変えると、保存済みの値は別の項目になるので使えない。
        var hasUsableStoredSecret: Bool { hasStoredSecret && trimmedName == originalName }
    }

    let id: UUID
    let createdAt: Date
    let isNew: Bool
    var name: String
    var directory: String
    var model: String
    /// 空なら指定しない。
    var effort: String
    var permissionMode: String
    var tools: String
    var variables: [Variable]

    init(project: Project, isNew: Bool) {
        id = project.id
        createdAt = project.createdAt
        self.isNew = isNew
        name = project.name
        directory = project.directory
        model = project.environment.model ?? ""
        effort = project.environment.effort ?? ""
        permissionMode = project.environment.permissionMode ?? ""
        tools = ProjectEnvironment.formatToolList(project.environment.allowedTools)
        variables = project.environment.variables.map {
            Variable(id: $0.id, name: $0.name, value: $0.value ?? "", isSecret: $0.isSecret)
        }
    }

    func makeProject() -> Project {
        Project(
            id: id,
            name: name,
            directory: directory,
            environment: ProjectEnvironment(
                model: model,
                effort: effort,
                permissionMode: permissionMode,
                allowedTools: ProjectEnvironment.parseToolList(tools),
                variables: variables
                    .filter { !$0.trimmedName.isEmpty || !$0.value.isEmpty }
                    .map { EnvironmentVariable(id: $0.id, name: $0.name, value: $0.value, isSecret: $0.isSecret) }
            ),
            createdAt: createdAt
        )
    }
}
