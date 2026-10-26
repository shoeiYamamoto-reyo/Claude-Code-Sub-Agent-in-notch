import Foundation

/// 承認カードのキーボードショートカット（ROADMAP 2-2、F4-2）。
///
/// ノッチのパネルはキー入力を受けないので、アプリ側でグローバルなホットキーとして登録する。
/// 登録するのは、権限リクエストのカードが先頭にある間だけ（他のアプリのショートカットを常に奪わないように）。
/// 質問（`AskUserQuestion`）は選択肢を選ぶ必要があるので、ショートカットでは答えない。
///
/// 守ること: ショートカットはクリックと同じく `ApprovalQueue.resolve` を通す（表示中のカードだけ、切り替わり直後は無視）。
public enum ApprovalShortcut: String, Sendable, CaseIterable {
    case allow
    case deny
    case alwaysAllow
    case terminal

    /// ⌥⌘ と組み合わせる文字キー。⌥⌘ にしたのは、ターミナルのシェルに届くキー（⌃ や ⌥ だけの組み合わせ）と重ならないため。
    public var key: Character {
        switch self {
        case .allow: "Y"
        case .deny: "N"
        case .alwaysAllow: "A"
        case .terminal: "T"
        }
    }

    /// ボタンに添える表記。
    public var label: String { "⌥⌘\(key)" }

    public var reply: HookReply {
        switch self {
        case .allow: HookReply(decision: .allow)
        case .deny: HookReply(decision: .deny)
        case .alwaysAllow: HookReply(decision: .always)
        case .terminal: .pass
        }
    }

    /// 先頭の要求に対して今使えるショートカット。空なら何も登録しない。
    public static func available(for request: ApprovalRequest?) -> [ApprovalShortcut] {
        guard case .permission(_, _, _, let alwaysAllow)? = request?.kind else { return [] }
        return alwaysAllow == nil ? [.allow, .deny, .terminal] : [.allow, .deny, .alwaysAllow, .terminal]
    }
}
