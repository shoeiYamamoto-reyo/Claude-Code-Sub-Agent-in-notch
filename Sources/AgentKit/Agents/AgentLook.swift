import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// サブエージェントのキャラの見た目（ROADMAP 5-8、F5-8）。体の色は frontmatter の `color`（`AgentAppearance`）のままで、
/// 目の形・体形・小物をアプリ側で選ぶ。定義ファイル（リポジトリで共有されることがある）には書かない。
///
/// 目の形は待機中の目だけを変える（作業中・エラーなどの表情は状態が分かるようにそのまま）。
public struct AgentLook: Codable, Sendable, Equatable {
    public enum Eyes: String, Codable, Sendable, CaseIterable {
        case round
        case small
        case big
        case oval
        case sleepy

        public var displayName: String {
            switch self {
            case .round: "まる"
            case .small: "つぶら"
            case .big: "きらきら"
            case .oval: "たまご"
            case .sleepy: "ねむそう"
            }
        }
    }

    public enum Shape: String, Codable, Sendable, CaseIterable {
        case standard
        case tall
        case wide
        case small

        public var displayName: String {
            switch self {
            case .standard: "ふつう"
            case .tall: "のっぽ"
            case .wide: "ずんぐり"
            case .small: "ちび"
            }
        }

        /// 体の底（`CharacterSpec.bodyAnchor`）を支点にした伸び縮み。
        public var scale: (x: CGFloat, y: CGFloat) {
            switch self {
            case .standard: (1, 1)
            case .tall: (0.86, 1.14)
            case .wide: (1.14, 0.86)
            case .small: (0.84, 0.84)
            }
        }
    }

    public enum Accessory: String, Codable, Sendable, CaseIterable {
        case none
        case sprout
        case antenna
        case ribbon
        case hat
        case glasses

        public var displayName: String {
            switch self {
            case .none: "なし"
            case .sprout: "双葉"
            case .antenna: "アンテナ"
            case .ribbon: "リボン"
            case .hat: "とんがり帽子"
            case .glasses: "めがね"
            }
        }
    }

    public var eyes: Eyes
    public var shape: Shape
    public var accessory: Accessory

    public static let standard = AgentLook()

    public init(eyes: Eyes = .round, shape: Shape = .standard, accessory: Accessory = .none) {
        self.eyes = eyes
        self.shape = shape
        self.accessory = accessory
    }

    /// 知らない値（新しいアプリで選んだもの）は既定に戻して読む。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eyes = (try? container.decodeIfPresent(Eyes.self, forKey: .eyes)) ?? .round
        shape = (try? container.decodeIfPresent(Shape.self, forKey: .shape)) ?? .standard
        accessory = (try? container.decodeIfPresent(Accessory.self, forKey: .accessory)) ?? .none
    }

    private enum CodingKeys: String, CodingKey {
        case eyes, shape, accessory
    }
}

/// 体形に合わせた輪郭・目・陰・頭のてっぺんの位置（viewBox 単位）。体形は底を支点に伸び縮みさせ、目の大きさは変えない。
public struct CharacterGeometry: Sendable, Equatable {
    public var bodySegments: [PathSegment]
    public var leftEye: CGPoint
    public var rightEye: CGPoint
    public var shadowRadii: CGSize
    /// 頭のてっぺん（小物を置く位置）。
    public var top: CGPoint

    public static let standard = CharacterGeometry(shape: .standard)

    public init(shape: AgentLook.Shape) {
        let (sx, sy) = shape.scale
        let anchor = CharacterSpec.bodyAnchor
        func map(_ point: CGPoint) -> CGPoint {
            CGPoint(x: anchor.x + (point.x - anchor.x) * sx, y: anchor.y + (point.y - anchor.y) * sy)
        }
        bodySegments = CharacterSpec.bodySegments.map { segment in
            switch segment {
            case .move(let point): .move(to: map(point))
            case .line(let point): .line(to: map(point))
            case .curve(let point, let control1, let control2): .curve(to: map(point), control1: map(control1), control2: map(control2))
            }
        }
        leftEye = map(CharacterSpec.leftEye)
        rightEye = map(CharacterSpec.rightEye)
        shadowRadii = CGSize(width: CharacterSpec.shadowRadii.width * sx, height: CharacterSpec.shadowRadii.height)
        top = map(CGPoint(x: 70, y: 22))
    }
}

/// 定義ファイルのパスごとの見た目。既定の見た目は持たない。
public struct AgentLookLibrary: Sendable, Equatable {
    public private(set) var looks: [String: AgentLook]

    public init(looks: [String: AgentLook] = [:]) {
        self.looks = looks.filter { $0.value != .standard }
    }

    public func look(for path: String) -> AgentLook {
        looks[path] ?? .standard
    }

    /// 既定の見た目にしたら記録を消す。
    public mutating func set(_ look: AgentLook, for path: String) {
        looks[path] = look == .standard ? nil : look
    }
}

/// 見た目の保存先（`~/Library/Application Support/NotchAgent/agent-looks.json`）。
///
/// アプリ自身のファイルなので確認なしで書くが、読めなかったファイルは上書きしない（呼び出し側が保存を止める）。
public enum AgentLookFile {
    public static let fileName = "agent-looks.json"
    public static let currentVersion = 1

    public static func path(home: String) -> String {
        let base = home.hasSuffix("/") ? String(home.dropLast()) : home
        return "\(base)/Library/Application Support/\(HookBridge.supportDirectoryName)/\(fileName)"
    }

    /// ファイルが無ければ空。
    public static func load(from path: String) throws(ProjectRegistryFile.LoadError) -> AgentLookLibrary {
        guard FileManager.default.fileExists(atPath: path) else { return AgentLookLibrary() }
        guard let data = FileManager.default.contents(atPath: path) else { throw .unreadable(path) }
        return try decode(data)
    }

    public static func decode(_ data: Data) throws(ProjectRegistryFile.LoadError) -> AgentLookLibrary {
        let header: Header
        do {
            header = try JSONDecoder().decode(Header.self, from: data)
        } catch {
            throw .invalid(ProjectRegistryFile.describe(error))
        }
        guard header.version <= currentVersion else { throw .newerVersion(header.version) }
        do {
            return AgentLookLibrary(looks: try JSONDecoder().decode(Contents.self, from: data).looks)
        } catch {
            throw .invalid(ProjectRegistryFile.describe(error))
        }
    }

    public static func encode(_ library: AgentLookLibrary) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(Contents(version: currentVersion, looks: library.looks))
        data.append(0x0A)
        return data
    }

    /// 一時ファイルに書いて置き換える。新しく作るときはフォルダも作り、パーミッションは 0600。
    public static func save(_ library: AgentLookLibrary, to path: String) throws {
        let data = try encode(library)
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    private struct Header: Decodable {
        var version: Int
    }

    private struct Contents: Codable {
        var version: Int
        var looks: [String: AgentLook]
    }
}
