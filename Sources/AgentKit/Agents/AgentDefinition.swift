import Foundation

/// サブエージェントの定義（`.claude/agents/*.md`、F1-3 / F5-1）。docs/claude-code-spec.md 7 章。
public struct AgentDefinition: Sendable, Equatable {
    public enum Scope: Sendable, Equatable, Hashable {
        /// `~/.claude/agents/`
        case user
        /// プロジェクトの `.claude/agents/`（作業フォルダから上へ辿ったもの）
        case project

        public var displayName: String {
            switch self {
            case .user: "ユーザー"
            case .project: "プロジェクト"
            }
        }
    }

    public var name: String
    public var description: String
    /// 使えるツール。nil なら親から全部を引き継ぐ。
    public var tools: [String]?
    public var disallowedTools: [String]?
    public var model: String?
    public var effort: String?
    public var permissionMode: String?
    public var color: String?
    /// system prompt になる本文。
    public var body: String
    public var frontmatter: Frontmatter

    /// Claude Code が読み飛ばす定義の理由（docs/claude-code-spec.md 7 章）。
    public enum Problem: Error, Sendable, Equatable {
        case frontmatter(Frontmatter.ParseError)
        case missingName
        case invalidName(String)
        case missingDescription
        case unreadable

        public var message: String {
            switch self {
            case .frontmatter(let error): error.message
            case .missingName: "name がありません"
            case .invalidName(let name): "name「\(name)」は使えません（256 文字以内、: を含まず、- で始めない）"
            case .missingDescription: "description がありません"
            case .unreadable: "ファイルを読めません"
            }
        }
    }

    public static func parse(_ text: String) -> Result<AgentDefinition, Problem> {
        let parsed: (frontmatter: Frontmatter, body: String)
        do {
            parsed = try Frontmatter.parse(text)
        } catch {
            return .failure(.frontmatter(error))
        }
        let frontmatter = parsed.frontmatter
        guard let name = frontmatter["name"]?.stringValue?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            return .failure(.missingName)
        }
        guard isValidName(name) else { return .failure(.invalidName(name)) }
        guard let description = frontmatter["description"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !description.isEmpty
        else {
            return .failure(.missingDescription)
        }
        return .success(AgentDefinition(
            name: name,
            description: description,
            tools: toolList(frontmatter["tools"]),
            disallowedTools: toolList(frontmatter["disallowedTools"]),
            model: scalar(frontmatter["model"]),
            effort: scalar(frontmatter["effort"]),
            permissionMode: scalar(frontmatter["permissionMode"]),
            color: scalar(frontmatter["color"]),
            body: parsed.body,
            frontmatter: frontmatter
        ))
    }

    public static func isValidName(_ name: String) -> Bool {
        name.count <= 256 && !name.contains(":") && !name.hasPrefix("-")
    }

    /// カンマ区切りの文字列か YAML のリスト。
    static func toolList(_ value: Frontmatter.Value?) -> [String]? {
        switch value {
        case .string(let text):
            let tools = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return tools.isEmpty ? nil : tools
        case .list(let items):
            return items
        case .raw, nil:
            return nil
        }
    }

    private static func scalar(_ value: Frontmatter.Value?) -> String? {
        guard let text = value?.stringValue?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        return text
    }
}

/// ユーザーとプロジェクトのサブエージェント定義の一覧（ROADMAP 3-2）。
///
/// Claude Code と同じく、サブフォルダも再帰的に読み、`name` で識別する。同じ名前なら
/// 作業フォルダに近い `.claude/agents/` が勝ち、プロジェクトがユーザーに勝つ。
public struct AgentCatalog: Sendable, Equatable {
    /// 定義ファイル 1 つ分。
    public struct Entry: Sendable, Equatable, Identifiable {
        public var id: String { path }
        public var path: String
        public var scope: AgentDefinition.Scope
        /// 読み込んだ `.claude/agents` フォルダ。
        public var directory: String
        public var result: Result<AgentDefinition, AgentDefinition.Problem>
        /// 同じ名前の別の定義が優先されるとき、そのファイルのパス。
        public var shadowedBy: String?

