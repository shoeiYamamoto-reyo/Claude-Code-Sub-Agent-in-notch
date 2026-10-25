# Claude Code Sub-Agent in Notch

Mac のノッチから Claude Code のエージェント／サブエージェントを管理・監視する macOS アプリ（開発中）。

- 要件: [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md)
- 設計: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- ロードマップ: [docs/ROADMAP.md](docs/ROADMAP.md)
- 開発の流れ: [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)
- サブエージェント構成とルール: [CLAUDE.md](CLAUDE.md)

## ビルド
```sh
# AgentKit と notch-hook（macOS / Linux）
swift build
swift test

# アプリ（macOS、Xcode 16 以上と XcodeGen が必要）
brew install xcodegen
xcodegen generate
open NotchAgent.xcodeproj
```
