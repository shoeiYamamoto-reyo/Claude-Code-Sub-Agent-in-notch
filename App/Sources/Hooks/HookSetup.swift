import AgentKit
import AppKit
import SwiftUI

/// hooks のインストール／アンインストール（ROADMAP 1-7）。
///
/// 1. アプリに同梱した notch-hook を `~/Library/Application Support/NotchAgent/bin/` にコピーする
///    （アプリを移動・更新しても settings.json のパスが変わらないように）。
/// 2. `~/.claude/settings.json` の変更案を作り、差分を見せる。
/// 3. ユーザーが「書き込む」を押したときだけ、バックアップを取ってから書く（`SafeFileWriter`）。
@MainActor
final class HookSetup {
    let model: NotchModel
    private var window: NSWindow?

    init(model: NotchModel) {
        self.model = model
    }

    var settingsPath: String {
        HookBridge.userSettingsPath(home: NSHomeDirectory(), environment: ProcessInfo.processInfo.environment)
    }

    var hookPath: String { HookBridge.hookExecutablePath(home: NSHomeDirectory()) }

    func refreshStatus() {
        let path = (settingsPath as NSString).resolvingSymlinksInPath
        guard let data = FileManager.default.contents(atPath: path) else {
            model.hookInstallStatus = .notInstalled
            return
        }
        guard let settings = try? OrderedJSON.parse(data) else {
            model.hookInstallStatus = nil
            return
        }
        model.hookInstallStatus = HookInstaller.status(of: settings, hookPath: hookPath)
    }

    func beginInstall() {
        let hookPath = self.hookPath
        prepare(
            title: "hooks をインストール",
            message: "Claude Code のイベントをノッチに送るため、ユーザー設定に notch-hook を登録します。既存の設定はそのまま残し、書き込む前にバックアップを作ります。",
            actionTitle: "書き込む",
            transform: { try HookInstaller.install(into: $0, hookPath: hookPath) },
            beforeWrite: { [weak self] in
                guard let self else { return }
                try self.installBinary()
            }
        )
    }

    func beginUninstall() {
        prepare(
            title: "hooks をアンインストール",
            message: "ユーザー設定から notch-hook の登録だけを外します。他の hooks や設定には触りません。",
            actionTitle: "外す",
            transform: { try HookInstaller.uninstall(from: $0) },
            beforeWrite: {}
        )
    }

    // MARK: - 内部

    private func prepare(
        title: String,
        message: String,
        actionTitle: String,
        transform: (OrderedJSON) throws -> OrderedJSON,
        beforeWrite: @escaping () throws -> Void
    ) {
        let edit: SettingsFileEdit
        do {
            edit = try SafeFileWriter.prepare(path: settingsPath, transform: transform)
        } catch {
            showAlert(title: "\(title)できません", text: Self.describe(error, path: settingsPath))
            return
        }
        guard edit.hasChanges else {
            do {
                try beforeWrite()
                showAlert(title: "変更はありません", text: "\(settingsPath) は既にこの内容です。")
            } catch {
                showAlert(title: "\(title)できません", text: Self.describe(error, path: settingsPath))
            }
            refreshStatus()
            return
        }

        let view = SettingsDiffView(
            title: title,
            message: message,
            edit: edit,
            actionTitle: actionTitle,
            onCancel: { [weak self] in self?.closeWindow() },
            onConfirm: { [weak self] in self?.commit(edit, title: title, beforeWrite: beforeWrite) }
        )
        showWindow(title: title, content: view)
    }

    private func commit(_ edit: SettingsFileEdit, title: String, beforeWrite: () throws -> Void) {
        closeWindow()
        do {
            try beforeWrite()
            let backup = try SafeFileWriter.commit(edit)
            refreshStatus()
            var text = "\(edit.displayPath) を更新しました。"
            if let backup { text += "\nバックアップ: \(backup)" }
            text += "\n\n実行中の Claude Code には、次に起動したセッションから反映されます。"
            showAlert(title: "\(title)しました", text: text)
        } catch {
            showAlert(title: "\(title)できませんでした", text: Self.describe(error, path: edit.displayPath))
        }
    }

