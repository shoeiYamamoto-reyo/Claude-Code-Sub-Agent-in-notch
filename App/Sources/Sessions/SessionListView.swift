import AgentKit
import SwiftUI

/// 展開時に出すセッション一覧とサブエージェントのツリー（F3-1〜F3-3）。
struct SessionListView: View {
    let sessions: [Session]
    let receiver: ReceiverStatus
    let installStatus: HookInstaller.Status?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if sessions.isEmpty {
                emptyState
                Spacer(minLength: 0)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(sessions) { session in
                            SessionRow(session: session)
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
            Text("セッション")
                .font(.headline)
            if !sessions.isEmpty {
                Text("\(sessions.count)")
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.white.opacity(0.15), in: Capsule())
            }
            Spacer()
            switch receiver {
            case .listening:
                EmptyView()
            case .stopped:
                Label("受信停止中", systemImage: "antenna.radiowaves.left.and.right.slash")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            case .failed(let reason):
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch installStatus {
            case .installed:
                Text("Claude Code のセッションが始まると、ここに表示されます。")
                Text("既に動いているセッションも、次のイベント（ツールの実行やプロンプト）から表示されます。")
                    .foregroundStyle(.white.opacity(0.6))
            case .outdated:
                Text("hooks の登録内容が古くなっています。")
                Text("メニューバーのアイコン →「hooks をインストール…」で更新してください。")
                    .foregroundStyle(.white.opacity(0.6))
            case .notInstalled, nil:
                Text("まだ hooks がインストールされていません。")
                Text("メニューバーのアイコン →「hooks をインストール…」から登録すると、Claude Code のセッションが表示されます。")
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SessionRow: View {
    let session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                StatusBadge(status: session.status)
                Text(session.displayName)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            if let line = activityLine {
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                    .padding(.leading, 14)
            }
            ForEach(session.subagents) { subagent in
                SubagentRow(subagent: subagent)
                    .padding(.leading, 14)
            }
        }
    }

    private var details: String {
        var parts: [String] = []
        if let model = session.model { parts.append(model) }
        if let terminal = session.terminal { parts.append(terminal) }
        parts.append(session.lastEventAt.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))
        return parts.joined(separator: " · ")
    }

    /// 状態に応じて、いちばん知りたい 1 行を出す。
    private var activityLine: String? {
        switch session.status {
        case .waitingForApproval:
            if let pending = session.pendingPermission {
                return "承認待ち: " + [pending.toolName, pending.summary].compactMap { $0 }.joined(separator: " ")
            }
            return nil
        case .working:
            if let tool = session.recentTools.last(where: { $0.agentID == nil }) {
                return Self.describe(tool)
            }
            return session.lastPrompt.map { "指示: \($0)" }
        case .done:
            return session.lastAssistantMessage.flatMap { ToolSummary.oneLine($0) }
        case .error:
            return session.lastError.map { "エラー: \($0)" }
        case .waitingForInput, .stalled:
            return session.lastPrompt.map { "指示: \($0)" }
        }
    }

    static func describe(_ tool: ToolActivity) -> String {
        let mark = switch tool.status {
        case .running: "▸"
        case .succeeded: "✓"
        case .failed: "✗"
        case .interrupted: "–"
        }
        return [mark, tool.toolName, tool.summary].compactMap { $0 }.joined(separator: " ")
    }
}

private struct SubagentRow: View {
    let subagent: Subagent

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.turn.down.right")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.4))
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(subagent.type)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
        }
    }

    private var color: Color {
        switch subagent.status {
        case .running: .blue
        case .done: .green
        case .stalled: .gray
        }
    }

    private var detail: String {
        switch subagent.status {
        case .running:
            subagent.currentTool.map(SessionRow.describe) ?? "実行中"
        case .done:
            subagent.lastAssistantMessage.flatMap { ToolSummary.oneLine($0) } ?? "完了"
        case .stalled:
            "停止"
        }
    }
}

private struct StatusBadge: View {
    let status: SessionStatus

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(status.displayName)
                .font(.caption2.weight(.medium))
                .foregroundStyle(color)
        }
        .frame(minWidth: 58, alignment: .leading)
    }

    private var color: Color {
        switch status {
        case .working: .blue
        case .waitingForApproval: .orange
        case .waitingForInput: .white.opacity(0.7)
        case .done: .green
        case .error: .red
        case .stalled: .gray
        }
    }
}
