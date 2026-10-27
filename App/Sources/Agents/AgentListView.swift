import AgentKit
import AppKit
import SwiftUI

/// 展開時の「エージェント」タブ（F1-3 / F5-1、`docs/design/agent-characters.md`）。
/// サブエージェントをノッチと同じ形のキャラにして、ユーザー共通と登録プロジェクトごとに並べる。
/// 体の色は frontmatter の `color`。マウスを乗せると上の欄に詳細を出し、押すと編集、最後の「＋」で新規作成
/// （F5-2 / F5-3、`AgentEditor`）。
struct AgentListView: View {
    let overview: AgentOverview?
    let onRefresh: () -> Void
    /// 定義ファイルのパスと、それを読んだ `.claude/agents` フォルダ。
    let onEdit: (String, String) -> Void
    /// 置く `.claude/agents` フォルダと、置き場所の名前。
    let onNew: (String, String) -> Void

    /// マウスを乗せているキャラ。
    @State private var hovered: AgentCatalog.Entry?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("サブエージェント")
                    .font(.headline)
                Spacer()
                Button("再読み込み", action: onRefresh)
                    .buttonStyle(CardButtonStyle(tint: .white))
            }
            AgentDetail(entry: hovered)
            if let overview {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        AgentSection(
                            title: "ユーザー共通",
                            subtitle: "~/.claude/agents",
                            entries: overview.user,
                            emptyText: "定義はありません。",
                            hovered: $hovered,
                            onEdit: onEdit,
                            onNew: {
                                onNew(AgentCatalog.userAgentDirectory(home: NSHomeDirectory()), "ユーザー共通")
                            }
                        )
                        ForEach(overview.projects) { item in
                            AgentSection(
                                title: item.project.name,
                                subtitle: ProjectPath.abbreviate(item.project.directory) + "/.claude/agents",
                                entries: item.entries,
                                emptyText: "このプロジェクトの定義はありません（ユーザー共通のものが使えます）。",
                                hovered: $hovered,
                                onEdit: onEdit,
                                onNew: {
                                    let directories = AgentCatalog.projectAgentDirectories(
                                        for: item.project.directory, home: NSHomeDirectory()
                                    )
                                    if let directory = directories.first { onNew(directory, item.project.name) }
                                }
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

/// マウスを乗せているキャラの詳細。高さを固定して、乗せ替えても一覧が動かないようにする。
private struct AgentDetail: View {
    let entry: AgentCatalog.Entry?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch entry?.result {
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
                    .lineLimit(2)
                if let shadowedBy = entry?.shadowedBy {
                    Text("同じ名前の \(ProjectPath.abbreviate(shadowedBy)) が優先されます")
                        .font(.caption2)
                        .foregroundStyle(.gray)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            case .failure(let problem):
                Label {
                    Text("\(AgentTile.fileName(entry?.path ?? "")): \(problem.message)（Claude Code は読み飛ばします）")
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(3)
            case nil:
                Text("キャラにマウスを乗せると詳細を表示します。押すと編集、「新規」で新しく作ります。")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 52, maxHeight: 52, alignment: .topLeading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func toolsText(_ definition: AgentDefinition) -> String {
        guard let tools = definition.tools else { return "ツール: すべて" }
        return "ツール: " + (tools.isEmpty ? "なし" : tools.joined(separator: ", "))
    }
}

private struct AgentSection: View {
    let title: String
    let subtitle: String
    let entries: [AgentCatalog.Entry]
    let emptyText: String
    @Binding var hovered: AgentCatalog.Entry?
    let onEdit: (String, String) -> Void
    let onNew: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 74, maximum: 90), spacing: 4, alignment: .top)]

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
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
                ForEach(entries) { entry in
                    AgentTile(
                        entry: entry,
                        isHovered: hovered == entry,
                        onHover: { inside in
                            if inside {
                                hovered = entry
                            } else if hovered == entry {
                                hovered = nil
                            }
                        },
                        onEdit: { onEdit(entry.path, entry.directory) }
                    )
                }
                NewAgentTile(title: title, action: onNew)
            }
        }
    }
}

/// サブエージェント 1 体。普段は止めた絵で、マウスを乗せている間だけ待機中の動き（呼吸・まばたき）をする。
private struct AgentTile: View {
    let entry: AgentCatalog.Entry
    let isHovered: Bool
    let onHover: (Bool) -> Void
    let onEdit: () -> Void

    var body: some View {
        VStack(spacing: 3) {
            AgentCharacter(
                palette: AgentAppearance.palette(for: entry),
                mood: entry.definition == nil ? .error : .idle,
                animated: isHovered
            )
            .frame(width: 56, height: 40)
            Text(name)
                .font(.caption2.weight(isHovered ? .semibold : .regular))
                .foregroundStyle(entry.definition == nil ? .orange : .white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 3)
        .frame(maxWidth: .infinity)
        .background(.white.opacity(isHovered ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 8))
        .opacity(entry.shadowedBy == nil ? 1 : 0.55)
        .contentShape(Rectangle())
        .onHover(perform: onHover)
        // 読めない定義はフォームで直せないので、押しても開かない（Finder から直す）。
        .onTapGesture { if entry.definition != nil { onEdit() } }
        .contextMenu {
            if entry.definition != nil {
                Button("編集…", action: onEdit)
            }
            Button("Finder で表示") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
            }
        }
        .help(entry.path)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.definition == nil ? "\(name)（読めない定義）" : name)
        .accessibilityAddTraits(.isButton)
    }

    private var name: String {
        entry.definition?.name ?? Self.fileName(entry.path)
    }

    static func fileName(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}

/// 色を付けたキャラ。動かすときだけ `TimelineView` で描き直す（一覧は待機中に CPU を使わない）。
private struct AgentCharacter: View {
    let palette: CharacterPalette
    let mood: CharacterMood
    let animated: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if animated, !reduceMotion, let interval = CharacterAnimation.frameInterval(for: mood) {
            TimelineView(.periodic(from: .now, by: interval)) { context in
                canvas(pose: CharacterAnimation.pose(for: mood, at: context.date.timeIntervalSinceReferenceDate))
            }
        } else {
            canvas(pose: CharacterAnimation.pose(for: mood, at: 0, reduceMotion: true))
        }
    }

    private func canvas(pose: CharacterPose) -> some View {
        CharacterCanvas(mood: mood, eyeOffset: .zero, pose: pose, palette: palette)
    }
}

/// 新しく作る入口。キャラの輪郭を点線で描く。
private struct NewAgentTile: View {
    let title: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                ZStack {
                    CharacterOutline()
                        .stroke(.white.opacity(isHovered ? 0.7 : 0.4), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                    Image(systemName: "plus")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(isHovered ? 0.9 : 0.6))
                        .offset(y: 3)
                }
                .frame(width: 56, height: 40)
                Text("新規")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 3)
            .frame(maxWidth: .infinity)
            .background(.white.opacity(isHovered ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("\(title) にサブエージェントを作る")
    }
}

/// キャラの体の輪郭を、枠に合わせて縮小したもの。
private struct CharacterOutline: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / CharacterSpec.viewBoxWidth, rect.height / CharacterSpec.viewBoxHeight)
        let transform = CGAffineTransform(
            translationX: rect.minX + (rect.width - CharacterSpec.viewBoxWidth * scale) / 2,
            y: rect.minY + (rect.height - CharacterSpec.viewBoxHeight * scale) / 2
        ).scaledBy(x: scale, y: scale)
        return CharacterCanvas.bodyPath.applying(transform)
    }
}
