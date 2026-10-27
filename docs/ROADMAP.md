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
| M7 クラウドのセッション（拡張） | claude.ai/code などクラウドで動く Claude Code もノッチに表示し、承認する |

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
| 1-3 | ☑ `HookEvent` モデルとデコード（未知イベントも落ちない） | swift-macos-engineer | 実ペイロードのフィクスチャをすべてデコードできる | `swift test` |
| 1-4 | ☑ `notch-hook` 中継 CLI（送信のみ、アプリ不在で即終了） | swift-macos-engineer | ソケット不在時に 100 ms 以内で exit 0 | `swift test`（タイムアウト試験） |
| 1-5 | ☑ `SessionStore`（セッション／サブエージェントの状態集約、停止判定） | swift-macos-engineer | イベント列 → 期待状態のテーブルテストが通る | `swift test` |
| 1-6 | ☑ ソケットサーバー（アプリ側）とセッション一覧・サブエージェントツリーの UI、キャラクターの状態連動 | swift-macos-engineer | 中継 CLI から送ったイベントが表示に反映される | 結合テスト + 手動 |
| 1-7 | ☑ hooks インストーラ（バックアップ → マージ → 差分 → 確認、アンインストール） | swift-macos-engineer | 既存設定が失われないことをテストで保証 | `swift test`（マージ処理）+ 手動 |
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
| 3-1 | ☑ `Project` / `ProjectEnvironment` のモデルと保存（`ProjectRegistry` / `ProjectRegistryFile`、`projects.json`）、登録・編集 UI（ノッチの「プロジェクト」タブ、編集ウインドウ、秘密の環境変数は Keychain）、未登録フォルダからの登録（セッションの行の「登録」） | swift-macos-engineer | 再起動後も登録が残る | `swift test` + 手動 |
| 3-2 | ☑ エージェント定義の読み取り（ユーザー／プロジェクト）と一覧表示（`Frontmatter` / `AgentDefinition` / `AgentCatalog`、ノッチの「エージェント」タブ。読み飛ばされる定義と、同じ名前で上書きされる定義も表示） | swift-macos-engineer | 実在の `.claude/agents/*.md` を正しく読める | `swift test` |
| 3-3 | ☑ `TaskRunner`: 起動コマンドの組み立て（`AgentKit` の `TaskCommand`、指示は標準入力で渡す）と子プロセス実行・停止（アプリ、SIGINT → 5 秒後 SIGTERM、出力は `tasks/<session-id>.jsonl`）、`claude` の場所の検出（`ClaudeLocator`、ログインシェルの `PATH`）。確認用の「タスクを開始」ウインドウ | swift-macos-engineer | 指示 → 実行 → 完了、途中停止が動く | コマンド組み立ては `swift test`、実行は手動 |
| 3-4 | ☑ stream-json のデコード（`StreamJSONEvent` / `TaskTranscript` / `LineBuffer`）と結果表示（最後の応答、変更ファイル、コスト・時間。タスクの行と「タスクの結果」ウインドウ）。進み具合のセッション一覧は同じ session-id の hook で表示されるので、`SessionStore` には入れない | swift-macos-engineer | 起動したタスクが一覧に出て、結果が見られる | `swift test`（フィクスチャ）+ 手動 |
| 3-5 | ☑ タスク投入 UI（プロジェクト・エージェント選択、指示入力、クイック入力ショートカット）。展開したノッチの入力欄（`QuickTaskBar`）を押すか ⌃⌥⌘N（`QuickInputHotKey`、起動中は登録したまま）で入力を始め、Return で開始、Esc でやめる。入力中だけパネルがキーウインドウになり（操作しないパネルなのでアプリは前面に出ない）、マウスが離れても縮まない（`NotchPresentationMachine.pin`）。プロジェクトの既定値は最後に使ったもの（`QuickTaskDefaults`）、エージェントは「おまかせ」。長い指示は従来のウインドウ | swift-macos-engineer | ホバー → 入力 → 開始が 3 操作以内 | 手動 |
| 3-6 | ☑ 追加の指示で続ける（`--resume`）。「タスクの結果」ウインドウの「追加の指示で続ける」から、終わったタスクを同じセッション ID で再開する（`TaskRequest.resume`、`--fork-session` は付けない）。エージェントとプロジェクトの環境は毎回付け直し、`--name` は付けない。一覧の行と出力ファイル（追記）は同じものを使い、`TaskTranscript.beginFollowUp` で前回の結果だけを消す | swift-macos-engineer | 同じセッションで会話が続く | 手動 |

