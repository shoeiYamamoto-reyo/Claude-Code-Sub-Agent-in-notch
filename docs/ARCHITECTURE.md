# アーキテクチャ方針

- ステータス: ドラフト v0.1（2026-10-25）
- 詳細な決定は `docs/adr/` に ADR として残す。

## 全体像

```
Claude Code ──(hook: stdin JSON)──▶ notch-hook（中継 CLI）
                                        │ Unix ソケット（~/Library/Application Support/<App>/hook.sock）
                                        ▼
                               NotchAgent.app
                               ├─ HookServer      … ソケット受信・応答
                               ├─ SessionStore    … セッション／サブエージェントの状態
                               ├─ ApprovalQueue   … 承認待ちキュー
                               ├─ AgentCatalog    … .claude/agents の読み書き
                               └─ NotchUI         … NSPanel + SwiftUI
```

- **notch-hook**: Claude Code の hooks から呼ばれる小さな実行ファイル。stdin の JSON をそのままソケットへ送る。承認系イベントはアプリの応答（ユーザーのクリック）を待ち、結果を stdout の JSON で返す。ソケットに接続できない・タイムアウトした場合は**何も出力せず exit 0**し、Claude Code の通常動作に任せる。
- **NotchAgent.app**: メニューバー常駐（Dock 非表示）。ノッチ部分に枠なし `NSPanel` を置き、状態機械（`hidden → compact → expanded`）で表示を切り替える。

## モジュール構成

| モジュール | 種類 | 内容 | Linux でテスト |
| --- | --- | --- | --- |
| `AgentKit` | Swift Package (library) | hook イベントのモデルとデコード、セッション状態の集約、承認キュー、エージェント定義（frontmatter）のパース／生成、settings.json の安全なマージ、ソケットのワイヤプロトコル | ✅ |
| `notch-hook` | Swift Package (executable) | 中継 CLI。`AgentKit` のプロトコル定義を使う | ✅（ソケット部分含む） |
| `NotchAgent` | Xcode アプリ（XcodeGen） | AppKit / SwiftUI の UI、ソケットサーバー、ファイル監視、Keychain | ❌（macOS のみ） |

ディレクトリ案:
```
Package.swift            # AgentKit, notch-hook
Sources/AgentKit/
Sources/notch-hook/
Tests/AgentKitTests/
App/                     # NotchAgent（SwiftUI + AppKit）
project.yml              # XcodeGen
docs/
```

## 主要な設計判断（ADR 候補）
1. **連携方式は hooks + Unix ソケット**（coucou と同じ）。トランスクリプト監視は補助（サブエージェントの詳細取得）に限る。→ [ADR-0001](adr/0001-hook-bridge.md)
2. **状態はメモリのみ**に保持し、永続化しない（アプリ再起動で消えてよい）。必要になったら再検討。
3. **設定ファイル書き込みは必ず「バックアップ → 差分 → 確認」**の 1 経路（`SafeFileWriter`）に集約する。
4. **非表示時はタイマーを止める**。描画更新はイベント受信時のみ。

## インターフェース草案（AgentKit）

```swift
public struct HookEvent: Sendable, Decodable {
    public let name: HookEventName          // SessionStart, PreToolUse, ...
    public let sessionID: String
    public let cwd: String?
    public let payload: JSONValue            // 未知フィールドも保持
}

public protocol SessionStore: Sendable {
    func apply(_ event: HookEvent) async
    func snapshot() async -> [Session]
}

public enum ApprovalDecision: Sendable { case allow, deny(reason: String?) }

public protocol ApprovalQueue: Sendable {
    func enqueue(_ request: ApprovalRequest) async -> ApprovalDecision   // ユーザー操作まで待つ
    func resolve(_ id: ApprovalRequest.ID, with decision: ApprovalDecision) async
}

public struct AgentDefinition: Sendable, Equatable {
    public var name: String
    public var description: String
    public var tools: [String]?
    public var model: String?
    public var body: String
    public var scope: Scope                  // .user / .project(URL)
}
```

hook イベント名・ペイロードの正確な形は `docs/claude-code-spec.md` で確認してから確定する。
