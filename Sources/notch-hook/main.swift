// notch-hook: Claude Code の hooks から呼ばれる中継 CLI（ADR-0001）。
//
// M0 時点では骨組みだけで、何も送らずに終了する。
// ソケットへの送信は ROADMAP 1-4、承認の応答待ちは 2-1 で実装する。
//
// 守ること: Claude Code を絶対にブロックしない。
// どんな場合も stdout には何も出さず（または Claude Code 向けの JSON 1 つだけ）、exit 0 で終わる。

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

exit(0)
