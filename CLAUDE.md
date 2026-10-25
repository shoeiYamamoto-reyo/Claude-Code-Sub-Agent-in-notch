# Claude Code Sub-Agent in Notch — AI コーディングエージェント向けガイド

Mac のノッチ（ノッチが無い画面では画面上部）に常駐し、Claude Code のエージェントとサブエージェントを管理・監視する macOS ネイティブアプリを作るリポジトリです。参考実装は [coucou](https://github.com/louis-cfm/coucou)（MIT）。

## 目指す機能（初期案）
- 実行中の Claude Code セッションと、その中で動いているサブエージェントをノッチに一覧表示する（hooks 経由で受信）。
- 権限リクエストの承認／拒否、`AskUserQuestion` への回答をノッチから行う。
- `~/.claude/agents/` と各プロジェクトの `.claude/agents/` にあるサブエージェント定義を一覧・作成・編集する。

## サブエージェント（`.claude/agents/`）
| 名前 | 役割 | 使う場面 |
| --- | --- | --- |
| `architect` | 要件整理・設計・タスク分解 | 新機能に着手する前、設計判断が必要なとき |
| `coucou-researcher` | 参考実装 coucou の調査 | 「coucou ではどうしているか」を知りたいとき |
| `claude-code-integration` | Claude Code の hooks / agents / settings / トランスクリプト仕様 | 連携部分の仕様確認・設計 |
| `swift-macos-engineer` | Swift / SwiftUI / AppKit の実装 | コードを書く・直すとき |
| `test-engineer` | テスト追加・ビルド検証・CI | 実装の後、失敗の調査 |
| `code-reviewer` | 差分レビュー（読み取り専用） | コミット・PR の前 |

標準の流れ: `architect`（必要に応じて `coucou-researcher` / `claude-code-integration` に調査を依頼）→ `swift-macos-engineer` → `test-engineer` → `code-reviewer` → PR。

## ルール
- Swift 6 / SwiftUI + AppKit、macOS 15 以上。XcodeGen の `project.yml` で管理し、`.xcodeproj` は手で編集しない。外部依存は原則なし。
- UI に依存しないロジックは Swift Package に分け、Linux でも `swift test` できるようにする。
- Claude Code を絶対にブロックしない（アプリが応答しなければ hook は即終了）。
- `~/.claude/settings.json` やエージェント定義を黙って上書きしない（バックアップ → 差分表示 → 確認後に書き込み）。
- 権限承認はユーザーの明示的なクリックでのみ行う。
- 秘密情報は Keychain。テレメトリなし。非表示時の CPU 使用率は 0 % を目標にする。
- coucou のコードを流用する場合は MIT の著作権表示を残す。キャラクター等のアセットは別ライセンスなので流用しない。
- ユーザーとのやり取りは日本語で行う。
