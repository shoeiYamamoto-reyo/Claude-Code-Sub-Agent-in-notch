import AgentKit
import AppKit
import SwiftUI

/// サブエージェント定義の作成・編集（ROADMAP 4-2、F5-2 / F5-3）。
///
/// 1. フォームで編集する（入力しながら検証の結果を出す）。
/// 2. 「変更を確認…」で書き込む内容の差分を見せる。
/// 3. 「保存」を押したときだけ、バックアップを取ってから書く（`SafeFileWriter`）。
///    編集を始めてからファイルが変わっていたら書かない。
@MainActor
final class AgentEditor {
    let model: NotchModel
    private var window: NSWindow?

    init(model: NotchModel) {
        self.model = model
        model.onEditAgent = { [weak self] path, directory in self?.edit(path: path, directory: directory) }
        model.onNewAgent = { [weak self] directory, title in self?.create(in: directory, title: title) }
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
        open(
            title: "\(definition.name) を編集",
            definition: definition,
            existingPath: path,
            originalData: data,
            directory: directory
        )
    }

    func create(in directory: String, title: String) {
        open(
            title: "新しいサブエージェント（\(title)）",
            definition: AgentFileStore.template(),
            existingPath: nil,
            originalData: nil,
            directory: directory
        )
    }

    // MARK: - 内部

