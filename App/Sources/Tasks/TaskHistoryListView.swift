import AgentKit
import SwiftUI

/// 展開時の「履歴」タブ（ROADMAP 5-4、F3-8）。アプリから始めたタスクを、いつ・どのエージェントに・何を頼み・
/// どうなったかの 1 行ずつで並べる。押すと結果のウインドウを開く（そこから続けられる）。
struct TaskHistoryListView: View {
    let history: TaskHistory
    let error: String?
    let onShow: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("タスクの履歴")
                    .font(.headline)
                Text("\(history.entries.count) 件")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }
            if history.entries.isEmpty {
                Text("まだありません。プロジェクトからタスクを始めると、ここに残ります。")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.6))
                Spacer(minLength: 0)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(history.entries) { entry in
                            TaskHistoryRow(entry: entry, onShow: { onShow(entry.id) })
                        }
                    }
                    .padding(.bottom, 4)
                }
                .scrollIndicators(.automatic)
            }
        }
    }
}

private struct TaskHistoryRow: View {
    let entry: TaskHistoryEntry
    let onShow: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onShow) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(TaskHistoryText.color(entry.outcome))
                        .frame(width: 7, height: 7)
                    Text(TaskHistoryText.outcome(entry.outcome))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(TaskHistoryText.color(entry.outcome))
                        .frame(minWidth: 40, alignment: .leading)
                    Text(entry.startedAt.formatted(.dateTime.month(.defaultDigits).day().hour().minute()))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.55))
                    Text([entry.projectName, entry.agent].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if entry.filesChanged > 0 {
                        Text("\(entry.filesChanged) ファイル +\(entry.linesAdded) −\(entry.linesRemoved)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
                Text(TaskHistoryText.oneLine(entry))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .padding(.leading, 13)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .background(.white.opacity(isHovered ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(entry.prompt)
    }
}

enum TaskHistoryText {
    static func outcome(_ outcome: TaskHistoryEntry.Outcome) -> String {
        switch outcome {
        case .running: "実行中"
        case .finished: "完了"
        case .error: "エラー"
        case .stopped: "停止"
        case .failed: "エラー"
        case .interrupted: "中断"
        }
    }

    static func color(_ outcome: TaskHistoryEntry.Outcome) -> Color {
        switch outcome {
        case .running: .blue
        case .finished: .green
        case .error, .failed: .red
        case .stopped, .interrupted: .gray
        }
    }

    /// 2 行目: 頼んだこと（続けたなら最後の指示）→ 結果。
    static func oneLine(_ entry: TaskHistoryEntry) -> String {
        let asked = TaskCommand.displayName(for: entry.followUps.last ?? entry.prompt)
        let result: String? = switch entry.outcome {
        case .error, .failed: entry.detail.flatMap { ToolSummary.oneLine($0) }
        default: entry.summary.flatMap { ToolSummary.oneLine($0) }
        }
        guard let result else { return asked }
        return "\(asked) → \(result)"
    }

    /// エージェントの詳細に出す利用回数（F5-6）。使ったことが無ければ nil。
    static func usage(_ usage: AgentUsage) -> String? {
        guard usage.runs > 0 else { return nil }
        var text = "利用 \(usage.runs) 回"
        if usage.succeeded + usage.failed > 0 {
            text += " · 成功 \(usage.succeeded)/\(usage.succeeded + usage.failed)"
        }
        return text
    }
}
