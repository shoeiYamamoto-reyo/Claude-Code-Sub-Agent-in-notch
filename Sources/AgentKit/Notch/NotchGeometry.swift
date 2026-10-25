import Foundation

/// 1 枚の画面について、ノッチの位置計算に必要な値。アプリ側で `NSScreen` から作る。
/// 座標は AppKit のグローバル座標（原点は主画面の左下、y は上向き）。
public struct ScreenMetrics: Sendable, Equatable {
    /// `NSScreen.frame`。
    public var frame: CGRect
    /// `NSScreen.visibleFrame`。メニューバーの高さを求めるのに使う。
    public var visibleFrame: CGRect
    /// `NSScreen.safeAreaInsets.top`。0 より大きければノッチがある。
    public var safeAreaTop: CGFloat
    /// `NSScreen.auxiliaryTopLeftArea` の幅（ノッチの左側でメニューバーに使える領域）。
    public var auxiliaryTopLeftWidth: CGFloat?
    /// `NSScreen.auxiliaryTopRightArea` の幅。
    public var auxiliaryTopRightWidth: CGFloat?

    public init(
        frame: CGRect,
        visibleFrame: CGRect,
        safeAreaTop: CGFloat = 0,
        auxiliaryTopLeftWidth: CGFloat? = nil,
        auxiliaryTopRightWidth: CGFloat? = nil
    ) {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.safeAreaTop = safeAreaTop
        self.auxiliaryTopLeftWidth = auxiliaryTopLeftWidth
        self.auxiliaryTopRightWidth = auxiliaryTopRightWidth
    }

    public var hasNotch: Bool { safeAreaTop > 0 }

    /// メニューバーの高さ。自動で隠す設定などで 0 になることがある。
    public var menuBarHeight: CGFloat { max(0, frame.maxY - visibleFrame.maxY) }
}

/// ノッチ（ノッチが無い画面では、画面上部中央に置く仮想のノッチ）の位置と大きさ。
public struct NotchGeometry: Sendable, Equatable {
    /// 物理的なノッチがあるか。
    public var hasNotch: Bool
    /// ノッチの矩形（グローバル座標）。ノッチが無い画面では幅 0、高さはメニューバーの高さ。
    public var notchRect: CGRect
    /// 画面の矩形。パネルがはみ出さないように使う。
    public var screenFrame: CGRect

    /// `auxiliaryTopLeftArea` などが取れなかったときのノッチの幅。
    public static let fallbackNotchWidth: CGFloat = 184
    /// ノッチが無く、メニューバーの高さも取れないときの高さ。
    public static let fallbackBarHeight: CGFloat = 24

    public init(hasNotch: Bool, notchRect: CGRect, screenFrame: CGRect) {
        self.hasNotch = hasNotch
        self.notchRect = notchRect
        self.screenFrame = screenFrame
    }

    public init(screen: ScreenMetrics) {
        let frame = screen.frame
        if screen.hasNotch {
            var width = Self.fallbackNotchWidth
            if let left = screen.auxiliaryTopLeftWidth, let right = screen.auxiliaryTopRightWidth {
                let measured = frame.width - left - right
                if measured > 0 { width = measured }
            }
            let height = screen.safeAreaTop
            self.init(
                hasNotch: true,
                notchRect: CGRect(x: frame.midX - width / 2, y: frame.maxY - height, width: width, height: height),
                screenFrame: frame
            )
        } else {
            let bar = screen.menuBarHeight
            let height = bar > 0 ? min(max(bar, 22), 32) : Self.fallbackBarHeight
            self.init(
                hasNotch: false,
                notchRect: CGRect(x: frame.midX, y: frame.maxY - height, width: 0, height: height),
                screenFrame: frame
            )
        }
    }
}

/// キャラクターを表示する画面の選び方（F0-1）。
public enum DisplayChoice: String, Sendable, CaseIterable, Codable {
    /// ノッチのある画面（内蔵ディスプレイ）。無ければメニューバーのある画面。
    case automatic
    /// メニューバーのある画面（システム設定の「メインディスプレイ」）。
    case main

    /// `screens` のうち表示に使う画面の添字。`screens[0]` がメニューバーのある画面
    /// （`NSScreen.screens` の並び）という前提。画面が無ければ nil。
    public func screenIndex(in screens: [ScreenMetrics]) -> Int? {
        guard !screens.isEmpty else { return nil }
        switch self {
        case .automatic:
            return screens.firstIndex(where: \.hasNotch) ?? 0
        case .main:
            return 0
        }
    }
}
