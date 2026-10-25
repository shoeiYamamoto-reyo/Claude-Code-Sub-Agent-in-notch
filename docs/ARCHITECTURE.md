# アーキテクチャ方針

- ステータス: **v1.0（M0-3 で確定、2026-10-25）**。Claude Code の仕様は `docs/claude-code-spec.md`、coucou の調査は `docs/coucou-notes.md`。
- 詳細な決定は `docs/adr/` に ADR として残す。

## 全体像

```
                    ┌──────── タスク起動（claude -p ... stream-json）────────┐
                    │                                                         ▼
NotchAgent.app ◀────┤                                                   Claude Code
 ├─ ProjectRegistry … 登録プロジェクトと環境設定                            │
 ├─ TaskRunner      … タスクの起動・停止・出力の読み取り                     │ hook: stdin JSON
 ├─ HookServer      … ソケット受信・応答 ◀── Unix ソケット ── notch-hook（中継 CLI）
 ├─ SessionStore    … セッション／サブエージェントの状態（hook と TaskRunner の両方から）
 ├─ ApprovalQueue   … 承認待ちキュー
 ├─ AgentCatalog    … .claude/agents の読み書き
 └─ NotchUI         … NSPanel + SwiftUI（キャラクター、展開ウィンドウ）
```

- **notch-hook**: Claude Code の hooks から呼ばれる小さな実行ファイル。stdin の JSON をそのままソケットへ送る。承認系イベント（`--wait`: `PermissionRequest`、`--ask`: `AskUserQuestion`）はアプリの応答（ユーザーのクリック）を待ち、結果を stdout の JSON で返す。ソケットに接続できない（300 ms）・タイムアウトした場合は**何も出力せず exit 0**し、Claude Code の通常動作に任せる。登録内容とワイヤプロトコルは [ADR-0001](adr/0001-hook-bridge.md)。
- **NotchAgent.app**: メニューバー常駐（Dock 非表示）。ノッチ部分に枠なし `NSPanel` を置き、状態機械（`character → peek → expanded`）で表示を切り替える。
  - `character`: キャラクターだけ表示。パネルはマウスを透過し、ホバー検知用の小さな領域だけ受ける。
  - `peek`: 承認待ちなどを知らせる小さな吹き出し。
  - `expanded`: ホバー中。プロジェクト、タスク投入、監視、承認、定義管理のタブ。
  - 寸法と状態機械は `AgentKit`（`NotchGeometry` / `NotchLayout` / `NotchPresentationMachine`）。島（黒い領域）はノッチの中心から左右対称に広がり、キャラクターはノッチの左の「翼」に置く（ノッチの中には画素が無いため）。ノッチの無い画面では上部中央の小さな島の真ん中に置く。キャラクターは展開しても動かない。
  - ホバー検知はマウス移動のイベント（グローバル／ローカルのモニタとトラッキング領域）を 15 Hz 以下に間引いて処理する。展開 0.12 秒・縮小 0.6 秒の遅延はワンショットの待ちだけで、常時動くタイマーは持たない。
- **キャラクター**: SwiftUI の `Canvas` + `TimelineView(.periodic)` で描く（画像アセットなし）。姿勢・まばたきは時刻の関数（`AgentKit` の `CharacterAnimation`）にし、描き直す頻度は状態ごとに決める（待機中 12 fps、作業中・承認待ち・完了 30 fps、エラーは静止）。目の追従は移動量が 0.25（viewBox 単位）以上変わったときだけ描き直す。「視差効果を減らす」がオンなら動きと追従を止める。
- **TaskRunner**: プロジェクトの作業フォルダで `claude -p ... --output-format stream-json --verbose --session-id <UUID>` を子プロセスとして起動し、stream-json の出力を読んで `SessionStore` に流す。`--session-id` をアプリが決めるので、同じセッションの hook イベントと確実に結び付く。停止は SIGINT → SIGTERM。詳細は [ADR-0002](adr/0002-task-launch.md)。
- **セッションとサブエージェントの識別**: hook の `session_id` でセッション、`agent_id` / `agent_type` が付いていればサブエージェント内のイベント。`SubagentStart` / `SubagentStop` で開始・終了（`docs/claude-code-spec.md` 3 章）。`SessionEnd` が来ないことがあるため、一定時間イベントの無いセッションは「停止」扱いにする（F3-5）。

