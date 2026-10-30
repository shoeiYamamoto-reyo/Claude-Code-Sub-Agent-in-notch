import AppKit

/// ノッチから設定画面を開く（ROADMAP 5-10）。
///
/// SwiftUI の `openSettings` はシーンの中のビューでしか使えないので、ノッチのパネル（`NSHostingView`）からは
/// アプリを前に出してから、メインメニューの「設定…」（⌘,）を実行する。見つからなければ従来のアクションを送る。
@MainActor
enum SettingsOpener {
    static func open() {
        NSApp.activate()
        if let (menu, index) = settingsItem(in: NSApp.mainMenu) {
            menu.performActionForItem(at: index)
        } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }

    private static func settingsItem(in menu: NSMenu?) -> (NSMenu, Int)? {
        guard let menu else { return nil }
        for (index, item) in menu.items.enumerated() {
            if item.keyEquivalent == ",", item.keyEquivalentModifierMask == .command {
                return (menu, index)
            }
            if let found = settingsItem(in: item.submenu) { return found }
        }
        return nil
    }
}
