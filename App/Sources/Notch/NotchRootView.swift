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
                if let noticeText = model.noticeText {
                    Label(noticeText, systemImage: "bell")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
                SessionListView(
                    sessions: model.sessions,
                    receiver: model.receiver,
                    installStatus: model.hookInstallStatus
                )
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.top, barHeight + (state == .expanded ? 14 : 6))
        .padding(.bottom, 12)
        .transition(.opacity)
    }
}
