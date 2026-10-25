import Foundation

/// キーの順番と数値の書き方をそのまま保つ JSON。
/// ユーザーの `settings.json` を書き換えるとき、触っていない部分の差分が出ないようにするために使う。
public indirect enum OrderedJSON: Sendable, Equatable {
    case null
    case bool(Bool)
    /// 数値は元の表記のまま持つ（`1.0` が `1` に変わったりしないように）。
    case number(String)
    case string(String)
    case array([OrderedJSON])
    case object([Member])

    public struct Member: Sendable, Equatable {
        public var key: String
        public var value: OrderedJSON

        public init(_ key: String, _ value: OrderedJSON) {
            self.key = key
            self.value = value
        }
    }

    public subscript(key: String) -> OrderedJSON? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.key == key }?.value
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public var arrayValue: [OrderedJSON]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    public var members: [Member]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    /// オブジェクトのキーを設定する。既にあればその場所で置き換え、無ければ末尾に足す。nil なら消す。
    public mutating func set(_ key: String, _ value: OrderedJSON?) {
        guard case .object(var members) = self else { return }
        if let index = members.firstIndex(where: { $0.key == key }) {
            if let value {
                members[index].value = value
            } else {
                members.remove(at: index)
            }
        } else if let value {
            members.append(Member(key, value))
        }
        self = .object(members)
    }
}

// MARK: - 読み取り

extension OrderedJSON {
    public struct ParseError: Error, Equatable {
        public let offset: Int
        public let reason: String
    }

    public static func parse(_ data: Data) throws -> OrderedJSON {
        var parser = Parser(bytes: Array(data))
        parser.skipWhitespace()
        let value = try parser.parseValue(depth: 0)
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw parser.error("末尾に余分な文字があります") }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        static let maxDepth = 512

        init(bytes: [UInt8]) {
            // UTF-8 の BOM は読み飛ばす。
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
                self.bytes = Array(bytes.dropFirst(3))
            } else {
                self.bytes = bytes
            }
        }

        func error(_ reason: String) -> ParseError { ParseError(offset: index, reason: reason) }

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func expect(_ literal: String) throws {
            let expected = Array(literal.utf8)
            guard bytes.count - index >= expected.count, Array(bytes[index..<index + expected.count]) == expected else {
                throw error("\(literal) が必要です")
            }
            index += expected.count
        }

        mutating func parseValue(depth: Int) throws -> OrderedJSON {
            guard depth < Self.maxDepth else { throw error("入れ子が深すぎます") }
            guard index < bytes.count else { throw error("値がありません") }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try parseObject(depth: depth)
            case UInt8(ascii: "["): return try parseArray(depth: depth)
            case UInt8(ascii: "\""): return .string(try parseString())
            case UInt8(ascii: "t"): try expect("true"); return .bool(true)
            case UInt8(ascii: "f"): try expect("false"); return .bool(false)
            case UInt8(ascii: "n"): try expect("null"); return .null
            default: return .number(try parseNumber())
            }
        }

        mutating func parseObject(depth: Int) throws -> OrderedJSON {
            index += 1
            var members: [Member] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
                index += 1
                return .object(members)
            }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw error("キーが必要です") }
                let key = try parseString()
                skipWhitespace()
                try expect(":")
                skipWhitespace()
                members.append(Member(key, try parseValue(depth: depth + 1)))
                skipWhitespace()
                guard index < bytes.count else { throw error("} が必要です") }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
                throw error(", か } が必要です")
            }
        }

        mutating func parseArray(depth: Int) throws -> OrderedJSON {
            index += 1
            var elements: [OrderedJSON] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
                index += 1
                return .array(elements)
            }
            while true {
                skipWhitespace()
                elements.append(try parseValue(depth: depth + 1))
                skipWhitespace()
                guard index < bytes.count else { throw error("] が必要です") }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(elements) }
                throw error(", か ] が必要です")
            }
        }

        mutating func parseString() throws -> String {
            index += 1
            var scalars = String.UnicodeScalarView()
            var run: [UInt8] = []
            func flush() throws {
                guard !run.isEmpty else { return }
                guard let text = String(validating: run, as: UTF8.self) else { throw error("UTF-8 として読めません") }
                scalars.append(contentsOf: text.unicodeScalars)
                run.removeAll(keepingCapacity: true)
            }
            while index < bytes.count {
                let byte = bytes[index]
                if byte == UInt8(ascii: "\"") {
                    index += 1
                    try flush()
                    return String(scalars)
                }
                if byte < 0x20 { throw error("文字列に制御文字があります") }
                if byte != UInt8(ascii: "\\") {
                    run.append(byte)
                    index += 1
                    continue
                }
                try flush()
                index += 1
                guard index < bytes.count else { break }
                let escape = bytes[index]
                index += 1
                switch escape {
                case UInt8(ascii: "\""): scalars.append("\"")
                case UInt8(ascii: "\\"): scalars.append("\\")
                case UInt8(ascii: "/"): scalars.append("/")
                case UInt8(ascii: "b"): scalars.append("\u{08}")
                case UInt8(ascii: "f"): scalars.append("\u{0C}")
                case UInt8(ascii: "n"): scalars.append("\n")
                case UInt8(ascii: "r"): scalars.append("\r")
                case UInt8(ascii: "t"): scalars.append("\t")
                case UInt8(ascii: "u"):
                    var code = try parseHex4()
                    if (0xD800..<0xDC00).contains(code),
                       bytes.count - index >= 6, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                        let saved = index
                        index += 2
                        let low = try parseHex4()
                        if (0xDC00..<0xE000).contains(low) {
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        } else {
                            index = saved
                        }
                    }
                    scalars.append(Unicode.Scalar(code) ?? "\u{FFFD}")
                default:
                    throw error("不正なエスケープです")
                }
            }
            throw error("文字列が閉じていません")
        }

        mutating func parseHex4() throws -> UInt32 {
            guard bytes.count - index >= 4 else { throw error("\\u の後に 16 進数 4 桁が必要です") }
            var value: UInt32 = 0
            for _ in 0..<4 {
                guard let digit = hexValue(bytes[index]) else { throw error("16 進数ではありません") }
                value = value * 16 + digit
                index += 1
            }
            return value
        }

        func hexValue(_ byte: UInt8) -> UInt32? {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): UInt32(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): UInt32(byte - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): UInt32(byte - UInt8(ascii: "A") + 10)
            default: nil
            }
        }

        mutating func parseNumber() throws -> String {
            let start = index
            func digits() -> Int {
                let begin = index
                while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }
                return index - begin
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
            guard digits() > 0 else { throw error("値が読めません") }
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                index += 1
                guard digits() > 0 else { throw error("小数点の後に数字が必要です") }
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
                guard digits() > 0 else { throw error("指数に数字が必要です") }
            }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }
    }
}

