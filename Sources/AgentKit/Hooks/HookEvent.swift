import Foundation

/// hook のイベント名。知らない名前も `.unknown` として受け取る（Claude Code のバージョンで増えるため）。
public enum HookEventName: Sendable, Hashable {
    case sessionStart
    case sessionEnd
    case userPromptSubmit
    case preToolUse
    case permissionRequest
    case postToolUse
    case postToolUseFailure
    case notification
    case subagentStart
    case subagentStop
    case stop
    case stopFailure
    case unknown(String)

    private static let known: [(HookEventName, String)] = [
        (.sessionStart, "SessionStart"),
        (.sessionEnd, "SessionEnd"),
        (.userPromptSubmit, "UserPromptSubmit"),
        (.preToolUse, "PreToolUse"),
        (.permissionRequest, "PermissionRequest"),
        (.postToolUse, "PostToolUse"),
        (.postToolUseFailure, "PostToolUseFailure"),
        (.notification, "Notification"),
        (.subagentStart, "SubagentStart"),
        (.subagentStop, "SubagentStop"),
        (.stop, "Stop"),
        (.stopFailure, "StopFailure"),
    ]

    public init(rawValue: String) {
        self = Self.known.first { $0.1 == rawValue }?.0 ?? .unknown(rawValue)
    }

    public var rawValue: String {
        if case .unknown(let name) = self { return name }
        return Self.known.first { $0.0 == self }!.1
    }
}

public enum HookEventError: Error, Equatable {
    case notAnObject
    case missingField(String)
}

/// Claude Code の hook が stdin に渡す JSON 1 つ分（`docs/claude-code-spec.md` 1 章）。
/// よく使うフィールドはプロパティで引き、それ以外は `raw` から読む。未知のフィールドも `raw` に残る。
public struct HookEvent: Sendable, Equatable {
    public let name: HookEventName
    public let sessionID: String
    public let raw: JSONValue

    public init(json: JSONValue) throws {
        guard case .object = json else { throw HookEventError.notAnObject }
        guard let name = json["hook_event_name"]?.stringValue else {
            throw HookEventError.missingField("hook_event_name")
        }
        guard let sessionID = json["session_id"]?.stringValue, !sessionID.isEmpty else {
            throw HookEventError.missingField("session_id")
        }
        self.name = HookEventName(rawValue: name)
        self.sessionID = sessionID
        self.raw = json
    }

    public init(data: Data) throws {
        try self.init(json: JSONDecoder().decode(JSONValue.self, from: data))
    }

    // 共通のフィールド
    public var cwd: String? { string("cwd") }
    public var transcriptPath: String? { string("transcript_path") }
    public var permissionMode: String? { string("permission_mode") }
    /// サブエージェント内で発火したときだけ付く。
    public var agentID: String? { string("agent_id") }
    public var agentType: String? { string("agent_type") }

    // ツール系（PreToolUse / PermissionRequest / PostToolUse / PostToolUseFailure）
    public var toolName: String? { string("tool_name") }
    public var toolUseID: String? { string("tool_use_id") }
    public var toolInput: JSONValue? { raw["tool_input"] }
    public var toolResponse: JSONValue? { raw["tool_response"] }

    // イベント固有
    /// SessionStart: `startup` / `resume` / `clear` / `compact` / `fork`
    public var source: String? { string("source") }
    public var model: String? { string("model") }
    public var sessionTitle: String? { string("session_title") }
    /// UserPromptSubmit
    public var prompt: String? { string("prompt") }
    /// Stop / SubagentStop
    public var lastAssistantMessage: String? { string("last_assistant_message") }
    /// Notification
    public var message: String? { string("message") }
    public var notificationType: String? { string("notification_type") }
    /// SessionEnd
    public var reason: String? { string("reason") }

    private func string(_ key: String) -> String? {
        guard let value = raw[key]?.stringValue, !value.isEmpty else { return nil }
        return value
    }
}

extension JSONValue {
    /// 配列なら要素。配列でなければ nil。
    public var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }
}
