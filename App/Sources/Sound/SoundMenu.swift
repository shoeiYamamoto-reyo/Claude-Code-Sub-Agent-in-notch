import AgentKit
import SwiftUI

/// メニューバーの「サウンド」メニュー。設定画面ができるまでの置き場所（M5 で設定画面に移す）。
struct SoundMenu: View {
    let sound: SoundPlayer

    var body: some View {
        let settings = sound.settings
        Menu("サウンド") {
            Toggle("音を鳴らす", isOn: binding(\.isEnabled))
            Picker("音量", selection: binding(\.volume)) {
                ForEach(SoundSettings.Volume.allCases, id: \.self) { volume in
                    Text(volume.displayName).tag(volume)
                }
            }
            .disabled(!settings.isEnabled)
            Toggle("ノッチの開閉の音", isOn: binding(\.playsInterfaceSounds))
                .disabled(!settings.isEnabled)
            Toggle("お知らせの音", isOn: binding(\.playsAlertSounds))
                .disabled(!settings.isEnabled)
            Divider()
            quietMenu(settings)
            Menu("音を試す") {
                ForEach(SoundCue.allCases, id: \.self) { cue in
                    Button(cue.displayName) { sound.preview(cue) }
                }
            }
        }
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

    private func binding<Value>(_ keyPath: WritableKeyPath<SoundSettings, Value>) -> Binding<Value> {
        Binding(
            get: { sound.settings[keyPath: keyPath] },
            set: { value in sound.update { $0[keyPath: keyPath] = value } }
        )
    }
}
