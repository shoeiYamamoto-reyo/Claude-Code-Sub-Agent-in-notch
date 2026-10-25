import Foundation
#if canImport(CoreGraphics)
// macOS では CGRect の minX や init(x:y:width:height:) などが CoreGraphics 側にある。
import CoreGraphics
#endif

/// キャラクターの状態（F0-3）。表情は目の形だけで表す。
public enum CharacterMood: String, Sendable, Equatable, CaseIterable, Codable {
    case idle
    case working
    case waiting
    case done
    case error

    /// メニューなどに出す名前。
    public var displayName: String {
        switch self {
        case .idle: "待機中"
        case .working: "作業中"
        case .waiting: "承認待ち"
        case .done: "完了"
        case .error: "エラー"
        }
    }
}

/// 輪郭を組み立てる 1 区間（SVG の M / L / C に相当）。
public enum PathSegment: Sendable, Equatable {
    case move(to: CGPoint)
    case line(to: CGPoint)
    case curve(to: CGPoint, control1: CGPoint, control2: CGPoint)
}

/// `docs/design/character.md` の数値。単位は viewBox（140 × 100、y は下向き）。
public enum CharacterSpec {
    public static let viewBoxWidth: CGFloat = 140
    public static let viewBoxHeight: CGFloat = 100

    /// 体の輪郭。SVG の `M70 22 C98 22 114 36 120 56 C126 76 124 86 108 88 L32 88 C16 86 14 76 20 56 C26 36 42 22 70 22 Z`。
    /// アプリ側でこの順に `Path` を組み立て、最後に閉じる。
    public static let bodySegments: [PathSegment] = [
        .move(to: CGPoint(x: 70, y: 22)),
        .curve(to: CGPoint(x: 120, y: 56), control1: CGPoint(x: 98, y: 22), control2: CGPoint(x: 114, y: 36)),
        .curve(to: CGPoint(x: 108, y: 88), control1: CGPoint(x: 126, y: 76), control2: CGPoint(x: 124, y: 86)),
        .line(to: CGPoint(x: 32, y: 88)),
        .curve(to: CGPoint(x: 20, y: 56), control1: CGPoint(x: 16, y: 86), control2: CGPoint(x: 14, y: 76)),
        .curve(to: CGPoint(x: 70, y: 22), control1: CGPoint(x: 26, y: 36), control2: CGPoint(x: 42, y: 22)),
    ]
    /// 体の底（伸び縮み・回転の支点）。
    public static let bodyAnchor = CGPoint(x: 70, y: 88)

    public static let leftEye = CGPoint(x: 56, y: 56)
    public static let rightEye = CGPoint(x: 84, y: 56)
    public static var eyesMidpoint: CGPoint {
        CGPoint(x: (leftEye.x + rightEye.x) / 2, y: (leftEye.y + rightEye.y) / 2)
    }

    /// 底の陰（楕円）。
    public static let shadowCenter = CGPoint(x: 70, y: 83)
    public static let shadowRadii = CGSize(width: 38, height: 4.5)

    /// 色（sRGB の 16 進）。
    public static let bodyColor: UInt32 = 0xFBFAF6
    public static let shadowColor: UInt32 = 0xE6E1D8
    public static let eyeColor: UInt32 = 0x2B2230

    public static let idleEyeRadius: CGFloat = 5
    public static let waitingEyeRadius: CGFloat = 7.5
    /// 作業中・完了・エラーの線の太さ。
    public static let eyeStrokeWidth: CGFloat = 3.5
    /// 作業中の「— —」の横幅の半分（x 49–63, 77–91）。
    public static let workingLineHalfWidth: CGFloat = 7
}

/// 目全体の平行移動量（viewBox 単位、y は下向き）。
/// Linux の Foundation には `CGVector` が無いので自前で持つ。
public struct EyeOffset: Sendable, Equatable {
    public var dx: CGFloat
    public var dy: CGFloat

    public static let zero = EyeOffset(dx: 0, dy: 0)

    public init(dx: CGFloat, dy: CGFloat) {
        self.dx = dx
        self.dy = dy
    }
}

/// 待機中の目の追従（F0-7）。
public enum EyeTracking {
    /// 移動量が最大になる距離（pt）。
    public static let fullDistance: CGFloat = 220
    public static let maxHorizontal: CGFloat = 10
    public static let maxUp: CGFloat = 4
    public static let maxDown: CGFloat = 12
    /// これより小さい変化では描き直さない（viewBox 単位）。
    public static let redrawThreshold: CGFloat = 0.25

    /// 目全体の平行移動量（viewBox 単位、y は下向き）。
    /// - Parameters:
    ///   - eyeCenter: 両目の中点（グローバル座標、y は上向き）。
    ///   - cursor: カーソル位置（グローバル座標、y は上向き）。
    public static func offset(eyeCenter: CGPoint, cursor: CGPoint) -> EyeOffset {
        let dx = cursor.x - eyeCenter.x
        let dyDown = eyeCenter.y - cursor.y
        let distance = (dx * dx + dyDown * dyDown).squareRoot()
        guard distance > 0.001 else { return .zero }
        let strength = min(distance / fullDistance, 1)
        let unitX = dx / distance
        let unitY = dyDown / distance
        let x = unitX * strength * maxHorizontal
        let y = unitY * strength * (unitY < 0 ? maxUp : maxDown)
        return EyeOffset(dx: x, dy: y)
    }

