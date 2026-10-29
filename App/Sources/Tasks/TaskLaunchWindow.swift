import AgentKit
import AppKit
import SwiftUI

/// タスクを始める（ROADMAP 3-3、3-5）。ノッチのクイック入力（`QuickTaskBar`）と、長い指示を書くためのウインドウの両方から使う。
/// ウインドウではテンプレート（ROADMAP 5-5）を選んだり、書いた指示をテンプレートとして保存したりできる。
@MainActor
final class TaskLauncher {
    private static let lastProjectKey = "lastTaskProjectID"

    let model: NotchModel
    private let runner: TaskRunner
    private var window: NSWindow?

    init(model: NotchModel, runner: TaskRunner) {
        self.model = model
        self.runner = runner
        model.onStartTask = { [weak self] projectID in self?.open(projectID: projectID) }
        model.onQuickStart = { [weak self] projectID, agent, prompt, separate in
            guard let self else { return "タスクを始められません。" }
            return await self.start(projectID: projectID, agent: agent, prompt: prompt, separate: separate)
        }
        model.lastTaskProjectID = UserDefaults.standard.string(forKey: Self.lastProjectKey).flatMap(UUID.init(uuidString:))
    }

    func open(projectID: Project.ID? = nil) {
        let projects = model.projects.projects
        guard !projects.isEmpty else {
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "プロジェクトがありません"
            alert.informativeText = "先にプロジェクトを登録してください（ノッチの「プロジェクト」タブ、またはメニューバーの「プロジェクトを追加…」）。"
            alert.runModal()
            return
        }
        // 決めずに開いたときは、ノッチのクイック入力と同じ既定値にする。
        let selected = projectID.flatMap { id in projects.first { $0.id == id } }
            ?? QuickTaskDefaults.project(
                in: model.projects,
                lastUsed: model.lastTaskProjectID,
                activeDirectories: model.sessions.filter(\.isActive).compactMap(\.cwd)
            )
            ?? projects[0]
        let view = TaskLaunchView(
            projects: projects,
            initialProjectID: selected.id,
            claudePath: model.claudePath,
            loadAgents: { directory in
                AgentCatalog.load(projectDirectory: directory, home: NSHomeDirectory()).effective.map(\.name)
            },
            // ビューの中から呼ぶので、保存すればメニューも変わる（Observation）。
            templates: { [model] projectID in model.templates.available(for: projectID) },
            onSaveTemplate: { [model] template in model.onSaveTemplate?(template) ?? ["保存できません。"] },
            isBusy: { [model] projectID in model.projects.project(id: projectID).map { model.isProjectBusy($0) } ?? false },
            onCancel: { [weak self] in self?.close() },
            onStart: { [weak self] projectID, agent, prompt, separate in
                guard let self else { return nil }
                let problem = await self.start(projectID: projectID, agent: agent, prompt: prompt, separate: separate)
                if problem == nil { self.close() }
                return problem
            }
        )
        close()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "タスクを開始"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.center()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// 始められなければ理由を返す。`separate` なら git worktree を作ってその中で動かす（ROADMAP 5-6、F2-5）。
    func start(projectID: Project.ID, agent: String?, prompt: String, separate: Bool = false) async -> String? {
        guard let project = model.projects.project(id: projectID) else { return "プロジェクトが見つかりません。" }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "指示を入力してください。" }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: project.directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            return "作業フォルダがありません: \(project.directory)"
        }
        let sessionID = UUID()
        var worktree: GitWorktree.Plan?
        if separate {
            // チェックアウトに時間がかかることがあるので、別スレッドで作る。
            let directory = project.directory
            let result = await Task.detached(priority: .userInitiated) { () -> Result<GitWorktree.Plan, GitWorktree.Failure> in
                do {
                    return .success(try GitWorktree.create(projectDirectory: directory, sessionID: sessionID))
                } catch {
                    return .failure(error)
                }
            }.value
            switch result {
            case .success(let plan): worktree = plan
            case .failure(let failure): return failure.message
            }
        }
        let request = TaskRequest(
            projectID: project.id, agent: agent, prompt: trimmed, sessionID: sessionID, directory: worktree?.workingDirectory
        )
        if let error = runner.start(request, project: project, worktree: worktree) {
            // 作ったばかりの worktree は残さない（ブランチは残る）。
            if let path = worktree?.path {
                Task.detached(priority: .utility) { _ = try? GitWorktree.remove(path: path) }
            }
            return error
        }
        model.lastTaskProjectID = project.id
        UserDefaults.standard.set(project.id.uuidString, forKey: Self.lastProjectKey)
        return nil
    }

    private func close() {
        window?.close()
        window = nil
    }
}

private struct TaskLaunchView: View {
    let projects: [Project]
    let claudePath: String?
    let loadAgents: (String) -> [String]
    let templates: (Project.ID) -> [PromptTemplate]
    let onSaveTemplate: (PromptTemplate) -> [String]
    let isBusy: (Project.ID) -> Bool
    let onCancel: () -> Void
    let onStart: @MainActor (Project.ID, String?, String, Bool) async -> String?

    @State private var projectID: Project.ID
    /// 空なら「おまかせ」。
    @State private var agent = ""
    @State private var agents: [String] = []
    @State private var prompt = ""
    @State private var problem: String?
    @State private var isSavingTemplate = false
    /// ほかのタスクが動いていても、worktree で分けずに同じフォルダで動かす。
    @State private var keepInPlace = false
    @State private var isStarting = false

