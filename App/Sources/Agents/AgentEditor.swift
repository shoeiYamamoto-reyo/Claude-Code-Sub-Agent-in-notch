import AgentKit
import AppKit
import Foundation

/// ノッチの中で編集している定義 1 つ分と、フォームの入力内容（ROADMAP 4-4）。
///
/// ノッチが縮むと編集画面のビューは消えるので、入力内容はビューの `@State` ではなくここに置く
/// （ほかのアプリを押して縮んでも、もう一度乗せれば続きから書ける）。
@MainActor
@Observable
final class AgentEditSession: Identifiable {
    enum Stage {
        case form
        case review(AgentSavePlan, SettingsFileEdit)
        /// 変更を捨てて戻るか確かめている。
        case confirmDiscard
    }

    let id = UUID()
    let title: String
    /// 編集を始めたときの定義。新しく作るときはひな形。
    let definition: AgentDefinition
    /// 編集している定義のファイル。新しく作るときは nil。
    let existingPath: String?
    /// 編集を始めたときのファイルの中身。保存までにファイルが変わっていたら書き込みをやめるのに使う。
    let originalData: Data?
    /// 定義を置く `.claude/agents` フォルダ。
    let directory: String

    var stage = Stage.form
    var name: String
    var description: String
    var inheritsTools: Bool
    /// 1 行に 1 つ（ツール名にカンマを含むことがあるため）。
    var tools: String
    var disallowedTools: String
    var model: String
    var effort: String
    var permissionMode: String
    var color: String
    var body: String
    var problem: String?

    init(title: String, definition: AgentDefinition, existingPath: String?, originalData: Data?, directory: String) {
        self.title = title
        self.definition = definition
        self.existingPath = existingPath
        self.originalData = originalData
        self.directory = directory
        name = definition.name
        description = definition.description
        inheritsTools = definition.tools == nil
        tools = (definition.tools ?? []).joined(separator: "\n")
        disallowedTools = (definition.disallowedTools ?? []).joined(separator: "\n")
        model = definition.model ?? ""
        effort = definition.effort ?? ""
        permissionMode = definition.permissionMode ?? ""
        color = definition.color ?? ""
        body = definition.body
    }

    var isNew: Bool { existingPath == nil }
    /// 画面に出す場所。
    var location: String { existingPath ?? directory }

    /// フォームの内容を反映した定義。
    var edited: AgentDefinition {
        var edited = definition
        edited.name = name
        edited.description = description
        edited.tools = inheritsTools ? nil : Self.lines(tools)
        let disallowed = Self.lines(disallowedTools)
        // 元が `disallowedTools: []` なら、空のままでも消さない。
        edited.disallowedTools = disallowed.isEmpty && definition.disallowedTools?.isEmpty != true ? nil : disallowed
        edited.model = model
        edited.effort = effort
        edited.permissionMode = permissionMode
        edited.color = color
        edited.body = body
        return edited
    }

    /// 書き込む内容が編集を始めたときと変わったか。
    var hasChanges: Bool {
        edited.render() != definition.render()
    }

    private static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// サブエージェント定義の作成・編集（ROADMAP 4-2 / 4-4、F5-2 / F5-3 / F5-7）。
///
/// 別ウインドウは開かず、ノッチの中で一覧 → 編集フォーム → 差分の確認と画面を移す（`AgentEditorView`）。
/// 「保存」を押したときだけ、バックアップを取ってから書く（`SafeFileWriter`）。
/// 編集を始めてからファイルが変わっていたら書かない。
@MainActor
final class AgentEditor {
    let model: NotchModel
    /// 編集を始めたとき・終えたとき（ノッチを広げて留め、キー入力を受ける。`NotchPanelController`）。
    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?

    init(model: NotchModel) {
        self.model = model
        model.onEditAgent = { [weak self] path, directory in self?.edit(path: path, directory: directory) }
        model.onNewAgent = { [weak self] directory, title in self?.create(in: directory, title: title) }
        model.onPlanAgentSave = { [weak self] edited in self?.plan(edited) }
        model.onSaveAgent = { [weak self] edit in self?.save(edit) }
        model.onCloseAgentEdit = { [weak self] in self?.close() }
    }

    func edit(path: String, directory: String) {
        guard let data = FileManager.default.contents(atPath: path) else {
            showAlert(title: "定義を開けません", text: "\(path) を読めませんでした。")
            return
        }
        let definition: AgentDefinition
        switch AgentDefinition.parse(String(decoding: data, as: UTF8.self)) {
        case .success(let parsed):
            definition = parsed
        case .failure(let problem):
            showAlert(title: "定義を開けません", text: "\(path): \(problem.message)\nテキストエディタで直してください。")
            return
        }
        open(AgentEditSession(
            title: "\(definition.name) を編集",
            definition: definition,
            existingPath: path,
            originalData: data,
            directory: directory
        ))
    }

    func create(in directory: String, title: String) {
        open(AgentEditSession(
            title: "新しいサブエージェント（\(title)）",
            definition: AgentFileStore.template(),
            existingPath: nil,
            originalData: nil,
            directory: directory
        ))
    }

    // MARK: - 内部

    private func open(_ session: AgentEditSession) {
        model.agentEdit = session
        onBegin?()
    }

    private func plan(_ edited: AgentDefinition) -> AgentSavePlan? {
        guard let session = model.agentEdit else { return nil }
        return AgentFileStore.plan(
            edited,
            existingPath: session.existingPath,
            originalData: session.originalData,
            directory: session.directory,
            entries: model.agentOverview?.allEntries ?? []
        )
    }

    /// 書き込めなければ理由を返す。
    private func save(_ edit: SettingsFileEdit) -> String? {
        do {
            try SafeFileWriter.commit(edit)
        } catch SafeFileWriter.WriteError.changedOnDisk {
            return "確認している間に \(edit.displayPath) が変更されたため、保存をやめました。一覧に戻って開き直してください。"
        } catch SafeFileWriter.WriteError.writeFailed(let detail) {
            return "保存できませんでした: \(detail)"
        } catch SafeFileWriter.WriteError.unreadable {
            return "\(edit.displayPath) を読めないため、保存をやめました。"
        } catch {
            return "保存できませんでした: \(error.localizedDescription)"
        }
        close()
        model.onRefreshAgents?()
        return nil
    }

    private func close() {
        guard model.agentEdit != nil else { return }
        model.agentEdit = nil
        onEnd?()
    }

    private func showAlert(title: String, text: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}
