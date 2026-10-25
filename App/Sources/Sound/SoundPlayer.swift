import AgentKit
import AVFoundation
import Foundation
import Observation

/// 効果音を鳴らす。音は `SoundSynthesizer` が作った WAV をメモリから再生する（音声ファイルを持たない）。
///
/// 待機中に CPU を使わないため、オーディオエンジンを動かし続けず、音ごとの `AVAudioPlayer` を初めて鳴らすときに作る。
@MainActor
@Observable
final class SoundPlayer {
    private static let settingsKey = "soundSettings"

    private(set) var settings: SoundSettings
    @ObservationIgnored private var gate = SoundGate()
    @ObservationIgnored private var players: [SoundCue: AVAudioPlayer] = [:]

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.settingsKey),
           let saved = try? JSONDecoder().decode(SoundSettings.self, from: data) {
            settings = saved
        } else {
            settings = SoundSettings()
        }
    }

    /// 設定とおやすみモードに従って鳴らす。
    func play(_ cue: SoundCue) {
        guard gate.shouldPlay(
            cue,
            settings: settings,
            systemInterfaceSoundsEnabled: Self.systemInterfaceSoundsEnabled,
            at: .now
        ) else { return }
        start(cue)
    }

    /// 設定にかかわらず鳴らす（メニューの「音を試す」）。音量は設定に従う。
    func preview(_ cue: SoundCue) {
        start(cue)
    }

    func update(_ change: (inout SoundSettings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        settings = next
        if let data = try? JSONEncoder().encode(next) {
            UserDefaults.standard.set(data, forKey: Self.settingsKey)
        }
    }

    private func start(_ cue: SoundCue) {
        guard let player = player(for: cue) else { return }
        player.volume = settings.volume.level
        player.currentTime = 0
        player.play()
    }

    private func player(for cue: SoundCue) -> AVAudioPlayer? {
        if let player = players[cue] { return player }
        guard let player = try? AVAudioPlayer(data: SoundSynthesizer.wavData(for: cue)) else { return nil }
        player.prepareToPlay()
        players[cue] = player
        return player
    }

    /// システム設定 › サウンド の「ユーザインターフェイスのサウンドエフェクトを再生」。未設定ならオン。
    private static var systemInterfaceSoundsEnabled: Bool {
        let value = CFPreferencesCopyAppValue(
            "com.apple.sound.uiaudio.enabled" as CFString,
            "com.apple.systemsound" as CFString
        )
        return (value as? NSNumber)?.boolValue ?? true
    }
}