    init(
        projects: [Project],
        initialProjectID: Project.ID,
        claudePath: String?,
        loadAgents: @escaping (String) -> [String],
        templates: @escaping (Project.ID) -> [PromptTemplate],
        onSaveTemplate: @escaping (PromptTemplate) -> [String],
        isBusy: @escaping (Project.ID) -> Bool,
        onCancel: @escaping () -> Void,
        onStart: @escaping @MainActor (Project.ID, String?, String, Bool) async -> String?
    ) {
        self.projects = projects
        self.claudePath = claudePath
        self.loadAgents = loadAgents
        self.templates = templates
        self.onSaveTemplate = onSaveTemplate
        self.isBusy = isBusy
        self.onCancel = onCancel
        self.onStart = onStart
        _projectID = State(initialValue: initialProjectID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                Picker("プロジェクト", selection: $projectID) {
                    ForEach(projects) { project in
                        Text(project.name).tag(project.id)
                    }
                }
                Picker("エージェント", selection: $agent) {
                    Text("おまかせ").tag("")
                    ForEach(agents, id: \.self) { Text($0).tag($0) }
                }
            }
            HStack {
                Text("指示")
                    .font(.headline)
                Spacer()
                let available = templates(projectID)
                Menu("テンプレート") {
                    ForEach(available) { template in
                        Button(template.name) { apply(template) }
                    }
                    if !available.isEmpty { Divider() }
                    Button("この指示をテンプレートとして保存…") { isSavingTemplate = true }
                        .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .fixedSize()
            }
            TextEditor(text: $prompt)
                .font(.body)
                .frame(minHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            if let project = projects.first(where: { $0.id == projectID }) {
                Text("作業フォルダ: \(ProjectPath.abbreviate(project.directory))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if project.environment.runsWithoutApproval, let mode = project.environment.normalized().permissionMode {
                    Label("権限モード \(mode): ツールの実行が確認なしで進みます。ノッチに承認のお知らせは届きません。", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
            if isBusy(projectID) {
                Toggle("ほかのタスクが動いているので、git worktree で分けて動かす", isOn: Binding(
                    get: { !keepInPlace },
                    set: { keepInPlace = !$0 }
                ))
                .help("プロジェクトの .claude/worktrees/ に作業場所を作り、新しいブランチで動かします")
            }
            if claudePath == nil {
                Label("claude コマンドが見つかっていません。メニューバーの「claude の場所を指定…」で指定してください。", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            HStack {
                if projects.first(where: { $0.id == projectID })?.environment.runsWithoutApproval != true {
                    Text("承認が必要な操作は、ノッチに承認のお知らせが届きます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("キャンセル", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(isStarting ? "準備中…" : "開始") {
                    let separate = isBusy(projectID) && !keepInPlace
                    isStarting = true
                    Task {
                        problem = await onStart(projectID, agent.isEmpty ? nil : agent, prompt, separate)
                        isStarting = false
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(isStarting || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 360)
        .onAppear(perform: reloadAgents)
        .onChange(of: projectID) { reloadAgents() }
        .sheet(isPresented: $isSavingTemplate) {
            SaveTemplateSheet(
                template: PromptTemplate(name: "", prompt: prompt, agent: agent.isEmpty ? nil : agent),
                projectName: projects.first { $0.id == projectID }?.name ?? "",
                projectID: projectID,
                onSave: onSaveTemplate,
                onClose: { isSavingTemplate = false }
            )
        }
    }

    /// テンプレートの内容を入れる。指示は置き換える。
    private func apply(_ template: PromptTemplate) {
        problem = nil
        prompt = template.prompt
        if let id = template.projectID, projects.contains(where: { $0.id == id }), id != projectID {
            projectID = id
            agents = projects.first { $0.id == id }.map { loadAgents($0.directory) } ?? []
        }
        if let name = template.agent, !agents.contains(name) {
            agent = ""
            problem = "エージェント「\(name)」はこのプロジェクトに無いので、おまかせにしました。"
        } else {
            agent = template.agent ?? ""
        }
    }

    private func reloadAgents() {
        guard let project = projects.first(where: { $0.id == projectID }) else { return }
        agents = loadAgents(project.directory)
        if !agent.isEmpty, !agents.contains(agent) { agent = "" }
    }
}

/// 書いた指示をテンプレートとして保存する（ROADMAP 5-5）。名前と、使うプロジェクトを決める。
private struct SaveTemplateSheet: View {
    let projectName: String
    let projectID: Project.ID
    let onSave: (PromptTemplate) -> [String]
    let onClose: () -> Void

    @State private var template: PromptTemplate
    @State private var onlyThisProject = false
    @State private var problems: [String] = []

    init(
        template: PromptTemplate,
        projectName: String,
        projectID: Project.ID,
        onSave: @escaping (PromptTemplate) -> [String],
        onClose: @escaping () -> Void
    ) {
        self.projectName = projectName
        self.projectID = projectID
        self.onSave = onSave
        self.onClose = onClose
        _template = State(initialValue: template)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("テンプレートとして保存")
                .font(.headline)
            Form {
                TextField("名前", text: $template.name)
                LabeledContent("エージェント", value: template.agent ?? "おまかせ")
                Toggle("「\(projectName)」だけで使う", isOn: $onlyThisProject)
            }
            ForEach(problems, id: \.self) { problem in
                Text(problem).foregroundStyle(.red)
            }
            Text("指示とエージェントを保存します。設定画面の「テンプレート」で直せます。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("キャンセル", role: .cancel, action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    var saved = template
                    saved.projectID = onlyThisProject ? projectID : nil
                    problems = onSave(saved)
                    if problems.isEmpty { onClose() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(template.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
