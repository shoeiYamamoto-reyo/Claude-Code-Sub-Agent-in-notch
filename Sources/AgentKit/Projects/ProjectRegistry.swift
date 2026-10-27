import Foundation

/// 登録したプロジェクトの一覧（F1-1）。値型。保存は `ProjectRegistryFile`。
public struct ProjectRegistry: Sendable, Equatable {
    /// 登録順。
    public private(set) var projects: [Project]

    public init(projects: [Project] = []) {
        self.projects = projects
    }

    /// 登録できない理由。
    public enum Issue: Sendable, Equatable {
        case emptyName
        case relativeDirectory
        /// 同じフォルダが別のプロジェクトとして登録済み。
        case duplicateDirectory(existing: String)
        case invalidVariableName(String)
        case duplicateVariableName(String)

        public var message: String {
            switch self {
            case .emptyName: "名前を入力してください。"
            case .relativeDirectory: "フォルダは絶対パスで指定してください。"
            case .duplicateDirectory(let existing): "このフォルダは「\(existing)」として登録済みです。"
            case .invalidVariableName(let name): "環境変数名「\(name)」は使えません（英字か _ で始まり、英数字と _ だけ）。"
            case .duplicateVariableName(let name): "環境変数「\(name)」が重複しています。"
            }
        }
    }

    public struct ValidationError: Error, Sendable, Equatable {
        public var issues: [Issue]
    }

    /// 保存する前の形にそろえる（名前とパスの空白、パスの正規化、環境設定の空欄）。
    public static func normalized(_ project: Project, home: String = NSHomeDirectory()) -> Project {
        var project = project
        project.name = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
        project.directory = ProjectPath.normalize(project.directory, home: home)
        project.environment = project.environment.normalized()
        return project
    }

    /// `project`（正規化済み）を登録・更新できるかを調べる。同じ ID のものは自分自身として扱う。
    public func issues(for project: Project) -> [Issue] {
        var issues: [Issue] = []
        if project.name.isEmpty { issues.append(.emptyName) }
        if !project.directory.hasPrefix("/") { issues.append(.relativeDirectory) }
        if let existing = projects.first(where: { $0.id != project.id && $0.directory == project.directory }) {
            issues.append(.duplicateDirectory(existing: existing.name))
        }
        var seen = Set<String>()
        for variable in project.environment.variables {
            if !EnvironmentVariable.isValidName(variable.name) {
                issues.append(.invalidVariableName(variable.name))
            } else if !seen.insert(variable.name).inserted {
                issues.append(.duplicateVariableName(variable.name))
            }
        }
        return issues
    }

    /// 登録する。同じ ID があれば置き換える（編集）。正規化した値を返す。
    @discardableResult
    public mutating func upsert(_ project: Project, home: String = NSHomeDirectory()) throws(ValidationError) -> Project {
        let project = Self.normalized(project, home: home)
        let issues = self.issues(for: project)
        guard issues.isEmpty else { throw ValidationError(issues: issues) }
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index] = project
        } else {
            projects.append(project)
        }
        return project
    }

    @discardableResult
    public mutating func remove(id: Project.ID) -> Project? {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return nil }
        return projects.remove(at: index)
    }

    public func project(id: Project.ID) -> Project? {
        projects.first { $0.id == id }
    }

    /// セッションの作業フォルダ（hook の `cwd`）が属するプロジェクト。入れ子なら一番内側のもの。
    public func project(containing path: String) -> Project? {
        let path = ProjectPath.normalize(path)
        return projects
            .filter { ProjectPath.isInside(path, directory: $0.directory) }
            .max { ProjectPath.components(of: $0.directory).count < ProjectPath.components(of: $1.directory).count }
    }
}

/// プロジェクト登録の保存先（`~/Library/Application Support/NotchAgent/projects.json`）。
///
/// アプリ自身のファイルなので確認なしで書くが、読めなかったファイルは上書きしない（呼び出し側が保存を止める）。
public enum ProjectRegistryFile {
    public static let fileName = "projects.json"
    /// ファイル形式のバージョン。
    public static let currentVersion = 1

    public enum LoadError: Error, Sendable, Equatable {
        case unreadable(String)
        case invalid(String)
        /// 新しいバージョンのアプリが書いたファイル。上書きすると情報が消えるので読まない。
        case newerVersion(Int)

        public var message: String {
            switch self {
            case .unreadable(let path): "\(path) を読めませんでした。"
            case .invalid(let detail): "プロジェクトの保存ファイルが壊れています（\(detail)）。"
            case .newerVersion(let version): "新しいバージョンのアプリで保存されたファイルです（形式 \(version)）。アプリを更新してください。"
            }
        }
    }

    public static func path(home: String) -> String {
        let base = home.hasSuffix("/") ? String(home.dropLast()) : home
        return "\(base)/Library/Application Support/\(HookBridge.supportDirectoryName)/\(fileName)"
    }

    /// ファイルが無ければ空の一覧。
    public static func load(from path: String) throws(LoadError) -> ProjectRegistry {
        guard FileManager.default.fileExists(atPath: path) else { return ProjectRegistry() }
        guard let data = FileManager.default.contents(atPath: path) else { throw .unreadable(path) }
        return try decode(data)
    }

    public static func decode(_ data: Data) throws(LoadError) -> ProjectRegistry {
        let header: Header
        do {
            header = try JSONDecoder().decode(Header.self, from: data)
        } catch {
            throw .invalid(describe(error))
        }
        guard header.version <= currentVersion else { throw .newerVersion(header.version) }
        do {
            let file = try decoder.decode(Contents.self, from: data)
            return ProjectRegistry(projects: file.projects)
        } catch {
            throw .invalid(describe(error))
        }
    }

    public static func encode(_ registry: ProjectRegistry) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(Contents(version: currentVersion, projects: registry.projects))
        data.append(0x0A)
        return data
    }

    /// 一時ファイルに書いて置き換える。新しく作るときはフォルダも作り、パーミッションは 0600。
    public static func save(_ registry: ProjectRegistry, to path: String) throws {
        let data = try encode(registry)
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
        var projects: [Project]
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, let context):
            "\(keyPath(context.codingPath + [key])) がありません"
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
            "\(keyPath(context.codingPath)) の形が違います"
        case DecodingError.dataCorrupted(let context):
            context.codingPath.isEmpty ? "JSON として読めません" : "\(keyPath(context.codingPath)) の値が不正です"
        default:
            error.localizedDescription
        }
    }

    private static func keyPath(_ codingPath: [CodingKey]) -> String {
        codingPath.reduce(into: "") { result, key in
            if let index = key.intValue {
                result += "[\(index)]"
            } else {
                result += result.isEmpty ? key.stringValue : ".\(key.stringValue)"
            }
        }
    }
}
