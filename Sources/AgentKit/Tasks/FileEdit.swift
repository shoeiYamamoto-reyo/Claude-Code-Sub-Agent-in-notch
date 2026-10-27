import Foundation

/// ファイルを書き換えるツール呼び出し 1 回分の差分（ROADMAP 5-3、F3-6）。
///
/// ツールの入力（`tool_input`）だけから作る。ディスクの中身は読まないので、`Write` は前の内容が分からず
/// 「すべて追加」として数える。
public struct FileEdit: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        /// `Edit` / `MultiEdit`: 置き換え。
        case edit
        /// `Write`: ファイル全体を書く（前の内容は分からない）。
        case write
        /// `NotebookEdit`: セル 1 つ。
        case notebook
    }

    /// ファイルを書き換えるツールと、その入力でパスを持つキー。
    public static let pathKeys: [String: String] = [
        "Edit": "file_path",
        "MultiEdit": "file_path",
        "Write": "file_path",
        "NotebookEdit": "notebook_path",
    ]

    /// 詳細に残す行数の上限（大きな Write でメモリを使い過ぎないため）。数（`added` / `removed`）は上限を超えても正しい。
    public static let maxStoredLines = 400
    /// LCS の表の大きさの上限（行数の積）。超えたら「全部消して全部足した」として数える。
    static let maxDiffCells = 1_000_000

    public var path: String
    public var kind: Kind
    public var added: Int
    public var removed: Int
    /// 置き換えごとの差分（`LineDiff.hunks` で前後 3 行に絞ったもの。省いたところは nil）。
    public var hunks: [[LineDiff.Line?]]
    /// `maxStoredLines` を超えて詳細を省いたか。
    public var isTruncated: Bool

    public init(path: String, kind: Kind, added: Int, removed: Int, hunks: [[LineDiff.Line?]], isTruncated: Bool = false) {
        self.path = path
        self.kind = kind
        self.added = added
        self.removed = removed
        self.hunks = hunks
        self.isTruncated = isTruncated
    }

    /// ツール呼び出しの入力から作る。ファイルを書き換えるツールでなければ nil。
    public static func from(toolName: String, input: JSONValue?) -> FileEdit? {
        guard let key = pathKeys[toolName], let input, let path = input[key]?.stringValue, !path.isEmpty else {
            return nil
        }
        var replacements: [(old: String, new: String)] = []
        let kind: Kind
        switch toolName {
        case "Edit":
            kind = .edit
            replacements.append((input["old_string"]?.stringValue ?? "", input["new_string"]?.stringValue ?? ""))
        case "MultiEdit":
            kind = .edit
            if case .array(let edits) = input["edits"] {
                for edit in edits {
                    replacements.append((edit["old_string"]?.stringValue ?? "", edit["new_string"]?.stringValue ?? ""))
                }
            }
        case "Write":
            kind = .write
            replacements.append(("", input["content"]?.stringValue ?? ""))
        default:
            kind = .notebook
            let mode = input["edit_mode"]?.stringValue
            let source = input["new_source"]?.stringValue ?? ""
            // 削除は中身が分からないので 0 行として数える。
            replacements.append(("", mode == "delete" ? "" : source))
        }

        var edit = FileEdit(path: path, kind: kind, added: 0, removed: 0, hunks: [])
        var stored = 0
        for replacement in replacements {
            let lines = diff(replacement.old, replacement.new)
            edit.added += lines.filter { $0.kind == .added }.count
            edit.removed += lines.filter { $0.kind == .removed }.count
            var hunk = LineDiff.hunks(lines)
            if stored + hunk.count > maxStoredLines {
                hunk = Array(hunk.prefix(max(0, maxStoredLines - stored)))
                edit.isTruncated = true
            }
            stored += hunk.count
            if !hunk.isEmpty { edit.hunks.append(hunk) }
        }
        return edit
    }

    private static func diff(_ old: String, _ new: String) -> [LineDiff.Line] {
        let oldCount = lineCount(old)
        let newCount = lineCount(new)
        guard oldCount * newCount > maxDiffCells else { return LineDiff.compare(old, new) }
        // 大きすぎるときは表を作らない。
        return LineDiff.compare(old, "") + LineDiff.compare("", new)
    }

    private static func lineCount(_ text: String) -> Int {
        text.utf8.reduce(1) { $1 == 0x0A ? $0 + 1 : $0 }
    }
}

/// ファイルごとにまとめた変更（成功した編集だけ）。
public struct FileChange: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public var path: String
    public var added: Int
    public var removed: Int
    /// 古い順。
    public var edits: [FileEdit]

    public init(path: String, edits: [FileEdit] = []) {
        self.path = path
        self.added = 0
        self.removed = 0
        self.edits = []
        for edit in edits { add(edit) }
    }

    public mutating func add(_ edit: FileEdit) {
        added += edit.added
        removed += edit.removed
        edits.append(edit)
    }

    /// 「+12 −3」。
    public var countsText: String { "+\(added) −\(removed)" }

    /// `edit` を最初に変わった順のまま、該当するファイルにまとめる。
    /// - Parameter keepingEdits: ファイルごとに詳細を残す編集の数（古いものから捨てる）。
    public static func record(_ edit: FileEdit, in changes: inout [FileChange], keepingEdits: Int = 50) {
        if let index = changes.firstIndex(where: { $0.path == edit.path }) {
            changes[index].add(edit)
            if changes[index].edits.count > keepingEdits {
                changes[index].edits.removeFirst(changes[index].edits.count - keepingEdits)
            }
        } else {
            changes.append(FileChange(path: edit.path, edits: [edit]))
        }
    }

    /// 全ファイルの合計。
    public static func totals(_ changes: [FileChange]) -> (added: Int, removed: Int) {
        changes.reduce((0, 0)) { ($0.0 + $1.added, $0.1 + $1.removed) }
    }
}
