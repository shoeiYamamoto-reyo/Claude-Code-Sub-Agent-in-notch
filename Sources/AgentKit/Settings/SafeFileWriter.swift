import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// 設定ファイルの変更案。`SafeFileWriter.prepare` で作り、ユーザーが差分を確認してから `commit` する。
public struct SettingsFileEdit: Sendable, Equatable {
    /// ユーザーに見せるパス（シンボリックリンクならリンクのほう）。
    public let displayPath: String
    /// 実際に書き込むパス（リンク先）。
    public let targetPath: String
    /// 変更案を作ったときのファイルの中身。ファイルが無ければ nil。
    public let originalData: Data?
    public let newData: Data
    /// ファイルを新しく作るときのパーミッション（設定ファイルは 0600、エージェント定義は 0644）。
    public let newFilePermissions: Int

    public init(displayPath: String, targetPath: String, originalData: Data?, newData: Data, newFilePermissions: Int = 0o600) {
        self.displayPath = displayPath
        self.targetPath = targetPath
        self.originalData = originalData
        self.newData = newData
        self.newFilePermissions = newFilePermissions
    }

    public var hasChanges: Bool { originalData != newData }

    public var originalText: String { originalData.map { String(decoding: $0, as: UTF8.self) } ?? "" }
    public var newText: String { String(decoding: newData, as: UTF8.self) }

    public var diff: [LineDiff.Line] { LineDiff.compare(originalText, newText) }
}

/// 設定ファイルを安全に書き換える（ARCHITECTURE「主要な設計判断」4、`docs/coucou-notes.md` 4 章）。
///
/// - ファイルが無ければ空のオブジェクトとして扱う。あるのに JSON として読めなければ何もしない。
/// - 書く直前にファイルが変わっていたら書かない（別のツールや手編集との競合）。
/// - 書く前に日付付きのバックアップを同じフォルダに作る。
/// - シンボリックリンクならリンク先に書き、リンクは保つ。パーミッションは保つ（新規は `newFilePermissions`）。
public enum SafeFileWriter {
    public enum WriteError: Error, Equatable {
        case unreadable(String)
        case invalidJSON(String)
        case changedOnDisk
        case writeFailed(String)
    }

    public static func prepare(
        path: String,
        transform: (OrderedJSON) throws -> OrderedJSON
    ) throws -> SettingsFileEdit {
        let target = (path as NSString).resolvingSymlinksInPath
        let original = try read(target)

        let text = original.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let current: OrderedJSON
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            current = .object([])
        } else {
            do {
                current = try OrderedJSON.parse(original ?? Data())
            } catch let error as OrderedJSON.ParseError {
                throw WriteError.invalidJSON("\(error.offset) バイト目: \(error.reason)")
            }
        }

        let updated = try transform(current)
        let newData: Data
        if updated == current, let original {
            newData = original
        } else {
            var output = updated.formatted(indent: OrderedJSON.detectIndent(in: text))
            if original == nil || text.hasSuffix("\n") { output += "\n" }
            newData = Data(output.utf8)
        }
        return SettingsFileEdit(displayPath: path, targetPath: target, originalData: original, newData: newData)
    }

    /// 変更を書き込む。作ったバックアップのパスを返す（元のファイルが無かったときは nil）。
    @discardableResult
    public static func commit(_ edit: SettingsFileEdit, now: Date = Date()) throws -> String? {
        guard edit.hasChanges else { return nil }
        guard try read(edit.targetPath) == edit.originalData else { throw WriteError.changedOnDisk }

        let fileManager = FileManager.default
        let directory = (edit.targetPath as NSString).deletingLastPathComponent
        var permissions = edit.newFilePermissions
        var backupPath: String?

        if let original = edit.originalData {
            if let mode = (try? fileManager.attributesOfItem(atPath: edit.targetPath))?[.posixPermissions] as? NSNumber {
                permissions = mode.intValue
            }
            let path = uniqueBackupPath(for: edit.targetPath, now: now)
            guard fileManager.createFile(atPath: path, contents: original, attributes: [.posixPermissions: permissions]) else {
                throw WriteError.writeFailed("バックアップを作れませんでした: \(path)")
            }
            backupPath = path
        } else {
            do {
                try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
            } catch {
                throw WriteError.writeFailed(error.localizedDescription)
            }
        }

        // 同じフォルダに一時ファイルを書いて rename する（途中で落ちても壊れたファイルを残さない）。
        let temporary = (directory as NSString).appendingPathComponent(".\((edit.targetPath as NSString).lastPathComponent).notchagent-\(UUID().uuidString)")
        guard fileManager.createFile(atPath: temporary, contents: edit.newData, attributes: [.posixPermissions: permissions]) else {
            throw WriteError.writeFailed("一時ファイルを作れませんでした: \(temporary)")
        }
        chmod(temporary, mode_t(permissions))
        guard rename(temporary, edit.targetPath) == 0 else {
            let message = String(cString: strerror(errno))
            unlink(temporary)
            throw WriteError.writeFailed(message)
        }
        return backupPath
    }

    static func uniqueBackupPath(for path: String, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = "\(path).backup-\(formatter.string(from: now))"
        var candidate = base
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate) {
            candidate = "\(base)-\(counter)"
            counter += 1
        }
        return candidate
    }

    private static func read(_ path: String) throws -> Data? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        guard let data = FileManager.default.contents(atPath: path) else {
            throw WriteError.unreadable(path)
        }
        return data
    }
}

/// 行単位の差分（確認画面用）。設定ファイル程度の大きさを想定した素朴な LCS。
public enum LineDiff {
    public struct Line: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case same
            case added
            case removed
        }

        public var kind: Kind
        public var text: String
    }

    public static func compare(_ old: String, _ new: String) -> [Line] {
        let a = lines(old)
        let b = lines(new)
        let n = a.count, m = b.count
        // lengths[i][j] = a[i...] と b[j...] の最長共通部分列の長さ
        var lengths = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lengths[i][j] = a[i] == b[j] ? lengths[i + 1][j + 1] + 1 : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }
        var result: [Line] = []
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, a[i] == b[j] {
                result.append(Line(kind: .same, text: a[i]))
                i += 1
                j += 1
            } else if i < n, j == m || lengths[i + 1][j] >= lengths[i][j + 1] {
                result.append(Line(kind: .removed, text: a[i]))
                i += 1
            } else {
                result.append(Line(kind: .added, text: b[j]))
                j += 1
            }
        }
        return result
    }

    /// 変更のまわり `context` 行だけを残す。省いた部分は nil。
    public static func hunks(_ lines: [Line], context: Int = 3) -> [Line?] {
        let changed = lines.indices.filter { lines[$0].kind != .same }
        guard !changed.isEmpty else { return [] }
        var keep = Set<Int>()
        for index in changed {
            for k in max(0, index - context)...min(lines.count - 1, index + context) { keep.insert(k) }
        }
        var result: [Line?] = []
        var previous: Int?
        for index in keep.sorted() {
            if let previous, index != previous + 1 { result.append(nil) }
            if previous == nil, index > 0 { result.append(nil) }
            result.append(lines[index])
            previous = index
        }
        if let previous, previous < lines.count - 1 { result.append(nil) }
        return result
    }

    private static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        // `\r\n` は Swift では 1 文字なので、文字単位の分割（Linux の `components(separatedBy:)`）では切れない。
        // スカラーの `\n` で切り、`\r` は行に残す（macOS の NSString と同じ結果）。
        var result = text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
        if result.last == "" { result.removeLast() }
        return result
    }
}
