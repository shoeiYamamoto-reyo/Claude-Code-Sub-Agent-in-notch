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
 ├─ HookCenter      … ソケット受信（AgentKit の HookSocketServer）◀── Unix ソケット ── notch-hook（中継 CLI）
 ├─ SessionStore    … セッション／サブエージェントの状態（hook と TaskRunner の両方から）
 ├─ ApprovalQueue   … 承認待ちキュー（AgentKit の値型。表示中のカードにだけ答える）
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
- **キャラクター**: SwiftUI の `Canvas` + `TimelineView(.periodic)` で描く（画像アセットなし）。姿勢・まばたきは時刻の関数（`AgentKit` の `CharacterAnimation`）にし、描き直す頻度は状態ごとに決める（待機中 12 fps、作業中・承認待ち・完了 30 fps、エラーは静止）。目の追従はカーソル位置を 15 Hz 以下で取得し、目標が 0.25（viewBox 単位）以上変わったときだけ、今の位置から 0.15 秒かけて補間する（補間中だけ 60 fps、`EyeMotion`）。「視差効果を減らす」がオンなら動きと追従を止める。
- **TaskRunner**: プロジェクトの作業フォルダで `claude -p ... --output-format stream-json --verbose --session-id <UUID>` を子プロセスとして起動し、stream-json の出力を読んで `SessionStore` に流す。`--session-id` をアプリが決めるので、同じセッションの hook イベントと確実に結び付く。停止は SIGINT → SIGTERM。詳細は [ADR-0002](adr/0002-task-launch.md)。
- **hook の受信（M1 で実装）**: 受信そのもの（`HookSocketServer`）は POSIX ソケットと Dispatch だけで書けるので `AgentKit` に置き、Linux でも中継 CLI との結合テストを行う。アプリの `HookCenter` は、受け取った 1 行を MainActor で `SessionStore` に反映し、表示（セッション一覧・キャラクターの表情・承認待ちの peek）を更新する。時間で変わるもの（停止扱い、完了の表情を戻す）は次に起きる時刻にワンショットで起きるだけ。
- **SessionStore（M1 で実装）**: 値型。イベントと時刻を受けて状態を変える（`apply(_:environment:at:)`、`expire(now:)`）。状態は 入力待ち／実行中／承認待ち／完了／エラー／停止。作業中のまま 30 分音沙汰が無ければ「停止」、12 時間で一覧から消す（coucou と同じ閾値）。サブエージェントは `agent_id` 単位でセッションの下に平らに並べる（入れ子の親子は hook からは分からない）。
- **hooks のインストール（M1 で実装）**: `HookInstaller`（JSON の変換）と `SafeFileWriter`（バックアップ・競合検出・リンク先への書き込み・パーミッション保持）、`OrderedJSON`（キーの順番と数値の表記を保つ）、`LineDiff`（確認画面の差分）。アプリの `HookSetup` が差分を見せ、ユーザーが押したときだけ書く。
- **セッションとサブエージェントの識別**: hook の `session_id` でセッション、`agent_id` / `agent_type` が付いていればサブエージェント内のイベント。`SubagentStart` / `SubagentStop` で開始・終了（`docs/claude-code-spec.md` 3 章）。`SessionEnd` が来ないことがあるため、一定時間イベントの無いセッションは「停止」扱いにする（F3-5）。

## モジュール構成

| モジュール | 種類 | 内容 | Linux でテスト |
| --- | --- | --- | --- |
| `AgentKit` | Swift Package (library) | hook イベントと stream-json のモデルとデコード、セッション状態の集約、承認キュー、プロジェクト設定、タスク起動コマンドの組み立て、エージェント定義（frontmatter）のパース／生成、settings.json の安全なマージ、ソケットのワイヤプロトコルと Claude Code 向け出力への変換、ノッチの寸法計算と表示の状態機械、効果音の合成と鳴らす条件 | ✅ |
| `notch-hook` | Swift Package (executable) | 中継 CLI。`AgentKit` のプロトコル定義を使う | ✅（ソケット部分含む） |
| `NotchAgent` | Xcode アプリ（XcodeGen） | AppKit / SwiftUI の UI、キャラクター描画、受信とセッション表示のつなぎ込み、hooks インストールの確認画面、子プロセス管理、ファイル監視、Keychain。`notch-hook` を `Contents/MacOS/` に同梱 | ❌（macOS のみ） |

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
   - **クラウドのセッション（拡張）は、クラウド側の hook → ユーザー自身のリレー → アプリの WebSocket で受け取る**（提案）。→ [ADR-0003](adr/0003-cloud-sessions.md)
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