        public var definition: AgentDefinition? { try? result.get() }

        public var problem: AgentDefinition.Problem? {
            if case .failure(let problem) = result { return problem }
            return nil
        }
    }

    /// 優先順（近いプロジェクトのフォルダ → 遠いフォルダ → ユーザー）。同じフォルダの中はパス順。
    public var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    /// 実際に使われる定義（名前順）。
    public var effective: [AgentDefinition] {
        entries
            .filter { $0.shadowedBy == nil }
            .compactMap(\.definition)
            .sorted { ($0.name.lowercased(), $0.name) < ($1.name.lowercased(), $1.name) }
    }

    public func entries(in scope: AgentDefinition.Scope) -> [Entry] {
        entries.filter { $0.scope == scope }
    }

    /// プロジェクトの `.claude/agents` の候補。作業フォルダから上へ辿り、ホーム（ユーザーの定義の場所）の手前で止める。
    public static func projectAgentDirectories(for projectDirectory: String, home: String) -> [String] {
        let home = ProjectPath.normalize(home, home: home)
        var directory = ProjectPath.normalize(projectDirectory, home: home)
        var result: [String] = []
        while directory != home {
            result.append(join(directory, ".claude/agents"))
            guard directory != "/" else { break }
            let parent = (directory as NSString).deletingLastPathComponent
            directory = parent.isEmpty ? "/" : parent
        }
        return result
    }

    public static func userAgentDirectory(home: String) -> String {
        join(ProjectPath.normalize(home, home: home), ".claude/agents")
    }

    /// ファイルを読んで一覧を作る。`projectDirectory` が nil ならユーザーの定義だけ。
    public static func load(projectDirectory: String?, home: String) -> AgentCatalog {
        var sources: [(directory: String, scope: AgentDefinition.Scope)] = []
        if let projectDirectory {
            sources += projectAgentDirectories(for: projectDirectory, home: home).map { ($0, .project) }
        }
        sources.append((userAgentDirectory(home: home), .user))

        var entries: [Entry] = []
        for source in sources {
            for path in markdownFiles(in: source.directory) {
                let result: Result<AgentDefinition, AgentDefinition.Problem>
                if let data = FileManager.default.contents(atPath: path), data.count <= maxFileBytes {
                    result = AgentDefinition.parse(String(decoding: data, as: UTF8.self))
                } else {
                    result = .failure(.unreadable)
                }
                entries.append(Entry(path: path, scope: source.scope, directory: source.directory, result: result))
            }
        }
        return AgentCatalog(entries: resolvingShadows(entries))
    }

    /// 先にあるものを優先し、同じ名前の後のものに `shadowedBy` を付ける。
    static func resolvingShadows(_ entries: [Entry]) -> [Entry] {
        var winners: [String: String] = [:]
        return entries.map { entry in
            var entry = entry
            guard let name = entry.definition?.name else { return entry }
            if let winner = winners[name] {
                entry.shadowedBy = winner
            } else {
                winners[name] = entry.path
            }
            return entry
        }
    }

    /// 定義ファイルの上限。これより大きいものは読まない。
    static let maxFileBytes = 1 << 20

    private static func markdownFiles(in directory: String) -> [String] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue,
              let enumerator = FileManager.default.enumerator(atPath: directory)
        else { return [] }
        var files: [String] = []
        while let relative = enumerator.nextObject() as? String {
            guard relative.hasSuffix(".md") else { continue }
            let path = join(directory, relative)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue {
                files.append(path)
            }
        }
        return files.sorted()
    }

    private static func join(_ directory: String, _ component: String) -> String {
        directory.hasSuffix("/") ? directory + component : directory + "/" + component
    }
}