    /// 前回の移動量から描き直す必要があるほど変わったか。
    public static func needsRedraw(from old: EyeOffset, to new: EyeOffset) -> Bool {
        abs(old.dx - new.dx) >= redrawThreshold || abs(old.dy - new.dy) >= redrawThreshold
    }
}

/// ある時刻の体の姿勢。`bodyAnchor` を支点に、拡大 → 回転 → 平行移動の順にかける。
public struct CharacterPose: Sendable, Equatable {
    public var scaleX: CGFloat
    public var scaleY: CGFloat
    /// 上下の移動（viewBox 単位、負で上）。
    public var offsetY: CGFloat
    public var rotationDegrees: CGFloat
    /// 目の開き具合（1 = 開いている、まばたき中は小さくなる）。
    public var eyeOpenness: CGFloat

    public static let neutral = CharacterPose(scaleX: 1, scaleY: 1, offsetY: 0, rotationDegrees: 0, eyeOpenness: 1)

    public init(scaleX: CGFloat, scaleY: CGFloat, offsetY: CGFloat, rotationDegrees: CGFloat, eyeOpenness: CGFloat) {
        self.scaleX = scaleX
        self.scaleY = scaleY
        self.offsetY = offsetY
        self.rotationDegrees = rotationDegrees
        self.eyeOpenness = eyeOpenness
    }
}

/// 状態ごとの動き（`docs/design/character.md` の表）。時刻の関数にして、描画頻度とは切り離す。
public enum CharacterAnimation {
    public static let breathingPeriod: TimeInterval = 3.6
    public static let blinkInterval: TimeInterval = 4.5
    public static let blinkDuration: TimeInterval = 0.18
    public static let workingPeriod: TimeInterval = 0.7
    public static let hopPeriod: TimeInterval = 1.2
    public static let swayPeriod: TimeInterval = 1.6

    /// 描き直す間隔（秒）。nil は動かない（状態が変わったときと目の追従のときだけ描く）。
    /// 待機中は常時表示なので頻度を下げ、CPU をほぼ使わないようにする。
    public static func frameInterval(for mood: CharacterMood) -> TimeInterval? {
        switch mood {
        case .idle: 1.0 / 12
        case .working, .waiting, .done: 1.0 / 30
        case .error: nil
        }
    }

    /// 時刻 `time`（秒、基準は任意）の姿勢。`reduceMotion` なら動きを止めた姿勢を返す。
    public static func pose(for mood: CharacterMood, at time: TimeInterval, reduceMotion: Bool = false) -> CharacterPose {
        var pose = CharacterPose.neutral
        if mood == .error {
            // ぺしゃっと潰れたまま（動きではなく形なので、視差を減らす設定でもそのまま）。
            pose.scaleX = 1.06
            pose.scaleY = 0.9
            return pose
        }
        if reduceMotion { return pose }
        switch mood {
        case .idle:
            let s = wave(time, period: breathingPeriod)
            pose.scaleX = 1 + 0.04 * s
            pose.scaleY = 1 - 0.05 * s
            pose.eyeOpenness = blinkOpenness(at: time)
        case .working:
            pose.offsetY = -2 * wave(time, period: workingPeriod)
        case .waiting:
            let phase = fraction(time, period: hopPeriod)
            // 周期の前半 40 % で跳ねて、残りは着地している。
            if phase < 0.4 {
                pose.offsetY = -10 * CGFloat(sin(Double.pi * phase / 0.4))
            }
        case .done:
            pose.rotationDegrees = 3 * CGFloat(sin(2 * Double.pi * fraction(time, period: swayPeriod)))
        case .error:
            break
        }
        return pose
    }

    /// まばたき中は目を細くする。
    public static func blinkOpenness(at time: TimeInterval) -> CGFloat {
        let t = fraction(time, period: blinkInterval) * blinkInterval
        guard t < blinkDuration else { return 1 }
        // 閉じて開く（0.15 まで細くなる）。
        let closing = CGFloat(sin(Double.pi * t / blinkDuration))
        return 1 - 0.85 * closing
    }

    /// 0 → 1 → 0 と滑らかに往復する値。
    static func wave(_ time: TimeInterval, period: TimeInterval) -> CGFloat {
        CGFloat((1 - cos(2 * Double.pi * fraction(time, period: period))) / 2)
    }

    /// 周期の中での位置（0 以上 1 未満）。
    static func fraction(_ time: TimeInterval, period: TimeInterval) -> Double {
        let value = (time / period).truncatingRemainder(dividingBy: 1)
        return value < 0 ? value + 1 : value
    }
}