    /// 同梱の notch-hook をアプリの外にコピーする。中身が同じなら何もしない。
    private func installBinary() throws {
        guard let source = Bundle.main.url(forAuxiliaryExecutable: HookInstaller.executableName) else {
            throw SetupError.missingHelper
        }
        let destination = URL(fileURLWithPath: hookPath)
        let fileManager = FileManager.default
        if let installed = fileManager.contents(atPath: destination.path),
           installed == fileManager.contents(atPath: source.path) {
            return
        }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".notch-hook-\(UUID().uuidString)")
        try fileManager.copyItem(at: source, to: temporary)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }

    private enum SetupError: LocalizedError {
        case missingHelper

        var errorDescription: String? {
            "アプリの中に notch-hook が見つかりません（Contents/MacOS/notch-hook）。アプリをビルドし直してください。"
        }
    }

    private static func describe(_ error: Error, path: String) -> String {
        switch error {
        case SafeFileWriter.WriteError.invalidJSON(let detail):
            "\(path) を JSON として読めないため、何もしませんでした（\(detail)）。"
        case SafeFileWriter.WriteError.unreadable:
            "\(path) を読めないため、何もしませんでした。"
        case SafeFileWriter.WriteError.changedOnDisk:
            "確認している間に \(path) が変更されたため、書き込みをやめました。もう一度やり直してください。"
        case SafeFileWriter.WriteError.writeFailed(let detail):
            "書き込めませんでした: \(detail)"
        case HookInstaller.PlanError.settingsNotAnObject:
            "\(path) の中身が JSON のオブジェクトではないため、何もしませんでした。"
        case HookInstaller.PlanError.hooksNotAnObject:
            "\(path) の \"hooks\" が想定と違う形のため、何もしませんでした。"
        case HookInstaller.PlanError.eventNotAnArray(let event):
            "\(path) の \"hooks.\(event)\" が配列ではないため、何もしませんでした。"
        default:
            error.localizedDescription
        }
    }

    private func showWindow<Content: View>(title: String, content: Content) {
        closeWindow()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content)
        window.center()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func closeWindow() {
        window?.close()
        window = nil
    }

    private func showAlert(title: String, text: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}

/// 書き込む前の確認画面。差分を見せ、ボタンを押したときだけ書く。
private struct SettingsDiffView: View {
    let title: String
    let message: String
    let edit: SettingsFileEdit
    let actionTitle: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2.bold())
            Text(message).fixedSize(horizontal: false, vertical: true)
            LabeledContent("ファイル") {
                Text(edit.displayPath).textSelection(.enabled)
            }
            if edit.targetPath != edit.displayPath {
                LabeledContent("リンク先") {
                    Text(edit.targetPath).textSelection(.enabled)
                }
            }
            if edit.originalData == nil {
                Text("ファイルが無いので新しく作ります。").foregroundStyle(.secondary)
            }

            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(LineDiff.hunks(edit.diff).enumerated()), id: \.offset) { _, line in
                        DiffLineView(line: line)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

            HStack {
                Spacer()
                Button("キャンセル", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(actionTitle, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 420)
    }
}

private struct DiffLineView: View {
    let line: LineDiff.Line?

    var body: some View {
        Group {
            if let line {
                switch line.kind {
                case .same:
                    Text("  " + line.text)
                case .added:
                    Text("+ " + line.text)
                        .foregroundStyle(.green)
                        .background(Color.green.opacity(0.08))
                case .removed:
                    Text("- " + line.text)
                        .foregroundStyle(.red)
                        .background(Color.red.opacity(0.08))
                }
            } else {
                Text("  ⋯").foregroundStyle(.secondary)
            }
        }
        .font(.system(.callout, design: .monospaced))
        .lineLimit(1)
        .fixedSize()
    }
}
