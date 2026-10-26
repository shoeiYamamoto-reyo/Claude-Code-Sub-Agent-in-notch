import Foundation

/// Markdown の先頭にある YAML の frontmatter（`---` で囲んだ部分）。
///
/// サブエージェント定義で使う範囲の YAML だけを読む: 1 階層の `key: value`、クォート、
/// 複数行の文字列（`|` / `>` と字下げした続き）、リスト（`- item` と `[a, b]`）。
/// 入れ子のマップ（`hooks`、`mcpServers` など）は中身を解釈せず `raw` として持つ。
/// 書き出し（未知のフィールドを保ったままの往復）は M4-1 で扱う。
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
        return (Frontmatter(entries: entries), body)
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
            entries.append(Entry(key: key, value: value))
        }
        return entries
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
