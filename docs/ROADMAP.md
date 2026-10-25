# ロードマップ

各タスクは 1 PR で完結する大きさにする。担当はサブエージェント名（`.claude/agents/`）。
状態: ☐ 未着手 / ◐ 進行中 / ☑ 完了

## M0. 準備（仕様確認と土台）
| # | タスク | 担当 | 完了条件 | テスト方法 |
| --- | --- | --- | --- | --- |
| 0-1 | ☐ Claude Code の hooks / agents / settings / トランスクリプト仕様を一次情報で確認し `docs/claude-code-spec.md` にまとめる | claude-code-integration | 要件定義書 6 章の項目すべてに「確認済み（出典 URL）」か「未確認」が付いている | レビュー |
| 0-2 | ☐ coucou の hook 中継・ソケット・承認キュー・ノッチ表示の実装を調査し `docs/coucou-notes.md` にまとめる | coucou-researcher | 参考にする箇所のファイルパスと要点、流用時のライセンス注意点 | レビュー |
| 0-3 | ☐ 0-1, 0-2 を受けて ARCHITECTURE.md と ADR-0001 を確定する | architect | ADR が「承認」 | レビュー |
| 0-4 | ☐ リポジトリの骨組み: `Package.swift`（AgentKit, notch-hook）、`project.yml`、空のアプリ、`.gitignore` | swift-macos-engineer | `swift build` と `xcodegen && xcodebuild` が通る | CI |
| 0-5 | ☐ CI: Linux で `swift test`、macOS で `xcodebuild build test` | test-engineer | PR で自動実行され緑 | CI |

## M1. 監視 MVP（読み取り専用）
| # | タスク | 担当 | 完了条件 | テスト方法 |
| --- | --- | --- | --- | --- |
| 1-1 | ☐ `HookEvent` モデルとデコード（未知イベントも落ちない） | swift-macos-engineer | 実ペイロードのフィクスチャをすべてデコードできる | `swift test` |
| 1-2 | ☐ `notch-hook` 中継 CLI（送信のみ、アプリ不在で即終了） | swift-macos-engineer | ソケット不在時に 100 ms 以内で exit 0 | `swift test`（タイムアウト試験） |
| 1-3 | ☐ `SessionStore`（セッション／サブエージェントの状態集約、停止判定） | swift-macos-engineer | イベント列 → 期待状態のテーブルテストが通る | `swift test` |
| 1-4 | ☐ ソケットサーバー（アプリ側） | swift-macos-engineer | 中継 CLI から送ったイベントがストアに届く | 結合テスト（macOS） |
| 1-5 | ☐ ノッチ UI: NSPanel、compact / expanded、セッション一覧とサブエージェントのツリー | swift-macos-engineer | 3 セッション同時表示、ノッチ無し画面でも表示 | 手動確認チェックリスト |
| 1-6 | ☐ hooks インストーラ（バックアップ → マージ → 差分 → 確認、アンインストール） | swift-macos-engineer | 既存設定が失われないことをテストで保証 | `swift test`（マージ処理）+ 手動 |

## M2. 承認
| # | タスク | 担当 | 完了条件 | テスト方法 |
| --- | --- | --- | --- | --- |
| 2-1 | ☐ 中継 CLI の応答待ちモード（承認イベントで応答を待ち、stdout に決定を返す） | swift-macos-engineer | 許可・拒否・タイムアウト・アプリ終了の 4 パターンが正しく動く | `swift test` |
| 2-2 | ☐ `ApprovalQueue` と承認 UI（許可／拒否、キュー表示、ショートカット） | swift-macos-engineer | 明示クリック以外で承認されない | `swift test` + 手動 |
| 2-3 | ☐ `AskUserQuestion` への回答（仕様上可能な場合） | swift-macos-engineer | 選択肢を選ぶと Claude Code に反映 | 手動 |

## M3. サブエージェント定義の管理
| # | タスク | 担当 | 完了条件 | テスト方法 |
| --- | --- | --- | --- | --- |
| 3-1 | ☐ `AgentDefinition` のパース／生成（frontmatter 往復で内容が変わらない） | swift-macos-engineer | 往復テストが通る | `swift test` |
| 3-2 | ☐ 定義の一覧（ユーザー／プロジェクト、ファイル監視で自動更新） | swift-macos-engineer | ファイル追加・変更が反映される | 手動 |
| 3-3 | ☐ 作成・編集 UI（差分表示 → 確認 → バックアップ付き保存、検証） | swift-macos-engineer | 確認なしに書き込まれない | `swift test` + 手動 |

## M4. 仕上げ・配布
- ログイン時起動、設定画面、日本語／英語、アプリ署名と公証、README のインストール手順、リリース自動化。
- 再検討: 差分表示（F1-6）、ターミナルを前面に出す（F1-7）、「常に許可」（F2-6）、ノッチからのエージェント起動。

## 各タスクの完了の定義（共通）
- テストが追加され、CI が緑。
- `code-reviewer` のレビューで指摘が解消済み。
- 関係する docs（REQUIREMENTS / ARCHITECTURE / ROADMAP の状態）を更新済み。
