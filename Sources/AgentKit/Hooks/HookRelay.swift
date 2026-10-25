import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// 中継 CLI（notch-hook）の本体。実行ファイルの main からはこれを呼ぶだけにして、テストできるようにする。
///
/// 守ること（ADR-0001）: Claude Code を絶対にブロックしない。何が起きても stdout には何も出さない。
public enum HookRelay {
    public enum Outcome: Equatable, Sendable {
        case sent
        /// 送らなかった・送れなかった。理由はテストと調査用。
        case skipped(Reason)
    }

    public enum Reason: Equatable, Sendable {
        case emptyInput
        case tooLarge
        case invalidJSON
        case noSocketPath
        case unreachable
    }

    /// 引数からモードを決める。M1 では `--wait` / `--ask` も送るだけで応答は待たない（応答待ちは M2-1 / M2-3）。
    public static func mode(arguments: [String]) -> HookWireMessage.Mode {
        if arguments.contains("--wait") { return .wait }
        if arguments.contains("--ask") { return .ask }
        return .event
    }

    public static func run(
        arguments: [String],
        input: Data,
        environment: [String: String],
        timeoutMilliseconds: Int = HookBridge.connectTimeoutMilliseconds
    ) -> Outcome {
        guard !input.isEmpty else { return .skipped(.emptyInput) }
        guard input.count <= HookBridge.maxMessageBytes else { return .skipped(.tooLarge) }
        guard let hook = try? JSONDecoder().decode(JSONValue.self, from: input), case .object = hook else {
            return .skipped(.invalidJSON)
        }
        guard let path = HookBridge.socketPath(environment: environment) else { return .skipped(.noSocketPath) }

        let message = HookWireMessage(
            mode: mode(arguments: arguments),
            env: HookWireMessage.Environment(processEnvironment: environment),
            hook: hook
        )
        guard let line = try? message.encodedLine(), line.count <= HookBridge.maxMessageBytes else {
            return .skipped(.tooLarge)
        }
        return UnixSocketClient.send(line, to: path, timeoutMilliseconds: timeoutMilliseconds) ? .sent : .skipped(.unreachable)
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
