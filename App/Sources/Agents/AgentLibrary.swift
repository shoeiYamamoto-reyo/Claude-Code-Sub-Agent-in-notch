import AgentKit
import Foundation

/// ユーザーと登録プロジェクトのサブエージェント定義を読む（ROADMAP 3-2、F1-3）。
///
/// 「エージェント」タブを開いたとき、プロジェクトが変わったとき、定義のフォルダの中身が変わったとき
/// （ROADMAP 4-2、`DirectoryWatcher`）に読み直す。見張るのは今あるエージェントのフォルダだけで、
/// 最初にタブを開くまでは何も見張らない。読み込みはメインスレッドの外で行う。
@MainActor
final class AgentLibrary {
    let model: NotchModel
    private var loadTask: Task<Void, Never>?
    private lazy var watcher = DirectoryWatcher { [weak self] in self?.refresh() }

    init(model: NotchModel) {
        self.model = model
        model.onRefreshAgents = { [weak self] in self?.refresh() }
    }

    func refresh() {
        let projects = model.projects.projects
        let home = NSHomeDirectory()
        loadTask?.cancel()
        loadTask = Task { [weak self, model] in
            let (overview, watched) = await Task.detached(priority: .utility) {
                let overview = AgentOverview(
                    user: AgentCatalog.load(projectDirectory: nil, home: home),
                    projects: projects.map { project in
                        (project, AgentCatalog.load(projectDirectory: project.directory, home: home))
                    }
                )
                let watched = AgentFileStore.watchedDirectories(projectDirectories: projects.map(\.directory), home: home)
                return (overview, watched)
            }.value
            guard !Task.isCancelled, let self else { return }
            model.agentOverview = overview
            watcher.watch(watched)
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

    /// 読み込んだすべての定義（同じフォルダの name の重なりを調べるのに使う）。
    var allEntries: [AgentCatalog.Entry] {
        user + projects.flatMap(\.entries)
    }

    init(user: AgentCatalog, projects: [(Project, AgentCatalog)]) {
        self.user = user.entries(in: .user)
        self.projects = projects.map { ProjectAgents(project: $0.0, entries: $0.1.entries(in: .project)) }
    }
}