## モジュール構成

| モジュール | 種類 | 内容 | Linux でテスト |
| --- | --- | --- | --- |
| `AgentKit` | Swift Package (library) | hook イベントと stream-json のモデルとデコード、セッション状態の集約、承認キュー、プロジェクト設定、タスク起動コマンドの組み立て、エージェント定義（frontmatter）のパース／生成、settings.json の安全なマージ、ソケットのワイヤプロトコルと Claude Code 向け出力への変換、ノッチの寸法計算と表示の状態機械 | ✅ |
| `notch-hook` | Swift Package (executable) | 中継 CLI。`AgentKit` のプロトコル定義を使う | ✅（ソケット部分含む） |
| `NotchAgent` | Xcode アプリ（XcodeGen） | AppKit / SwiftUI の UI、キャラクター描画、ソケットサーバー、子プロセス管理、ファイル監視、Keychain | ❌（macOS のみ） |

ディレクトリ（M0-4 で作成）:
```
Package.swift            # AgentKit, notch-hook（Linux / macOS）
Sources/AgentKit/
Sources/notch-hook/
Tests/AgentKitTests/
App/                     # NotchAgent（SwiftUI + AppKit、macOS のみ）
project.yml              # XcodeGen。App と、ローカルパッケージの AgentKit を参照
.github/workflows/ci.yml # Linux: swift test / macOS: xcodegen + xcodebuild
docs/
```
- アプリ名・バンドル ID は仮に `NotchAgent` / `dev.notchagent.NotchAgent`。キャラクターの名前が決まったら、公開前に変更する（バンドル ID は Keychain や設定の保存先になるので、変えるなら M5 より前）。

## 主要な設計判断（ADR 候補）
1. **連携方式は hooks + Unix ソケット**（coucou と同じ）。トランスクリプト監視は補助（サブエージェントの詳細取得）に限る。→ [ADR-0001](adr/0001-hook-bridge.md)
2. **タスクの起動は `claude` CLI を子プロセスで実行**する。→ [ADR-0002](adr/0002-task-launch.md)
3. **永続化するのはプロジェクト登録とタスク履歴だけ**（`~/Library/Application Support/<App>/` に JSON）。実行中セッションの状態はメモリのみ。
4. **設定ファイル書き込みは必ず「バックアップ → 差分 → 確認」**の 1 経路（`SafeFileWriter`）に集約する。
5. **待機中はタイマーを止める**。描画更新はイベント受信時とホバー中のみ。

## インターフェース草案（AgentKit）

```swift
public struct HookEvent: Sendable, Decodable {
    public let name: HookEventName          // 既知のイベント + .unknown(String)
    public let sessionID: String
    public let cwd: String?
    public let transcriptPath: String?
    public let permissionMode: String?
    public let agentID: String?              // サブエージェント内のイベントなら付く
    public let agentType: String?
    public let toolName: String?
    public let toolUseID: String?
    public let raw: JSONValue                // 受け取った JSON 全体（未知フィールドも保持）
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

public struct Project: Sendable, Codable, Identifiable {
    public let id: UUID
    public var name: String
    public var directory: URL
    public var environment: ProjectEnvironment   // model, permissionMode, allowedTools, env
}

public struct TaskRequest: Sendable {
    public var project: Project.ID
    public var agent: String?                    // nil = おまかせ
    public var prompt: String
}

public protocol TaskRunner: Sendable {
    func start(_ request: TaskRequest) async throws -> TaskHandle
    func stop(_ handle: TaskHandle) async
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

hook イベント名・ペイロードの形は `docs/claude-code-spec.md` 1 章のとおり。実ペイロードのフィクスチャは M1-3 で Mac から採取する。
