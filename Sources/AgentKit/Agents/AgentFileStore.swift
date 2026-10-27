import Foundation

/// 定義を保存する前の計画（ROADMAP 4-2、F5-2 / F5-3）。
///
/// 検証の結果と、書き込む内容（`SettingsFileEdit`）をまとめる。ユーザーが差分を確認してから
/// `SafeFileWriter.commit` で書く（バックアップを作り、確認の間にファイルが変わっていたら書かない）。
public struct AgentSavePlan: Sendable, Equatable {
    /// 書き込むファイル。
    public var path: String
    public var isNew: Bool
    public var issues: [AgentDefinition.Issue]
    /// 書き込む内容。エラーがあるときは nil（保存させない）。
    public var edit: SettingsFileEdit?

    public var errors: [AgentDefinition.Issue] { issues.filter { $0.severity == .error } }
    public var warnings: [AgentDefinition.Issue] { issues.filter { $0.severity == .warning } }
}

public enum AgentFileStore {
    /// 保存の計画を作る。ファイルにはまだ何も書かない。
    /// - Parameters:
    ///   - existingPath: 編集している定義のファイル。新しく作るときは nil（`directory/<name>.md` に作る）。
    ///   - originalData: 編集を始めたときのファイルの中身。保存までにファイルが変わっていたら書き込みをやめるのに使う。
    ///   - directory: 定義を置く `.claude/agents` フォルダ。
    ///   - entries: 読み込んである定義（同じフォルダの name の重なりを調べる）。
    public static func plan(
        _ definition: AgentDefinition,
        existingPath: String?,
        originalData: Data?,
        directory: String,
        entries: [AgentCatalog.Entry],
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> AgentSavePlan {
        let names = entries
            .filter { $0.directory == directory && $0.path != existingPath }
            .compactMap { $0.definition?.name }
        var issues = definition.validate(namesInSameDirectory: names)
        let path = existingPath ?? join(directory, definition.suggestedFileName)
        if existingPath == nil, fileExists(path) {
            issues.append(AgentDefinition.Issue(
                field: "name",
                severity: .error,
                message: "\((path as NSString).lastPathComponent) は既にあります。name を変えてください"
            ))
        }
        var plan = AgentSavePlan(path: path, isNew: existingPath == nil, issues: issues, edit: nil)
        guard plan.errors.isEmpty else { return plan }

        var text = definition.render()
        // 元が CRLF なら合わせる（変えていない行まで差分に出さないため）。
        if let originalData, String(decoding: originalData, as: UTF8.self).contains("\r\n") {
            text = text.replacingOccurrences(of: "\n", with: "\r\n")
        }
        plan.edit = SettingsFileEdit(
            displayPath: path,
            targetPath: existingPath == nil ? path : (path as NSString).resolvingSymlinksInPath,
            originalData: existingPath == nil ? nil : originalData,
            newData: Data(text.utf8),
            newFilePermissions: 0o644
        )
        return plan
    }

    /// 新しい定義のひな形。
    public static func template(name: String = "") -> AgentDefinition {
        AgentDefinition(
            name: name,
            description: "",
            body: "You are a specialist. Describe the role, the steps to follow and what to report back.\n"
        )
    }

    /// 定義の追加・変更・削除を知るために見張るフォルダ（ROADMAP 4-2）。
    ///
    /// 今あるエージェントのフォルダだけを返す。`~/.claude` やプロジェクト全体を見張ると、
    /// トランスクリプトやビルドのたびに起こされるため。まだ無いフォルダは、このアプリで作ったあと読み直すときに加わる。
    public static func watchedDirectories(
        projectDirectories: [String],
        home: String,
        isDirectory: (String) -> Bool = { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    ) -> [String] {
        var candidates = [AgentCatalog.userAgentDirectory(home: home)]
        for directory in projectDirectories {
            candidates += AgentCatalog.projectAgentDirectories(for: directory, home: home)
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted && isDirectory($0) }.sorted()
    }

    private static func join(_ directory: String, _ component: String) -> String {
        directory.hasSuffix("/") ? directory + component : directory + "/" + component
    }
}
