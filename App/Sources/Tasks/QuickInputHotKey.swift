import Carbon.HIToolbox

/// ノッチのクイック入力を開くグローバルなショートカット ⌃⌥⌘N（ROADMAP 3-5、F0-5）。
///
/// `ApprovalHotKeys` と同じく Carbon のホットキーを使う（アクセシビリティの許可は要らない）。
/// 起動している間は登録したままにする。他のアプリが同じ組み合わせを使っていれば登録できず、そのときはクリックで開く。
@MainActor
final class QuickInputHotKey {
    static let displayName = "⌃⌥⌘N"

    var onPress: (() -> Void)?
    private(set) var isRegistered = false

    nonisolated private static let signature: OSType = 0x4E_54_51_49  // 'NTQI'
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    func register() {
        guard ref == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &id
            )
            // 承認カードのホットキーなど、自分のもの以外は次のハンドラに回す。
            guard status == noErr, id.signature == QuickInputHotKey.signature else { return OSStatus(eventNotHandledErr) }
            // アプリのイベントターゲットのハンドラはメインスレッドで呼ばれる。
            MainActor.assumeIsolated {
                Unmanaged<QuickInputHotKey>.fromOpaque(context).takeUnretainedValue().onPress?()
            }
            return noErr
        }, 1, &spec, context, &handler)

        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_N), UInt32(controlKey | optionKey | cmdKey), id, GetApplicationEventTarget(), 0, &ref
        )
        isRegistered = status == noErr && ref != nil
    }
}
