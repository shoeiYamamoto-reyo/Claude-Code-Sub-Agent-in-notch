import AgentKit
import AppKit
import SwiftUI

/// 設定画面（ROADMAP 5-1）。メニューバーの「設定…」（⌘,）で開く。
/// メニューにあったサウンドと表示する画面の設定をここに移し、ログイン時の起動を加えた。
/// 指示のテンプレート（ROADMAP 5-5）もここで管理する。
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
            TemplateSettingsView(model: model)
                .tabItem { Label("テンプレート", systemImage: "text.badge.star") }
            ClaudeSettings(model: model, hookSetup: hookSetup, claudeSetup: claudeSetup)
                .tabItem { Label("Claude Code", systemImage: "terminal") }
        }
        .frame(width: 560, height: 480)
    }
}

private struct GeneralSettings: View {
    let model: NotchModel
    let controller: NotchPanelController
    let loginItem: LoginItem
    @State private var isConfirmingClear = false

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
            Section {
                LabeledContent("タスクの履歴") {
                    HStack {
                        Text("\(model.taskHistory.entries.count) 件（最大 \(TaskHistory.maxEntries) 件）")
                            .foregroundStyle(.secondary)
                        Button("消去…") { isConfirmingClear = true }
                            .disabled(model.taskHistory.entries.isEmpty)
                    }
                }
                if let error = model.taskHistoryError {
                    Text(error).foregroundStyle(.red)
                }
            } footer: {
                Text("アプリから始めたタスクの指示・結果の要約・変更したファイルの数を残します。出力そのものは 14 日で消えます。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("タスクの履歴をすべて消去しますか？", isPresented: $isConfirmingClear) {
            Button("消去", role: .destructive) { model.onClearTaskHistory?() }
        } message: {
            Text("エージェントごとの利用回数も 0 に戻ります。元に戻せません。")
        }
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
                Text("おやすみモード（一時的に音を止める）はメニューバーのメニューと、展開したノッチの月のボタン（1 時間）から使えます。")
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
