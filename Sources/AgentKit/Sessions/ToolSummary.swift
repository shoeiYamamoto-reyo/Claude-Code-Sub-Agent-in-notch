import Foundation

/// ツール呼び出しの入力から、一覧に出す 1 行の要約を作る（F3-3）。
public enum ToolSummary {
    public static let maxLength = 120

    public static func summarize(toolName: String, input: JSONValue?) -> String? {
        guard let input else { return nil }
        let text: String?
        switch toolName {
        case "Bash":
            text = input["command"]?.stringValue
        case "Read", "Edit", "Write", "MultiEdit":
            text = input["file_path"]?.stringValue.map(fileName)
        case "NotebookEdit":
            text = input["notebook_path"]?.stringValue.map(fileName)
        case "Grep", "Glob":
            text = input["pattern"]?.stringValue
        case "Agent", "Task":
            let type = input["subagent_type"]?.stringValue
            let description = input["description"]?.stringValue
            text = [type, description].compactMap { $0 }.joined(separator: ": ")
        case "WebFetch":
            text = input["url"]?.stringValue
        case "WebSearch":
            text = input["query"]?.stringValue
        default:
            text = ["description", "command", "file_path", "path", "pattern", "url", "query"]
                .lazy.compactMap { input[$0]?.stringValue }.first
        }
        guard let text else { return nil }
        return oneLine(text)
    }

    /// 最初の空でない行を、`maxLength` 文字までに切り詰める。
    public static func oneLine(_ text: String, maxLength: Int = maxLength) -> String? {
        let line = text.split(whereSeparator: \.isNewline)
            .lazy.map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard let line else { return nil }
        return line.count > maxLength ? String(line.prefix(maxLength - 1)) + "…" : line
    }

    private static func fileName(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }
}
