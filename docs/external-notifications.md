# 他アプリ・外部サービスの通知をノッチで扱う（検討メモ）

- ステータス: **提案**（2026-10-25）
- 関連: REQUIREMENTS の F7、ROADMAP の M6

## 1. やりたいこと
Claude Code 以外の通知（git、メール、Slack、GitHub など）もノッチに集め、キャラクターの表情と peek で知らせ、展開 UI で一覧・既読・元アプリを開く、ができるようにする。

## 2. 前提: 他アプリの通知を横取りする公開 API は無い
macOS には「他のアプリが出した通知（通知センターの中身）を読む」公開 API が無い。考えられる抜け道とその評価:

| 方法 | 評価 |
| --- | --- |
| 通知センターのデータベース（`usernoted` の SQLite）を読む | **採用しない**。macOS 15 Sequoia でこのデータベースは保護されたコンテナに移され、他のアプリから読めなくなった（[9to5Mac](https://9to5mac.com/2024/09/01/security-bite-apple-addresses-privacy-concerns-around-notification-center-database-in-macos-sequoia/), [Michael Tsai](https://mjtsai.com/blog/2024/07/15/sequoia-finally-addresses-notification-center-privacy)）。本アプリの対象は macOS 15 以上なので使えない |
| アクセシビリティ API で通知バナーの表示を読み取る | **採用しない**。アクセシビリティ権限が強すぎる、OS 更新で簡単に壊れる、公開時に説明しにくい |
| Dock アイコンのバッジ数を読む（`lsappinfo` が使う LaunchServices の情報） | **実験的に検討**（Could）。権限不要で Mail / Slack / メッセージの未読数だけは分かるが、非公開 API でポーリングも要る |

したがって「通知を横取りする」のではなく、**通知の元（サービスやスクリプト）から直接ノッチに届ける**方針にする。

## 3. 届け方の選択肢

### A. 汎用の受け口 `notch-notify` CLI（＋URL スキーム）
`notch-hook` と同じソケットに「通知」を 1 件送るだけの小さな CLI。どんなスクリプトからでも呼べる。

```sh
notch-notify --source git --title "main に push しました" --body "3 commits" \
             --level info --open "https://github.com/owner/repo/commits/main"
notch-notify run -- swift test     # 長いコマンドの終了（成功／失敗）を通知
```

- これだけで次が実現できる（レシピを docs に用意する）:
  - **git**: `post-commit` / `post-merge` / `pre-push` などの git hooks、`notch-notify run -- git push`
  - **メール**: Mail.app の「ルール」→「AppleScript を実行」で、条件に合う受信メールのときだけ `notch-notify` を呼ぶ（イベント駆動、認証情報不要）
  - **ショートカット.app** のオートメーション、cron / launchd ジョブ、CI 待ちスクリプトなど
- 守ること: `notch-hook` と同じく、アプリが起動していなければ 300 ms 以内に静かに終了し、呼び出し元（git など）を絶対に待たせない。
- 長所: 外部依存・認証・ポーリングなし。待機中 CPU 0 % の方針に合う。実装が小さい（既存のソケットとプロトコルの拡張）。
- 短所: Slack や GitHub のように「サービス側で起きたこと」は、別途何かが呼ばないと届かない。

### B. サービスごとの連携（アプリが API を呼ぶ）
| サービス | 方式 | 認証 | 注意点 |
| --- | --- | --- | --- |
| **GitHub** | [Notifications API](https://docs.github.com/en/rest/activity/notifications)（`GET /notifications`）をポーリング。`If-Modified-Since` を付け、応答の `X-Poll-Interval`（通常 60 秒）に従う。304 応答はレート制限を消費しない | classic PAT（`notifications` スコープ）を Keychain に保存、または `gh auth token` を利用。※この API は fine-grained PAT では使えない | レビュー依頼・メンション・CI 失敗などを種類で絞り込める。サービス連携の中では一番素直 |
| **Slack** | ユーザー自身のワークスペースに Slack アプリを作り、Socket Mode（WebSocket）でメンション・DM のイベントを受ける | アプリトークン（`xapp-`）とユーザートークン（`xoxp-`）を Keychain に保存 | ワークスペースによっては管理者の承認が要る。設定手順が長い。会社の Slack では使えないことがある |
| **メール（IMAP）** | IMAP IDLE で新着を待つ | パスワード／アプリパスワードを Keychain に保存。Gmail は OAuth が必要 | Mail.app ルール（案 A）で足りるなら不要 |

- 長所: スクリプトを書かなくてもすぐ使える。
- 短所: 「アプリ自身の通信はローカルのみ」という今の非機能要件を緩める必要がある。トークン管理・ポーリング・API 変更への追従が増える。

### C. Dock バッジ数のミラー（実験）
Mail / Slack / メッセージなど登録したアプリの未読バッジ数を低頻度で読み、ノッチに数字だけ出す。内容は分からない。非公開 API のため既定はオフ、壊れたら静かに無効化する。

## 4. 推奨
1. **まず A（`notch-notify` と通知一覧 UI）を作る。** git・長いコマンド・Mail.app ルール・ショートカットは、これだけで賄える。外部通信も権限追加も不要で、今の安全方針を崩さない。
2. **次に B の GitHub 連携。** 開発者の用途で一番価値が高く（レビュー依頼、CI 失敗）、API も安定している。これを入れる時点で「外部通信はユーザーが有効にした連携だけ」に非機能要件を改める。
3. **Slack と Dock バッジは Could。** Slack は設定の手間とワークスペースの制約が大きいので、需要が固まってから。

## 5. UI と優先度の方針
- 通知には `source`（git / mail / github / slack / 任意文字列）、`title`、`body`、`level`（`info` / `attention`）、開く先（URL またはアプリのバンドル ID）を持たせる。
- **Claude Code の承認待ちが常に最優先。** 外部通知は承認カードの後ろに並べ、`attention` のときだけ peek する。`info` はキャラクターに小さな印を付けるだけ。
- ソースごとのミュート、おやすみモード（F0-6）に従う、既読・一括既読、クリックで開く。
- 外部通知は Claude のセッション一覧とは別のタブ（「通知」）にまとめる。
- 保存はメモリ上の直近 N 件（例: 200）だけ。履歴として永続化はしない（必要になったら別途検討）。

## 6. 実装メモ
- ワイヤプロトコル（ADR-0001）の `mode` に `notify` を追加する。ペイロードは `{"v":1,"mode":"notify","notify":{...}}`。デコードと検証は `AgentKit` に置き Linux でテストする。
- `notch-notify` は `notch-hook` と同じ Swift Package の別 executable にし、ソケット送信部分を共有する。
- GitHub 連携の HTTP クライアントは `URLSession` のみ（外部依存なし）。ポーリングはネットワーク接続中かつ連携が有効なときだけ、`X-Poll-Interval` 以上の間隔で行う。
