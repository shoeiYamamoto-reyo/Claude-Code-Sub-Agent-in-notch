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
                    IslandContent(state: state, noticeText: model.noticeText, barHeight: layout.barHeight)
                        .frame(width: size.width, height: size.height, alignment: .top)
                        .clipped()
                }

                CharacterView(mood: model.mood, eyeOffset: model.eyeOffset)
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
    let state: NotchPresentationState
    let noticeText: String?
    let barHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch state {
            case .character:
                EmptyView()
            case .peek:
                Text(noticeText ?? "")
                    .font(.callout)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
            case .expanded:
                Text("Notch Agent")
                    .font(.headline)
                if let noticeText {
                    Label(noticeText, systemImage: "bell")
                        .font(.callout)
                }
                Text("セッション一覧・承認・タスク投入はこれから追加します（M1-6 以降）。")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.6))
                Spacer(minLength: 0)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.top, barHeight + (state == .expanded ? 14 : 6))
        .padding(.bottom, 12)
        .transition(.opacity)
    }
}
