import Foundation

/// Markdown の先頭にある YAML の frontmatter（`---` で囲んだ部分）。
///
/// サブエージェント定義で使う範囲の YAML だけを読む: 1 階層の `key: value`、クォート、
/// 複数行の文字列（`|` / `>` と字下げした続き）、リスト（`- item` と `[a, b]`）。
/// 入れ子のマップ（`hooks`、`mcpServers` など）は中身を解釈せず `raw` として持つ。
///
/// 書き出し（ROADMAP 4-1）は元の行を土台にし、`set` で変えた項目だけを書き直す。
/// 変えていない項目・コメント・空行・順序はそのまま残る（未知のフィールドを壊さない）。
public struct Frontmatter: Sendable, Equatable {
    public enum Value: Sendable, Equatable {
        case string(String)
        case list([String])
        /// 解釈しない値（入れ子のマップ、`{...}` など）。元のテキスト。
        case raw(String)

        public var stringValue: String? {
            if case .string(let value) = self { return value }
            return nil
        }
    }

    public struct Entry: Sendable, Equatable {
        public var key: String
        public var value: Value
        /// 元のテキストでの行（`sourceLines` の添字）。新しく足した項目は nil。
        var lines: Range<Int>?
        /// `set` で値を変えたか。変えたものだけ書き直す。
        var edited = false

        public init(key: String, value: Value) {
            self.key = key
            self.value = value
        }

        /// 書き方（行の位置など）は比べない。
        public static func == (lhs: Entry, rhs: Entry) -> Bool {
            lhs.key == rhs.key && lhs.value == rhs.value
        }
    }

    public enum ParseError: Error, Sendable, Equatable {
        /// 1 行目が `---` でない。
        case missingOpeningDelimiter
        /// 閉じる `---` が無い。
        case missingClosingDelimiter
        /// YAML として読めない行（1 から数えた、ファイル全体での行番号）。
        case invalidLine(Int)

        public var message: String {
            switch self {
            case .missingOpeningDelimiter: "1 行目が --- ではありません"
            case .missingClosingDelimiter: "frontmatter を閉じる --- がありません"
            case .invalidLine(let line): "\(line) 行目を YAML として読めません"
            }
        }
    }

    /// 書かれた順。
    public var entries: [Entry]
    /// 元のテキストの、`---` の間の行。
    var sourceLines: [String] = []
    /// `set` で消した項目の元の行。
    var removedLines: [Range<Int>] = []

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    /// 項目の中身だけを比べる（元の書き方は比べない）。
    public static func == (lhs: Frontmatter, rhs: Frontmatter) -> Bool {
        lhs.entries == rhs.entries
    }

    public subscript(key: String) -> Value? {
        entries.first { $0.key == key }?.value
    }

    /// frontmatter と本文に分ける。本文は閉じる `---` の次の行から。
    public static func parse(_ text: String) throws(ParseError) -> (frontmatter: Frontmatter, body: String) {
        // Swift では "\r\n" が 1 文字になるので、先に "\n" にそろえる。
        var text = text.replacingOccurrences(of: "\r\n", with: "\n")
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first, first.trimmingTrailingWhitespace() == "---" else {
            throw .missingOpeningDelimiter
        }
        guard let closing = lines.indices.dropFirst().first(where: {
            let line = lines[$0].trimmingTrailingWhitespace()
            return line == "---" || line == "..."
        }) else {
            throw .missingClosingDelimiter
        }
        let entries = try parseEntries(Array(lines[1..<closing]), firstLineNumber: 2)
        let body = lines[(closing + 1)...].joined(separator: "\n")
        var frontmatter = Frontmatter(entries: entries)
        frontmatter.sourceLines = lines[1..<closing].map(String.init)
        return (frontmatter, body)
    }

    // MARK: - YAML のサブセット

    private static func parseEntries(_ lines: [Substring], firstLineNumber: Int) throws(ParseError) -> [Entry] {
        var entries: [Entry] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if isBlankOrComment(line) {
                index += 1
                continue
            }
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = keyColon(in: line) else {
                throw .invalidLine(firstLineNumber + index)
            }
            let start = index
            let key = unquote(String(line[..<colon]).trimmingCharacters(in: .whitespaces))
            let rest = stripComment(String(line[line.index(after: colon)...])).trimmingCharacters(in: .whitespaces)
            index += 1

            // 続く字下げした行（と途中の空行）を集める。
            var continuation: [Substring] = []
            while index < lines.count {
                let next = lines[index]
                if next.hasPrefix(" ") || next.hasPrefix("\t") || next.trimmingCharacters(in: .whitespaces).isEmpty {
                    continuation.append(next)
                    index += 1
                } else {
                    break
                }
            }
            while let last = continuation.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
                continuation.removeLast()
            }

