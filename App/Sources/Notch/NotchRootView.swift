import AgentKit
import SwiftUI

/// パネル全体。上端中央に島を置き、キャラクターは状態にかかわらず同じ場所に描く。
struct NotchRootView: View {
    let model: NotchModel

    var body: some View {
        if let layout = model.layout {
            let state = model.presentation
            let size = layout.islandSize(for: state)
            ZStack(alignment: .top) {
                UnevenRoundedRectangle(
                    bottomLeadingRadius: cornerRadius(for: state),
                    bottomTrailingRadius: cornerRadius(for: state),
                    style: .continuous
                )
                .fill(.black)
                .frame(width: size.width, height: size.height)
                .overlay(alignment: .top) {
                    IslandContent(model: model, state: state, barHeight: layout.barHeight)
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
                ExpandedTabBar(selection: $tab)
                switch tab {
                case .sessions:
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
                        onEdit: { model.onEditProject?($0) }
                    )
                case .agents:
                    AgentListView(
                        overview: model.agentOverview,
                        onRefresh: { model.onRefreshAgents?() }
                    )
                    // 登録・編集・削除したプロジェクトの定義を出し直す。
                    .onChange(of: model.projects) { model.onRefreshAgents?() }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.top, barHeight + (state == .expanded ? 14 : 6))
        .padding(.bottom, 12)
        .transition(.opacity)
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

    var title: String {
        switch self {
        case .sessions: "セッション"
        case .projects: "プロジェクト"
        case .agents: "エージェント"
        }
    }
}

/// 展開時のタブの切り替え。パネルはキー入力を受けないので、クリックだけで切り替える。
private struct ExpandedTabBar: View {
    @Binding var selection: ExpandedTab

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
        }
    }
}
