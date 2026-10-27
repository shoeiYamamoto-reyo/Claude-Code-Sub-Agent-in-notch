import Foundation

/// よく使う指示のテンプレート（ROADMAP 5-5、F2-6）。
///
/// 選ぶと指示の欄に入り、エージェントやプロジェクトが決めてあればそれも選ぶ。
public struct PromptTemplate: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var prompt: String
    /// 使うサブエージェント。nil なら「おまかせ」。
    public var agent: String?
    /// このプロジェクトで使う。nil ならどのプロジェクトでも使える。
    public var projectID: UUID?

    public init(id: UUID = UUID(), name: String, prompt: String, agent: String? = nil, projectID: UUID? = nil) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.agent = agent
        self.projectID = projectID
    }
}

/// テンプレートの一覧（名前順、大文字と小文字は区別しない）。値型。保存は `PromptTemplateFile`。
public struct PromptTemplateLibrary: Sendable, Equatable {
    public private(set) var templates: [PromptTemplate]

    public init(templates: [PromptTemplate] = []) {
        self.templates = Self.sorted(templates)
    }

    public enum Issue: Sendable, Equatable {
        case emptyName
        case emptyPrompt
        case duplicateName

        public var message: String {
            switch self {
            case .emptyName: "名前を入力してください。"
            case .emptyPrompt: "指示を入力してください。"
            case .duplicateName: "同じ名前のテンプレートがあります。"
            }
        }
    }

    public struct ValidationError: Error, Sendable, Equatable {
        public var issues: [Issue]
    }

    /// 名前・エージェントの前後の空白を取り、空のエージェントは「おまかせ」にする。指示は末尾の空白だけ取る。
    public static func normalized(_ template: PromptTemplate) -> PromptTemplate {
        var template = template
        template.name = template.name.trimmingCharacters(in: .whitespacesAndNewlines)
        template.agent = template.agent?.trimmingCharacters(in: .whitespacesAndNewlines)
        if template.agent?.isEmpty == true { template.agent = nil }
        while let last = template.prompt.last, last.isWhitespace { template.prompt.removeLast() }
        return template
    }

    /// `template`（正規化済み）を保存できるか。同じ ID のものは自分自身として扱う。
    public func issues(for template: PromptTemplate) -> [Issue] {
        var issues: [Issue] = []
        if template.name.isEmpty { issues.append(.emptyName) }
        if template.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append(.emptyPrompt) }
        if !template.name.isEmpty, templates.contains(where: {
            $0.id != template.id && $0.name.lowercased() == template.name.lowercased()
        }) {
            issues.append(.duplicateName)
        }
        return issues
    }

    /// 保存する。同じ ID があれば置き換える。正規化した値を返す。
    @discardableResult
    public mutating func upsert(_ template: PromptTemplate) throws(ValidationError) -> PromptTemplate {
        let template = Self.normalized(template)
        let issues = self.issues(for: template)
        guard issues.isEmpty else { throw ValidationError(issues: issues) }
        templates.removeAll { $0.id == template.id }
        templates = Self.sorted(templates + [template])
        return template
    }

    @discardableResult
    public mutating func remove(id: PromptTemplate.ID) -> PromptTemplate? {
        guard let index = templates.firstIndex(where: { $0.id == id }) else { return nil }
        return templates.remove(at: index)
    }

    public func template(id: PromptTemplate.ID) -> PromptTemplate? {
        templates.first { $0.id == id }
    }

    /// 選べるテンプレート。どのプロジェクトでも使えるものと、`projectID` のもの。
    /// `projectID` が nil なら、すべて。
    public func available(for projectID: UUID?) -> [PromptTemplate] {
        guard let projectID else { return templates }
        return templates.filter { $0.projectID == nil || $0.projectID == projectID }
    }

    private static func sorted(_ templates: [PromptTemplate]) -> [PromptTemplate] {
        templates.sorted { ($0.name.lowercased(), $0.name, $0.id.uuidString) < ($1.name.lowercased(), $1.name, $1.id.uuidString) }
    }
}

/// テンプレートの保存先（`~/Library/Application Support/NotchAgent/templates.json`、0600）。
///
/// アプリ自身のファイルなので確認なしで書くが、読めなかったファイルは上書きしない（呼び出し側が保存を止める）。
public enum PromptTemplateFile {
    public static let fileName = "templates.json"
    public static let currentVersion = 1

    public static func path(home: String) -> String {
        let base = home.hasSuffix("/") ? String(home.dropLast()) : home
        return "\(base)/Library/Application Support/\(HookBridge.supportDirectoryName)/\(fileName)"
    }

    /// ファイルが無ければ空。
    public static func load(from path: String) throws(ProjectRegistryFile.LoadError) -> PromptTemplateLibrary {
        guard FileManager.default.fileExists(atPath: path) else { return PromptTemplateLibrary() }
        guard let data = FileManager.default.contents(atPath: path) else { throw .unreadable(path) }
        return try decode(data)
    }

    public static func decode(_ data: Data) throws(ProjectRegistryFile.LoadError) -> PromptTemplateLibrary {
        let header: Header
        do {
            header = try JSONDecoder().decode(Header.self, from: data)
        } catch {
            throw .invalid(ProjectRegistryFile.describe(error))
        }
        guard header.version <= currentVersion else { throw .newerVersion(header.version) }
        do {
            return PromptTemplateLibrary(templates: try JSONDecoder().decode(Contents.self, from: data).templates)
        } catch {
            throw .invalid(ProjectRegistryFile.describe(error))
        }
    }

    public static func encode(_ library: PromptTemplateLibrary) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(Contents(version: currentVersion, templates: library.templates))
        data.append(0x0A)
        return data
    }

    /// 一時ファイルに書いて置き換える。新しく作るときはフォルダも作り、パーミッションは 0600。
    public static func save(_ library: PromptTemplateLibrary, to path: String) throws {
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
        var templates: [PromptTemplate]
    }
}
