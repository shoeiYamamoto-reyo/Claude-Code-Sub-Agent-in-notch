# ADR-0002: タスクの起動は claude CLI を子プロセスで実行する

- ステータス: **承認**
- 日付: 2026-10-25（提案）、2026-10-25（承認: M0-3、`docs/claude-code-spec.md` 5 章を反映）

## 背景
ユーザーはノッチからプロジェクトのサブエージェントに仕事を与え、状況を確認し、停止したい（REQUIREMENTS F2）。

## 選択肢
1. **`claude -p "<指示>" --output-format stream-json --verbose` を作業フォルダで子プロセスとして起動**し、出力を読む
2. Claude Agent SDK を使う（TypeScript / Python ランタイムが必要）
3. Terminal.app / iTerm2 を AppleScript で開き、対話モードの `claude` を起動する
4. `claude --bg "<指示>"` で Claude Code の背景セッションとして起動し、`claude agents --json` / `claude logs` で様子を見る

## 決定
1 を基本にする。F2-7「ターミナルで開いて続きを手で操作する」は、3 または 4（`claude attach <id>`）を後から追加する（M5）。

## 理由
- 外部依存なし（Swift の `Process` で起動できる）。ユーザーが普段使っている `claude` と同じ認証・設定・hooks がそのまま使える。
- stream-json でツール実行・応答を逐次受け取れる。サブエージェントのメッセージは `parent_tool_use_id` で区別できる。
- `-p` でも `PermissionRequest` フックが動くので、承認はノッチからできる（ADR-0001 と同じ経路）。
- 2 は Node / Python が必要になり「外部依存なし」に反する。
- 4 は `-p` と併用できず、出力を機械的に読む手段が `logs` だけになる。

## 起動コマンド
```
claude -p "<指示>"
  --output-format stream-json --verbose     # --verbose は必須（無いとエラー）
  --session-id <アプリが生成した UUID>       # hook イベントと確実に結び付ける
  [--agent <name>]                          # エージェントを選んだとき。「おまかせ」なら付けない
  [--model <m>] [--effort <e>]              # プロジェクトの環境設定にあるときだけ
  [--permission-mode <mode>] [--allowedTools ...]   # 同上。既定では付けない
  [-n <表示名>]
```
- 作業ディレクトリはプロジェクトのフォルダ。環境変数はユーザーのログインシェルの `PATH` を引き継ぎ、プロジェクトの追加の環境変数（秘密は Keychain から）を足す。
- 続きの指示（F2-4）: `claude -p "<追加の指示>" --resume <session-id> --output-format stream-json --verbose`。`-p` で再開すると権限モードは復元されないので、元の起動と同じオプションを付け直す。
- 停止（F2-2）: まず **SIGINT**（ターンを終わらせて記録を残す）。5 秒待って終わらなければ SIGTERM（exit 143）。
- `claude` の場所（F6-3）: 設定値 → ログインシェルでの `command -v claude` → よくある場所（`~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`）の順に探す。
- コマンドの組み立てと stream-json のデコードは `AgentKit`（`TaskCommandBuilder`, `StreamJSONEvent`）に置いて Linux でテストする。子プロセスの管理はアプリ側。

## 確認が残っていること（`docs/claude-code-spec.md`）
- U2: `-p` タスクの `PermissionRequest` をノッチから許可して続行できるか（M3-3）。
- U3: `-p --agent <name>` でプロジェクトの `.claude/agents/` の定義が使われるか（M3-3）。使えない場合は、指示文の先頭で「<name> サブエージェントを使って」と指定する方式に切り替える。
- `AskUserQuestion` は `-p` で権限ホストが無いと Claude に提供されない。当面アプリ起動のタスクでは質問は来ない前提とし、必要になったら `PreToolUse` の `defer` + `--resume` を検討する。

## 影響
- `claude` 実行ファイルの場所を検出・設定する必要がある（F6-3）。
- 子プロセスの出力を読み続ける必要があるため、待機中 CPU 0 % の目標はタスク実行中は対象外とする。
- 権限モードを勝手に緩めない（REQUIREMENTS 6 章）。承認が必要な操作はノッチの承認待ちになる。