    private func open(title: String, definition: AgentDefinition, existingPath: String?, originalData: Data?, directory: String) {
        let view = AgentEditorView(
            definition: definition,
            location: existingPath ?? directory,
            plan: { [weak self] edited in
                AgentFileStore.plan(
                    edited,
                    existingPath: existingPath,
                    originalData: originalData,
                    directory: directory,
                    entries: self?.model.agentOverview?.allEntries ?? []
                )
            },
            onCancel: { [weak self] in self?.close() },
            onSave: { [weak self] edit in self?.save(edit) }
        )
        close()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.center()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// 書き込めなければ理由を返す。
    private func save(_ edit: SettingsFileEdit) -> String? {
        do {
            try SafeFileWriter.commit(edit)
        } catch SafeFileWriter.WriteError.changedOnDisk {
            return "確認している間に \(edit.displayPath) が変更されたため、保存をやめました。ウインドウを閉じて開き直してください。"
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

/// 定義のフォーム。「変更を確認…」で差分（`SettingsDiffView`）に切り替える。
private struct AgentEditorView: View {
    let location: String
    let plan: (AgentDefinition) -> AgentSavePlan
    let onCancel: () -> Void
    /// 書き込めなければ理由を返す。
    let onSave: (SettingsFileEdit) -> String?

    /// 編集を始めたときの定義。フォームに無い項目（frontmatter の未知の項目など）はここから引き継ぐ。
    private let original: AgentDefinition
    @State private var name: String
    @State private var description: String
    @State private var inheritsTools: Bool
    /// 1 行に 1 つ（ツール名にカンマを含むことがあるため）。
    @State private var tools: String
    @State private var disallowedTools: String
    @State private var model: String
    @State private var effort: String
    @State private var permissionMode: String
    @State private var color: String
    @State private var bodyText: String
    @State private var pending: AgentSavePlan?
    @State private var problem: String?

    init(
        definition: AgentDefinition,
        location: String,
        plan: @escaping (AgentDefinition) -> AgentSavePlan,
        onCancel: @escaping () -> Void,
        onSave: @escaping (SettingsFileEdit) -> String?
    ) {
        self.original = definition
        self.location = location
        self.plan = plan
        self.onCancel = onCancel
        self.onSave = onSave
        _name = State(initialValue: definition.name)
        _description = State(initialValue: definition.description)
        _inheritsTools = State(initialValue: definition.tools == nil)
        _tools = State(initialValue: (definition.tools ?? []).joined(separator: "\n"))
        _disallowedTools = State(initialValue: (definition.disallowedTools ?? []).joined(separator: "\n"))
        _model = State(initialValue: definition.model ?? "")
        _effort = State(initialValue: definition.effort ?? "")
        _permissionMode = State(initialValue: definition.permissionMode ?? "")
        _color = State(initialValue: definition.color ?? "")
        _bodyText = State(initialValue: definition.body)
    }

    var body: some View {
        if let pending, let edit = pending.edit {
            SettingsDiffView(
                title: pending.isNew ? "サブエージェントを作成" : "サブエージェントの定義を保存",
                message: confirmMessage(pending),
                edit: edit,
                actionTitle: "保存",
                cancelTitle: "戻る",
                onCancel: { self.pending = nil },
                onConfirm: {
                    problem = onSave(edit)
                    if problem != nil { self.pending = nil }
                }
            )
        } else {
            form
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            Form {
                TextField("name", text: $name, prompt: Text("code-reviewer"))
                TextField("description", text: $description, prompt: Text("いつ使うか（Claude が委任を決める手がかり）"), axis: .vertical)
                    .lineLimit(2...5)
                Toggle("ツールを親から全部引き継ぐ", isOn: $inheritsTools)
                if !inheritsTools {
                    TextField("tools", text: $tools, prompt: Text("1 行に 1 つ（Read、Bash(git diff *) など）。空ならツールなし"), axis: .vertical)
                        .lineLimit(2...6)
                }
                TextField("disallowedTools", text: $disallowedTools, prompt: Text("使わせないツール。1 行に 1 つ"), axis: .vertical)
                    .lineLimit(1...4)
                choice("model", selection: $model, values: AgentDefinition.modelValues)
                choice("effort", selection: $effort, values: ProjectEnvironment.effortLevels)
                choice("permissionMode", selection: $permissionMode, values: AgentDefinition.permissionModeValues)
                choice("color", selection: $color, values: AgentDefinition.colorValues)
            }
            Text("本文（system prompt）")
                .font(.headline)
            TextEditor(text: $bodyText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

            let issues = edited.validate()
            ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                Label(issue.message, systemImage: issue.severity == .error ? "xmark.octagon" : "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(issue.severity == .error ? .red : .orange)
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            HStack {
                Text(ProjectPath.abbreviate(location))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
                Spacer()
                Button("キャンセル", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("変更を確認…", action: review)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(issues.contains { $0.severity == .error })
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 560)
    }

    /// 候補から選ぶか、自由に入力する（モデル ID など、候補に無い値もある）。
    private func choice(_ label: String, selection: Binding<String>, values: [String]) -> some View {
        HStack {
            TextField(label, text: selection, prompt: Text("指定なし"))
            Menu {
                Button("指定なし") { selection.wrappedValue = "" }
                Divider()
                ForEach(values, id: \.self) { value in
                    Button(value) { selection.wrappedValue = value }
                }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    /// フォームの内容を反映した定義。
    private var edited: AgentDefinition {
        var definition = original
        definition.name = name
        definition.description = description
        definition.tools = inheritsTools ? nil : Self.lines(tools)
        let disallowed = Self.lines(disallowedTools)
        // 元が `disallowedTools: []` なら、空のままでも消さない。
        definition.disallowedTools = disallowed.isEmpty && original.disallowedTools?.isEmpty != true ? nil : disallowed
        definition.model = model
        definition.effort = effort
        definition.permissionMode = permissionMode
        definition.color = color
        definition.body = bodyText
        return definition
    }

    private func review() {
        problem = nil
        let result = plan(edited)
        guard result.errors.isEmpty, let edit = result.edit else {
            problem = result.errors.map(\.message).joined(separator: "\n")
            return
        }
        guard edit.hasChanges else {
            problem = "変更はありません。"
            return
        }
        pending = result
    }

    private func confirmMessage(_ plan: AgentSavePlan) -> String {
        var message = plan.isNew
            ? "新しい定義ファイルを作ります。"
            : "変えた項目だけを書き直します。ほかの項目・コメント・順序はそのまま残し、書き込む前にバックアップを作ります。"
        if !plan.warnings.isEmpty {
            message += "\n\n注意: " + plan.warnings.map(\.message).joined(separator: "\n")
        }
        message += "\n\n実行中の Claude Code には、次に起動したセッションから反映されます。"
        return message
    }

    private static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
