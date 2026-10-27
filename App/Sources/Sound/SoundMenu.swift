import AgentKit
import SwiftUI

/// メニューバーのおやすみモード（F0-8）。すぐ切り替えたいのでメニューに残し、ほかの音の設定は設定画面（`SettingsView`）に移した。
struct SoundMenu: View {
    let sound: SoundPlayer

    var body: some View {
        quietMenu(sound.settings)
            .disabled(!sound.settings.isEnabled)
    }

    @ViewBuilder
    private func quietMenu(_ settings: SoundSettings) -> some View {
        let now = Date.now
        if settings.isQuiet(at: now), let until = settings.quietUntil {
            Button("おやすみモードを終える（\(until.formatted(date: .omitted, time: .shortened)) まで）") {
                sound.update { $0.quietUntil = nil }
            }
        } else {
            Menu("おやすみモード") {
                Button("1 時間") {
                    sound.update { $0.quietUntil = Date.now.addingTimeInterval(60 * 60) }
                }
                Button("明日の朝 8 時まで") {
                    sound.update { $0.quietUntil = SoundSettings.nextOccurrence(ofHour: 8, after: .now) }
                }
            }
        }
    }
}
