import AgentKit
import Observation

/// ノッチの表示に必要な状態。変更は `NotchPanelController` だけが行い、ビューは読むだけ。
@MainActor
@Observable
final class NotchModel {
    /// 表示している画面に合わせた寸法。画面が無いときは nil。
    var layout: NotchLayout?
    var presentation: NotchPresentationState = .character
    var mood: CharacterMood = .idle
    /// 待機中の目の移動量（viewBox 単位）。待機中以外は常に `.zero`。
    var eyeOffset: EyeOffset = .zero
    /// `peek` に出す文。nil なら知らせることは無い。
    var noticeText: String?
    var displayChoice: DisplayChoice = .automatic
}