## M4. 定義の管理
| # | タスク | 担当 | 完了条件 | テスト方法 |
| --- | --- | --- | --- | --- |
| 4-1 | ☑ `AgentDefinition` の生成（frontmatter 往復で内容が変わらない）と検証。`AgentDefinition.render` は読み込んだ frontmatter を土台に値が変わった項目だけを書き直し（`Frontmatter.set` / `render`）、未知の項目・順序・コメント・本文を残す。何も変えなければ同じテキストに戻る（改行は LF）。そのままでは別の意味に読まれる値はクォートし、複数行は `|` / `|-`。`validate` は Claude Code が読み飛ばす条件と同じフォルダの name の重なりをエラー、知らない model / effort / permissionMode / color などを警告にする | swift-macos-engineer | 往復テスト・検証テストが通る | `swift test` |
| 4-2 | ☑ 作成・編集 UI（差分表示 → 確認 → バックアップ付き保存）、ファイル監視で自動更新。「エージェント」タブの行を押すと編集、見出しの「＋」で新規作成。`AgentFileStore.plan` が検証（同じフォルダの name・ファイル名の重なりを含む）と書き込み内容を作り、差分を見て「保存」を押したときだけ `SafeFileWriter.commit`（バックアップ、編集中にファイルが変わっていたら書かない、新規は 0644）。CRLF のファイルは CRLF のまま。今あるエージェントのフォルダだけを FSEvents で見張り、変わったら読み直す | swift-macos-engineer | 確認なしに書き込まれない | `swift test` + 手動 |
| 4-3 | ☑ 「エージェント」タブをキャラクター一覧にする（`docs/design/agent-characters.md`）。定義ごとにノッチと同じ形のキャラを並べ、体の色は `color`（`AgentAppearance`、白はノッチだけ）。色の指定が無い・知らない値は白に近い灰色、読めない定義は濃い灰色の「> <」。普段は止めた絵で、マウスを乗せたキャラだけ動かし、上の欄に詳細を出す。押すと編集、最後の点線のキャラで新規作成 | swift-macos-engineer | 待機中に一覧が描き直されない | `swift test` + 手動 |
| 4-4 | ☑ 定義の編集をノッチの中で完結させる（F5-7）。キャラを押すとノッチ内で一覧 → 編集フォーム → 差分確認と画面が移る（`AgentEditorView`、別ウインドウは開かない）。編集中はノッチを 640 × 600 に広げて留め（`NotchLayout.editingMinimumSize`、`machine.pin`）、クイック入力と同じくパネルだけをキーウインドウにする（アプリは前面に出さない）。ほかのアプリを押すと留めるのをやめて縮むが、入力内容は `AgentEditSession` に残り、乗せ直すと続きから書ける。「一覧」・「キャンセル」・Esc で一覧へ戻る（変更があればノッチ内で確かめる）。承認リクエストは編集画面の上に出す | swift-macos-engineer | 編集中にノッチが縮まず、別ウインドウを開かずに保存できる | `swift test` + 手動 |

