# hook ペイロードのフィクスチャ

`HookEventTests` がこのフォルダの `*.json` をすべてデコードする。

- 現在のファイルは `docs/claude-code-spec.md` 1 章（公式ドキュメント）の例をもとに作ったもの。
- Mac で実際のペイロードを採取したら（メニュー「受信したイベントを記録」、`~/Library/Application Support/NotchAgent/captures/`）、
  個人情報（パス、プロンプト、コマンド）を伏せてここに追加する（`docs/claude-code-spec.md` U4）。
- ファイル名は `<イベント名>[-<補足>].json`。
