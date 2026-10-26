# ADR-0003: クラウドの Claude Code セッションは「クラウド側の hook → 自分専用のリレー → アプリ」で受け取る

- ステータス: **提案**（2026-10-26）。M7-0 の検証結果を受けて「承認」にする
- 関連: REQUIREMENTS の F8、ROADMAP の M7、[ADR-0001](0001-hook-bridge.md)

## 背景
ADR-0001 の経路（`~/.claude/settings.json` → `notch-hook` → Unix ソケット）は、Mac の上で動く Claude Code にしか届かない。ユーザーはクラウドで動く Claude Code（claude.ai/code、`claude --cloud`、モバイルアプリ、ルーティン、プロジェクトのスレッド）もノッチに表示し、承認までしたい。

クラウドのセッションは Anthropic が管理する Linux の VM で動き、Mac の Unix ソケットにも `~/.claude/settings.json` にも触れない。何らかの「外から Mac に届ける道」が要る。

## 調べたこと（2026-10-26 時点の公式ドキュメント）

### 1. 公開 API はあるか → 状態の取得・承認に使える公開 API は無い
| できること | 手段 | ノッチで使えるか |
| --- | --- | --- |
| クラウドセッションを**始める** | `claude --cloud "<指示>"`、ルーティンの `/fire` エンドポイント（研究プレビュー、ベータヘッダー付き、新しいセッションの ID と URL を返す） | 使える（M7-7） |
| 動いているセッションに**追加の指示を送る** | `claude -p "<文>" --cloud <session-id>`（`--output-format json` で `{ok, session_id, url}`） | 使える（M7-7） |
| セッションの**一覧・状態・イベントを読む** | 公開 API なし。`--teleport` や Remote Control が使う仕組みは非公開で、`claude agents --json` はローカルのセッションだけ | 使えない |
| **承認・質問に答える** | 公開 API なし（claude.ai の画面かモバイルアプリだけ） | 使えない |

- 非公開の claude.ai の API を真似て読むことはしない（規約上の問題があり、予告なく壊れる）。
- 別の Claude Code セッションからは `ListAgents` / `SendMessage`（クロスセッションメッセージ）でクラウドのセッションに文を送れるが、これは Claude 自身のツールで、外部アプリが状態を読む API ではない。届いたメッセージは承認の代わりにもならない。

