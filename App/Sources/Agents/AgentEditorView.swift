import AgentKit
import SwiftUI

/// ノッチの中の定義の編集画面（ROADMAP 4-4、F5-2 / F5-3 / F5-7）。
///
/// 1. フォームで編集する（入力しながら検証の結果を出す）。
/// 2. 「変更を確認…」で書き込む内容の差分に切り替える。
/// 3. 「保存」を押したときだけ書く（`AgentEditor`）。「戻る」・Esc では書かずに一覧へ戻る（変更があれば確かめる）。
struct AgentEditorView: View {
    /// 入力内容はセッションに置く（ノッチが縮んでビューが消えても残す）。
    @Bindable var session: AgentEditSession
    /// 一覧で選んだ見た目（ROADMAP 5-8）。見出しのキャラに使う。
    let look: AgentLook
    let plan: (AgentDefinition) -> AgentSavePlan?
    /// 書き込めなければ理由を返す。
    let onSave: (SettingsFileEdit) -> String?
    let onClose: () -> Void

    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            switch session.stage {
            case .form, .confirmDiscard:
                form
            case .review(let plan, let edit):
                review(plan, edit)
            }
        }
        .environment(\.colorScheme, .dark)
        .onAppear { if session.isNew && session.name.isEmpty { nameFocused = true } }
    }

    // MARK: - 見出し

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: back) {
                Label("一覧", systemImage: "chevron.left")
            }
            .buttonStyle(CardButtonStyle(tint: .white))
            .help("保存せずに一覧へ戻る（Esc）")
            AgentCharacter(palette: AgentAppearance.palette(color: session.color), mood: .idle, animated: false, look: look)
                .frame(width: 34, height: 24)
            Text(session.title)
                .font(.headline)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(ProjectPath.abbreviate(session.location))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
                .truncationMode(.head)
                .help(session.location)
        }
    }

    // MARK: - フォーム

    private var form: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 8) {
                    field("name") {
                        TextField("", text: $session.name, prompt: Text("code-reviewer"))
                            .focused($nameFocused)
                            .modifier(NotchFieldStyle())
                    }
                    field("description") {
                        TextField("", text: $session.description, prompt: Text("いつ使うか（Claude が委任を決める手がかり）"), axis: .vertical)
                            .lineLimit(2...4)
                            .modifier(NotchFieldStyle())
                    }
                    field("tools") {
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle("親から全部引き継ぐ", isOn: $session.inheritsTools)
                                .toggleStyle(.checkbox)
                                .font(.caption)
                            if !session.inheritsTools {
                                TextField("", text: $session.tools, prompt: Text("1 行に 1 つ（Read、Bash(git diff *) など）。空ならツールなし"), axis: .vertical)
                                    .lineLimit(2...5)
                                    .modifier(NotchFieldStyle())
                            }
                        }
                    }
                    field("disallowedTools") {
                        TextField("", text: $session.disallowedTools, prompt: Text("使わせないツール。1 行に 1 つ"), axis: .vertical)
                            .lineLimit(1...4)
                            .modifier(NotchFieldStyle())
                    }
                    HStack(spacing: 12) {
                        field("model") { choice(selection: $session.model, values: AgentDefinition.modelValues) }
                        field("effort") { choice(selection: $session.effort, values: ProjectEnvironment.effortLevels) }
                    }
                    HStack(spacing: 12) {
                        field("permissionMode") { choice(selection: $session.permissionMode, values: AgentDefinition.permissionModeValues) }
                        field("color") { choice(selection: $session.color, values: AgentDefinition.colorValues) }
                    }
                    Text("本文（system prompt）")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                    TextEditor(text: $session.body)
                        .font(.system(.callout, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(minHeight: 150)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                .padding(.trailing, 6)
            }
            .scrollIndicators(.automatic)

            let issues = session.edited.validate()
            ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                Label(issue.message, systemImage: issue.severity == .error ? "xmark.octagon" : "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(issue.severity == .error ? .red : .orange)
                    .lineLimit(2)
            }
            if let problem = session.problem {
                Label(problem, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
            if case .confirmDiscard = session.stage {
                HStack(spacing: 8) {
                    Label("保存していない変更があります。", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("編集を続ける") { session.stage = .form }
                        .buttonStyle(CardButtonStyle(tint: .white))
                        .keyboardShortcut(.cancelAction)
                    Button("変更を捨てて戻る", action: onClose)
                        .buttonStyle(CardButtonStyle(tint: .red, prominent: true))
                }
            } else {
                HStack(spacing: 8) {
                    Spacer()
                    Button("キャンセル", action: back)
                        .buttonStyle(CardButtonStyle(tint: .white))
                        .keyboardShortcut(.cancelAction)
                    Button("変更を確認…", action: review)
                        .buttonStyle(CardButtonStyle(tint: .blue, prominent: true))
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(issues.contains { $0.severity == .error })
                        .help("書き込む内容の差分を見る（⌘Return）")
                }
            }
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 候補から選ぶか、自由に入力する（モデル ID など、候補に無い値もある）。
    private func choice(selection: Binding<String>, values: [String]) -> some View {
        HStack(spacing: 4) {
            TextField("", text: selection, prompt: Text("指定なし"))
                .modifier(NotchFieldStyle())
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

    // MARK: - 差分の確認

    private func review(_ plan: AgentSavePlan, _ edit: SettingsFileEdit) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(confirmMessage(plan))
                .font(.callout)
                .foregroundStyle(.white.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
            if edit.targetPath != edit.displayPath {
                Text("リンク先: \(edit.targetPath)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
            }
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(LineDiff.hunks(edit.diff).enumerated()), id: \.offset) { _, line in
                        DiffLineView(line: line)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 8) {
                Spacer()
                Button("戻る") { session.stage = .form }
                    .buttonStyle(CardButtonStyle(tint: .white))
                    .keyboardShortcut(.cancelAction)
                Button("保存") { save(edit) }
                    .buttonStyle(CardButtonStyle(tint: .blue, prominent: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func confirmMessage(_ plan: AgentSavePlan) -> String {
        var message = plan.isNew
            ? "新しい定義ファイルを作ります。"
            : "変えた項目だけを書き直します。ほかの項目・コメント・順序はそのまま残し、書き込む前にバックアップを作ります。"
        if !plan.warnings.isEmpty {
            message += "\n注意: " + plan.warnings.map(\.message).joined(separator: "\n")
        }
        message += "\n実行中の Claude Code には、次に起動したセッションから反映されます。"
        return message
    }

    // MARK: - 操作

    private func back() {
        if case .form = session.stage, session.hasChanges {
            session.stage = .confirmDiscard
        } else {
            onClose()
        }
    }

    private func review() {
        session.problem = nil
        guard let result = plan(session.edited) else { return }
        guard result.errors.isEmpty, let edit = result.edit else {
            session.problem = result.errors.map(\.message).joined(separator: "\n")
            return
        }
        guard edit.hasChanges else {
            session.problem = "変更はありません。"
            return
        }
        session.stage = .review(result, edit)
    }

    private func save(_ edit: SettingsFileEdit) {
        session.problem = onSave(edit)
        if session.problem != nil { session.stage = .form }
    }
}

/// ノッチ（黒地）の入力欄。
private struct NotchFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.callout)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }
}
