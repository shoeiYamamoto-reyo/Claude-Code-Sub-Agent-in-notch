# coucou 調査メモ

- 対象: [louis-cfm/coucou](https://github.com/louis-cfm/coucou) `main` @ `47d1c2d`（2026-10-23）
- 調べた範囲: Mac 版 `NotchBuddy/`（hook 中継、ソケット、承認キュー、settings.json の書き込み、ノッチ表示、キャラクター描画）。iPhone / Windows / 音声 / 外部サービス連携は対象外。
- 行番号は上記コミット時点のもの。

## 0. ライセンス（最初に読むこと）
- **コード**: MIT（`LICENSE`, © 2026 Louis Raillé）。流用するファイルの先頭に、著作権表示と MIT の許諾文を残す。
- **アセット・名前**: `LICENSE-ASSETS.md` で別扱い（All rights reserved）。対象は名前「Coucou」「Mochi」、**Mochi のキャラクター（デザイン・見た目・表情・アニメーション）**、アプリ／メニューバーのアイコン、`Resources/sounds/` の音、`docs/media/` と `design/` の画像・動画。
  - → `BotEngine.swift` / `MochiOutfitDrawing.swift` などキャラクターを描くコードは、コードとしては MIT でも**出来上がる見た目が Mochi そのもの**になるため流用しない。描画の仕組み（`TimelineView` + `Canvas` の構成）だけ参考にする。
  - 音も流用しない。
- 当面の方針: **コードはコピーせず、設計を参考に書き直す**。どうしてもまとまった量を移すときは、そのファイルに出典コメントと MIT 表示を入れ、PR に明記する。

## 1. 全体の構成
| 役割 | coucou の場所 | 要点 |
| --- | --- | --- |
| hook 中継 | `HookServer.swift` 内の文字列 `nbHookShellWrapper`（L3237〜）と `nbHookPythonGitHub`（L3273〜） | シェルの wrapper + **Python スクリプト**。アプリ起動時に `~/Library/Application Support/NotchBuddy/` に書き出す |
| ソケットサーバー | `HookServer.swift` L300〜400 | Unix ソケット `~/Library/Application Support/NotchBuddy/nb.sock`。改行区切り JSON |
| イベント処理 | `HookServer.swift` `processEvent`（L410〜690） | `hook_event_name` で switch。`AppState`（`ObservableObject`）を更新 |
| 承認 | `HookServer.swift` `processPermissionRequest`（L803〜940）、`ApprovalQueue.swift` | 接続を開いたまま保持し、クリックで応答を書き込む |
| 質問 | `AskQuestion.swift`、`processQuestionRequest` | `PreToolUse` の専用フック（`--ask`） |
| hooks インストール | `HookServer.swift` L1440〜1540、`ClaudeSettingsFile.swift` | バックアップ → マージ → 差分 → 確認 |
| セッション集約 | `PillSessionRegistry.swift` | 値型。`maxSilence` 12 時間、`maxTurnSilence` 30 分 |
| ノッチのウィンドウ | `IslandWindowController.swift`、`IslandScreenGeometry.swift`、`IslandDisplayChoice.swift` | 枠なし `NSPanel` |
| 表示の状態機械 | `IslandStateMachine.swift` | AppKit 非依存の純粋な状態機械 |
| キャラクター | `BotCanvasView.swift`、`CoucouKit/BotEngine.swift` | `TimelineView(.animation)` + `Canvas` |

## 2. hook 中継（nb-hook）
- 構成: `/bin/sh` の wrapper が `xcode-select -p` を確認してから `/usr/bin/python3 nb-hook.py` を実行。**`xcode-select` を確認するのは、CLT 未インストールの Mac で python3 を呼ぶとインストールダイアログが出てしまうため**（L3234 のコメント）。wrapper は常に exit 0。
- 動き（`nb-hook.py`）:
  - stdin を全部読んで JSON にする。読めなければ何もせず終了。
  - 送信時に端末情報を付け足す: `term_program`（`TERM_PROGRAM`）、`iterm_session_id`、`term_session_id`、`bundle_id`（`__CFBundleIdentifier`）。トランスクリプトの先頭から `session_root`（起動時の cwd）、末尾から `/rename` のタイトルも読む。
  - **承認以外のイベント**: `settimeout(0.3)` で接続・送信して即終了（応答は待たない）。
  - **`PermissionRequest`**: `settimeout(118)` で接続し、アプリからの 1 行の応答を待つ。応答 `{"permissionDecision": "allow" | "always" | "deny" | "ask" | ...}` を Claude Code の形式（`hookSpecificOutput.decision.behavior`）に変換して stdout に出す。`always` は `permission_suggestions` を `updatedPermissions` に入れて返す。接続できない・タイムアウト・`ask` のときは**何も出力しない**（= ターミナルで通常どおり確認）。
  - **`--ask`（`AskUserQuestion`）**: `PreToolUse` の専用フック。`tool_name` が違えば即終了。`settimeout(125)` で応答を待ち、`answer` なら `permissionDecision: allow` + `updatedInput{questions, answers}` を出す。
- 登録内容（`~/.claude/settings.json`、L1465〜1492）:
  - `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `Notification`, `Stop`, `StopFailure`, `SubagentStart`, `SubagentStop` に timeout 10 秒。
  - `PermissionRequest` に timeout **120 秒**。
  - `PreToolUse` に matcher `AskUserQuestion` で `nb-hook --ask`、timeout **130 秒**。
  - コマンドは `/bin/sh "<パス>"`（空白入りパスに対応するためクォート）。
- **自分たちとの違い**: Python 依存をやめ、Swift の単一実行ファイル `notch-hook` にする（REQUIREMENTS の「外部依存なし」、CLT のダイアログ問題も起きない）。コマンドは `args` 形式（シェルを通さない）で登録できる（`docs/claude-code-spec.md` 8 章）。

## 3. ソケットサーバーと承認の流れ
- `accept` ループ → 1 接続 1 スレッド（`Thread.detachNewThread`）。同時接続上限 32、受信タイムアウト 5 秒（`SO_RCVTIMEO`）、1 メッセージ最大 1 MB。
- ソケットのパスは `sun_path` の 104 バイト制限に注意（App Store 版は短いパスにしている、L20〜26）。
- 承認（`processPermissionRequest`）:
  1. 端末・エディタの種類で「ノッチで扱うか」を判断。扱わないものは即 `ask` を返す（ターミナルに任せる）。
  2. `QueuedApproval`（fd, session, tool, command, `inputKey` = `tool_input` を sortedKeys で直列化した文字列）をキューに入れる。**上限 5 件**、溢れたら `ask`。
  3. fd に `DispatchSource.makeReadSource` を付ける。**相手が接続を閉じたら（= ターミナル側で答えた、または Claude Code がフックを kill した）カードを消す**。fd を閉じるのはこの source の cancel handler だけ、という規則で二重 close を防いでいる。
  4. 115 秒の安全タイムアウトで、応答せずに閉じる（中継は EOF を読んで何も出さずに終わる → ターミナルで再確認）。
  5. クリックしたときは、**画面に出ていた要求の ID** にだけ応答する（カードが次の要求に切り替わった直後の誤クリック対策）。
  6. `PostToolUse` が来たら `inputKey` で照合して、ターミナルで答えられた要求を片付ける。
- `ApprovalQueue.swift` は AppKit も I/O も持たない値型で、テストしやすい。→ 同じ形で `AgentKit` に置く。

## 4. settings.json の安全な書き込み（`ClaudeSettingsFile.swift`）
そのまま採用したい規則:
- ファイルが無い → 空のオブジェクトとして扱う。**あるのに読めない・JSON オブジェクトでない → 何もしない**（空とみなして上書きしない）。
- `hooks` が想定外の型（オブジェクトでない、各イベントが配列でない）→ 何もしない。
- 書き込みは「プレビュー時に読んだバイト列」と「今のファイル」を比べ、**変わっていたら書かない**（別のツールや手編集との競合対策）。
- 書く前に日付付きバックアップ（同名があれば連番）。
- **シンボリックリンク**（dotfiles 管理）なら、リンク先のファイルに書いてリンクを保つ。
- パーミッションを保つ（新規は 0600。`env` に API キーが入りうるため）。
- 自分のエントリの判定は「コマンドに `nb-hook` を含むか」。アンインストールはそれだけを外す。

## 5. ノッチの表示
- パネル: `NSPanel(styleMask: [.borderless, .nonactivatingPanel])`、`level = mainMenuWindow + 3`、`collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]`、背景透明・影なし。最初は `ignoresMouseEvents = true`。
- パネルは大きめ（720 × 560）に固定し、中で描く島の大きさを変える。マウスが島の矩形（±6 pt）に入ったときだけ `ignoresMouseEvents = false` にして**クリック透過を切り替える**。ノッチの無い画面では余白を付けない（メニューバー直下のアプリのクリックを奪わないため）。
- マウス位置はタイマーでポーリング: 開いている・近いとき 60 Hz、帯の中 20 Hz、それ以外 8 Hz（L397〜399）。目の追従は別に `NSEvent.addGlobalMonitorForEvents(.mouseMoved)` で受ける（マウスが止まっていれば何も動かない）。
- ノッチの大きさ（`IslandScreenGeometry`）: `safeAreaInsets.top > 0` ならノッチあり。幅 = 画面幅 − `auxiliaryTopLeftArea` 幅 − `auxiliaryTopRightArea` 幅（取れなければ 184 pt）、高さ = `safeAreaInsets.top`。ノッチ無しは 80 × min(24, メニューバー高さ)。純粋な構造体でテスト可能 → `AgentKit` に同様のものを置く。
- 表示する画面の選択（`IslandDisplayChoice`）: ノッチのある内蔵画面 / メニューバーの画面 / マウスのある画面 / 指定（ディスプレイ UUID で保存）。
- 状態機械（`IslandStateMachine`）: `hidden / petit / home / coucou / listening`。遅延（ホバーで開いたものは離れて 0.6 秒で閉じる等）を持つ純粋なクラス。うちの `character / peek / expanded` も同じく AppKit 非依存にしてテストする。

## 6. キャラクター描画
- `TimelineView(.animation(paused: 非表示 || paused))` の中の `Canvas` で毎フレーム `BotEngine.draw()` を呼ぶ。`timeline.date` を Canvas のクロージャで参照しないと再描画されない、という注意書きがある（`BotCanvasView.swift` L21〜27）。
- **注意**: coucou は島が表示されている間はディスプレイのリフレッシュレートで描き続ける（「非表示時は 0 %」が目標）。うちは**キャラクターを常時表示したまま待機中 CPU ≈ 0 %** が要件なので、そのままでは足りない。待機中は `TimelineView(.periodic)` の低頻度（まばたき・呼吸だけ）か、状態が変わったときだけ描く方式にする（M1-2 で設計）。
- 目の追従は `AppState.mousePosition` を 1 pt 以上動いたときだけ更新して無駄な再描画を避けている。

## 7. セッションの集約（`PillSessionRegistry`）
- 値型で、変更はすべて `mutating` 経由。
- **`SessionEnd` が来ないこと**（ターミナルを kill、クラッシュ）を前提にしている: 12 時間音沙汰が無ければ消す。ターン中に 30 分イベントが無ければ `Stop` を取りこぼしたとみなす。→ F3-5「停止扱い」の閾値の参考にする。
- 同じ表示先に複数セッションがあるとき、最後のセッションが終わるまで表示を消さない。

## 8. 取り入れること・変えること
| 項目 | 方針 |
| --- | --- |
| 中継 CLI | 取り入れる（送信のみは 0.3 秒、承認は応答待ち、失敗時は無出力 exit 0）。**Python ではなく Swift の実行ファイル** |
| 承認の応答形式 | アプリ → 中継は自前の小さな形式（`allow` / `deny` / `always` / `answer` / `pass`）、Claude Code の JSON への変換は中継側。変換ロジックは `AgentKit` に置いてテスト |
| 接続が切れたら承認カードを消す | 取り入れる |
| 表示中の要求 ID にだけ応答 | 取り入れる |
| `ApprovalQueue` の上限 5 件・115 秒 | 取り入れる（定数は設定可能に） |
| settings.json の書き込み規則 | すべて取り入れる（`SafeFileWriter`） |
| ノッチのパネル設定とクリック透過 | 取り入れる。ポーリングは「近づいたときだけ」にして待機中のタイマーを減らす |
| キャラクター | 見た目は自作（`docs/design/character.md`）。描画頻度は待機中に下げる |
| 多エージェント対応（Codex, Gemini 等）| やらない（スコープ外） |
