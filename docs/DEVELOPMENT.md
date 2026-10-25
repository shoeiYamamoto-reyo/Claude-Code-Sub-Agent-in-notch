# 開発の流れ

## 1 タスクの進め方
1. **タスクを選ぶ**: `docs/ROADMAP.md` の未着手タスクを上から 1 つ選ぶ（または GitHub Issue にする）。
2. **設計を確認**: 設計判断が要るなら `architect` に依頼する。仕様が不明なら `claude-code-integration`、coucou の実装を知りたければ `coucou-researcher` に調べさせる。決まったことは `docs/` に書く。
3. **ブランチを切る**: `feat/<短い名前>`、`fix/<短い名前>`、`docs/<短い名前>`。
4. **実装**: `swift-macos-engineer`。UI 非依存のロジックは必ず `AgentKit` に置く。
5. **テスト**: `test-engineer`。`swift test`（Linux / macOS）と `xcodebuild test`（macOS）。
6. **レビュー**: `code-reviewer` で差分をレビューし、指摘を直す。
7. **PR**: テンプレートに沿って書き、CI が緑になったらマージ。ROADMAP の状態を ☑ にする。

Claude Code に頼むときの例:
```
ROADMAP の 1-2 を進めて。architect で設計確認 → swift-macos-engineer で実装 → test-engineer でテスト → code-reviewer でレビューしてから PR を作って。
```

## 動作確認の分担
- クラウドの Claude Code セッション（Linux）: `AgentKit` と `notch-hook` のビルドとテストまで。
- 手元の Mac: アプリのビルド、ノッチ UI、実際の Claude Code と組み合わせた確認。手動確認の手順は各 PR に書く。

## ルール（抜粋、詳細は CLAUDE.md）
- `.xcodeproj` は手で編集しない（`project.yml` から生成）。
- Claude Code を絶対にブロックしない。hook 周りの変更にはタイムアウトのテストを付ける。
- 設定・定義ファイルの書き込みは「バックアップ → 差分 → 確認」を通す。
- コミットメッセージは英語の命令形で簡潔に（例: `Add HookEvent decoding`）。PR の説明は日本語で可。

## ドキュメント
| ファイル | 内容 |
| --- | --- |
| `docs/REQUIREMENTS.md` | 要件定義（何を作るか） |
| `docs/ARCHITECTURE.md` | 構成と設計方針（どう作るか） |
| `docs/adr/` | 設計判断の記録（0001: hooks 連携、0002: タスク起動） |
| `docs/ROADMAP.md` | タスクと順番、進捗 |
| `docs/claude-code-spec.md` | 確認済みの Claude Code 仕様（M0 で作成） |
| `docs/coucou-notes.md` | coucou の調査メモ（M0 で作成） |
