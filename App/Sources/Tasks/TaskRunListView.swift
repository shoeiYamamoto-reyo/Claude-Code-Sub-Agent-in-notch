import AgentKit
import SwiftUI

/// アプリから始めたタスクの一覧（ROADMAP 3-3）。セッション一覧の上に出し、実行中のものは停止できる（F2-2）。
/// 進み具合はセッション一覧（hook）に同じセッションとして出る。結果の表示は 3-4。
struct TaskRunListView: View {
    let tasks: [TaskRun]
    let onStop: (UUID) -> Void
    /// 行を押したとき（結果のウインドウ）。
    let onShow: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("アプリから始めたタスク")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.6))
            ForEach(visibleTasks) { task in
                TaskRunRow(task: task, onStop: { onStop(task.id) }, onShow: { onShow(task.id) })
            }
        }
    }

    /// 動いているものは（停止できるよう）すべて、終わったものは新しい 3 件まで。
    private var visibleTasks: [TaskRun] {
        tasks.filter(\.isActive) + tasks.filter { !$0.isActive }.prefix(3)
    }
}

private struct TaskRunRow: View {
    let task: TaskRun
    let onStop: () -> Void
    let onShow: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onShow) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(color)
                        .frame(width: 7, height: 7)
                    Text(TaskResultSummary.stateText(task))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(color)
                        .frame(minWidth: 40, alignment: .leading)
                    Text(title)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Text(TaskResultSummary.oneLine(task))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("結果を見る")
            if task.state == .running {
                Button("停止", action: onStop)
                    .buttonStyle(CardButtonStyle(tint: .red))
                    .help("Claude Code に中断を伝えます（SIGINT）。5 秒で終わらなければ強制終了します")
            }
        }
    }

    private var title: String {
        [task.projectName, task.agent].compactMap { $0 }.joined(separator: " · ")
    }

    private var color: Color {
        if TaskResultSummary.isError(task) { return .red }
        return switch task.state {
        case .running: .blue
        case .stopping: .orange
        case .finished: .green
        case .stopped: .gray
        case .failed: .red
        }
    }
}
