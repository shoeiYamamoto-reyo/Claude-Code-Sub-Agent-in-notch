# hook ペイロードのフィクスチャ

`HookEventTests` がこのフォルダの `*.json` をすべてデコードする。

- 現在のファイルは `docs/claude-code-spec.md` 1 章（公式ドキュメント）の例をもとに作ったもの。
- Mac で実際のペイロードを採取したら（メニュー「受信したイベントを記録」、`~/Library/Application Support/NotchAgent/captures/`）、
  個人情報（パス、プロンプト、コマンド）を伏せてここに追加する（`docs/claude-code-spec.md` U4）。
- ファイル名は `<イベント名>[-<補足>].json`。

## stream-json（`../stream-json/`）
`claude -p --output-format stream-json --verbose` の出力の形（docs/claude-code-spec.md 5 章、docs: headless）に合わせて手で作った例。実機の出力を採取したら差し替える（アプリが `~/Library/Application Support/NotchAgent/tasks/<session-id>.jsonl` に保存している）。
