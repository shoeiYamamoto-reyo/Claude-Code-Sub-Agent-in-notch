import Foundation

/// 登録したプロジェクト（F1-1）。作業フォルダと、タスクを起動するときの環境設定（F1-2）を持つ。
public struct Project: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    /// 作業フォルダの絶対パス（`ProjectPath.normalize` 済み）。
    public var directory: String
    public var environment: ProjectEnvironment
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        directory: String,
        environment: ProjectEnvironment = ProjectEnvironment(),
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.directory = directory
        self.environment = environment
        self.createdAt = createdAt
    }

    /// フォルダから登録するときの初期値（F1-4）。名前はフォルダ名。
    public static func suggested(forDirectory path: String, now: Date = Date()) -> Project {
        let directory = ProjectPath.normalize(path)
        let name = ProjectPath.components(of: directory).last ?? directory
        return Project(name: name, directory: directory, createdAt: now)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        directory = try container.decode(String.self, forKey: .directory)
        environment = try container.decodeIfPresent(ProjectEnvironment.self, forKey: .environment) ?? ProjectEnvironment()
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
    }
}

/// プロジェクトごとの環境設定（F1-2、ADR-0002「起動コマンド」）。
///
/// 値が nil・空のものは起動コマンドに付けない（ユーザーの Claude Code の設定どおりになる）。
/// 権限モードは既定で指定しない（REQUIREMENTS 6 章）。
public struct ProjectEnvironment: Sendable, Equatable, Codable {
    /// `--model`。エイリアス（`sonnet` など）かフル ID。
    public var model: String?
    /// `--effort`。
    public var effort: String?
    /// `--permission-mode`。
    public var permissionMode: String?
    /// `--allowedTools`。
    public var allowedTools: [String]
    /// 子プロセスに足す環境変数。
    public var variables: [EnvironmentVariable]

    public init(
        model: String? = nil,
        effort: String? = nil,
        permissionMode: String? = nil,
        allowedTools: [String] = [],
        variables: [EnvironmentVariable] = []
    ) {
        self.model = model
        self.effort = effort
        self.permissionMode = permissionMode
        self.allowedTools = allowedTools
        self.variables = variables
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        effort = try container.decodeIfPresent(String.self, forKey: .effort)
        permissionMode = try container.decodeIfPresent(String.self, forKey: .permissionMode)
        allowedTools = try container.decodeIfPresent([String].self, forKey: .allowedTools) ?? []
        variables = try container.decodeIfPresent([EnvironmentVariable].self, forKey: .variables) ?? []
    }

    /// 何も指定していない（ユーザーの設定どおりに起動する）か。
    public var isDefault: Bool {
        model == nil && effort == nil && permissionMode == nil && allowedTools.isEmpty && variables.isEmpty
    }

    /// 前後の空白を落とし、空の値を nil・空配列にそろえる。保存の前に呼ぶ。
    public func normalized() -> ProjectEnvironment {
        ProjectEnvironment(
            model: Self.nonEmpty(model),
            effort: Self.nonEmpty(effort),
            permissionMode: Self.nonEmpty(permissionMode),
            allowedTools: allowedTools.compactMap { Self.nonEmpty($0) },
            variables: variables.map { $0.normalized() }
        )
    }

    /// `--model` の候補（docs/claude-code-spec.md）。フル ID も入力できる。
    public static let modelSuggestions = ["sonnet", "opus", "haiku", "fable"]
    /// `--effort` の値。
    public static let effortLevels = ["low", "medium", "high", "xhigh", "max"]
    /// `--permission-mode` の値（docs/claude-code-spec.md 5 章）。
    public static let permissionModes = ["manual", "acceptEdits", "plan", "auto", "dontAsk", "bypassPermissions"]
    /// 確認なしで操作が進む権限モード。設定画面で注意を出す。
    public static let unattendedPermissionModes: Set<String> = ["dontAsk", "bypassPermissions"]

    /// 「許可するツール」の入力欄の文字列を分ける。カンマと改行で区切る（`Bash(git diff *)` のように空白を含むものがあるため、空白では区切らない）。
    public static func parseToolList(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    public static func formatToolList(_ tools: [String]) -> String {
        tools.joined(separator: ", ")
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// 子プロセスに足す環境変数 1 つ分。
///
/// 秘密の値（API キーなど）は JSON に保存せず、アプリが Keychain に入れる。
/// そのときは `value` を nil にし、`keychainAccount` の名前で Keychain から読む。
public struct EnvironmentVariable: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    /// 秘密でない値。秘密なら nil。
    public var value: String?
    public var isSecret: Bool

    public init(id: UUID = UUID(), name: String, value: String? = nil, isSecret: Bool = false) {
        self.id = id
        self.name = name
        self.value = isSecret ? nil : (value ?? "")
        self.isSecret = isSecret
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        isSecret = try container.decodeIfPresent(Bool.self, forKey: .isSecret) ?? false
        // 秘密の値がファイルに紛れ込んでいても読み込まない（次の保存で消える）。
        value = try isSecret ? nil : (container.decodeIfPresent(String.self, forKey: .value) ?? "")
    }

    public func normalized() -> EnvironmentVariable {
        EnvironmentVariable(id: id, name: name.trimmingCharacters(in: .whitespaces), value: value, isSecret: isSecret)
    }

    /// Keychain の項目名。プロジェクトと変数名で決まる。
    public static func keychainAccount(projectID: UUID, name: String) -> String {
        "\(projectID.uuidString)/\(name)"
    }

    /// 環境変数名として使えるか（英字か `_` で始まり、英数字と `_` だけ）。
    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first else { return false }
        func isLetter(_ s: Unicode.Scalar) -> Bool { ("a"..."z").contains(s) || ("A"..."Z").contains(s) || s == "_" }
        func isDigit(_ s: Unicode.Scalar) -> Bool { ("0"..."9").contains(s) }
        return isLetter(first) && name.unicodeScalars.allSatisfy { isLetter($0) || isDigit($0) }
    }
}

/// プロジェクトのフォルダのパスの扱い。
public enum ProjectPath {
    /// `~` を展開し、`.` と `..`、重複と末尾の `/` を取り除いた絶対パスにする。シンボリックリンクは解決しない。
    /// 相対パスはそのまま正規化する（検証で弾く）。
    public static func normalize(_ path: String, home: String = NSHomeDirectory()) -> String {
        var path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if path == "~" {
            path = home
        } else if path.hasPrefix("~/") {
            path = home + path.dropFirst()
        }
        let isAbsolute = path.hasPrefix("/")
        var result: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                if !result.isEmpty, result.last != ".." {
                    result.removeLast()
                } else if !isAbsolute {
                    result.append(component)
                }
            default:
                result.append(component)
            }
        }
        let joined = result.joined(separator: "/")
        return isAbsolute ? "/" + joined : joined
    }

    public static func components(of path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }

    /// `path` が `directory` そのものか、その中にあるか。どちらも正規化済みのパスを渡す。
    public static func isInside(_ path: String, directory: String) -> Bool {
        let base = components(of: directory)
        let target = components(of: path)
        return target.count >= base.count && Array(target.prefix(base.count)) == base
    }

    /// 表示用にホームを `~` にする。
    public static func abbreviate(_ path: String, home: String = NSHomeDirectory()) -> String {
        let home = normalize(home, home: home)
        guard home != "/", isInside(path, directory: home) else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
