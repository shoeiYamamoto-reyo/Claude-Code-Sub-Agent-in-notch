import Foundation

/// アプリから始めたタスクの出力（`tasks/<session-id>.jsonl`）をどれだけ残すか。
///
/// 中身は会話とツールの出力そのもので、秘密情報を含むこともあるので、溜め続けない。
/// 新しいものから `maxCount` 件まで、かつ `maxAge` より新しいものだけ残す。
public enum TaskOutputRetention {
    public static let maxAge: TimeInterval = 14 * 24 * 60 * 60
    public static let maxCount = 100

    public struct File: Sendable, Equatable {
        public var path: String
        public var modifiedAt: Date

        public init(path: String, modifiedAt: Date) {
            self.path = path
            self.modifiedAt = modifiedAt
        }
    }

    /// 消すファイルのパス。`keeping` にあるもの（動いているタスクの出力）は消さない。
    public static func filesToDelete(
        _ files: [File],
        now: Date,
        keeping: Set<String> = [],
        maxAge: TimeInterval = maxAge,
        maxCount: Int = maxCount
    ) -> [String] {
        let newestFirst = files.sorted { ($0.modifiedAt, $0.path) > ($1.modifiedAt, $1.path) }
        return newestFirst.enumerated().compactMap { index, file in
            guard !keeping.contains(file.path) else { return nil }
            let tooOld = now.timeIntervalSince(file.modifiedAt) > maxAge
            return tooOld || index >= maxCount ? file.path : nil
        }
    }
}