出典: [Use Claude Code in the cloud](https://code.claude.com/docs/en/claude-code-on-the-web)、[Routines](https://code.claude.com/docs/en/routines)、[Agent view](https://code.claude.com/docs/en/agent-view)、[Cross-session messaging](https://code.claude.com/docs/en/cross-session-messaging)

### 2. クラウドで hooks は動くか → 動く。ただし設定の置き場所に制約がある
- 「Claude Code はどこで動いても同じ hook イベントを発火する（クラウドセッションを含む）」と明記されている。クラウドでは環境変数 `CLAUDE_CODE_REMOTE=true`、`CLAUDE_CODE_REMOTE_SESSION_ID`（`cse_…`）が入る（このリポジトリのクラウドセッションで実際に確認済み）。
- どの設定ファイルの hooks が効くか:
  | セッションの種類 | リポジトリの `.claude/settings.json` の hooks | Mac の `~/.claude/settings.json` |
  | --- | --- | --- |
  | claude.ai/code・`--cloud`・モバイル・ルーティン（リポジトリ 1 つ） | **効く**（クローンに含まれるため） | 効かない |
  | 同上でリポジトリが複数 | 効かない（`enabledPlugins` などだけ読む） | 効かない |
  | **プロジェクトのスレッド**（このスレッドを含む） | **効かない**（公式に「Not run」） | 効かない |
- プロジェクトのスレッドで考えられる道（すべて要検証、M7-0）:
  1. スレッドを**自分の Mac で動かす**（Remote Control）。その場合は Mac 上の Claude Code なので、**今の ADR-0001 の経路のまま表示・承認できる**。リレーは要らない。
  2. **プロジェクト設定のプラグイン**に hooks を入れる（公式は「プラグインはプロジェクト設定で追加する」と案内している。プラグインの `hooks/hooks.json` がスレッドで動くかは未確認）。
  3. クラウド環境の**セットアップスクリプト**で VM 内の `~/.claude/settings.json` に hooks を書く（`~/.claude/CLAUDE.md` をこの方法で読ませる例は公式にある。settings.json も読まれるかは未確認）。

出典: [Hooks reference](https://code.claude.com/docs/en/hooks)、[Settings in cloud sessions](https://code.claude.com/docs/en/settings#settings-in-cloud-sessions)、[What threads pick up from your repositories](https://code.claude.com/docs/en/claude-projects)、[What carries over from your setup](https://code.claude.com/docs/en/cloud-environments#what-carries-over-from-your-setup)

### 3. クラウドの hook から Mac に届ける経路 → 直接は届かないので、間に常時オンのリレーを置く
- クラウドの VM から外への通信は、環境の「ネットワークアクセス」設定（None / Trusted / Full / Custom）で決まる。既定の Trusted はパッケージレジストリなどの許可リストだけ。**Custom で自分のドメインを足す**か、そのホストを**ネットワークシークレット**に登録すれば届く（シークレットのホストは許可リストを通らずに到達できる）。
- Mac は普通 NAT の内側でスリープもするので、クラウドから Mac に直接つなぐのは不向き。Cloudflare Tunnel / Tailscale Funnel で Mac を公開する案もあるが、Mac を常時インターネットに開くことになり、スリープ中は hook が待たされる。
- そこで、**ユーザー自身がデプロイする小さなリレー**を間に置く。クラウドの hook はリレーに送り、Mac のアプリはリレーに外向きの WebSocket を張って受け取る。

### 4. 認証 → 経路ごとに別のトークン。クラウド側はトークンを VM に入れない
- **クラウド → リレー**: リレーのホストを、クラウド環境の**ネットワークシークレット**（Bearer）に登録する。Anthropic のエージェントプロキシが VM の外でヘッダーを付けるので、**トークンは VM 内の環境変数にもファイルにも現れない**。ネットワークシークレットが使えない環境では、環境変数 + hook の `allowedEnvVars` で代用する（環境の利用者には見える）。
- **Mac → リレー**: 別の端末トークン。Keychain に保存する。
- リレーはトークンの照合だけで、claude.ai のアカウントや Anthropic のトークンには一切触れない。

### 5. 承認をクラウドに返せるか → hook の応答として返せる（見込み。M7-0 で実機確認）
- `PermissionRequest` は HTTP フックの応答本文（`hookSpecificOutput.decision`）で許可／拒否を返せる。クラウドの権限確認は claude.ai の画面に出るが、ドキュメント上「`--permission-prompt-tool` や SDK の `canUseTool` に届く呼び出しでは、hooks はホストと並行して動き、**先に決めた方が適用される**」とある。クラウドの画面もこの形だと考えられるので、ノッチと claude.ai の画面のどちらで答えてもよいはず（要検証）。
- `AskUserQuestion` も `PreToolUse` の `updatedInput` で返す仕組みは同じなので、承認ができれば同じ経路で答えられる見込み。
- 自動モード・バイパスモードのセッションやルーティン（権限モードの選択なしで自動実行）では、そもそも確認が出ない。その場合は表示だけになる。

## 選択肢
1. **クラウド側の hook → ユーザー専用リレー（Cloudflare Workers + Durable Object） → Mac のアプリ**
2. クラウド側の hook → Mac をトンネル（Cloudflare Tunnel / Tailscale Funnel）で公開して直接受ける
3. ntfy.sh などの公開プッシュサービスを中継に使う
4. claude.ai の非公開 API を読む
5. クラウドは対象外とし、「スレッドを自分の Mac で動かす（Remote Control）」ことだけを案内する

## 決定
**1 を採用する。**あわせて 5 を「リレーなしでできる最初の手段」として案内する（プロジェクトのスレッドで hooks が動かない場合の逃げ道にもなる）。2・3・4 は採用しない。

## 理由
- 1 は Mac がスリープ中・オフラインでも、クラウド側がリレーに送った時点ですぐ終われる（Claude Code を待たせない原則を守れる）。Mac から見ると外向きの接続だけで、ポートを開けなくてよい。
- 2 は Mac を常時インターネットに公開することになり、スリープ中は hook がタイムアウトまで待たされる。
- 3 は公開サービスにコマンドやファイルの中身が流れる。トピック名を知られると読まれる。
- 4 は規約上の問題があり、予告なく壊れる。
- 5 だけでは claude.ai/code やモバイルから始めたセッションが見えない。

## 詳細

### 全体の流れ
```
[クラウドの VM]                                [Cloudflare（ユーザーのアカウント）]         [Mac]
Claude Code ─hook→ notch-cloud-hook.sh ─HTTPS→ リレー（Worker + Durable Object） ←WebSocket─ NotchAgent.app
                   （CLAUDE_CODE_REMOTE=true の      ・トークン照合                        ・RelayClient
                     ときだけ動く）                  ・Mac 未接続なら即「判断しない」         ・SessionStore に統合
                                                    ・承認は Mac の応答まで保持
```

### クラウド側の hook（`notch-cloud-hook.sh`）
- リポジトリの `.claude/settings.json`（または M7-0 で分かったプロジェクトのスレッド用の置き場所）に `command` フックとして登録する。シェル + `curl` だけで動く（クラウドの VM に標準で入っている。Swift のビルドは要らない）。
- **ローカルでは何もしない**: 先頭で `[ "$CLAUDE_CODE_REMOTE" = "true" ] || exit 0`。同じ `.claude/settings.json` を Mac で使っても、Mac 側は ADR-0001 の `notch-hook` だけが働く。`http` フックだとこの切り分けができない（ローカルでもリレーに送ってしまう）ので使わない。
- 登録の形:
  | イベント | 引数 | timeout | 動き |
  | --- | --- | --- | --- |
  | `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `Notification`, `Stop`, `StopFailure`, `SubagentStart`, `SubagentStop` | なし | 5（`async: true`） | 送信だけ。`curl --connect-timeout 2 --max-time 3` |
  | `PermissionRequest` | `--wait` | 120 | リレーに送って応答を待ち、決定を stdout に出す（`--max-time 115`） |
  | `PreToolUse`（matcher `AskUserQuestion`） | `--ask` | 130 | 同上（`--max-time 125`） |
- 守ること（ADR-0001 と同じ）: 接続できない・壊れた応答・タイムアウトのときは**何も出力せず exit 0**。終了コードは常に 0。stdout には Claude Code 向けの JSON 1 つだけ。1 メッセージ 1 MB まで。
- 送る内容は hook の JSON そのままに、`CLAUDE_CODE_REMOTE_SESSION_ID` と `GITHUB_REPOSITORY` 相当の情報（クローンの remote）を足す。リレーのホストに付けるトークンはエージェントプロキシが付けるので、スクリプトはトークンを持たない。

### リレー（`relay/`、Cloudflare Workers + Durable Object）
- ユーザーが自分の Cloudflare アカウントに `wrangler deploy` で入れる（無料枠で足りる想定）。Durable Object は 1 ユーザー 1 つ。
- エンドポイント:
  | パス | 呼ぶ側 | 動き |
  | --- | --- | --- |
  | `POST /v1/event` | クラウドの hook | Mac が接続中なら転送、いなければ捨てる。すぐ `204` |
  | `POST /v1/wait` | クラウドの hook | Mac が未接続なら**即 `200 {}`（判断しない）**。接続中なら転送し、Mac の応答か 110 秒まで保持 |
  | `GET /v1/stream` | Mac | WebSocket。イベントと承認依頼を流す |
  | `POST /v1/decision` | Mac | 承認依頼 ID に対する決定（ADR-0001 の `{"decision":…}` と同じ形） |
- **保存しない**: イベントはメモリ上で転送するだけ。ログに本文を残さない。承認依頼も応答か期限で消す。
- ワイヤ形式は ADR-0001 と揃え、`{"v":1,"origin":"cloud","mode":"event|wait|ask","cloud":{"session_id":"cse_…","repo":"owner/name"},"hook":{…}}` とする。デコードと検証は `AgentKit` に置いて Linux でテストする。
- リレーは TypeScript になるが、アプリ本体とは別にデプロイするもので、アプリの「外部依存なし」の対象外とする。

### アプリ側
- `RelayClient`: `URLSession` の WebSocket だけで実装（外部依存なし）。**ユーザーが F8 を有効にしたときだけ**接続する。切れたら指数バックオフで再接続。ノッチが閉じていても接続は保つが、待機中はイベントが来るまで何もしない（CPU 0 % の方針を守る）。
- 受けたイベントは `SessionStore` に入れ、セッションに「クラウド」の印と claude.ai/code の URL（`cse_` → `session_` に置き換え）を付ける。クリックでブラウザで開く。
- 承認は `ApprovalQueue` にローカルのものと同じように入れる。**明示的なクリックでのみ**許可する原則はそのまま。カードには「クラウド」とリポジトリ名を出す。claude.ai の画面で先に答えられた場合は、リレーからの切断（hook 側が終了）か `PostToolUse` でカードを消す（ADR-0001 と同じ考え方）。
- 設定画面: リレーの URL、端末トークン（Keychain）、接続状態、テスト送信。クラウド環境に登録する内容（許可するドメイン・ネットワークシークレット・hooks の設定例）を表示し、リポジトリへの hooks の追加は SafeFileWriter と同じ「差分 → 確認 → 書き込み」で行う。

## 影響
- REQUIREMENTS の「やらないこと」から「クラウド中継」を外し、F8 として追加する。非機能要件の「アプリの通信はローカルのみ」に、ユーザーが有効にしたリレーへの接続を例外として加える。
- ユーザーが Cloudflare のアカウントとリレーのデプロイ、クラウド環境の設定（ネットワークシークレットまたは許可ドメイン）を用意する必要がある。手順は docs にまとめる（M7-6）。
- hook の本文（コマンドやファイルの中身）が、ユーザー自身のリレーを TLS で通る。リレーには保存しない。将来、端末間の暗号化（VM 内の鍵が要る）を検討する。
- プロジェクトのスレッドは M7-0 の結果しだいで「表示できない」可能性がある。その場合は「スレッドを自分の Mac で動かす」を案内する。

## 確認が残っていること（M7-0）
| # | 内容 | 確かめ方 |
| --- | --- | --- |
| C1 | リポジトリ 1 つの claude.ai/code セッションで、`.claude/settings.json` の `command` フックが `CLAUDE_CODE_REMOTE=true` で動き、許可したドメインに `curl` で届く | テスト用リポジトリにフックを置き、requestbin 相当の自前エンドポイントで受ける |
| C2 | クラウドで `PermissionRequest` が発火し、hook の `allow` / `deny` が適用され、claude.ai の画面の確認が閉じる。画面で先に答えたとき hook は止められる | 既定の権限モードのセッションで実験 |
| C3 | プロジェクトのスレッドで hooks を動かす手段（プロジェクト設定のプラグイン、セットアップスクリプトで VM の `~/.claude/settings.json` を書く）のどちらかが効くか | プロジェクトに専用環境を作って実験 |
| C4 | ネットワークシークレットのホストに `curl` したとき、Bearer が付き、許可リスト外でも届く | C1 と同時に |
| C5 | `async: true` の送信フックが、セッション終了（`SessionEnd`）時にも送り切れるか | C1 と同時に |
