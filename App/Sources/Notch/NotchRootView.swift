import AgentKit
import SwiftUI

/// パネル全体。上端中央に島を置き、キャラクターは状態にかかわらず同じ場所に描く。
struct NotchRootView: View {
    let model: NotchModel
    let sound: SoundPlayer

    var body: some View {
        if let layout = model.layout {
            let state = model.presentation
            let size = layout.islandSize(for: state, editing: model.agentEdit != nil)
            ZStack(alignment: .top) {
                UnevenRoundedRectangle(
                    bottomLeadingRadius: cornerRadius(for: state),
                    bottomTrailingRadius: cornerRadius(for: state),
                    style: .continuous
                )
                .fill(.black)
                .frame(width: size.width, height: size.height)
                .overlay(alignment: .top) {
                    IslandContent(model: model, sound: sound, state: state, barHeight: layout.barHeight)
                        .frame(width: size.width, height: size.height, alignment: .top)
                        .clipped()
                }

                CharacterView(mood: model.mood, eyeMotion: model.eyeMotion)
                    .frame(width: layout.characterSize.width, height: layout.characterSize.height)
                    .offset(x: layout.characterOffsetX)
            }
            .frame(width: layout.panelSize.width, height: layout.panelSize.height, alignment: .top)
            .animation(.spring(duration: 0.32, bounce: 0.15), value: state)
        }
    }

    private func cornerRadius(for state: NotchPresentationState) -> CGFloat {
        switch state {
        case .character: 10
        case .peek: 14
        case .expanded: 22
        }
    }
}

/// 島の中身。キャラクターの行（ノッチの高さ）より下に置く。
private struct IslandContent: View {
    let model: NotchModel
    let sound: SoundPlayer
    let state: NotchPresentationState
    let barHeight: CGFloat
    /// 縮んでも覚えておき、次に展開したときも同じタブを出す。
    @State private var tab: ExpandedTab = .sessions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch state {
            case .character:
                EmptyView()
            case .peek:
                Text(model.noticeText ?? "")
                    .font(.callout)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
            case .expanded:
                if let request = model.approvals.first {
                    ApprovalCardView(
                        request: request,
                        sessionName: sessionName(for: request),
                        queueCount: model.approvals.count,
                        onReply: { reply in model.onApprovalReply?(request.id, reply) }
                    )
                    // 要求が変わったら選択状態などを作り直す。
                    .id(request.id)
                } else if let noticeText = model.noticeText {
                    Label(noticeText, systemImage: "bell")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
                if let session = model.agentEdit {
                    // 定義の編集はノッチの中で完結させる（ROADMAP 4-4）。承認カードは上に出したまま、編集内容は残す。
                    AgentEditorView(
                        session: session,
                        plan: { model.onPlanAgentSave?($0) },
                        onSave: { model.onSaveAgent?($0) },
                        onClose: { model.onCloseAgentEdit?() }
                    )
                    .id(session.id)
                } else {
                    tabs
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.top, barHeight + (state == .expanded ? 14 : 6))
        .padding(.bottom, 12)
        .transition(.opacity)
    }

    /// 入力欄とタブ（定義を編集していないとき）。
    @ViewBuilder
    private var tabs: some View {
        // 承認カードが出ている間は場所を譲る（入力中は出したまま）。
        if model.isQuickInputActive || (model.approvals.isEmpty && !model.projects.projects.isEmpty && model.projectLoadError == nil) {
            QuickTaskBar(model: model)
        }
        ExpandedTabBar(selection: $tab, sound: sound, onOpenSettings: { model.onOpenSettings?() })
        switch tab {
        case .sessions:
            if !model.tasks.isEmpty {
                TaskRunListView(
                    tasks: model.tasks,
                    onStop: { model.onStopTask?($0) },
                    onShow: { model.onShowTask?($0) }
                )
            }
            SessionListView(
                sessions: model.sessions,
                projects: model.projects,
                receiver: model.receiver,
                installStatus: model.hookInstallStatus,
                onInstallHooks: { model.onInstallHooks?() },
                onRegisterFolder: { model.onRegisterFolder?($0) }
            )
        case .projects:
            ProjectListView(
                registry: model.projects,
                sessions: model.sessions,
                loadError: model.projectLoadError,
                onAdd: { model.onAddProject?() },
                onEdit: { model.onEditProject?($0) },
                onStartTask: { model.onStartTask?($0) }
            )
        case .agents:
            AgentListView(
                overview: model.agentOverview,
                history: model.taskHistory,
                onRefresh: { model.onRefreshAgents?() },
                onEdit: { model.onEditAgent?($0, $1) },
                onNew: { model.onNewAgent?($0, $1) }
            )
            // 登録・編集・削除したプロジェクトの定義を出し直す。
            .onChange(of: model.projects) { model.onRefreshAgents?() }
        case .history:
            TaskHistoryListView(
                history: model.taskHistory,
                error: model.taskHistoryError,
                onShow: { model.onShowHistoryEntry?($0) }
            )
        }
    }

    private func sessionName(for request: ApprovalRequest) -> String {
        if let session = model.sessions.first(where: { $0.id == request.sessionID }) {
            return session.displayName
        }
        return request.cwd.map { ($0 as NSString).lastPathComponent } ?? "Claude Code"
    }
}

enum ExpandedTab: CaseIterable {
    case sessions
    case projects
    case agents
    case history

    var title: String {
        switch self {
        case .sessions: "セッション"
        case .projects: "プロジェクト"
        case .agents: "エージェント"
        case .history: "履歴"
        }
    }
}

/// 展開時のタブの切り替え。パネルはキー入力を受けないので、クリックだけで切り替える。
/// 右端にはおやすみモードと設定のボタンを置く（ROADMAP 5-10。メニューバーのアイコンがノッチに隠れても届くように）。
private struct ExpandedTabBar: View {
    @Binding var selection: ExpandedTab
    let sound: SoundPlayer
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ExpandedTab.allCases, id: \.self) { tab in
                Button {
                    selection = tab
                } label: {
                    Text(tab.title)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .foregroundStyle(selection == tab ? .black : .white.opacity(0.75))
                        .background(selection == tab ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.1)), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 8)
            quietButton
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 24, height: 20)
                    .background(.white.opacity(0.1), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("設定…")
        }
    }

    /// 押すたびに 1 時間のおやすみモードを始める・終える。ほかの長さはメニューバーのメニューから選ぶ。
    private var quietButton: some View {
        let quietUntil = sound.settings.isQuiet(at: .now) ? sound.settings.quietUntil : nil
        return Button {
            sound.update { $0.quietUntil = quietUntil == nil ? Date.now.addingTimeInterval(60 * 60) : nil }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: quietUntil == nil ? "moon" : "moon.fill")
                if let quietUntil {
                    Text(quietUntil.formatted(date: .omitted, time: .shortened))
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(quietUntil == nil ? .white.opacity(0.75) : .black)
            .padding(.horizontal, 7)
            .frame(minWidth: 24, minHeight: 20)
            .background(quietUntil == nil ? AnyShapeStyle(.white.opacity(0.1)) : AnyShapeStyle(.yellow), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(quietUntil.map { "おやすみモードを終える（\($0.formatted(date: .omitted, time: .shortened)) まで）" } ?? "おやすみモード（1 時間、音を止める）")
    }
}
