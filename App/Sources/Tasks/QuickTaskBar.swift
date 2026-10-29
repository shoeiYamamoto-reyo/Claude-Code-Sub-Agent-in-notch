import AgentKit
import SwiftUI

/// ノッチから指示を入力してタスクを始める（ROADMAP 3-5、F2-1）。
///
/// ホバーで展開 → 入力欄を押して入力 → Return で開始、の 3 操作。⌃⌥⌘N でも入力を始められる。
/// プロジェクトは最後に使ったもの（`QuickTaskDefaults`）、エージェントは「おまかせ」から始める。
/// 長い指示は「プロジェクト」タブの「タスクを開始…」のウインドウで書く。
/// 保存したテンプレート（ROADMAP 5-5）を選ぶと、指示・エージェント・プロジェクトが入る。
struct QuickTaskBar: View {
    let model: NotchModel

    @State private var projectID: Project.ID?
    /// nil なら「おまかせ」。
    @State private var agent: String?
    @State private var agents: [String] = []
    /// テンプレートでプロジェクトを変えたとき、読み直したあとに選ぶエージェント。
    @State private var pendingAgent: String?
    /// ほかのタスクが動いていても、worktree で分けずに同じフォルダで動かす（ROADMAP 5-6）。
    @State private var keepInPlace = false
    @State private var isStarting = false
    @State private var problem: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        if model.isQuickInputActive {
            editor
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        Button {
            model.onBeginQuickInput?()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus.bubble")
                Text(model.quickInputDraft.isEmpty ? "指示を入力してタスクを開始…" : model.quickInputDraft)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let shortcut = model.quickInputShortcut {
                    Text(shortcut)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .font(.callout)
            .foregroundStyle(.white.opacity(0.6))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("ノッチで指示を入力して、Claude Code のタスクを始めます")
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Menu {
                    ForEach(model.projects.projects) { project in
                        Button(project.name) { projectID = project.id }
                    }
                } label: {
                    Label(selectedProject?.name ?? "プロジェクト", systemImage: "folder")
                }
                Menu {
                    Button("おまかせ") { agent = nil }
                    if !agents.isEmpty { Divider() }
                    ForEach(agents, id: \.self) { name in
                        Button(name) { agent = name }
                    }
                } label: {
                    Label(agent ?? "おまかせ", systemImage: "person.crop.circle")
                }
                let templates = model.templates.available(for: projectID)
                if !templates.isEmpty {
                    Menu {
                        ForEach(templates) { template in
                            Button(template.name) { apply(template) }
                        }
                    } label: {
                        Label("テンプレート", systemImage: "text.badge.star")
                    }
                }
                Spacer()
                if let directory = selectedProject?.directory {
                    Text(ProjectPath.abbreviate(directory))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.visible)
            .font(.caption.weight(.medium))
            .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .bottom, spacing: 8) {
                TextField("指示（Return で開始、Esc でやめる）", text: draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .lineLimit(1...4)
                    .focused($isFocused)
                    .onSubmit(start)
                    .onExitCommand { model.onEndQuickInput?() }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                Button(isStarting ? "準備中…" : "開始", action: start)
                    .buttonStyle(CardButtonStyle(tint: .blue, prominent: true))
                    .disabled(projectID == nil || isDraftEmpty || isStarting)
            }

            if isBusy {
                Toggle("ほかのタスクが動いているので worktree で分ける", isOn: Binding(
                    get: { !keepInPlace },
                    set: { keepInPlace = !$0 }
                ))
                .toggleStyle(.checkbox)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
                .help("プロジェクトの .claude/worktrees/ に作業場所を作り、新しいブランチで動かします")
            }

            if let problem {
                Label(problem, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            } else if model.claudePath == nil {
                Label("claude コマンドが見つかっていません（メニューバーの「claude の場所を指定…」）", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            } else if let project = selectedProject, project.environment.runsWithoutApproval,
                      let mode = project.environment.normalized().permissionMode {
                Label("権限モード \(mode): 確認なしで実行されます（承認のお知らせは届きません）", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .onAppear(perform: prepare)
        .onChange(of: projectID) { reloadAgents() }
    }

    /// 縮んでも消えないよう、下書きはモデルに置く。
    private var draft: Binding<String> {
        Binding(get: { model.quickInputDraft }, set: { model.quickInputDraft = $0 })
    }

    private var isDraftEmpty: Bool {
        model.quickInputDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var selectedProject: Project? {
        projectID.flatMap { model.projects.project(id: $0) }
    }

    private var isBusy: Bool {
        selectedProject.map { model.isProjectBusy($0) } ?? false
    }

    private func prepare() {
        problem = nil
        if selectedProject == nil {
            projectID = QuickTaskDefaults.project(
                in: model.projects,
                lastUsed: model.lastTaskProjectID,
                activeDirectories: model.sessions.filter(\.isActive).compactMap(\.cwd)
            )?.id
        }
        reloadAgents()
        // パネルがキーウインドウになってから入力欄に移る。
        Task { isFocused = true }
    }

    private func reloadAgents() {
        guard let directory = selectedProject?.directory else {
            agents = []
            agent = nil
            pendingAgent = nil
            return
        }
        Task {
            let names = await Task.detached {
                AgentCatalog.load(projectDirectory: directory, home: NSHomeDirectory()).effective.map(\.name)
            }.value
            // 読んでいる間にプロジェクトを変えていれば捨てる。
            guard selectedProject?.directory == directory else { return }
            agents = names
            if let agent, !names.contains(agent) { self.agent = nil }
            if let name = pendingAgent {
                pendingAgent = nil
                if names.contains(name) {
                    agent = name
                } else {
                    problem = "エージェント「\(name)」はこのプロジェクトに無いので、おまかせで始めます。"
                }
            }
        }
    }

    /// テンプレートの内容を入れる。下書きは置き換える。
    private func apply(_ template: PromptTemplate) {
        problem = nil
        model.quickInputDraft = template.prompt
        pendingAgent = nil
        if let id = template.projectID, model.projects.project(id: id) != nil, id != projectID {
            // 新しいプロジェクトの定義を読み直してから選ぶ（`reloadAgents`）。それまでは「おまかせ」。
            agent = nil
            pendingAgent = template.agent
            projectID = id
        } else if let name = template.agent, !agents.contains(name) {
            agent = nil
            problem = "エージェント「\(name)」はこのプロジェクトに無いので、おまかせで始めます。"
        } else {
            agent = template.agent
        }
        isFocused = true
    }

    private func start() {
        guard let projectID, !isDraftEmpty, !isStarting, let onQuickStart = model.onQuickStart else { return }
        let prompt = model.quickInputDraft
        let separate = isBusy && !keepInPlace
        isStarting = true
        Task {
            let problem = await onQuickStart(projectID, agent, prompt, separate)
            isStarting = false
            if let problem {
                self.problem = problem
                return
            }
            self.problem = nil
            // 準備の間に書き足していなければ消す。
            if model.quickInputDraft == prompt { model.quickInputDraft = "" }
            keepInPlace = false
            model.onEndQuickInput?()
        }
    }
}