// MARK: - 書き出し

extension OrderedJSON {
    /// `JSON.stringify(value, null, indent)` と同じ形で書き出す（Claude Code 自身の書き方に合わせる）。
    public func formatted(indent: String = "  ") -> String {
        var output = ""
        write(to: &output, indent: indent, level: 0)
        return output
    }

    private func write(to output: inout String, indent: String, level: Int) {
        switch self {
        case .null: output += "null"
        case .bool(let value): output += value ? "true" : "false"
        case .number(let literal): output += literal
        case .string(let value): Self.writeString(value, to: &output)
        case .array(let elements):
            guard !elements.isEmpty else { output += "[]"; return }
            output += "[\n"
            for (offset, element) in elements.enumerated() {
                output += String(repeating: indent, count: level + 1)
                element.write(to: &output, indent: indent, level: level + 1)
                output += offset == elements.count - 1 ? "\n" : ",\n"
            }
            output += String(repeating: indent, count: level) + "]"
        case .object(let members):
            guard !members.isEmpty else { output += "{}"; return }
            output += "{\n"
            for (offset, member) in members.enumerated() {
                output += String(repeating: indent, count: level + 1)
                Self.writeString(member.key, to: &output)
                output += ": "
                member.value.write(to: &output, indent: indent, level: level + 1)
                output += offset == members.count - 1 ? "\n" : ",\n"
            }
            output += String(repeating: indent, count: level) + "}"
        }
    }

    private static func writeString(_ value: String, to output: inout String) {
        output += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            case _ where scalar.value < 0x20:
                let hex = String(scalar.value, radix: 16)
                output += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        output += "\""
    }

    /// 既存ファイルの字下げ（最初に字下げされた行の先頭の空白）を推定する。分からなければ 2 スペース。
    public static func detectIndent(in text: String) -> String {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).dropFirst() {
            let leading = line.prefix { $0 == " " || $0 == "\t" }
            if !leading.isEmpty { return String(leading) }
        }
        return "  "
    }
}
