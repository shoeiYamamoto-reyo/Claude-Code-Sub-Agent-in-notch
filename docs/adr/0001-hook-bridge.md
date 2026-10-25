# ADR-0001: Claude Code との連携は hooks + 中継 CLI + Unix ソケットで行う

- ステータス: **承認**
- 日付: 2026-10-25（提案）、2026-10-25（承認: M0-3、`docs/claude-code-spec.md` と `docs/coucou-notes.md` を反映）

## 背景
アプリは Claude Code の実行状況をリアルタイムに受け取り、権限リクエストにはユーザーの判断を返す必要がある。アプリが起動していないときでも Claude Code を待たせてはいけない。

## 選択肢
1. **`command` フックから中継 CLI（`notch-hook`）を呼び、Unix ソケットでアプリに転送する**（coucou と同じ方式）
2. `http` フックでアプリの localhost サーバーに直接送る
3. トランスクリプト（`~/.claude/projects/*/*.jsonl`）をファイル監視する
4. アプリから `claude -p --output-format stream-json` で起動したものだけを管理する

## 決定
1 を採用する。3 は補助（サブエージェントの詳細表示など）に限る。4 はタスク起動（ADR-0002）で併用するが、手動起動のセッションも見たいので主経路にはしない。

## 理由
- 承認への応答（双方向）は hooks でしかできない（`PermissionRequest` の `decision`、`AskUserQuestion` の `updatedInput`）。
- 2 の HTTP フックは、**アプリが起動していないと接続失敗が non-blocking error になり、ツール呼び出しのたびにトランスクリプトに `hook error` 通知が出る**。1 なら中継 CLI が「何も出力せず exit 0」で静かに終われる。
- 3 のトランスクリプトの形式は内部仕様で、バージョンごとに変わると公式に明記されている。
- イベント駆動なので待機中の CPU 使用率 0 % を狙える。
- 非対話の `claude -p` でも hooks と `PermissionRequest` が動く（docs 上確認済み）ので、アプリから起動したタスクも同じ経路で承認できる。

## 詳細
### 中継 CLI（`notch-hook`）
- Swift の単一実行ファイル（外部依存なし、Python 不要）。インストール時に `~/Library/Application Support/NotchAgent/bin/notch-hook` へコピーし、アプリを移動してもパスが変わらないようにする。
- settings.json への登録は `args` 形式（シェルを通さない）。
  | イベント | 引数 | timeout | 動き |
  | --- | --- | --- | --- |
  | `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `Notification`, `Stop`, `StopFailure`, `SubagentStart`, `SubagentStop` | なし | 5 | 送信だけして即終了 |
  | `PermissionRequest` | `--wait` | 120 | 応答を待ち、決定を stdout に出す |
  | `PreToolUse`（matcher `AskUserQuestion`） | `--ask` | 130 | 回答を待ち、`updatedInput` を出す |
- 守ること:
  - ソケットへの接続タイムアウトは 300 ms。接続できない・応答が無い・壊れた応答のときは**何も出力せず exit 0**。
  - 終了コードは常に 0（exit 2 は使わない）。stdout には Claude Code 向けの JSON 1 つだけを出す。
  - 送信だけのイベントは応答を待たない。`SessionEnd` の 1.5 秒予算に十分収まること。
  - 1 メッセージ 1 MB まで（超えたら送らない）。
- テスト: ソケット不在時に 100 ms 以内に exit 0（ROADMAP 1-4）、応答待ちのタイムアウト・接続断・各決定の変換（ROADMAP 2-1）。

### ソケットとワイヤプロトコル
- パス: `~/Library/Application Support/NotchAgent/notch.sock`（`sun_path` の 104 バイト制限に収まることを起動時に確認）。ディレクトリは 0700。
- 形式: 改行区切りの JSON 1 行ずつ。中継 → アプリ:
  ```json
  {"v":1,"mode":"event|wait|ask","env":{"term_program":"...","bundle_id":"..."},"hook":{ ...Claude Code から受け取った JSON そのまま... }}
  ```
- アプリ → 中継（`wait` / `ask` のときだけ、1 行）:
  ```json
  {"decision":"allow|always|deny|answer|pass","message":"...","answers":{"質問文":"ラベル"}}
  ```
  `pass` は「判断しない」（中継は何も出力しない）。Claude Code の JSON への変換は中継側で行い、その変換ロジックは `AgentKit` に置いてテストする。
- アプリは `wait` / `ask` の接続を開いたまま保持し、**相手が接続を閉じたら承認カードを消す**（ターミナルで答えた・Claude Code がフックを止めた）。アプリ側の諦め時間は `wait` 115 秒、`ask` 125 秒。

### hooks のインストール
- `~/.claude/settings.json`（`CLAUDE_CONFIG_DIR` があればその下）に対して、`SafeFileWriter` でバックアップ → マージ → 差分表示 → 確認後に書き込む（規則は `docs/coucou-notes.md` 4 章）。
- 自分のエントリは「コマンドのパスが `notch-hook` で終わる」で判定し、アンインストール時はそれだけを外す。

## 影響
- `~/.claude/settings.json` に hooks を追加する必要がある → インストーラ（ROADMAP 1-7）。
- 対話セッションでは、フォルダの信頼を承認するまで hooks が動かない（Claude Code の仕様）。表示されないセッションがあり得ることを UI で説明する。
- 対話ターミナルで承認がターミナル側にも同時に出るかは未確認（`docs/claude-code-spec.md` U1）。どちらでも動くよう、接続断でカードを消す。
