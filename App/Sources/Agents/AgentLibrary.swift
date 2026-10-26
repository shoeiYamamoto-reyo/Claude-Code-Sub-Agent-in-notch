import AgentKit
import Foundation

/// ユーザーと登録プロジェクトのサブエージェント定義を読む（ROADMAP 3-2、F1-3）。
///
/// 常時の監視はせず、「エージェント」タブを開いたときとプロジェクトが変わったときにだけ読み直す
/// （待機中に CPU を使わないため。ファイル監視は M4-2）。読み込みはメインスレッドの外で行う。
@MainActor
final class AgentLibrary {
    let model: NotchModel
    private var loadTask: Task<Void, Never>?

    init(model: NotchModel) {
        self.model = model
        model.onRefreshAgents = { [weak self] in self?.refresh() }
    }

    func refresh() {
        let projects = model.projects.projects
        let home = NSHomeDirectory()
        loadTask?.cancel()
        loadTask = Task { [model] in
            let overview = await Task.detached(priority: .utility) {
                AgentOverview(
                    user: AgentCatalog.load(projectDirectory: nil, home: home),
                    projects: projects.map { project in
                        (project, AgentCatalog.load(projectDirectory: project.directory, home: home))
                    }
                )
            }.value
            guard !Task.isCancelled else { return }
            model.agentOverview = overview
        }
    }
}

/// 「エージェント」タブに出す内容。
struct AgentOverview: Equatable {
    struct ProjectAgents: Equatable, Identifiable {
        var project: Project
        /// プロジェクトの `.claude/agents`（上へ辿ったものを含む）にある定義だけ。
        var entries: [AgentCatalog.Entry]
        var id: Project.ID { project.id }
    }

    var user: [AgentCatalog.Entry]
    var projects: [ProjectAgents]

    init(user: AgentCatalog, projects: [(Project, AgentCatalog)]) {
        self.user = user.entries(in: .user)
        self.projects = projects.map { ProjectAgents(project: $0.0, entries: $0.1.entries(in: .project)) }
    }
}
