import AgentKit
import SwiftUI

/// 承認・質問のカード（ROADMAP 2-2、2-3）。キューの先頭だけを出し、押されたボタンはこのカードの要求 ID に答える。
///
/// 守ること（F4-2）: 答えはボタンを押したときだけ作る。カードが出ただけ・時間が経っただけでは何も返さない。
struct ApprovalCardView: View {
    let request: ApprovalRequest
    let sessionName: String
    let queueCount: Int
    let onReply: (HookReply) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            switch request.kind {
            case .permission(let toolName, _, let detail, let alwaysAllow):
                PermissionBody(toolName: toolName, detail: detail, alwaysAllow: alwaysAllow, onReply: onReply)
            case .question(let questions):
                QuestionBody(questions: questions, onReply: onReply)
            }
        }
        .padding(12)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.orange.opacity(0.5), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: request.isQuestion ? "questionmark.bubble" : "hand.raised")
                .foregroundStyle(.orange)
            Text(request.isQuestion ? "質問" : "承認待ち")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            Text(sessionName)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            if let agentType = request.agentType {
                Text("· \(agentType)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if queueCount > 1 {
                Text("ほか \(queueCount - 1) 件")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.white.opacity(0.15), in: Capsule())
            }
        }
    }
}

private struct PermissionBody: View {
    let toolName: String
    let detail: String?
    let alwaysAllow: String?
    let onReply: (HookReply) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(toolName)
                .font(.callout.weight(.semibold))
            if let detail {
                ScrollView(.vertical) {
                    Text(detail)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 54)
                .padding(6)
                .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            }
            HStack(spacing: 8) {
                Button { onReply(ApprovalShortcut.terminal.reply) } label: {
                    ShortcutLabel(title: "ターミナルで答える", shortcut: .terminal)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
                .help("ノッチでは答えず、Claude Code の通常の確認に任せます")
                Spacer()
                Button { onReply(ApprovalShortcut.deny.reply) } label: {
                    ShortcutLabel(title: "拒否", shortcut: .deny)
                }
                .buttonStyle(CardButtonStyle(tint: .red))
                if let alwaysAllow {
                    Button { onReply(ApprovalShortcut.alwaysAllow.reply) } label: {
                        ShortcutLabel(title: "常に許可", shortcut: .alwaysAllow)
                    }
                    .buttonStyle(CardButtonStyle(tint: .blue))
                    .help("許可し、今後も確認しないようにします: \(alwaysAllow)")
                }
                Button { onReply(ApprovalShortcut.allow.reply) } label: {
                    ShortcutLabel(title: "許可", shortcut: .allow)
                }
                .buttonStyle(CardButtonStyle(tint: .green, prominent: true))
            }
            if let alwaysAllow {
                Text("常に許可: \(alwaysAllow)")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(2)
            }
        }
    }
}

private struct QuestionBody: View {
    let questions: [AskQuestion]
    let onReply: (HookReply) -> Void
    /// 質問文 → 選んだラベル（選んだ順）。
    @State private var selections: [String: [String]] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(questions, id: \.question) { question in
                        questionView(question)
                    }
                }
            }
            .frame(maxHeight: 150)
            HStack(spacing: 8) {
                Button("ターミナルで答える") { onReply(.pass) }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                Button("回答する") {
                    onReply(HookReply(decision: .answer, answers: answers))
                }
                .buttonStyle(CardButtonStyle(tint: .green, prominent: true))
                .disabled(!isComplete)
            }
        }
    }

    private func questionView(_ question: AskQuestion) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let header = question.header, !header.isEmpty {
                    Text(header)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.white.opacity(0.15), in: Capsule())
                }
                Text(question.question)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if question.multiSelect {
                    Text("（複数選択可）")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            ForEach(question.options, id: \.label) { option in
                let selected = selections[question.question, default: []].contains(option.label)
                Button {
                    toggle(option.label, in: question)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: icon(selected: selected, multi: question.multiSelect))
                            .foregroundStyle(selected ? .green : .white.opacity(0.5))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(option.label).font(.callout)
                            if let description = option.description, !description.isEmpty {
                                Text(description)
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.6))
                                    .lineLimit(2)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func icon(selected: Bool, multi: Bool) -> String {
        switch (multi, selected) {
        case (true, true): "checkmark.square.fill"
        case (true, false): "square"
        case (false, true): "largecircle.fill.circle"
        case (false, false): "circle"
        }
    }

    private func toggle(_ label: String, in question: AskQuestion) {
        var chosen = selections[question.question, default: []]
        if question.multiSelect {
            if let index = chosen.firstIndex(of: label) {
                chosen.remove(at: index)
            } else {
                chosen.append(label)
            }
        } else {
            chosen = chosen == [label] ? [] : [label]
        }
        selections[question.question] = chosen
    }

    private var isComplete: Bool {
        questions.allSatisfy { !(selections[$0.question] ?? []).isEmpty }
    }

    /// 選択肢の並び順で回答を作る。
    private var answers: [String: String] {
        var result: [String: String] = [:]
        for question in questions {
            let chosen = selections[question.question] ?? []
            let ordered = question.options.map(\.label).filter(chosen.contains)
            result[question.question] = AskQuestion.answerText(for: ordered)
        }
        return result
    }
}

/// ボタンの名前に、グローバルなショートカット（`ApprovalHotKeys`）を小さく添える。
private struct ShortcutLabel: View {
    let title: String
    let shortcut: ApprovalShortcut

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            Text(shortcut.label)
                .font(.caption2.weight(.regular))
                .opacity(0.6)
        }
    }
}

struct CardButtonStyle: ButtonStyle {
    let tint: Color
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .foregroundStyle(prominent ? .black : tint)
            .background(
                prominent ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(0.18)),
                in: Capsule()
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.35)
    }
}
