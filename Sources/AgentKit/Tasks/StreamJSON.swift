import Foundation

/// `claude -p --output-format stream-json --verbose` の 1 行分（docs/claude-code-spec.md 5 章）。
///
/// 使うところだけを取り出し、知らない種類の行は `.unknown` にする（バージョンで増えても落ちない）。
public enum StreamJSONEvent: Sendable, Equatable {
    /// 最初の `system/init`。
    case initialized(sessionID: String?, model: String?, cwd: String?)
    /// Claude の応答。サブエージェントの中なら `parentToolUseID` が付く。
    case assistant(texts: [String], toolUses: [ToolUse], parentToolUseID: String?)
    /// ツールの結果（`user` メッセージの `tool_result`）。
    case toolResults([ToolResult], parentToolUseID: String?)
    /// 最後の `result`。
    case result(TaskResult)
    case unknown(type: String?)

    public struct ToolUse: Sendable, Equatable {
        public var id: String
        public var name: String
        public var input: JSONValue
    }

    public struct ToolResult: Sendable, Equatable {
        public var toolUseID: String
        public var isError: Bool
    }

    /// 1 行を読む。JSON として読めなければ nil。
    public static func decode(_ line: some StringProtocol) -> StreamJSONEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let value = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8)) else {
            return nil
        }
        return decode(value)
    }

    public static func decode(_ value: JSONValue) -> StreamJSONEvent {
        let type = value["type"]?.stringValue
        let parent = value["parent_tool_use_id"]?.stringValue
        switch type {
        case "system" where value["subtype"]?.stringValue == "init":
            return .initialized(
                sessionID: value["session_id"]?.stringValue,
                model: value["model"]?.stringValue,
                cwd: value["cwd"]?.stringValue
            )
        case "assistant":
            var texts: [String] = []
            var toolUses: [ToolUse] = []
            for block in contentBlocks(value) {
                switch block["type"]?.stringValue {
                case "text":
                    if let text = block["text"]?.stringValue { texts.append(text) }
                case "tool_use":
                    if let id = block["id"]?.stringValue, let name = block["name"]?.stringValue {
                        toolUses.append(ToolUse(id: id, name: name, input: block["input"] ?? .null))
                    }
                default:
                    break
                }
            }
            return .assistant(texts: texts, toolUses: toolUses, parentToolUseID: parent)
        case "user":
            let results = contentBlocks(value).compactMap { block -> ToolResult? in
                guard block["type"]?.stringValue == "tool_result", let id = block["tool_use_id"]?.stringValue else { return nil }
                return ToolResult(toolUseID: id, isError: block["is_error"]?.boolValue ?? false)
            }
            return .toolResults(results, parentToolUseID: parent)
        case "result":
            return .result(TaskResult(
                subtype: value["subtype"]?.stringValue,
                isError: value["is_error"]?.boolValue ?? (value["subtype"]?.stringValue != "success"),
                text: value["result"]?.stringValue,
                costUSD: value["total_cost_usd"]?.numberValue,
                durationMilliseconds: value["duration_ms"]?.numberValue,
                turns: value["num_turns"]?.numberValue.map { Int($0) }
            ))
        default:
            return .unknown(type: type)
        }
    }

    private static func contentBlocks(_ value: JSONValue) -> [JSONValue] {
        guard case .array(let blocks) = value["message"]?["content"] else { return [] }
        return blocks
    }
}

/// タスクの最後の結果（stream-json の `result`）。
public struct TaskResult: Sendable, Equatable {
    /// `success` / `error_max_turns` / `error_during_execution` など。
    public var subtype: String?
    public var isError: Bool
    /// 最後の応答の本文。
    public var text: String?
    public var costUSD: Double?
    public var durationMilliseconds: Double?
    public var turns: Int?
}

/// stream-json を流し込んで、結果の表示に使う内容をまとめる（ROADMAP 3-4、F2-3）。値型。
public struct TaskTranscript: Sendable, Equatable {
    /// ファイルを書き換えるツールと、その入力でパスを持つキー。
    public static let fileEditingTools: [String: String] = [
        "Edit": "file_path",
        "MultiEdit": "file_path",
        "Write": "file_path",
        "NotebookEdit": "notebook_path",
    ]

    public private(set) var sessionID: String?
    public private(set) var model: String?
    public private(set) var cwd: String?
    /// メインの会話の最後の応答（サブエージェントの中のものは含めない）。
    public private(set) var lastAssistantText: String?
    /// 成功した編集で変わったファイル（最初に変わった順、重複なし）。サブエージェントの編集も含む。
    public private(set) var changedFiles: [String] = []
    /// メインの会話で今動いているツール（結果が来るまで）。
    public private(set) var currentTool: StreamJSONEvent.ToolUse?
    public private(set) var toolUseCount = 0
    public private(set) var result: TaskResult?
    /// JSON として読めなかった行の数。
    public private(set) var unreadableLines = 0

    /// 結果待ちの編集（tool_use の ID → パス）。
    private var pendingEdits: [String: String] = [:]

    public init() {}

    /// 1 行を流し込む。
    public mutating func consume(_ line: some StringProtocol) {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard let event = StreamJSONEvent.decode(line) else {
            unreadableLines += 1
            return
        }
        apply(event)
    }

    /// 同じセッションの続き（`--resume`、ROADMAP 3-6）を流し込む前に呼ぶ。前回の結果と動いているツールを消す。
    /// 最後の応答・変更したファイル・ツールの回数はそのまま積み上げる。
    public mutating func beginFollowUp() {
        result = nil
        currentTool = nil
        pendingEdits.removeAll()
    }

    public mutating func apply(_ event: StreamJSONEvent) {
        switch event {
        case .initialized(let sessionID, let model, let cwd):
            self.sessionID = sessionID ?? self.sessionID
            self.model = model ?? self.model
            self.cwd = cwd ?? self.cwd
        case .assistant(let texts, let toolUses, let parent):
            toolUseCount += toolUses.count
            for use in toolUses {
                if let key = Self.fileEditingTools[use.name], let path = use.input[key]?.stringValue, !path.isEmpty {
                    pendingEdits[use.id] = path
                }
            }
            guard parent == nil else { return }
            let text = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { lastAssistantText = text }
            if let last = toolUses.last { currentTool = last }
        case .toolResults(let results, _):
            for toolResult in results {
                if let path = pendingEdits.removeValue(forKey: toolResult.toolUseID), !toolResult.isError,
                   !changedFiles.contains(path) {
                    changedFiles.append(path)
                }
                if currentTool?.id == toolResult.toolUseID { currentTool = nil }
            }
        case .result(let result):
            self.result = result
            currentTool = nil
            if let text = result.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                lastAssistantText = text
            }
        case .unknown:
            break
        }
    }
}

/// 読んだ分ずつ届くバイト列を行に分ける。最後の改行より後ろは次に回す。
public struct LineBuffer: Sendable {
    private var pending = Data()
    /// 改行の無いまま溜まったら捨てる上限（壊れた出力でメモリを使い切らないため）。
    public var maxLineBytes: Int

    public init(maxLineBytes: Int = 8 << 20) {
        self.maxLineBytes = maxLineBytes
    }

    public mutating func append(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            lines.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
            pending = Data(pending[pending.index(after: newline)...])
        }
        if pending.count > maxLineBytes { pending.removeAll() }
        return lines
    }

    /// 終わりに残った改行の無い行。
    public mutating func flush() -> String? {
        defer { pending.removeAll() }
        guard !pending.isEmpty else { return nil }
        return String(decoding: pending, as: UTF8.self)
    }
}
