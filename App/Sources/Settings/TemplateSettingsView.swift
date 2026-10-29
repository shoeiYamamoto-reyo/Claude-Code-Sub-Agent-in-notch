import AgentKit
import SwiftUI

/// 設定画面の「テンプレート」（ROADMAP 5-5、F2-6）。よく使う指示を作る・直す・消す。
/// 使うときはノッチのクイック入力や「タスクを開始」のウインドウで選ぶ。
struct TemplateSettingsView: View {
    let model: NotchModel

    @State private var selection: PromptTemplate.ID?
    /// 編集中の内容。新しく作るときは一覧に無い ID。
    @State private var draft = PromptTemplate(name: "", prompt: "")
    @State private var problems: [String] = []
    @State private var isConfirmingDelete = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(model.templates.templates) { template in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(template.name)
                                .lineLimit(1)
                            Text(subtitle(template))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .tag(template.id)
                    }
                }
                Divider()
                HStack(spacing: 0) {
                    Button {
                        selection = nil
                        startNew()
                    } label: {
                        Image(systemName: "plus").frame(width: 24, height: 20)
                    }
                    .help("新しいテンプレート")
                    Button {
                        isConfirmingDelete = true
                    } label: {
                        Image(systemName: "minus").frame(width: 24, height: 20)
                    }
                    .help("選んだテンプレートを削除")
                    .disabled(selection == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(4)
            }
            .frame(width: 170)
            Divider()
            editor
        }
        .disabled(model.templateLoadError != nil)
        .overlay(alignment: .bottom) {
            if let error = model.templateLoadError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(8)
                    .background(.background, in: RoundedRectangle(cornerRadius: 6))
                    .padding()
            }
        }
        .onChange(of: selection) { load(selection) }
        .onAppear { load(selection) }
        .confirmationDialog(
            "「\(model.templates.template(id: selection ?? UUID())?.name ?? "")」を削除しますか？",
            isPresented: $isConfirmingDelete
        ) {
            Button("削除", role: .destructive) {
                guard let selection else { return }
                let failures = model.onDeleteTemplate?(selection) ?? ["削除できません。"]
                if failures.isEmpty {
                    self.selection = nil
                    startNew()
                } else {
                    problems = failures
                }
            }
        }
    }

    private var editor: some View {
        Form {
            TextField("名前", text: $draft.name)
            Picker("プロジェクト", selection: $draft.projectID) {
                Text("すべて").tag(UUID?.none)
                ForEach(model.projects.projects) { project in
                    Text(project.name).tag(UUID?.some(project.id))
                }
            }
            TextField("エージェント", text: Binding(
                get: { draft.agent ?? "" },
                set: { draft.agent = $0 }
            ), prompt: Text("おまかせ"))
            VStack(alignment: .leading, spacing: 4) {
                Text("指示")
                TextEditor(text: $draft.prompt)
                    .font(.body)
                    .frame(minHeight: 140)
            }
            ForEach(problems, id: \.self) { problem in
                Text(problem).foregroundStyle(.red)
            }
            HStack {
                Text("エージェントは、そのプロジェクトに無ければ「おまかせ」で始めます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(isNew ? "追加" : "保存", action: save)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!hasChanges)
            }
        }
        .formStyle(.grouped)
    }

    private var isNew: Bool {
        model.templates.template(id: draft.id) == nil
    }

    private var hasChanges: Bool {
        guard let saved = model.templates.template(id: draft.id) else { return true }
        return PromptTemplateLibrary.normalized(draft) != saved
    }

    private func subtitle(_ template: PromptTemplate) -> String {
        let project = template.projectID.flatMap { model.projects.project(id: $0)?.name } ?? "すべて"
        return [project, template.agent].compactMap { $0 }.joined(separator: " · ")
    }

    private func load(_ id: PromptTemplate.ID?) {
        problems = []
        if let id, let template = model.templates.template(id: id) {
            draft = template
        } else if id != nil || !isNew {
            startNew()
        }
    }

    private func startNew() {
        problems = []
        draft = PromptTemplate(name: "", prompt: "")
    }

    private func save() {
        problems = model.onSaveTemplate?(draft) ?? ["保存できません。"]
        if problems.isEmpty { selection = draft.id }
    }
}
