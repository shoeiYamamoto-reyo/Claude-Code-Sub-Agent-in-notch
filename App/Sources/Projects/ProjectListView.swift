import AgentKit
import SwiftUI

/// 展開時の「プロジェクト」タブ（F1-1）。行を押すと編集ウインドウが開く。
struct ProjectListView: View {
    let registry: ProjectRegistry
    let sessions: [Session]
    let loadError: String?
    let onAdd: () -> Void
    let onEdit: (Project.ID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            } else if registry.projects.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("まだプロジェクトがありません。")
                    Text("作業フォルダを登録しておくと、モデルや権限モードなどの設定をプロジェクトごとに決められます。セッション一覧の「登録」からも追加できます。")
                        .foregroundStyle(.white.opacity(0.6))
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(registry.projects) { project in
                            ProjectRow(project: project, activeSessions: activeSessionCount(in: project)) {
                                onEdit(project.id)
                            }
                        }
                    }
                    .padding(.bottom, 4)
                }
                .scrollIndicators(.automatic)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("プロジェクト")
                .font(.headline)
            if !registry.projects.isEmpty {
                Text("\(registry.projects.count)")
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.white.opacity(0.15), in: Capsule())
            }
            Spacer()
            Button("追加…", action: onAdd)
                .buttonStyle(CardButtonStyle(tint: .white))
                .disabled(loadError != nil)
        }
    }

    private func activeSessionCount(in project: Project) -> Int {
        sessions.filter { session in
            guard session.isActive, let cwd = session.cwd else { return false }
            return registry.project(containing: cwd)?.id == project.id
        }.count
    }
}

private struct ProjectRow: View {
    let project: Project
    let activeSessions: Int
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                    Text(project.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    if activeSessions > 0 {
                        Text("実行中 \(activeSessions)")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.blue)
                    }
                    Spacer(minLength: 4)
                    Text(ProjectPath.abbreviate(project.directory))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Text(environmentSummary)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
                    .padding(.leading, 20)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(isHovering ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var environmentSummary: String {
        let environment = project.environment
        guard !environment.isDefault else { return "ふだんの設定で起動" }
        var parts: [String] = []
        if let model = environment.model { parts.append(model) }
        if let effort = environment.effort { parts.append("effort \(effort)") }
        if let mode = environment.permissionMode { parts.append(mode) }
        if !environment.allowedTools.isEmpty { parts.append("ツール \(environment.allowedTools.count)") }
        if !environment.variables.isEmpty { parts.append("環境変数 \(environment.variables.count)") }
        return parts.joined(separator: " · ")
    }
}
