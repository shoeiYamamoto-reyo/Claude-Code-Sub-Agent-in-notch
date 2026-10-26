import Foundation
#if canImport(CoreGraphics)
// macOS では CGRect の minX や init(x:y:width:height:) などが CoreGraphics 側にある。
import CoreGraphics
#endif

/// ノッチ周りの寸法。島（ノッチから広がる黒い領域）とキャラクターとパネルの位置を決める。
///
/// - 島はノッチの中心を軸に左右対称に広がり、上端は画面の上端に付く。
/// - ノッチのある画面では、ノッチの左右に「翼」を足し、左の翼にキャラクターを置く。
///   ノッチの中は画素が無いので、キャラクターをノッチの中に描いても見えない。
/// - ノッチの無い画面では、画面上部中央の小さな島の真ん中にキャラクターを置く。
/// - キャラクターはどの状態でも同じ場所に居る（展開しても動かない）。
public struct NotchLayout: Sendable, Equatable {
    public var geometry: NotchGeometry

    /// キャラクターの viewBox（`docs/design/character.md`）の縦横比。
    public static let characterAspectRatio: CGFloat = CharacterSpec.viewBoxWidth / CharacterSpec.viewBoxHeight
    /// 翼の中でキャラクターの左右に空ける余白。
    public static let wingPadding: CGFloat = 6
    /// ホバー判定を島より広げる量（ノッチのある画面のみ）。
    public static let hoverMargin: CGFloat = 6
    /// `peek` で島の下に足す高さ。
    public static let peekExtraHeight: CGFloat = 34
    public static let peekMinimumWidth: CGFloat = 320
    public static let expandedMinimumSize = CGSize(width: 560, height: 380)
    /// パネルを島より大きく取る余白（アニメーションの行き過ぎで切れないように）。
    public static let panelMargin: CGFloat = 24

    public init(geometry: NotchGeometry) {
        self.geometry = geometry
    }

    public var barHeight: CGFloat { geometry.notchRect.height }

    /// キャラクターを描く矩形の大きさ。高さはノッチ（メニューバー）と同じ。
    public var characterSize: CGSize {
        CGSize(width: barHeight * Self.characterAspectRatio, height: barHeight)
    }

    public var wingWidth: CGFloat { characterSize.width + Self.wingPadding * 2 }

    public func islandSize(for state: NotchPresentationState) -> CGSize {
        let collapsedWidth = geometry.hasNotch
            ? geometry.notchRect.width + wingWidth * 2
            : wingWidth
        switch state {
        case .character:
            return CGSize(width: collapsedWidth, height: barHeight)
        case .peek:
            return CGSize(
                width: max(collapsedWidth, Self.peekMinimumWidth),
                height: barHeight + Self.peekExtraHeight
            )
        case .expanded:
            return CGSize(
                width: max(collapsedWidth + 32, Self.expandedMinimumSize.width),
                height: max(barHeight + 120, Self.expandedMinimumSize.height)
            )
        }
    }

    /// パネル（NSPanel）の大きさ。どの状態の島も入るように固定する。
    public var panelSize: CGSize {
        let sizes = NotchPresentationState.allCases.map(islandSize(for:))
        let width = sizes.map(\.width).max() ?? 0
        let height = sizes.map(\.height).max() ?? 0
        return CGSize(width: width + Self.panelMargin * 2, height: height + Self.panelMargin)
    }

    /// パネルのフレーム（グローバル座標）。上端は画面の上端、中心はノッチの中心。
    public var panelFrame: CGRect {
        let size = panelSize
        return CGRect(
            x: geometry.notchRect.midX - size.width / 2,
            y: geometry.screenFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// 島の矩形（グローバル座標）。
    public func islandFrame(for state: NotchPresentationState) -> CGRect {
        let size = islandSize(for: state)
        return CGRect(
            x: geometry.notchRect.midX - size.width / 2,
            y: geometry.screenFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// この矩形にマウスがある間はクリックを受け、展開する（グローバル座標）。
    /// ノッチの無い画面では、メニューバー直下のクリックを奪わないよう余白を付けない。
    public func hoverFrame(for state: NotchPresentationState) -> CGRect {
        let island = islandFrame(for: state)
        guard geometry.hasNotch else { return island }
        let margin = Self.hoverMargin
        // 上は画面の外なので、左右と下だけ広げる。
        return CGRect(
            x: island.minX - margin,
            y: island.minY - margin,
            width: island.width + margin * 2,
            height: island.height + margin
        )
    }

    /// キャラクターの中心の、ノッチ中心からの横方向のずれ（pt）。SwiftUI での配置に使う。
    public var characterOffsetX: CGFloat {
        geometry.hasNotch ? -(geometry.notchRect.width / 2 + wingWidth / 2) : 0
    }

    /// キャラクターを描く矩形（グローバル座標）。
    public var characterFrame: CGRect {
        let size = characterSize
        let centerX = geometry.notchRect.midX + characterOffsetX
        return CGRect(
            x: centerX - size.width / 2,
            y: geometry.screenFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// 両目の中点（グローバル座標）。目の追従の基準。
    public var eyeCenter: CGPoint {
        let frame = characterFrame
        let scale = frame.width / CharacterSpec.viewBoxWidth
        return CGPoint(
            x: frame.minX + CharacterSpec.eyesMidpoint.x * scale,
            y: frame.maxY - CharacterSpec.eyesMidpoint.y * scale
        )
    }

    /// 1 pt が viewBox の何単位か。
    public var viewBoxUnitsPerPoint: CGFloat {
        CharacterSpec.viewBoxWidth / characterSize.width
    }
}
