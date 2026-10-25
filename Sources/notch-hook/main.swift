// notch-hook: Claude Code の hooks から呼ばれる中継 CLI（ADR-0001）。
//
// stdin の JSON をそのまま Unix ソケットでアプリに送り、すぐに終わる。
// アプリが起動していない・応答しないときは何もせずに終わる（接続の待ちは 300 ms まで）。
// --wait（PermissionRequest）と --ask（AskUserQuestion）はアプリの応答を待ち、決定を Claude Code 向けの JSON で出す。
//
// 守ること: Claude Code を絶対にブロックしない。
// どんな場合も stdout には何も出さず（または Claude Code 向けの JSON 1 つだけ）、exit 0 で終わる。

import AgentKit
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

signal(SIGPIPE, SIG_IGN)

let input = HookRelay.readAll(fileDescriptor: STDIN_FILENO)
let outcome = HookRelay.run(
    arguments: Array(CommandLine.arguments.dropFirst()),
    input: input,
    environment: ProcessInfo.processInfo.environment
)
if case .answered(let output) = outcome {
    FileHandle.standardOutput.write(output)
}
exit(0)
