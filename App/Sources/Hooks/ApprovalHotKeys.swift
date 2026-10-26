import AgentKit
import Carbon.HIToolbox

/// 承認カードのグローバルなショートカット（ROADMAP 2-2）。ノッチのパネルはキー入力を受けないので、Carbon のホットキーを使う。
///
/// - 権限リクエストのカードが先頭にある間だけ登録し、無くなったらすぐ外す（他のアプリの ⌥⌘ キーを奪いっぱなしにしない）。
/// - 押されたら `onPress` を呼ぶだけ。答えるかどうかはクリックと同じく `HookCenter.respond` → `ApprovalQueue.resolve` が決める。
/// - アクセシビリティの許可は要らない（`RegisterEventHotKey` は登録したキーの組み合わせしか受け取らない）。
@MainActor
final class ApprovalHotKeys {
    var onPress: ((ApprovalShortcut) -> Void)?

    private static let signature: OSType = 0x4E_54_43_48  // 'NTCH'
    private var registered: [ApprovalShortcut: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?

    /// 今使えるショートカットに合わせて登録し直す。同じ内容なら何もしない。
    func update(_ shortcuts: [ApprovalShortcut]) {
        let wanted = Set(shortcuts)
        for (shortcut, ref) in registered where !wanted.contains(shortcut) {
            UnregisterEventHotKey(ref)
            registered[shortcut] = nil
        }
        guard !wanted.isEmpty else {
            removeHandler()
            return
        }
        installHandlerIfNeeded()
        for shortcut in shortcuts where registered[shortcut] == nil {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: shortcut.hotKeyID)
            let status = RegisterEventHotKey(
                shortcut.keyCode, UInt32(cmdKey | optionKey), id, GetApplicationEventTarget(), 0, &ref
            )
            // 他のアプリが同じ組み合わせを使っていれば登録できない。そのときはボタンで答える。
            if status == noErr, let ref { registered[shortcut] = ref }
        }
    }

    /// 自分のホットキーなら true（他のホットキーは次のハンドラに回す。`QuickInputHotKey`）。
    private func handle(_ id: EventHotKeyID) -> Bool {
        guard id.signature == Self.signature,
              let shortcut = ApprovalShortcut.allCases.first(where: { $0.hotKeyID == id.id }),
              registered[shortcut] != nil
        else { return false }
        onPress?(shortcut)
        return true
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &id
            )
            guard status == noErr else { return status }
            // アプリのイベントターゲットのハンドラはメインスレッドで呼ばれる。
            let handled = MainActor.assumeIsolated {
                Unmanaged<ApprovalHotKeys>.fromOpaque(context).takeUnretainedValue().handle(id)
            }
            return handled ? noErr : OSStatus(eventNotHandledErr)
        }, 1, &spec, context, &handler)
    }

    private func removeHandler() {
        guard let handler else { return }
        RemoveEventHandler(handler)
        self.handler = nil
    }
}

private extension ApprovalShortcut {
    var hotKeyID: UInt32 {
        UInt32(Self.allCases.firstIndex(of: self)! + 1)
    }

    var keyCode: UInt32 {
        switch self {
        case .allow: UInt32(kVK_ANSI_Y)
        case .deny: UInt32(kVK_ANSI_N)
        case .alwaysAllow: UInt32(kVK_ANSI_A)
        case .terminal: UInt32(kVK_ANSI_T)
        }
    }
}
