import AgentKit
import AppKit
import SwiftUI

/// タスクを始めるウインドウ（ROADMAP 3-3 の確認用の最小限。ノッチから素早く入力する UI は 3-5）。
///
/// ノッチのパネルはキー入力を受けないので、指示は普通のウインドウで入力する。
@MainActor
final class TaskLauncher {
    let model: NotchModel
    private let runner: TaskRunner
    private var window: NSWindow?

    init(model: NotchModel, runner: TaskRunner) {
        self.model = model
        self.runner = runner
        model.onStartTask = { [weak self] projectID in self?.open(projectID: projectID) }
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
        let selected = projectID.flatMap { id in projects.first { $0.id == id } } ?? projects[0]
        let view = TaskLaunchView(
            projects: projects,
            initialProjectID: selected.id,
            claudePath: model.claudePath,
            loadAgents: { directory in
                AgentCatalog.load(projectDirectory: directory, home: NSHomeDirectory()).effective.map(\.name)
            },
            onCancel: { [weak self] in self?.close() },
            onStart: { [weak self] projectID, agent, prompt in
                self?.start(projectID: projectID, agent: agent, prompt: prompt)
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

    /// 始められなければ理由を返す（ウインドウは開いたまま）。
    private func start(projectID: Project.ID, agent: String?, prompt: String) -> String? {
        guard let project = model.projects.project(id: projectID) else { return "プロジェクトが見つかりません。" }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "指示を入力してください。" }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: project.directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            return "作業フォルダがありません: \(project.directory)"
        }
        if let error = runner.start(TaskRequest(projectID: project.id, agent: agent, prompt: trimmed), project: project) {
            return error
        }
        close()
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
    let onCancel: () -> Void
    let onStart: (Project.ID, String?, String) -> String?

    @State private var projectID: Project.ID
    /// 空なら「おまかせ」。
    @State private var agent = ""
    @State private var agents: [String] = []
    @State private var prompt = ""
    @State private var problem: String?

    init(
        projects: [Project],
        initialProjectID: Project.ID,
        claudePath: String?,
        loadAgents: @escaping (String) -> [String],
        onCancel: @escaping () -> Void,
        onStart: @escaping (Project.ID, String?, String) -> String?
    ) {
        self.projects = projects
        self.claudePath = claudePath
        self.loadAgents = loadAgents
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
            Text("指示")
                .font(.headline)
            TextEditor(text: $prompt)
                .font(.body)
                .frame(minHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            if let project = projects.first(where: { $0.id == projectID }) {
                Text("作業フォルダ: \(ProjectPath.abbreviate(project.directory))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                Text("承認が必要な操作は、ノッチに承認のお知らせが届きます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("キャンセル", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("開始") {
                    problem = onStart(projectID, agent.isEmpty ? nil : agent, prompt)
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 360)
        .onAppear(perform: reloadAgents)
        .onChange(of: projectID) { reloadAgents() }
    }

    private func reloadAgents() {
        guard let project = projects.first(where: { $0.id == projectID }) else { return }
        agents = loadAgents(project.directory)
        if !agent.isEmpty, !agents.contains(agent) { agent = "" }
    }
}
