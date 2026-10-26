import AgentKit
import SwiftUI

/// プロジェクトの登録・編集画面（F1-1 / F1-2）。保存は `ProjectCenter.save` が行い、問題があればその説明を返す。
struct ProjectEditorView: View {
    @State private var draft: ProjectDraft
    let onChooseFolder: (_ current: String) -> String?
    let onCancel: () -> Void
    let onDelete: () -> Void
    let onSave: (ProjectDraft) -> [String]

    @State private var problems: [String] = []

    init(
        draft: ProjectDraft,
        onChooseFolder: @escaping (_ current: String) -> String?,
        onCancel: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onSave: @escaping (ProjectDraft) -> [String]
    ) {
        _draft = State(initialValue: draft)
        self.onChooseFolder = onChooseFolder
        self.onCancel = onCancel
        self.onDelete = onDelete
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("名前", text: $draft.name)
                    LabeledContent("フォルダ") {
                        HStack {
                            TextField("フォルダ", text: $draft.directory, prompt: Text("/Users/…/my-app"))
                                .labelsHidden()
                            Button("選択…") {
                                if let path = onChooseFolder(draft.directory) {
                                    draft.directory = path
                                }
                            }
                        }
                    }
                }

                Section {
                    LabeledContent("モデル") {
                        HStack {
                            TextField("モデル", text: $draft.model, prompt: Text("指定しない"))
                                .labelsHidden()
                            Menu("候補") {
                                ForEach(ProjectEnvironment.modelSuggestions, id: \.self) { model in
                                    Button(model) { draft.model = model }
                                }
                            }
                            .fixedSize()
                        }
                    }
                    Picker("推論の深さ（effort）", selection: $draft.effort) {
                        Text("指定しない").tag("")
                        ForEach(ProjectEnvironment.effortLevels, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("権限モード", selection: $draft.permissionMode) {
                        Text("指定しない（Claude Code の設定どおり）").tag("")
                        ForEach(permissionModeChoices, id: \.self) { Text($0).tag($0) }
                    }
                    if ProjectEnvironment.unattendedPermissionModes.contains(draft.permissionMode) {
                        Label("このモードでは、ツールの実行が確認なしで進みます。ノッチに承認のお知らせは届きません。", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.callout)
                    }
                    TextField("許可するツール", text: $draft.tools, prompt: Text("例: Read, Edit, Bash(npm test)"), axis: .vertical)
                        .lineLimit(1...3)
                } header: {
                    Text("タスクを起動するときの設定")
                } footer: {
                    Text("空欄の項目は起動コマンドに付けません（ふだんの Claude Code の設定が使われます）。許可するツールはカンマで区切ります。")
                        .foregroundStyle(.secondary)
                }

                Section {
                    ForEach($draft.variables) { $variable in
                        VariableRow(variable: $variable) {
                            draft.variables.removeAll { $0.id == variable.id }
                        }
                    }
                    Button {
                        draft.variables.append(ProjectDraft.Variable())
                    } label: {
                        Label("環境変数を追加", systemImage: "plus")
                    }
                } header: {
                    Text("環境変数")
                } footer: {
                    Text("「秘密」にした値は Keychain に保存し、設定ファイルには書きません。")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            if !problems.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(problems, id: \.self) { problem in
                        Label(problem, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.red)
                    }
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }

            HStack {
                if !draft.isNew {
                    Button("登録を削除…", role: .destructive, action: onDelete)
                }
                Spacer()
                Button("キャンセル", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(draft.isNew ? "登録" : "保存") {
                    problems = onSave(draft)
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(minWidth: 480, minHeight: 520)
    }

    /// 知らない値が保存されていても選べるように残す。
    private var permissionModeChoices: [String] {
        let modes = ProjectEnvironment.permissionModes
        if draft.permissionMode.isEmpty || modes.contains(draft.permissionMode) { return modes }
        return modes + [draft.permissionMode]
    }
}

private struct VariableRow: View {
    @Binding var variable: ProjectDraft.Variable
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField("名前", text: $variable.name, prompt: Text("NAME"))
                .labelsHidden()
                .font(.body.monospaced())
                .frame(width: 150)
            Group {
                if variable.isSecret {
                    SecureField("値", text: $variable.value, prompt: Text(variable.hasUsableStoredSecret ? "保存済み（変えるときだけ入力）" : "値"))
                } else {
                    TextField("値", text: $variable.value, prompt: Text("値"))
                }
            }
            .labelsHidden()
            Toggle("秘密", isOn: $variable.isSecret)
                .toggleStyle(.checkbox)
                .onChange(of: variable.isSecret) { _, isSecret in
                    // 秘密でなくするときに保存済みの値を見せることはしない。入力し直してもらう。
                    if !isSecret, variable.hasStoredSecret { variable.value = "" }
                }
            Button(action: onRemove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("この環境変数を削除")
        }
    }
}