## M5. 仕上げ・公開準備
| # | タスク | 担当 | 完了条件 | テスト方法 |
| --- | --- | --- | --- | --- |
| 5-1 | ☑ 設定画面（⌘,）とログイン時起動（F6-4）。「一般」（ログイン時に起動: `SMAppService.mainApp`、表示する画面、クイック入力のショートカット）、「サウンド」（メニューから移した）、「Claude Code」（claude の場所、hooks のインストール）。メニューにはおやすみモードだけ残す | swift-macos-engineer | 設定画面からログイン項目に登録・解除でき、システム設定の状態と食い違わない | 手動 |
| 5-2 | ☑ 待機中の CPU の再計測と、残っていれば原因の調査（下のメモ）。待機中はまばたきの間だけ描くようにした（PR #25）。2026-10-27 に手元の Mac で「特に問題なし」と確認 | swift-macos-engineer | 待機中ほぼ 0 %（`top` で 2 秒ごと 10 回の平均 1 % 未満） | 手動 |
| 5-3 | ☐ ファイル編集の差分（+N −M）と詳細表示（F3-6） | swift-macos-engineer | 編集のたびに件数が増え、詳細で差分が見える | `swift test` + 手動 |
| 5-4 | ☐ タスクの履歴（F3-8）と定義ごとの利用回数（F5-6） | swift-macos-engineer | アプリを再起動しても履歴が残る | `swift test` + 手動 |
| 5-5 | ☐ 指示のテンプレート（F2-6） | swift-macos-engineer | 保存したテンプレートからタスクを始められる | 手動 |
| 5-6 | ☐ セッションをターミナルで開く（F2-7）、git worktree での並行実行（F2-5） | swift-macos-engineer | 続きを手で操作でき、並行タスクが作業場所を取り合わない | 手動 |
| 5-7 | ☐ 集中モードとの連動（F0-8 の続き） | architect | 採否と方法を決める | レビュー |
| 5-8 | ☐ サブエージェントのキャラの見た目のカスタマイズ（F5-8）: 色以外（目の形・体形・小物など）。設定はアプリ側に保存する | swift-macos-engineer | 定義ファイルを書き換えずに見た目が変わる | 手動 |
| 5-9 | ☐ 公開準備: 英語対応、アプリ署名と公証、README のインストール手順、リリース自動化 | swift-macos-engineer | 署名・公証済みの配布物ができる | 手動 |
| 5-10 | ☐ 展開したノッチから設定画面を開けるようにする（5-1 の続き、下のメモ）。メニューバーのアイコンが隠れても設定に届くように、ノッチの展開画面（タブの並びの右端など）に「設定」ボタンを置き、5-1 の「設定…」と同じく `NSApp.activate()` → `openSettings()` で開く。おやすみモードも同じ場所から切り替えられると良い | swift-macos-engineer | メニューバーのアイコンが見えない状態でも、ノッチから設定画面を開ける | 手動 |

メモ
- 待機中の CPU 使用率（課題）: 2026-10-26 に手元の Mac（Debug ビルド）で測ると、待機中（`idle`）でも約 5 %、作業中は約 8 %（`top` で 2 秒ごとに 10 回）。待機中も 12 fps で `Canvas` を描き直し続けているのが主な原因とみられる（`CharacterAnimation.frameInterval`）。目のマウス追従はこのままにする前提で、待機中の描き直しを止める・間隔を広げるなどを検討する。REQUIREMENTS の性能目標（ほぼ 0 %）は未達。 → 待機中は呼吸をやめ、まばたきの間（4.5 秒ごとに約 0.2 秒）と目の追従中だけ描くようにした（`CharacterAnimation.nextFrameTime`）。2026-10-27 に手元の Mac で確かめ、問題なしとの報告（数値は未記録）。
- メニューバーのアイコンが隠れる（5-10）: 2026-10-27 に手元の Mac（14 インチ、ノッチあり）で PR #28 を確認したとき、メニューバーの常駐アイコンが多く、Notch Agent のアイコン（`circle.dotted`）がノッチの裏に隠れて表示されなかった。この状態ではメニューの「設定…」（⌘,）を押せず、設定画面に届かない（アプリを前面に出して ⌘, を送ると開けることは確認した）。メニューバーにしか入口が無い操作（hooks のインストール、claude の場所、おやすみモードなど）も同じ。

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

