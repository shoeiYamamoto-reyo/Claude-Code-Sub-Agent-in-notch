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

## Xcode なしで試す
CI（macOS）がビルドしたアプリを GitHub の Actions からダウンロードできます（14 日間保存）。

1. リポジトリの **Actions** → **CI** → 試したい実行（main への push か PR）を開く。
2. ページ下部の **Artifacts** から `NotchAgent-<コミット>` をダウンロードして展開する。中にもう一つ `NotchAgent.zip` があるので、それも展開して `NotchAgent.app` を取り出す（実行権限を保つため、アプリは zip にしてから Artifacts に置いている）。
3. ダウンロードしたアプリには「インターネットから来た」印が付いて起動を止められるので、ターミナルで外してから開く。
   ```sh
   xattr -dr com.apple.quarantine ~/Downloads/NotchAgent.app
   open ~/Downloads/NotchAgent.app
   ```
4. 終了はメニューバーの点線の丸アイコン →「終了」。

アドホック署名（証明書なし）の開発用ビルドです。正式な署名と公証は M5 で行います。
