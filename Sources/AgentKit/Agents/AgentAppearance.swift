import Foundation

/// 「エージェント」タブでサブエージェントを表すキャラクターの色（`docs/design/agent-characters.md`）。
///
/// frontmatter の `color` を、ノッチのキャラと同じ形の体の色にする。目（`CharacterSpec.eyeColor`）が
/// 見えるよう淡い色にそろえる。白はノッチのキャラだけに使うので、ここでは使わない。
public enum AgentAppearance {
    /// `AgentDefinition.colorValues` の色ごとの体と陰。
    public static let palettes: [String: CharacterPalette] = [
        "red": CharacterPalette(body: 0xF4A3A3, shadow: 0xDC8A8A),
        "blue": CharacterPalette(body: 0x9DC3F5, shadow: 0x84A9DA),
        "green": CharacterPalette(body: 0xA8DDA8, shadow: 0x8EC48E),
        "yellow": CharacterPalette(body: 0xF6E08E, shadow: 0xDDC674),
        "purple": CharacterPalette(body: 0xC9B0F2, shadow: 0xAF96D8),
        "orange": CharacterPalette(body: 0xF7BE8A, shadow: 0xDEA471),
        "pink": CharacterPalette(body: 0xF5B3D6, shadow: 0xDB99BC),
        "cyan": CharacterPalette(body: 0x99E0E3, shadow: 0x7FC6C9),
    ]
    /// `color` が無いか、知らない値のとき（白に近い灰色）。
    public static let uncolored = CharacterPalette(body: 0xCFCAC2, shadow: 0xB6B1A9)
    /// 読めない定義（Claude Code が読み飛ばすもの）。
    public static let unreadable = CharacterPalette(body: 0x8C8986, shadow: 0x75726F)

    public static func palette(for entry: AgentCatalog.Entry) -> CharacterPalette {
        guard let definition = entry.definition else { return unreadable }
        return palette(color: definition.color)
    }

    public static func palette(color: String?) -> CharacterPalette {
        guard let color = color?.trimmingCharacters(in: .whitespaces) else { return uncolored }
        return palettes[color] ?? uncolored
    }
}
