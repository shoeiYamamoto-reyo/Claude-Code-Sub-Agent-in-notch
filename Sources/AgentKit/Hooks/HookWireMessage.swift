import Foundation

/// 中継 CLI → アプリに送る 1 行（ADR-0001「ソケットとワイヤプロトコル」）。
public struct HookWireMessage: Sendable, Equatable, Codable {
    public enum Mode: String, Sendable, Codable {
        /// 送るだけ。アプリは応答しない。
        case event
        /// 権限リクエスト。アプリの応答を待つ（M2-1）。
        case wait
        /// AskUserQuestion。アプリの回答を待つ（M2-3）。
        case ask
    }

    /// hook を呼んだ端末・アプリの情報（表示と、将来「どの端末で答えるか」の判断に使う）。
    public struct Environment: Sendable, Equatable, Codable {
        public var termProgram: String?
        public var bundleID: String?

        public init(termProgram: String? = nil, bundleID: String? = nil) {
            self.termProgram = termProgram
            self.bundleID = bundleID
        }

        /// 中継 CLI のプロセス環境変数から作る。
        public init(processEnvironment env: [String: String]) {
            termProgram = env["TERM_PROGRAM"].flatMap { $0.isEmpty ? nil : $0 }
            bundleID = env["__CFBundleIdentifier"].flatMap { $0.isEmpty ? nil : $0 }
        }

        enum CodingKeys: String, CodingKey {
            case termProgram = "term_program"
            case bundleID = "bundle_id"
        }
    }

    public var v: Int
    public var mode: Mode
    public var env: Environment
    /// Claude Code から受け取った JSON そのまま。
    public var hook: JSONValue

    public init(v: Int = HookBridge.protocolVersion, mode: Mode, env: Environment, hook: JSONValue) {
        self.v = v
        self.mode = mode
        self.env = env
        self.hook = hook
    }

    /// 改行で終わる 1 行にする。改行は JSON の文字列中ではエスケープされるので、行の区切りと衝突しない。
    public func encodedLine() throws -> Data {
        var data = try JSONEncoder().encode(self)
        data.append(UInt8(ascii: "\n"))
        return data
    }

    /// 1 行（末尾の改行はあってもなくてもよい）を読む。
    public static func decode(line: Data) throws -> HookWireMessage {
        try JSONDecoder().decode(HookWireMessage.self, from: line)
    }
}
