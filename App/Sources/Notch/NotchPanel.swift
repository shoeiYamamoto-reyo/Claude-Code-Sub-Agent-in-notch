import AppKit

/// ノッチに重ねる枠なしのパネル。メニューバーより前面に出し、アプリをアクティブにしない。
final class NotchPanel: NSPanel {
    static func make() -> NotchPanel {
        let panel = NotchPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        // キャラクターだけのときはクリックを下のアプリに通す。ホバー中だけ受ける。
        panel.ignoresMouseEvents = true
        return panel
    }

    // 入力欄を置くまではキーウィンドウにならない（クリックでターミナルからフォーカスを奪わない）。
    // M3 のタスク投入 UI で見直す。
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// メニューバーの領域に置けるように、システムによる位置の補正をしない。
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
