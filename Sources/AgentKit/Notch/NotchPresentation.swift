import Foundation

/// ノッチの表示状態（ARCHITECTURE「NotchAgent.app」）。
public enum NotchPresentationState: String, Sendable, Equatable, CaseIterable {
    /// キャラクターだけ。パネルはほぼクリック透過。
    case character
    /// 承認待ちなどを知らせる小さな吹き出し。
    case peek
    /// ホバー中の展開表示。
    case expanded
}

/// ホバーと通知から表示状態を決める状態機械。AppKit にも時計にも依存しない。
///
/// 遅延はアプリ側が `nextDeadline` でワンショットのタイマーを張り、時間が来たら `tick(at:)` を呼ぶ。
/// 常時動くタイマーは持たない（待機中の CPU 0 % のため）。
public struct NotchPresentationMachine: Sendable, Equatable {
    public struct Configuration: Sendable, Equatable {
        /// マウスが乗ってから展開するまで。通りすがりで開かないようにする。
        public var expandDelay: TimeInterval
        /// マウスが離れてから縮むまで。
        public var collapseDelay: TimeInterval

        public init(expandDelay: TimeInterval = 0.12, collapseDelay: TimeInterval = 0.6) {
            self.expandDelay = expandDelay
            self.collapseDelay = collapseDelay
        }
    }

    public let configuration: Configuration
    public private(set) var state: NotchPresentationState = .character
    /// マウスがホバー領域の中にあるか。
    public private(set) var isHovering = false
    /// 知らせることがあるか（ある間、縮んだときは `peek` になる）。
    public private(set) var hasNotice = false
    /// 入力中などで、マウスが離れても展開したままにしているか。
    public private(set) var isPinned = false
    /// 次に `tick(at:)` を呼ぶべき時刻。nil ならタイマー不要。
    public private(set) var nextDeadline: Date?
    private var pendingState: NotchPresentationState?

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// 展開していないときの状態。
    public var restingState: NotchPresentationState { hasNotice ? .peek : .character }

    public mutating func mouseEntered(at now: Date) {
        guard !isHovering else { return }
        isHovering = true
        if state == .expanded {
            cancelPending()
        } else {
            schedule(.expanded, after: configuration.expandDelay, from: now)
        }
    }

    public mutating func mouseExited(at now: Date) {
        guard isHovering else { return }
        isHovering = false
        if isPinned {
            cancelPending()
        } else if state == .expanded {
            schedule(restingState, after: configuration.collapseDelay, from: now)
        } else {
            cancelPending()
        }
    }

    /// 通知の有無を切り替える。展開中なら、縮んだあとの状態だけが変わる。
    public mutating func setNotice(_ active: Bool, at now: Date) {
        hasNotice = active
        if state != .expanded {
            state = restingState
        } else if pendingState != nil && pendingState != .expanded {
            pendingState = restingState
        }
    }

    /// すぐ展開し、`unpin` まで展開したままにする（クイック入力、ROADMAP 3-5）。
    public mutating func pin() {
        isPinned = true
        cancelPending()
        state = .expanded
    }

    /// 展開したままにするのをやめる。マウスが外にあれば、少し待って縮む。
    public mutating func unpin(at now: Date) {
        guard isPinned else { return }
        isPinned = false
        if state == .expanded && !isHovering {
            schedule(restingState, after: configuration.collapseDelay, from: now)
        }
    }

    /// 展開中にすぐ縮める（Esc キーなど）。留めていても縮める。
    public mutating func collapse() {
        isPinned = false
        cancelPending()
        state = restingState
    }

    /// `nextDeadline` を過ぎていれば予定の状態に移る。早すぎる呼び出しは無視する。
    public mutating func tick(at now: Date) {
        guard let deadline = nextDeadline, let target = pendingState, now >= deadline else { return }
        cancelPending()
        state = target
    }

    private mutating func schedule(_ target: NotchPresentationState, after delay: TimeInterval, from now: Date) {
        if delay <= 0 {
            cancelPending()
            state = target
            return
        }
        pendingState = target
        nextDeadline = now.addingTimeInterval(delay)
    }

    private mutating func cancelPending() {
        pendingState = nil
        nextDeadline = nil
    }
}
