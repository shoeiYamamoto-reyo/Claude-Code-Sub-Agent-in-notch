import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// 中継 CLI（notch-hook）の本体。実行ファイルの main からはこれを呼ぶだけにして、テストできるようにする。
///
/// 守ること（ADR-0001）: Claude Code を絶対にブロックしない。stdout に出すのは、アプリが答えたときの JSON 1 つだけ。
public enum HookRelay {
    public enum Outcome: Equatable, Sendable {
        case sent
        /// アプリが答えた。この JSON を stdout に 1 つだけ出す。
        case answered(Data)
        /// 送らなかった・送れなかった。理由はテストと調査用。
        case skipped(Reason)
    }

    public enum Reason: Equatable, Sendable {
        case emptyInput
        case tooLarge
        case invalidJSON
        case noSocketPath
        case unreachable
        /// `--ask` だが AskUserQuestion ではない（送るだけの hook が別に送っている）。
        case notAQuestion
        /// 応答待ちで、アプリが判断しなかった・時間切れ・接続が切れた。
        case noDecision
    }

    /// 引数からモードを決める。`--wait`（PermissionRequest）と `--ask`（AskUserQuestion）は応答を待つ。
    public static func mode(arguments: [String]) -> HookWireMessage.Mode {
        if arguments.contains("--wait") { return .wait }
        if arguments.contains("--ask") { return .ask }
        return .event
    }

    public static func run(
        arguments: [String],
        input: Data,
        environment: [String: String],
        timeoutMilliseconds: Int = HookBridge.connectTimeoutMilliseconds,
        responseTimeoutMilliseconds: Int? = nil
    ) -> Outcome {
        guard !input.isEmpty else { return .skipped(.emptyInput) }
        guard input.count <= HookBridge.maxMessageBytes else { return .skipped(.tooLarge) }
        guard let hook = try? JSONDecoder().decode(JSONValue.self, from: input), case .object = hook else {
            return .skipped(.invalidJSON)
        }
        guard let path = HookBridge.socketPath(environment: environment) else { return .skipped(.noSocketPath) }

        let mode = mode(arguments: arguments)
        if mode == .ask, hook["tool_name"]?.stringValue != AskQuestion.toolName {
            return .skipped(.notAQuestion)
        }
        let message = HookWireMessage(
            mode: mode,
            env: HookWireMessage.Environment(processEnvironment: environment),
            hook: hook
        )
        guard let line = try? message.encodedLine(), line.count <= HookBridge.maxMessageBytes else {
            return .skipped(.tooLarge)
        }
        guard mode != .event else {
            return UnixSocketClient.send(line, to: path, timeoutMilliseconds: timeoutMilliseconds) ? .sent : .skipped(.unreachable)
        }

        let responseTimeout = responseTimeoutMilliseconds
            ?? (mode == .wait ? HookBridge.waitResponseTimeoutMilliseconds : HookBridge.askResponseTimeoutMilliseconds)
        guard let response = UnixSocketClient.exchange(
            line,
            with: path,
            connectTimeoutMilliseconds: timeoutMilliseconds,
            responseTimeoutMilliseconds: responseTimeout
        ) else {
            return .skipped(.noDecision)
        }
        guard let reply = try? JSONDecoder().decode(HookReply.self, from: response),
              let output = HookDecisionOutput.output(mode: mode, hook: hook, reply: reply)
        else {
            return .skipped(.noDecision)
        }
        return .answered(output)
    }

    /// fd を EOF まで読む。`limit` を超えたら読むのをやめ、`limit + 1` バイトで返す（呼び出し側で「大きすぎる」と判断する）。
    public static func readAll(fileDescriptor fd: Int32, limit: Int = HookBridge.maxMessageBytes) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count <= limit {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                data.append(contentsOf: buffer[0..<count])
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                break
            }
        }
        return data.count > limit ? data.prefix(limit + 1) : data
    }
}
