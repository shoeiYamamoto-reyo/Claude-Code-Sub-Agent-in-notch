# Claude Code 仕様メモ（確認済み）

- 最終確認: 2026-10-25
- 確認に使った一次情報:
  - 公式ドキュメント（以下「docs」）: [Hooks reference](https://code.claude.com/docs/en/hooks) / [CLI reference](https://code.claude.com/docs/en/cli-reference) / [Run Claude Code programmatically](https://code.claude.com/docs/en/headless) / [Create custom subagents](https://code.claude.com/docs/en/sub-agents) / [Sessions](https://code.claude.com/docs/en/sessions)
  - ローカルの `claude --help`（Claude Code **2.1.310**）と実行結果
- 凡例:
  - **確認済み（docs）**: 公式ドキュメントに明記されている
  - **確認済み（CLI）**: 2.1.310 の `--help` や実行で確かめた
  - **未確認**: 書かれていない、または実機で動かして確かめる必要がある。確認する時期を書く
- 仕様はバージョンで変わる。実装で前提にした項目は、M1 以降に Mac で実機確認したら「実機確認済み（バージョン）」を追記する。

---

## 1. hooks のイベント一覧とペイロード（REQUIREMENTS 7-1）

### 1-1. 設定の形 — 確認済み（docs: Hooks reference「Configuration」）
```json
{
  "hooks": {
    "PermissionRequest": [
      { "matcher": "", "hooks": [ { "type": "command", "command": "/path/notch-hook", "timeout": 120 } ] }
    ]
  }
}
```
- 3 段の入れ子: イベント → matcher グループ（`matcher` 省略・`""`・`"*"` で全件）→ ハンドラ。
- 置き場所: `~/.claude/settings.json`（全プロジェクト）、`.claude/settings.json`、`.claude/settings.local.json`、managed、plugin、skill / subagent の frontmatter。**各レベルの hooks はマージされる**（上書きではない）。同じハンドラが複数の設定ファイルにあっても 1 回しか実行されない。
- ハンドラの種類: `command`（stdin に JSON）、`http`（POST の本文に JSON）、`mcp_tool`、`prompt`、`agent`。
- 主なフィールド: `timeout`（秒）、`async`（command のみ。待たずに裏で実行）、`args`（シェルを通さず直接 exec）、`onFailure`（`continue` / `block`、v2.1.295 以降）。
- **`CLAUDE_CONFIG_DIR` が設定されていると `~/.claude` の場所が変わる**（docs: Sessions）。インストーラはこれを考慮する。

### 1-2. 使うイベント — 確認済み（docs: Hooks reference「Hook lifecycle」「Hook events」）
| イベント | 発火タイミング | アプリでの用途 |
| --- | --- | --- |
| `SessionStart` | セッション開始・再開。matcher は `startup` / `resume` / `clear` / `compact` / `fork` | セッションを一覧に追加 |
| `UserPromptSubmit` | プロンプト送信時 | 「作業中」へ |
| `PreToolUse` | ツール実行前（すべてのツール呼び出し） | 直近のツール表示、`AskUserQuestion` の回答 |
| `PermissionRequest` | 権限の確認が必要になったとき | **承認キュー** |
| `PostToolUse` / `PostToolUseFailure` | ツール成功／失敗の後 | ツール結果、差分 (+N −M)、Agent ツールの結果 |
| `Notification` | 通知。`permission_prompt`（約 6 秒待った後）、`idle_prompt`（約 60 秒操作なし）など | 「入力待ち」表示の補助 |
| `SubagentStart` / `SubagentStop` | サブエージェントの開始／終了 | サブエージェントのツリー |
| `Stop` / `StopFailure` | 応答完了／API エラーでターン終了 | 「完了」「エラー」 |
| `SessionEnd` | セッション終了。`reason`: `clear` / `resume` / `logout` / `prompt_input_exit` / `other` | 一覧から片付け |

この他に `PostToolBatch`, `PermissionDenied`, `TaskCreated`, `TaskCompleted`, `PreCompact` / `PostCompact`, `CwdChanged`, `ConfigChange` などがある。**未知のイベント名も落とさずに受け取れる作り**にする（`HookEvent` は未知フィールドを `JSONValue` で保持）。

### 1-3. 共通の入力フィールド — 確認済み（docs: 「Common input fields」）
| フィールド | 内容 |
| --- | --- |
| `session_id` | セッション ID |
| `transcript_path` | 会話の JSONL のパス（書き込みは非同期で、最新ターンが入っていないことがある） |
| `cwd` | フック実行時の作業ディレクトリ |
| `hook_event_name` | イベント名 |
| `permission_mode` | `default` / `plan` / `acceptEdits` / `auto` / `dontAsk` / `bypassPermissions`（**Manual は `default` で届く**）。イベントによっては無い |
| `prompt_id` | 処理中のプロンプトの UUID（最初の入力までは無い） |
| `agent_id` / `agent_type` | **サブエージェント内で発火したとき**（または `--agent` 起動時）に付く |
| `effort` | `{ "level": "high" }` など。ツール文脈のイベントのみ |

- `SessionStart` だけ `model`, `source`, `agent_type`（`--agent` 起動時）, `session_title` を受け取れる。
- 例（PreToolUse / Bash）:
```json
{ "session_id": "abc123", "transcript_path": "/home/user/.claude/projects/.../transcript.jsonl",
  "cwd": "/home/user/my-project", "permission_mode": "default", "hook_event_name": "PreToolUse",
  "tool_name": "Bash", "tool_input": { "command": "npm test", "description": "Run test suite" },
  "tool_use_id": "toolu_01ABC123..." }
```

### 1-4. イベント固有のフィールド — 確認済み（docs）
- `PermissionRequest`: `tool_name`, `tool_input`, `permission_suggestions`（任意）。**`tool_use_id` は無い**。MCP ツールなら `mcp_server`。
- `SubagentStart`: `agent_id`, `agent_type`（カスタムエージェントは frontmatter の `name`。plugin は `plugin:name`）。
- `SubagentStop`: `agent_id`, `agent_type`, `agent_transcript_path`（`.../<session>/subagents/agent-<id>.jsonl`）, `last_assistant_message`, `stop_hook_active`, `background_tasks`。**Claude Code 内部のエージェント（プロンプト候補、`/btw`）でも発火し、そのとき `agent_type` は空文字やセッションのエージェント名になる** → 対応する `SubagentStart` が無い `SubagentStop` は無視する。
- `Stop`: `last_assistant_message`（最後の応答本文。トランスクリプトを読まずに済む）, `stop_hook_active`, `background_tasks`, `session_crons`。ユーザーの中断では発火しない。
- `Notification`: `message`, `title`（任意）, `notification_type`。
- `PostToolUse`（Agent ツール）: `tool_response` に `status`（`completed` / `async_launched`）, `agentId`, `content`, `totalDurationMs`, `totalToolUseCount`, `usage` など。
- `SessionEnd`: `reason`。

### 1-5. タイミングの制約 — 確認済み（docs）
- `SessionEnd` のフックは**全体で 1.5 秒の予算**（設定で最大 60 秒まで延長可）。中継 CLI は数十 ms で終わる必要がある。
- `Notification` の `permission_prompt` は約 6 秒後。**承認は `PermissionRequest` で即時に受け取る**。
- 対話セッションでは、**フォルダの信頼ダイアログを承認するまで `~/.claude/settings.json` の hooks も含めて実行されない**。`-p` では信頼済みとして扱われる。

---

## 2. 権限の許可／拒否を返す方法とタイムアウト（REQUIREMENTS 7-2）

### 2-1. `PermissionRequest` の出力 — 確認済み（docs: 「PermissionRequest decision control」）
exit 0 で stdout に JSON を 1 つだけ出す。
```json
{ "hookSpecificOutput": { "hookEventName": "PermissionRequest",
    "decision": { "behavior": "allow" } } }
```
```json
{ "hookSpecificOutput": { "hookEventName": "PermissionRequest",
    "decision": { "behavior": "deny", "message": "ノッチで拒否されました" } } }
```
- `behavior`: `allow` / `deny`。deny / ask ルールは引き続き評価されるので、`allow` でも deny ルールは越えられない。
- `allow` のとき: `updatedInput`（入力を差し替え）、`updatedPermissions`（ルール追加・モード変更。`destination` は `session` / `localSettings` / `projectSettings` / `userSettings`）。**F4-6「常に許可」は `permission_suggestions` をそのまま `updatedPermissions` に返す方法で実現できる**（docs に明記）。
- `deny` のとき: `message`（Claude に伝える理由）、`interrupt: true` で Claude を止める。
- **何も出力せず exit 0 → 判断しない**（通常の確認フローに戻る）。exit 2 で `decision` が無い場合も変化なし。

### 2-2. 終了コードと失敗時の扱い — 確認済み（docs: 「Exit code output」「Timeouts」）
- exit 0: 出力した JSON を適用。何も出さなければ「成功・判断なし」。
- exit 2: ブロック（イベントによる）。**中継 CLI では使わない**。
- それ以外の終了コード、起動失敗、不正な JSON: 「non-blocking error」として処理は続行するが、**トランスクリプトに `<hook name> hook error` の通知が出る**。→ アプリ不在時は「何も出力せず exit 0」が正しい。
- stdout に JSON 以外（シェルの起動メッセージ等）が混じると JSON として読まれない。

### 2-3. タイムアウト — 確認済み（docs: 「Common fields」）
- `command` / `http` / `mcp_tool` の既定は **600 秒**（`UserPromptSubmit` は 30 秒、`SessionEnd` は上記の 1.5 秒予算）。設定の `timeout` で変えられる。
- タイムアウトしたフックの出力は捨てられ、通常の確認フローに戻る（`onFailure: "block"` を付けない限り）。
- **方針**: `PermissionRequest` は `timeout: 120` を明示し、アプリ側は 115 秒で諦める（coucou と同じ考え方。docs 上の上限ではなく、放置された承認がいつまでも残らないようにするため）。

### 2-4. 対話セッションでの「ターミナルの確認」との関係 — **未確認**
- docs には「`--permission-prompt-tool` や SDK の `canUseTool` がある場合は**フックとホストが並行して動き、先に決めた方が適用される**」とある。対話ターミナルで `PermissionRequest` フックの実行中にターミナル側にも確認が出るかは明記されていない。
- coucou は「ターミナル側で答えられたらフックの接続が切れる → カードを消す」処理を持っており（`HookServer.swift` の `DispatchSource.makeReadSource`）、並行して出る前提で作られている。
- **確認時期**: M2-1 の実装時に Mac で実機確認。どちらでも動くように、アプリ側は「フックの接続が切れたら承認カードを消す」を実装する。

### 2-5. `-p`（非対話）での権限 — 確認済み（docs: headless「Auto-approve tools」, Hooks「PermissionRequest」）
- v2.1.302 以降、権限モードを何も指定しない `claude -p` は **Manual モード**で始まる。
- 承認が必要な呼び出しは、**`PermissionRequest` フックか `--permission-prompt-tool` が承認しない限り拒否**される。フックが何も返さなければ拒否。
- → **アプリから起動したタスクでも、ノッチの承認がそのまま使える**（REQUIREMENTS 7-6 の答え）。実機での動作は **未確認**（M3-3 で確認）。
- `--permission-prompts none`: 誰も答えないことを明示。`AskUserQuestion` などは外される。

---

## 3. サブエージェントの識別（REQUIREMENTS 7-3）— 確認済み（docs）
- サブエージェント内のツール呼び出しでも、設定ファイルの hooks がそのまま発火し、**`agent_id` と `agent_type` が付く**。付いていなければメインの会話。
- 親子関係:
  1. メイン会話の `PreToolUse`（`tool_name: "Agent"`, `tool_input.subagent_type`, `tool_input.description`）で「起動しようとしている」ことが分かる。
  2. `SubagentStart`（`agent_id`, `agent_type`）で開始。
  3. その後 `agent_id` 付きのツールイベントが届く。
  4. `SubagentStop`（`last_assistant_message`）で終了。
  5. メイン会話の `PostToolUse`（Agent）の `tool_response.agentId` で `tool_use_id` と `agent_id` が結び付く。
- **注意**: `SubagentStart` 自体には親の `tool_use_id` が無い。同じ種類のサブエージェントが並行で動くと、`PostToolUse` が来るまで「どの Agent 呼び出しか」は確定しない。表示上は `agent_id` 単位で十分。
- **背景サブエージェント**（既定でメイン会話から起動されるサブエージェントは背景で動く）は `PostToolUse` の `status` が `async_launched` で、終了は `SubagentStop` で知る。
- サブエージェントの入れ子（サブエージェントがさらに起動）もある。
- トランスクリプト: `~/.claude/projects/<作業フォルダのパスの英数字以外を - に置換>/<session-id>.jsonl`、サブエージェントは `.../<session-id>/subagents/agent-<id>.jsonl`。**行の形式は内部仕様で、バージョンごとに変わると明記**（docs: Sessions「Where transcripts are stored」）→ 監視の主経路にはしない（ADR-0001 のとおり）。

---

## 4. `AskUserQuestion` への回答（REQUIREMENTS 7-4）— 確認済み（docs: 「Tools that require user interaction」）
- `PreToolUse`（matcher `AskUserQuestion`）で、`permissionDecision: "allow"` と、元の `questions` に `answers`（質問文 → 選んだラベル。複数選択はカンマ区切り）を足した `updatedInput` を返すと、**ターミナルで聞かずに回答できる**。`allow` だけでは不十分。
```json
{ "hookSpecificOutput": { "hookEventName": "PreToolUse", "permissionDecision": "allow",
    "updatedInput": { "questions": [ { "question": "Which framework?", "header": "Framework",
        "options": [ {"label": "React", "description": "..."}, {"label": "Vue", "description": "..."} ],
        "multiSelect": false } ],
      "answers": { "Which framework?": "React" } } } }
```
- 入力の形: `questions[]`（`question`, `header`, `options[]{label, description}`, `multiSelect`）、1〜4 問。
- **制約**: `-p` では、権限ホスト（`--permission-prompt-tool` の MCP ツールや SDK の `canUseTool`）が無いと `AskUserQuestion` 自体が Claude に提供されない。→ アプリから起動したタスクでは当面「質問は来ない」前提。必要になったら `defer`（`-p` 専用。ターンを止めて `--resume` で再開）を検討する。
- coucou は `PermissionRequest` とは別に、`PreToolUse` に `AskUserQuestion` 専用の matcher を付けた hook（`nb-hook --ask`、timeout 130 秒）を登録している。同じ方式を採る。

---

## 5. アプリからのタスク起動（REQUIREMENTS 7-5）

| 項目 | 内容 | 状態 |
| --- | --- | --- |
| 非対話実行 | `claude -p "<指示>"` | 確認済み（CLI） |
| ストリーム出力 | `--output-format stream-json`。**`-p` と併用するときは `--verbose` が必須**（付けないと `Error: When using --print, --output-format=stream-json requires --verbose`） | 確認済み（CLI: 2.1.310 で実行） |
| 最初のメッセージ | `system/init`（モデル、ツール、MCP、plugin）。最後は `result`（最終応答、コスト、`session_id`） | 確認済み（docs: headless） |
| サブエージェントのメッセージ | `assistant` / `user` メッセージの `parent_tool_use_id` に Agent 呼び出しの ID。メイン会話は `null`。本文まで欲しければ `--forward-subagent-text` | 確認済み（docs） |
| フックのイベントもストリームに | `--include-hook-events` | 確認済み（CLI / docs） |
| エージェントを指定 | `--agent <name>`: **セッション全体をそのエージェントとして動かす**（`agent` 設定を上書き）。`--agents '<json>'` でその場限りの定義を渡せる（`-p` ではファイルパスも可、v2.1.281 以降） | 確認済み（CLI / docs）。`-p` と `--agent` の組み合わせの実動作は未確認（M3-3） |
| セッション ID の事前指定 | `--session-id <uuid>`。**アプリが UUID を決めて渡せば、届く hook イベントの `session_id` と起動したタスクを確実に結び付けられる** | 確認済み（CLI） |
| 再開 | `--resume <session-id>`（`-p` と併用可）。別ディレクトリからでも ID で見つかる。`--fork-session` で別 ID に分岐 | 確認済み（docs: headless「Continue conversations」） |
| 権限 | `--permission-mode <acceptEdits\|auto\|bypassPermissions\|manual\|dontAsk\|plan>`, `--allowedTools`, `--disallowedTools`。**アプリは既定で指定しない**（ユーザー設定どおり。REQUIREMENTS 6 章） | 確認済み（CLI） |
| モデル | `--model <alias or id>`, `--effort <level>` | 確認済み（CLI） |
| 表示名 | `-n, --name <name>` | 確認済み（CLI） |
| 上限 | `--max-budget-usd <amount>`（`-p` のみ） | 確認済み（CLI） |
| 停止 | **SIGINT でターンを終わらせてから終了**。SIGTERM は exit 143 で、進行中のターンは記録されない。SIGTERM では実行中の Bash のプロセスツリーを終了し、`SessionEnd` フックを走らせてから終わる。承認待ちの間に SIGTERM を受けると、その確認は未回答のまま残る | 確認済み（docs: headless「Stop a run with SIGTERM」） |
| 背景作業の待ち | ターン終了後も背景サブエージェント等を待つ。既定で 10 分アイドルで打ち切り（`CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS`） | 確認済み（docs） |
| 信頼ダイアログ | `-p` では出ず、フォルダを信頼済みとして扱う（リポジトリの `.claude/settings.json` の hooks も動く） | 確認済み（CLI / docs） |

### 5-1. 参考: 背景セッション（F2-7「ターミナルで開く」の候補）— 確認済み（CLI）
- `claude --bg [--agent <name>] "<指示>"` で背景セッションを起動して即座に戻る（`-p` とは併用不可）。`claude attach <id>` でターミナルにつなぐ、`claude logs <id>`, `claude stop <id>`, `claude agents --json` で一覧。
- ADR-0002 の選択肢として追記する（当面は採用しない）。

---

## 6. 非対話モードでも hooks と承認が使えるか（REQUIREMENTS 7-6）
- hooks は `-p` でも動く（信頼済み扱い）。`PermissionRequest` は「プロンプトを出せないセッションでも実行され、フックが決めなければ拒否」— **確認済み（docs）**。
- よって「ノッチから承認して続行」は仕様上可能。**実機確認は未確認**（M3-3 で、手動の `claude -p` から確認する）。
- 注意: `async: true` のフックは `-p` の終了時に kill される（docs）。承認系は同期フックにする。

---

## 7. サブエージェント定義（F1-3, F5）— 確認済み（docs: sub-agents「Choose the subagent scope」「Frontmatter reference」）
| 場所 | 優先度 |
| --- | --- |
| managed settings | 1（最高） |
| `--agents` CLI | 2 |
| `.claude/agents/`（作業フォルダから上へ辿り、近いものが勝つ） | 3 |
| `~/.claude/agents/` | 4 |
| plugin の `agents/` | 5 |

- **サブフォルダも再帰的に読む**。識別は frontmatter の `name` だけで決まり、ファイル名は関係ない。同じディレクトリ内で `name` が重複すると、どちらが使われるかは不定。
- frontmatter（YAML、`---` は 1 行目）: 必須は `name`（256 文字以内、`:` 不可、`-` で始めない）と `description`。任意: `tools`（カンマ区切り文字列または YAML リスト）, `disallowedTools`, `model`（`sonnet` / `opus` / `haiku` / `fable` / フル ID / `inherit`）, `permissionMode`, `maxTurns`, `skills`, `mcpServers`, `hooks`, `memory`, `background`, `effort`, `isolation`（`worktree`）, `color`, `initialPrompt`, `omitClaudeMd`, `autoCompactWindow`, `experimental`。**未知のフィールドはエラーにならず無視**される。本文が system prompt。
- 読み飛ばされるファイル: `name` が無い、`---` が 1 行目でない、`name` が不正、`description` が無い、YAML が壊れている（いずれもセッション内では報告されない）。→ F5-4 の検証項目にする。
- Claude Code は `~/.claude/agents/` と `.claude/agents/` を監視しており、編集は数秒で反映（新しく作ったディレクトリは再起動が必要）。
- アプリの書き込みは「未知のフィールドを保持する」往復を保証する（M4-1）。

---

## 8. 連携方式の選択に関わる事実（ADR-0001 向け）
- **HTTP フック**（`type: "http"`）でもアプリに直接送れる。ただし**アプリが起動していないと接続失敗 = non-blocking error で、ツール呼び出しごとに `hook error` 通知が出る**（docs: 「HTTP response handling」）。中継 CLI なら「アプリ不在 → 何も出力せず exit 0」で静かに済む。
- `command` フックで `args` を使うと、シェルを通さずに実行ファイルを直接起動できる（パスに空白があっても安全、シェル起動のコストも無い）。
- 同期フックは毎回 Claude を待たせるので、中継 CLI はソケット接続のタイムアウトを短く（目安 300 ms）し、承認系以外は応答を待たずに終わる。

## 未確認事項のまとめ
| # | 内容 | 確認時期 |
| --- | --- | --- |
| U1 | 対話ターミナルで `PermissionRequest` フック実行中にターミナル側の確認も出るか、ターミナルで答えるとフックは kill されるか | M2-1 |
| U2 | `claude -p` で起動したタスクの `PermissionRequest` をノッチから許可して続行できるか | M3-3 |
| U3 | `claude -p --agent <name>` の実動作（プロジェクトの `.claude/agents/` の定義が使われるか） | M3-3 |
| U4 | 実際の hook ペイロード（フィクスチャ化するため、Mac で全イベントを記録） | M1-3 |
