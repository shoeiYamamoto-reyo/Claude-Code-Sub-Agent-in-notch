import Foundation

/// 効果音の設定。アプリは JSON にして UserDefaults に保存する。
public struct SoundSettings: Sendable, Equatable, Codable {
    /// 音量の段階。`AVAudioPlayer.volume` に渡す値を持つ（システムの音量に対する割合）。
    public enum Volume: String, Sendable, Equatable, CaseIterable, Codable {
        case low
        case medium
        case high

        public var level: Float {
            switch self {
            case .low: 0.3
            case .medium: 0.6
            case .high: 1.0
            }
        }

        public var displayName: String {
            switch self {
            case .low: "小"
            case .medium: "中"
            case .high: "大"
            }
        }
    }

    /// すべての音のオン／オフ。
    public var isEnabled: Bool
    public var volume: Volume
    /// 開閉の音（`SoundCue.Category.interface`）。
    public var playsInterfaceSounds: Bool
    /// お知らせ・承認待ち・完了・エラーの音（`SoundCue.Category.alert`）。
    public var playsAlertSounds: Bool
    /// おやすみモードの終わる時刻。これより前は音を鳴らさない（表示は変わらない）。nil ならオフ。
    public var quietUntil: Date?

    public init(
        isEnabled: Bool = true,
        volume: Volume = .medium,
        playsInterfaceSounds: Bool = true,
        playsAlertSounds: Bool = true,
        quietUntil: Date? = nil
    ) {
        self.isEnabled = isEnabled
        self.volume = volume
        self.playsInterfaceSounds = playsInterfaceSounds
        self.playsAlertSounds = playsAlertSounds
        self.quietUntil = quietUntil
    }

    /// `now` の時点でおやすみモード中か。
    public func isQuiet(at now: Date) -> Bool {
        guard let quietUntil else { return false }
        return now < quietUntil
    }

    /// 分類ごとのオン／オフ。
    public func plays(_ category: SoundCue.Category) -> Bool {
        switch category {
        case .interface: playsInterfaceSounds
        case .alert: playsAlertSounds
        }
    }

    /// 次の `hour` 時ちょうど（`now` より後）。おやすみモードの「明日の朝まで」に使う。
    public static func nextOccurrence(ofHour hour: Int, after now: Date, calendar: Calendar = .current) -> Date {
        calendar.nextDate(
            after: now,
            matching: DateComponents(hour: hour, minute: 0, second: 0),
            matchingPolicy: .nextTime
        ) ?? now.addingTimeInterval(12 * 60 * 60)
    }
}

/// 音を鳴らしてよいかを決める。設定、おやすみモード、macOS の設定、連打の間引きを見る。
///
/// 時計を持たないので、呼び出し側が今の時刻を渡す（テストできるように）。
public struct SoundGate: Sendable, Equatable {
    /// 同じ音を続けて鳴らすときの最短間隔。ホバーの出入りが速いときに開閉の音が重ならないようにする。
    public var minimumInterval: TimeInterval
    private var lastPlayed: [SoundCue: Date] = [:]

    public init(minimumInterval: TimeInterval = 0.25) {
        self.minimumInterval = minimumInterval
    }

    /// 鳴らしてよいかを返す。よい場合は鳴らした時刻として記録する。
    ///
    /// - Parameter systemInterfaceSoundsEnabled: macOS の「ユーザインターフェイスのサウンドエフェクトを再生」。
    ///   オフなら開閉の音（`interface`）を鳴らさない。お知らせの音には影響しない。
    public mutating func shouldPlay(
        _ cue: SoundCue,
        settings: SoundSettings,
        systemInterfaceSoundsEnabled: Bool,
        at now: Date
    ) -> Bool {
        guard settings.isEnabled,
              !settings.isQuiet(at: now),
              settings.plays(cue.category)
        else { return false }
        if cue.category == .interface && !systemInterfaceSoundsEnabled { return false }
        if let last = lastPlayed[cue], now.timeIntervalSince(last) < minimumInterval, now >= last {
            return false
        }
        lastPlayed[cue] = now
        return true
    }
}