## M7. クラウドのセッション（拡張）
方針は [ADR-0003](adr/0003-cloud-sessions.md)（提案）。M2 の後ならいつでも着手できる。7-0 の結果で ADR を「承認」にし、7-1 以降の範囲を確定する。

**リレーなしで今すぐできること**: プロジェクトのスレッドを自分の Mac で動かす（Remote Control）と、Mac 上の Claude Code として今の hooks 経路で表示・承認できる。

| # | タスク | 担当 | 完了条件 | テスト方法 |
| --- | --- | --- | --- | --- |
| 7-0 | ☐ 検証スパイク: ADR-0003 の C1〜C5（リポジトリの hooks がクラウドで動くか、`PermissionRequest` の応答が効くか、プロジェクトのスレッドで hooks を動かす手段、ネットワークシークレット、`SessionEnd` の送り切り） | claude-code-integration | C1〜C5 に「確認済み（日付・方法）」か「不可」が付き、ADR-0003 が更新されている | 実機（クラウド） |
| 7-1 | ☐ リレーのワイヤ形式（`origin: cloud`、`cloud.session_id`、`repo`）のモデルとデコード・検証を `AgentKit` に追加。`SessionStore` がクラウドのセッションを区別して持つ | swift-macos-engineer | 不正な入力でも落ちず、ローカルとクラウドの同じ ID が混ざらない | `swift test` |
| 7-2 | ☐ `notch-cloud-hook.sh`（`CLAUDE_CODE_REMOTE` 以外では即終了、送信は `async`、`--wait` / `--ask` は応答待ち、失敗時は何も出さず exit 0） | swift-macos-engineer | リレー不在で 3 秒以内に exit 0、ローカルでは何もしない | シェルのテスト（Linux CI）+ 実機 |
| 7-3 | ☐ リレー（`relay/`、Cloudflare Workers + Durable Object）: `event` / `wait` / `stream` / `decision`、トークン照合、保存しない、Mac 未接続なら即「判断しない」 | swift-macos-engineer | 認証なしの要求を拒否し、Mac 未接続の `wait` が即座に返る | Workers のローカル実行でテスト（CI） |
| 7-4 | ☐ アプリの `RelayClient`（`URLSession` WebSocket、有効時のみ接続、再接続）と一覧の「クラウド」表示、claude.ai/code を開く | swift-macos-engineer | 有効にしていなければ一切通信しない。待機中 CPU ほぼ 0 % のまま | `swift test`（再接続の判定）+ 手動 |
| 7-5 | ☐ クラウドの承認・質問を `ApprovalQueue` に統合（「クラウド」とリポジトリ名を表示、claude.ai で先に答えたらカードを消す） | swift-macos-engineer | 明示クリック以外で承認されない。期限切れで「判断しない」になる | `swift test` + 実機 |
| 7-6 | ☐ セットアップ: 設定画面（URL・端末トークン・接続状態・テスト送信）、クラウド環境の設定手順（ネットワークシークレット／許可ドメイン）と hooks の追加（差分 → 確認）、`docs/cloud-setup.md` | swift-macos-engineer | 手順どおりに設定するとクラウドのセッションが表示される | 手動 |
| 7-7 | ☐ ノッチからクラウドのタスクを始める（`claude --cloud`）・追加の指示（`claude -p --cloud <id>`）。需要を見て判断 | architect | 採否を ADR-0003 に追記 | レビュー |

## 各タスクの完了の定義（共通）
- テストが追加され、CI が緑。
- `code-reviewer` のレビューで指摘が解消済み。
- 関係する docs（REQUIREMENTS / ARCHITECTURE / ROADMAP の状態）を更新済み。
