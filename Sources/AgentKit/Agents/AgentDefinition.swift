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

    /// - Parameter frontmatter: 編集のときは読み込んだもの（未知の項目・順序・コメントを残すため）。新しく作るときは空。
    public init(
        name: String,
        description: String,
        tools: [String]? = nil,
        disallowedTools: [String]? = nil,
        model: String? = nil,
        effort: String? = nil,
        permissionMode: String? = nil,
        color: String? = nil,
        body: String,
        frontmatter: Frontmatter = Frontmatter()
    ) {
        self.name = name
        self.description = description
        self.tools = tools
        self.disallowedTools = disallowedTools
        self.model = model
        self.effort = effort
        self.permissionMode = permissionMode
        self.color = color
        self.body = body
        self.frontmatter = frontmatter
    }

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

    // MARK: - 書き出し（ROADMAP 4-1）

    /// ファイルの内容に戻す。`frontmatter` を土台に、値が変わった項目だけを書き直す。
    /// 未知の項目・順序・コメント・本文はそのまま残り、何も変えなければ読んだときと同じテキストになる
    /// （改行は LF、BOM なし）。
    public func render() -> String {
        var frontmatter = self.frontmatter
        let name = name.trimmingCharacters(in: .whitespaces)
        if Self.scalar(frontmatter["name"]) != Self.nonEmpty(name) {
            frontmatter.set("name", .string(name))
        }
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if frontmatter["description"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) != description {
            frontmatter.set("description", .string(description))
        }
        Self.setToolList("tools", tools, in: &frontmatter)
        Self.setToolList("disallowedTools", disallowedTools, in: &frontmatter)
        for (key, value) in [("model", model), ("effort", effort), ("permissionMode", permissionMode), ("color", color)] {
            let value = value.flatMap { Self.nonEmpty($0.trimmingCharacters(in: .whitespaces)) }
            if Self.scalar(frontmatter[key]) != value {
                frontmatter.set(key, value.map { .string($0) })
            }
        }
        return "---\n" + frontmatter.render() + "---\n" + body
    }

    /// ツールの一覧を書く。前と同じなら書き方を変えない。新しく書くときは、元がリストならリスト、
    /// そうでなければカンマ区切り（名前にカンマを含むときはリスト）。
    private static func setToolList(_ key: String, _ tools: [String]?, in frontmatter: inout Frontmatter) {
        let tools = tools?.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let normalized = tools?.isEmpty == true ? nil : tools
        guard toolList(frontmatter[key]) != normalized else { return }
        guard let normalized else {
            frontmatter.set(key, nil)
            return
        }
        if case .list = frontmatter[key] {
            frontmatter.set(key, .list(normalized))
        } else if normalized.contains(where: { $0.contains(",") }) {
            frontmatter.set(key, .list(normalized))
        } else {
            frontmatter.set(key, .string(normalized.joined(separator: ", ")))
        }
    }

    private static func nonEmpty(_ text: String) -> String? {
        text.isEmpty ? nil : text
    }

    /// 新しく作るときのファイル名（`<name>.md`）。パスに使えない文字と空白は `-` にする。
    public var suggestedFileName: String {
        let base = name.trimmingCharacters(in: .whitespaces)
            .map { $0 == "/" || $0 == ":" || $0 == "\\" || $0.isWhitespace ? "-" : String($0) }
            .joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        return (base.isEmpty ? "agent" : base) + ".md"
    }

    // MARK: - 検証（ROADMAP 4-1、F5-4）

    public struct Issue: Sendable, Equatable {
        public enum Severity: Sendable, Equatable {
            /// Claude Code が読み飛ばす、または動きが決まらない。保存させない。
            case error
            /// 読めるが、意図どおりに動かないかもしれない。
            case warning
        }

        /// frontmatter のキー（本文なら "body"）。
        public var field: String
        public var severity: Severity
        public var message: String
    }

    public static let modelValues = ProjectEnvironment.modelSuggestions + ["inherit"]
    public static let permissionModeValues = ["default"] + ProjectEnvironment.permissionModes
    public static let colorValues = ["red", "blue", "green", "yellow", "purple", "orange", "pink", "cyan"]

    /// 保存する前の検査。
    /// - Parameter namesInSameDirectory: 同じフォルダにあるほかの定義の `name`（重なるとどちらが使われるか決まらない）。
    public func validate(namesInSameDirectory: [String] = []) -> [Issue] {
        var issues: [Issue] = []
        func add(_ field: String, _ severity: Issue.Severity, _ message: String) {
            issues.append(Issue(field: field, severity: severity, message: message))
        }
        let name = name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty {
            add("name", .error, "name を入力してください")
        } else if !Self.isValidName(name) {
            add("name", .error, Problem.invalidName(name).message)
        } else if namesInSameDirectory.contains(name) {
            add("name", .error, "同じフォルダに name「\(name)」の定義がほかにもあります（どちらが使われるか決まりません）")
        }
        if description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add("description", .error, "description を入力してください（いつ使うかを Claude が判断する手がかりです）")
        }
        if let model = model?.trimmingCharacters(in: .whitespaces), !model.isEmpty,
           !Self.modelValues.contains(model), !model.hasPrefix("claude-") {
            add("model", .warning, "model「\(model)」は知らない値です（\(Self.modelValues.joined(separator: " / ")) かモデル ID）")
        }
        if let effort = effort?.trimmingCharacters(in: .whitespaces), !effort.isEmpty,
           !ProjectEnvironment.effortLevels.contains(effort) {
            add("effort", .warning, "effort「\(effort)」は知らない値です（\(ProjectEnvironment.effortLevels.joined(separator: " / "))）")
        }
        if let mode = permissionMode?.trimmingCharacters(in: .whitespaces), !mode.isEmpty,
           !Self.permissionModeValues.contains(mode) {
            add("permissionMode", .warning, "permissionMode「\(mode)」は知らない値です")
        }
        if let color = color?.trimmingCharacters(in: .whitespaces), !color.isEmpty, !Self.colorValues.contains(color) {
            add("color", .warning, "color「\(color)」は知らない値です（\(Self.colorValues.joined(separator: " / "))）")
        }
        let tools = Set(tools ?? [])
        let both = (disallowedTools ?? []).filter { tools.contains($0) }
        if !both.isEmpty {
            add("disallowedTools", .warning, "\(both.joined(separator: ", ")) は tools と disallowedTools の両方にあります")
        }
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add("body", .warning, "本文（system prompt）が空です")
        }
        // 書き出したものを Claude Code と同じ条件で読めるか。
        if issues.allSatisfy({ $0.severity != .error }), case .failure(let problem) = Self.parse(render()) {
            add("frontmatter", .error, "書き出した内容を読み戻せません: \(problem.message)")
        }
        return issues
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
