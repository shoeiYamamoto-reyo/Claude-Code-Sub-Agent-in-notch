import AgentKit
import AppKit
import SwiftUI

/// 設定画面（ROADMAP 5-1）。メニューバーの「設定…」（⌘,）で開く。
/// メニューにあったサウンドと表示する画面の設定をここに移し、ログイン時の起動を加えた。
struct SettingsView: View {
    let model: NotchModel
    let controller: NotchPanelController
    let loginItem: LoginItem
    let hookSetup: HookSetup
    let claudeSetup: ClaudeSetup

    var body: some View {
        TabView {
            GeneralSettings(model: model, controller: controller, loginItem: loginItem)
                .tabItem { Label("一般", systemImage: "gearshape") }
            SoundSettingsView(sound: controller.sound)
                .tabItem { Label("サウンド", systemImage: "speaker.wave.2") }
            ClaudeSettings(model: model, hookSetup: hookSetup, claudeSetup: claudeSetup)
                .tabItem { Label("Claude Code", systemImage: "terminal") }
        }
        .frame(width: 500, height: 440)
    }
}

private struct GeneralSettings: View {
    let model: NotchModel
    let controller: NotchPanelController
    let loginItem: LoginItem

    var body: some View {
        Form {
            Section {
                Toggle("ログイン時に起動", isOn: Binding(
                    get: { loginItem.state == .enabled || loginItem.state == .requiresApproval },
                    set: { loginItem.setEnabled($0) }
                ))
                .disabled(loginItem.state == .unavailable)
                switch loginItem.state {
                case .requiresApproval:
                    HStack {
                        Text("システム設定の「ログイン項目」で許可が必要です。")
                            .foregroundStyle(.secondary)
                        Button("開く…") { loginItem.openSystemSettings() }
                    }
                case .unavailable:
                    Text("このアプリの場所では登録できません。アプリを「アプリケーション」フォルダに入れてから試してください。")
                        .foregroundStyle(.secondary)
                case .enabled, .disabled:
                    EmptyView()
                }
                if let error = loginItem.lastError {
                    Text(error).foregroundStyle(.red)
                }
            }
            Section {
                Picker("表示する画面", selection: Binding(
                    get: { model.displayChoice },
                    set: { controller.setDisplayChoice($0) }
                )) {
                    ForEach(DisplayChoice.allCases, id: \.self) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                LabeledContent("クイック入力") {
                    Text(model.quickInputShortcut ?? "使えません（ほかのアプリが使っています）")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { loginItem.refresh() }
    }
}

private struct SoundSettingsView: View {
    let sound: SoundPlayer

    var body: some View {
        let settings = sound.settings
        Form {
            Section {
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
            }
            Section("音を試す") {
                ForEach(SoundCue.allCases, id: \.self) { cue in
                    LabeledContent(cue.displayName) {
                        Button("再生") { sound.preview(cue) }
                    }
                }
            }
            Section {
                Text("おやすみモード（一時的に音を止める）はメニューバーのメニューから使えます。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<SoundSettings, Value>) -> Binding<Value> {
        Binding(
            get: { sound.settings[keyPath: keyPath] },
            set: { value in sound.update { $0[keyPath: keyPath] = value } }
        )
    }
}

private struct ClaudeSettings: View {
    let model: NotchModel
    let hookSetup: HookSetup
    let claudeSetup: ClaudeSetup

    var body: some View {
        Form {
            Section("claude コマンド") {
                LabeledContent("場所") {
                    Text(model.claudePath ?? "見つかりません")
                        .textSelection(.enabled)
                        .foregroundStyle(model.claudePath == nil ? .red : .primary)
                }
                HStack {
                    Spacer()
                    if claudeSetup.configuredPath != nil {
                        Button("自動検出に戻す") { claudeSetup.resetConfiguredPath() }
                    }
                    Button("場所を指定…") { claudeSetup.chooseExecutable() }
                }
            }
            Section("hooks") {
                LabeledContent("状態") {
                    Text(hookStatusText)
                }
                HStack {
                    Spacer()
                    Button("アンインストール…") { hookSetup.beginUninstall() }
                        .disabled(model.hookInstallStatus == .notInstalled)
                    Button(model.hookInstallStatus == .installed ? "再インストール…" : "インストール…") {
                        hookSetup.beginInstall()
                    }
                }
                Text("書き込む前に差分を見せ、バックアップを作ります。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var hookStatusText: String {
        switch model.hookInstallStatus {
        case .installed: "インストール済み"
        case .outdated: "更新が必要"
        case .notInstalled: "未インストール"
        case nil: "settings.json を読めません"
        }
    }
}