            let value: Value
            if rest.hasPrefix("|") || rest.hasPrefix(">") {
                value = .string(blockScalar(continuation, folded: rest.hasPrefix(">"), keepTrailingNewline: !rest.contains("-")))
            } else if rest.isEmpty {
                let items = continuation.filter { !isBlankOrComment($0) }
                if items.isEmpty {
                    value = .string("")
                } else if items.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).hasPrefix("-") }) {
                    value = .list(items.map { item in
                        let text = item.trimmingCharacters(in: .whitespaces).dropFirst()
                        return unquote(stripComment(String(text)).trimmingCharacters(in: .whitespaces))
                    })
                } else {
                    value = .raw(continuation.joined(separator: "\n"))
                }
            } else if rest.hasPrefix("[") {
                let joined = ([rest] + continuation.map { $0.trimmingCharacters(in: .whitespaces) }).joined(separator: " ")
                guard joined.hasSuffix("]") else { throw .invalidLine(firstLineNumber + index - 1 - continuation.count) }
                value = .list(splitFlowList(String(joined.dropFirst().dropLast())))
            } else if rest.hasPrefix("{") {
                value = .raw(([Substring(rest)] + continuation).joined(separator: "\n"))
            } else if rest.hasPrefix("\"") || rest.hasPrefix("'") {
                let joined = ([rest] + continuation.map { $0.trimmingCharacters(in: .whitespaces) }).joined(separator: " ")
                value = .string(unquote(joined))
            } else {
                // 字下げした続きは空白 1 つでつなぐ（YAML のプレーンスカラーの折り返し）。
                let parts = [rest] + continuation.map { stripComment(String($0)).trimmingCharacters(in: .whitespaces) }
                value = .string(parts.filter { !$0.isEmpty }.joined(separator: " "))
            }
            var entry = Entry(key: key, value: value)
            entry.lines = start..<(start + 1 + continuation.count)
            entries.append(entry)
        }
        return entries
    }

    // MARK: - 書き出し（ROADMAP 4-1）

    /// 値を変える。無ければ末尾に足し、nil なら消す。同じ値なら何もしない（元の書き方を残す）。
    public mutating func set(_ key: String, _ value: Value?) {
        guard let index = entries.firstIndex(where: { $0.key == key }) else {
            if let value { entries.append(Entry(key: key, value: value)) }
            return
        }
        guard let value else {
            if let lines = entries[index].lines { removedLines.append(lines) }
            entries.remove(at: index)
            return
        }
        guard entries[index].value != value else { return }
        entries[index].value = value
        entries[index].edited = true
    }

    /// `---` の間に書く YAML（各行の終わりに改行）。変えていない項目・コメント・空行は元の行のまま。
    public func render() -> String {
        var starts: [Int: Entry] = [:]
        for entry in entries {
            if let lines = entry.lines { starts[lines.lowerBound] = entry }
        }
        let removed = Set(removedLines.flatMap { Array($0) })
        var output: [String] = []
        var index = 0
        while index < sourceLines.count {
            if let entry = starts[index], let lines = entry.lines {
                output += entry.edited ? Self.serialize(entry) : Array(sourceLines[lines])
                index = lines.upperBound
            } else {
                if !removed.contains(index) { output.append(sourceLines[index]) }
                index += 1
            }
        }
        for entry in entries where entry.lines == nil {
            output += Self.serialize(entry)
        }
        return output.map { $0 + "\n" }.joined()
    }

    static func serialize(_ entry: Entry) -> [String] {
        let key = entry.key
        switch entry.value {
        case .string(let text):
            if let block = blockScalarLines(text) { return ["\(key): \(block.indicator)"] + block.lines }
            return ["\(key): \(scalar(text))"]
        case .list(let items):
            if items.isEmpty { return ["\(key): []"] }
            return ["\(key):"] + items.map { "  - \(scalar($0))" }
        case .raw(let text):
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            // 字下げした続きなら次の行から、`{...}` なら同じ行から。
            if text.hasPrefix(" ") || text.hasPrefix("\t") { return ["\(key):"] + lines }
            return ["\(key): \(lines.first ?? "")"] + lines.dropFirst()
        }
    }

    /// 複数行の文字列を `|` / `|-` で書く。読み戻して同じにならない形（末尾の空行が 2 つ以上、
    /// 空白だけの行、全行が字下げされている）は nil（クォートで書く）。
    private static func blockScalarLines(_ text: String) -> (indicator: String, lines: [String])? {
        guard text.contains("\n") else { return nil }
        let keepsNewline = text.hasSuffix("\n")
        let content = keepsNewline ? String(text.dropLast()) : text
        guard !content.hasSuffix("\n"), !content.isEmpty else { return nil }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let nonEmpty = lines.filter { !$0.isEmpty }
        guard !nonEmpty.isEmpty,
              !lines.contains(where: { !$0.isEmpty && $0.trimmingCharacters(in: .whitespaces).isEmpty }),
              nonEmpty.contains(where: { !$0.hasPrefix(" ") && !$0.hasPrefix("\t") }),
              !lines.contains(where: { $0.hasSuffix(" ") || $0.hasSuffix("\t") })
        else { return nil }
        return (keepsNewline ? "|" : "|-", lines.map { $0.isEmpty ? "" : "  " + $0 })
    }

    /// 1 行の値。そのままでは別の意味に読まれるもの（`true`、数、`: ` を含むものなど）はクォートで囲む。
    static func scalar(_ text: String) -> String {
        needsQuoting(text) ? quoted(text) : text
    }

    private static let reservedWords: Set<String> = ["true", "false", "yes", "no", "on", "off", "null", "~"]

    private static func needsQuoting(_ text: String) -> Bool {
        guard let first = text.first, let last = text.last else { return true }
        if first.isWhitespace || last.isWhitespace { return true }
        if "-?:,[]{}#&*!|>'\"%@`".contains(first) { return true }
        if text.contains(": ") || text.contains(" #") || text.hasSuffix(":") { return true }
        if text.contains(where: { $0.isNewline || $0 == "\t" }) { return true }
        if reservedWords.contains(text.lowercased()) || Double(text) != nil { return true }
        return false
    }

    private static func quoted(_ text: String) -> String {
        // `"` を含む 1 行の値は '...' にする（読み取りでコメントの判定を誤らないよう、エスケープした `"` を避ける）。
        if text.contains("\""), !text.contains("'"), !text.contains(where: { $0.isNewline || $0 == "\t" }) {
            return "'" + text + "'"
        }
        var result = "\""
        for character in text {
            switch character {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n", "\r\n": result += "\\n"
            case "\t": result += "\\t"
            default: result.append(character)
            }
        }
        return result + "\""
    }

    private static func isBlankOrComment(_ line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.hasPrefix("#")
    }

    /// キーの後ろの `:`（後ろが空白か行末）の位置。
    private static func keyColon(in line: Substring) -> Substring.Index? {
        var inQuote: Character?
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if let quote = inQuote {
                if character == quote { inQuote = nil }
            } else if character == "\"" || character == "'", index == line.startIndex {
                inQuote = character
            } else if character == ":" {
                let next = line.index(after: index)
                if next == line.endIndex || line[next] == " " || line[next] == "\t" { return index }
            }
            index = line.index(after: index)
        }
        return nil
    }

    /// クォートの外にある ` #` 以降を落とす。
    private static func stripComment(_ text: String) -> String {
        var inQuote: Character?
        var previous: Character = " "
        for (offset, character) in text.enumerated() {
            if let quote = inQuote {
                if character == quote { inQuote = nil }
            } else if character == "\"" || character == "'" {
                if previous == " " || offset == 0 { inQuote = character }
            } else if character == "#", previous == " " || previous == "\t" || offset == 0 {
                return String(text.prefix(offset))
            }
            previous = character
        }
        return text
    }

    private static func blockScalar(_ lines: [Substring], folded: Bool, keepTrailingNewline: Bool) -> String {
        let indent = lines
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { line in line.prefix { $0 == " " || $0 == "\t" }.count }
            .min() ?? 0
        let content = lines.map { line in
            line.trimmingCharacters(in: .whitespaces).isEmpty ? "" : String(line.dropFirst(indent))
        }
        var result: String
        if folded {
            // 空行で段落を分け、段落の中は空白でつなぐ。
            var paragraphs: [[String]] = [[]]
            for line in content {
                if line.isEmpty {
                    paragraphs.append([])
                } else {
                    paragraphs[paragraphs.count - 1].append(line)
                }
            }
            result = paragraphs.map { $0.joined(separator: " ") }.joined(separator: "\n")
        } else {
            result = content.joined(separator: "\n")
        }
        if keepTrailingNewline, !result.isEmpty { result += "\n" }
        return result
    }

    private static func splitFlowList(_ text: String) -> [String] {
        var items: [String] = []
        var current = ""
        var inQuote: Character?
        for character in text {
            if let quote = inQuote {
                current.append(character)
                if character == quote { inQuote = nil }
            } else if character == "\"" || character == "'" {
                inQuote = character
                current.append(character)
            } else if character == "," {
                items.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        items.append(current)
        return items
            .map { unquote($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
    }

    /// `"..."`（`\"` `\\` `\n` `\t` を解釈）と `'...'`（`''` が `'`）のクォートを外す。
    static func unquote(_ text: String) -> String {
        if text.count >= 2, text.hasPrefix("'"), text.hasSuffix("'") {
            return String(text.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        guard text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") else { return text }
        var result = ""
        var escaping = false
        for character in text.dropFirst().dropLast() {
            if escaping {
                switch character {
                case "n": result.append("\n")
                case "t": result.append("\t")
                default: result.append(character)
                }
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                result.append(character)
            }
        }
        return result
    }
}

private extension Substring {
    func trimmingTrailingWhitespace() -> Substring {
        var result = self
        while let last = result.last, last == " " || last == "\t" { result.removeLast() }
        return result
    }
}
