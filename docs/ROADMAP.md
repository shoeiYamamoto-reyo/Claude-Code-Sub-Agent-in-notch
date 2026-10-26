# ロードマップ

各タスクは 1 PR で完結する大きさにする。担当はサブエージェント名（`.claude/agents/`）。機能 ID は `docs/REQUIREMENTS.md` を参照。
状態: ☐ 未着手 / ◐ 進行中 / ☑ 完了

| マイルストーン | ゴール |
| --- | --- |
| M0 準備 | 仕様確認、リポジトリの骨組み、CI |
| M1 常駐と監視 | キャラクターが常駐し、ホバーで展開。手動起動したセッションが見える |
| M2 承認 | ノッチから権限リクエストに答えられる |
| M3 プロジェクトとタスク投入 | プロジェクトを登録し、サブエージェントに仕事を与えて結果を見る |
| M4 定義の管理 | サブエージェント定義の作成・編集 |
| M5 仕上げ・公開準備 | 日常使いの快適さと配布 |
| M6 他アプリの通知（拡張） | git・メール・GitHub などの通知もノッチで受け取る |

## M0. 準備
| # | タスク | 担当 | 完了条件 | テスト方法 |
| --- | --- | --- | --- | --- |
| 0-1 | ☑ Claude Code の hooks / agents / settings / CLI（`-p`, stream-json, エージェント指定, `--resume`）/ トランスクリプト仕様を一次情報で確認し `docs/claude-code-spec.md` にまとめる | claude-code-integration | REQUIREMENTS 7 章の項目すべてに「確認済み（出典 URL）」か「未確認」が付いている | レビュー |
| 0-2 | ☑ coucou の hook 中継・ソケット・承認キュー・ノッチ表示・キャラクター描画の実装を調査し `docs/coucou-notes.md` にまとめる | coucou-researcher | 参考にする箇所のファイルパスと要点、流用時のライセンス注意点 | レビュー |
| 0-3 | ☑ 0-1, 0-2 を受けて ARCHITECTURE.md と ADR-0001 / 0002 を確定する | architect | ADR が「承認」 | レビュー |
| 0-4 | ☑ リポジトリの骨組み: `Package.swift`（AgentKit, notch-hook）、`project.yml`、空のアプリ、`.gitignore` | swift-macos-engineer | `swift build` と `xcodegen && xcodebuild` が通る | CI |
| 0-5 | ☑ CI: Linux で `swift test`、macOS で `swift test` と `xcodebuild build`（アプリのテストターゲットができたら `test` も足す） | test-engineer | PR で自動実行され緑 | CI |

## M1. 常駐と監視
| # | タスク | 担当 | 完了条件 | テスト方法 |
| --- | --- | --- | --- | --- |
| 1-1 | ☑ ノッチパネル: NSPanel の配置（ノッチ有無・複数ディスプレイ）、`character / peek / expanded` の状態機械、ホバーで展開・離れて縮む、非展開時はクリック透過 | swift-macos-engineer | ノッチ有り・無しの両方で正しい位置に出る | 状態機械は `swift test`、表示は手動 |
| 1-2 | ☑ キャラクター: `docs/design/character.md` のとおり `Canvas` で描画、5 状態の表情、マウス追従、待機中の低頻度アニメーション | swift-macos-engineer | 待機中 CPU ほぼ 0 %（アクティビティモニタで確認） | 手動 |
| 1-3 | ☐ `HookEvent` モデルとデコード（未知イベントも落ちない） | swift-macos-engineer | 実ペイロードのフィクスチャをすべてデコードできる | `swift test` |
| 1-4 | ☐ `notch-hook` 中継 CLI（送信のみ、アプリ不在で即終了） | swift-macos-engineer | ソケット不在時に 100 ms 以内で exit 0 | `swift test`（タイムアウト試験） |
| 1-5 | ☐ `SessionStore`（セッション／サブエージェントの状態集約、停止判定） | swift-macos-engineer | イベント列 → 期待状態のテーブルテストが通る | `swift test` |
| 1-6 | ☐ ソケットサーバー（アプリ側）とセッション一覧・サブエージェントツリーの UI、キャラクターの状態連動 | swift-macos-engineer | 中継 CLI から送ったイベントが表示に反映される | 結合テスト + 手動 |
| 1-7 | ☐ hooks インストーラ（バックアップ → マージ → 差分 → 確認、アンインストール） | swift-macos-engineer | 既存設定が失われないことをテストで保証 | `swift test`（マージ処理）+ 手動 |
| 1-8 | ☑ 効果音（F0-6）とおやすみモード（F0-8）: オリジナル音の合成、開閉・お知らせ・完了・エラーで鳴らす、メニューの「サウンド」で設定。設計は `docs/design/sound.md` | swift-macos-engineer | 設定どおりに鳴る／鳴らない。待機中 CPU ほぼ 0 % のまま | `swift test`（音の対応・判定・合成）+ 手動 |

