import Foundation

/// ノッチのクイック入力で最初に選んでおくもの（ROADMAP 3-5）。
public enum QuickTaskDefaults {
    /// 最後にタスクを始めたプロジェクト → 動いているセッションのあるプロジェクト（並び順）→ 先頭のプロジェクト。
    public static func project(in registry: ProjectRegistry, lastUsed: Project.ID?, activeDirectories: [String]) -> Project? {
        if let lastUsed, let project = registry.project(id: lastUsed) { return project }
        for directory in activeDirectories {
            if let project = registry.project(containing: directory) { return project }
        }
        return registry.projects.first
    }
}