// M1 で値型として実装（Sources/AgentKit/Sessions/SessionStore.swift）。
public struct SessionStore: Sendable, Equatable {
    public mutating func apply(_ event: HookEvent, environment: HookWireMessage.Environment?, at now: Date)
    public mutating func expire(now: Date) -> Bool
    public var sessions: [Session] { get }
    public func mood(now: Date) -> CharacterMood
}

public enum ApprovalDecision: Sendable { case allow, deny(reason: String?) }

public protocol ApprovalQueue: Sendable {
    func enqueue(_ request: ApprovalRequest) async -> ApprovalDecision   // ユーザー操作まで待つ
    func resolve(_ id: ApprovalRequest.ID, with decision: ApprovalDecision) async
}

// M3-1 で実装（Sources/AgentKit/Projects/）。
public struct Project: Sendable, Codable, Identifiable {
    public let id: UUID
    public var name: String
    public var directory: String                 // 正規化した絶対パス（ProjectPath.normalize）
    public var environment: ProjectEnvironment   // model, effort, permissionMode, allowedTools, variables（秘密は Keychain）
}

public struct ProjectRegistry: Sendable, Equatable {
    public mutating func upsert(_ project: Project) throws(ValidationError) -> Project
    public mutating func remove(id: Project.ID) -> Project?
    public func project(containing path: String) -> Project?   // hook の cwd → プロジェクト（入れ子は内側）
}
// 保存は ProjectRegistryFile（~/Library/Application Support/NotchAgent/projects.json、{"version": 1, "projects": [...]}）。
// 読めない・新しい形式のファイルは上書きしない（アプリは編集を止めて知らせる）。

// M3-3 で実装（Sources/AgentKit/Tasks/）。
public struct TaskRequest: Sendable, Equatable {
    public var projectID: UUID
    public var agent: String?                    // nil = おまかせ
    public var prompt: String                    // 標準入力で渡す
    public var sessionID: UUID                   // --session-id。hook のセッションと同じ ID になる
}

public enum TaskCommand {                        // 起動コマンドと環境変数の組み立て
    public static func arguments(for: TaskRequest, environment: ProjectEnvironment, name: String?) -> [String]
    public static func environment(base:loginShellPath:project:secrets:) -> [String: String]
}

public enum ClaudeLocator {                      // 設定値 → ログインシェルの command -v → よくある場所
    public static func locate(configured: String?, probed: String?, home: String) -> String?
}
// 子プロセスの管理はアプリの TaskRunner（@MainActor クラス、Process を使う）。

// M3-4 で実装。stream-json の 1 行 → StreamJSONEvent、流し込んで TaskTranscript
// （最後の応答・成功した編集で変わったファイル・result）。LineBuffer で読み取りのチャンクを行に分ける。
public struct TaskTranscript: Sendable, Equatable {
    public mutating func consume(_ line: some StringProtocol)
    public var lastAssistantText: String? { get }   // メインの会話だけ（サブエージェントの応答は含めない）
    public var changedFiles: [String] { get }       // Edit / MultiEdit / Write / NotebookEdit の成功分
    public var result: TaskResult? { get }
}

// M3-2 で実装（Sources/AgentKit/Agents/）。読み取りのみ。書き出し（未知のフィールドを保つ往復）は M4-1。
public struct AgentDefinition: Sendable, Equatable {
    public var name: String
    public var description: String
    public var tools: [String]?              // nil = 全部を引き継ぐ
    public var model: String?
    public var body: String
    public var frontmatter: Frontmatter      // 書かれた順の全項目（入れ子のマップは raw）
    public static func parse(_ text: String) -> Result<AgentDefinition, Problem>   // Problem = Claude Code が読み飛ばす理由
}

public struct AgentCatalog: Sendable, Equatable {
    public var entries: [Entry]              // 優先順: 近いプロジェクトの .claude/agents → 遠いもの → ~/.claude/agents。上書きされたものは shadowedBy
    public var effective: [AgentDefinition]  // 実際に使われる定義（タスク投入の選択肢、M3-5）
    public static func load(projectDirectory: String?, home: String) -> AgentCatalog
}
```

hook イベント名・ペイロードの形は `docs/claude-code-spec.md` 1 章のとおり。実ペイロードのフィクスチャは M1-3 で Mac から採取する。