## M2. 承認
| # | タスク | 担当 | 完了条件 | テスト方法 |
| --- | --- | --- | --- | --- |
| 2-1 | ☑ 中継 CLI の応答待ちモード（承認イベントで応答を待ち、stdout に決定を返す） | swift-macos-engineer | 許可・拒否・タイムアウト・アプリ終了の 4 パターンが正しく動く | `swift test` |
| 2-2 | ☑ `ApprovalQueue` と承認 UI（peek での通知、許可／拒否、キュー表示、ショートカット）。ショートカットはパネルがキー入力を受けないため、グローバルなホットキー（Carbon の `RegisterEventHotKey`）で、権限リクエストのカードがある間だけ登録する: ⌥⌘Y 許可、⌥⌘N 拒否、⌥⌘A 常に許可、⌥⌘T ターミナルで答える（`ApprovalShortcut`）。質問カードはショートカットなし | swift-macos-engineer | 明示クリック以外で承認されない | `swift test` + 手動 |
| 2-3 | ☑ `AskUserQuestion` への回答（仕様上可能な場合） | swift-macos-engineer | 選択肢を選ぶと Claude Code に反映 | 手動 |

## M3. プロジェクトとタスク投入
| # | タスク | 担当 | 完了条件 | テスト方法 |
| --- | --- | --- | --- | --- |
| 3-1 | ☐ `Project` / `ProjectEnvironment` のモデルと保存、登録・編集 UI、未登録フォルダからの登録 | swift-macos-engineer | 再起動後も登録が残る | `swift test` + 手動 |
| 3-2 | ☐ エージェント定義の読み取り（ユーザー／プロジェクト）と一覧表示 | swift-macos-engineer | 実在の `.claude/agents/*.md` を正しく読める | `swift test` |
| 3-3 | ☐ `TaskRunner`: 起動コマンドの組み立て（`AgentKit`）と子プロセス実行・停止（アプリ）、`claude` の場所の検出 | swift-macos-engineer | 指示 → 実行 → 完了、途中停止が動く | コマンド組み立ては `swift test`、実行は手動 |
| 3-4 | ☐ stream-json のデコードと `SessionStore` への反映、結果表示（最後の応答、変更ファイル） | swift-macos-engineer | 起動したタスクが一覧に出て、結果が見られる | `swift test`（フィクスチャ）+ 手動 |
| 3-5 | ☐ タスク投入 UI（プロジェクト・エージェント選択、指示入力、クイック入力ショートカット） | swift-macos-engineer | ホバー → 入力 → 開始が 3 操作以内 | 手動 |
| 3-6 | ☐ 追加の指示で続ける（`--resume`） | swift-macos-engineer | 同じセッションで会話が続く | 手動 |

## M4. 定義の管理
| # | タスク | 担当 | 完了条件 | テスト方法 |
| --- | --- | --- | --- | --- |
| 4-1 | ☐ `AgentDefinition` の生成（frontmatter 往復で内容が変わらない）と検証 | swift-macos-engineer | 往復テスト・検証テストが通る | `swift test` |
| 4-2 | ☐ 作成・編集 UI（差分表示 → 確認 → バックアップ付き保存）、ファイル監視で自動更新 | swift-macos-engineer | 確認なしに書き込まれない | `swift test` + 手動 |

## M5. 仕上げ・公開準備
- ログイン時起動、設定画面（サウンド設定をメニューから移す）、集中モードとの連動、差分表示（F3-6）。
- タスク履歴（F3-8）、テンプレート（F2-6）、git worktree での並行実行（F2-5）、ターミナルで開く（F2-7）。
- 公開時: 英語対応、アプリ署名と公証、README のインストール手順、リリース自動化。

## M6. 他アプリの通知（拡張）
方針は [external-notifications.md](external-notifications.md)。6-1〜6-4 は M2 の後ならいつでも着手できる（ソケットと承認キューの優先度付けが前提）。

| # | タスク | 担当 | 完了条件 | テスト方法 |
| --- | --- | --- | --- | --- |
| 6-1 | ☐ ワイヤプロトコルに `notify` を追加し、`ExternalNotification` のモデル・検証・`NotificationStore`（直近 N 件、既読、ミュート）を `AgentKit` に実装 | swift-macos-engineer | 不正な入力でも落ちず、上限件数で古いものから消える | `swift test` |
| 6-2 | ☐ `notch-notify` CLI（送信のみ、`run -- <cmd>` で終了通知、アプリ不在で即終了） | swift-macos-engineer | ソケット不在時に 100 ms 以内で終了し、`run` は元コマンドの終了コードを返す | `swift test` |
| 6-3 | ☐ 「通知」タブと peek・キャラクターへの反映（承認待ちを常に優先） | swift-macos-engineer | 承認待ちがある間は外部通知で peek が置き換わらない | `swift test`（優先度）+ 手動 |
| 6-4 | ☐ レシピ集（git hooks、Mail.app ルール、ショートカット、launchd）を docs に追加 | swift-macos-engineer | 手順どおりに設定すると通知が届く | 手動 |
| 6-5 | ☐ GitHub 連携（Notifications API、Keychain、`If-Modified-Since` / `X-Poll-Interval`、種類の絞り込み） | swift-macos-engineer | 304 時は何も更新せず、間隔を守る | `swift test`（応答フィクスチャ）+ 手動 |
| 6-6 | ☐ Slack 連携（Socket Mode）と Dock バッジ表示は需要を見て判断 | architect | 採否を ADR に残す | レビュー |

## 各タスクの完了の定義（共通）
- テストが追加され、CI が緑。
- `code-reviewer` のレビューで指摘が解消済み。
- 関係する docs（REQUIREMENTS / ARCHITECTURE / ROADMAP の状態）を更新済み。
