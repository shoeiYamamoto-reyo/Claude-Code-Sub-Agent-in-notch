import AgentKit
import AppKit
import SwiftUI

/// 展開時の「エージェント」タブ（F1-3 / F5-1）。ユーザー共通の定義と、登録プロジェクトごとの定義を並べる。
struct AgentListView: View {
    let overview: AgentOverview?
    let onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("サブエージェント")
                    .font(.headline)
                Spacer()
                Button("再読み込み", action: onRefresh)
                    .buttonStyle(CardButtonStyle(tint: .white))
            }
            if let overview {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        AgentSection(
                            title: "ユーザー共通",
                            subtitle: "~/.claude/agents",
                            entries: overview.user,
                            emptyText: "定義はありません。"
                        )
                        ForEach(overview.projects) { item in
                            AgentSection(
                                title: item.project.name,
                                subtitle: ProjectPath.abbreviate(item.project.directory) + "/.claude/agents",
                                entries: item.entries,
                                emptyText: "このプロジェクトの定義はありません（ユーザー共通のものが使えます）。"
                            )
                        }
                    }
                    .padding(.bottom, 4)
                }
                .scrollIndicators(.automatic)
            } else {
                Text("読み込み中…")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.6))
                Spacer(minLength: 0)
            }
        }
        .onAppear(perform: onRefresh)
    }
}

private struct AgentSection: View {
    let title: String
    let subtitle: String
    let entries: [AgentCatalog.Entry]
    let emptyText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            if entries.isEmpty {
                Text(emptyText)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.leading, 10)
            } else {
                ForEach(entries) { entry in
                    AgentRow(entry: entry)
                        .padding(.leading, 10)
                }
            }
        }
    }
}

private struct AgentRow: View {
    let entry: AgentCatalog.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            switch entry.result {
            case .success(let definition):
                HStack(spacing: 6) {
                    Text(definition.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    if let model = definition.model {
                        Text(model)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 5)
                            .background(.white.opacity(0.12), in: Capsule())
                    }
                    Text(toolsText(definition))
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
                Text(definition.description)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
                if let shadowedBy = entry.shadowedBy {
                    Text("同じ名前の \(ProjectPath.abbreviate(shadowedBy)) が優先されます")
                        .font(.caption2)
                        .foregroundStyle(.gray)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            case .failure(let problem):
                Label {
                    Text("\(fileName): \(problem.message)（Claude Code は読み飛ばします）")
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
            }
        }
        .opacity(entry.shadowedBy == nil ? 1 : 0.55)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Finder で表示") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
            }
        }
        .help(entry.path)
    }

    private var fileName: String { (entry.path as NSString).lastPathComponent }

    private func toolsText(_ definition: AgentDefinition) -> String {
        guard let tools = definition.tools else { return "ツール: すべて" }
        return "ツール: " + tools.joined(separator: ", ")
    }
}
