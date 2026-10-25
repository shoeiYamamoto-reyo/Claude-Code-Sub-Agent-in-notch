import Foundation

/// アプリ → 中継 CLI の応答 1 行（ADR-0001「ソケットとワイヤプロトコル」）。`wait` / `ask` のときだけ返す。
public struct HookReply: Sendable, Equatable, Codable {
    public enum Decision: String, Sendable, Codable {
        /// 許可。
        case allow
        /// 許可し、Claude Code が提案したルール（`permission_suggestions`）も追加する（F4-6）。
        case always
        /// 拒否。
        case deny
        /// `AskUserQuestion` に回答する。
        case answer
        /// 判断しない。中継は何も出力せず、Claude Code の通常の確認に任せる。
        case pass
    }

    public var decision: Decision
    /// 拒否の理由（Claude に伝わる）。
    public var message: String?
    /// 質問文 → 選んだラベル（複数選択は ", " 区切り）。
    public var answers: [String: String]?

    public init(decision: Decision, message: String? = nil, answers: [String: String]? = nil) {
        self.decision = decision
        self.message = message
        self.answers = answers
    }

    public static let pass = HookReply(decision: .pass)

    public func encodedLine() throws -> Data {
        var data = try JSONEncoder().encode(self)
        data.append(UInt8(ascii: "\n"))
        return data
    }
}

/// アプリの応答を、Claude Code が stdout から読む JSON に変換する（`docs/claude-code-spec.md` 2-1、4 章）。
/// nil は「何も出力しない」（= 判断しない）。
public enum HookDecisionOutput {
    public static let defaultDenyMessage = "ノッチで拒否されました"

    public static func output(mode: HookWireMessage.Mode, hook: JSONValue, reply: HookReply) -> Data? {
        let value: JSONValue?
        switch (mode, reply.decision) {
        case (.wait, .allow):
            value = permission(["behavior": .string("allow")])
        case (.wait, .always):
            var decision: [String: JSONValue] = ["behavior": .string("allow")]
            if let suggestions = hook["permission_suggestions"]?.arrayValue, !suggestions.isEmpty {
                decision["updatedPermissions"] = .array(suggestions)
            }
            value = permission(decision)
        case (.wait, .deny):
            let message = reply.message.flatMap { $0.isEmpty ? nil : $0 } ?? defaultDenyMessage
            value = permission(["behavior": .string("deny"), "message": .string(message)])
        case (.ask, .answer):
            value = answer(hook: hook, answers: reply.answers ?? [:])
        default:
            value = nil
        }
        guard let value else { return nil }
        return try? encoder.encode(value)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static func permission(_ decision: [String: JSONValue]) -> JSONValue {
        .object(["hookSpecificOutput": .object([
            "hookEventName": .string("PermissionRequest"),
            "decision": .object(decision),
        ])])
    }

    /// 元の `tool_input` に `answers` を足して `updatedInput` にする。`allow` だけでは回答にならない。
    private static func answer(hook: JSONValue, answers: [String: String]) -> JSONValue? {
        guard hook["tool_name"]?.stringValue == AskQuestion.toolName,
              case .object(var input)? = hook["tool_input"],
              !answers.isEmpty
        else { return nil }
        input["answers"] = .object(answers.mapValues(JSONValue.string))
        return .object(["hookSpecificOutput": .object([
            "hookEventName": .string("PreToolUse"),
            "permissionDecision": .string("allow"),
            "updatedInput": .object(input),
        ])])
    }
}
