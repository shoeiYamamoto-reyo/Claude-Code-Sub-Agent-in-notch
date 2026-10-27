import Foundation

/// アプリから始めたタスク 1 つ分の記録（ROADMAP 5-4、F3-8）。いつ・どのエージェントに・何を頼み・どうなったか。
///
/// 出力（`tasks/<session-id>.jsonl`）は 14 日で消すが、この記録はそれより長く残す。
/// 指示文や応答は長ければ切り詰めて持つ。
public struct TaskHistoryEntry: Codable, Sendable, Equatable, Identifiable {
    public enum Outcome: String, Codable, Sendable, Equatable {
        case running
        case finished
        /// プロセスは正常に終わったが、`result` がエラー（`error_max_turns` など）。
        case error
        case stopped
        /// プロセスが失敗した（終了コード、シグナル）。
        case failed
        /// 動いている間にアプリが終わった（その後どうなったかは分からない）。
        case interrupted

        public var isSuccess: Bool { self == .finished }
        public var isFailure: Bool { self == .error || self == .failed }
    }

    /// `--session-id` と同じ。
    public var id: UUID
    public var projectID: UUID
    public var projectName: String
    /// 指定したサブエージェント。nil ならメインのエージェント。
    public var agent: String?
    /// 最初の指示。
    public var prompt: String
    /// 続けて渡した指示（`--resume`）。古い順。
    public var followUps: [String]
    public var startedAt: Date
    /// 最後に終わった時刻。動いている間は nil。
    public var endedAt: Date?
    public var outcome: Outcome
    /// 失敗の理由。
    public var detail: String?
    /// 最後の応答。
    public var summary: String?
    /// 続きを含めた合計。
    public var costUSD: Double?
    public var filesChanged: Int
    public var linesAdded: Int
    public var linesRemoved: Int

    public init(
        id: UUID,
        projectID: UUID,
        projectName: String,
        agent: String?,
        prompt: String,
        followUps: [String] = [],
        startedAt: Date,
        endedAt: Date? = nil,
        outcome: Outcome = .running,
        detail: String? = nil,
        summary: String? = nil,
        costUSD: Double? = nil,
        filesChanged: Int = 0,
        linesAdded: Int = 0,
        linesRemoved: Int = 0
    ) {
        self.id = id
        self.projectID = projectID
        self.projectName = projectName
        self.agent = agent
        self.prompt = TaskHistory.clip(prompt, to: TaskHistory.maxPromptLength)
        self.followUps = followUps.map { TaskHistory.clip($0, to: TaskHistory.maxFollowUpLength) }
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.outcome = outcome
        self.detail = detail
        self.summary = summary
        self.costUSD = costUSD
        self.filesChanged = filesChanged
        self.linesAdded = linesAdded
        self.linesRemoved = linesRemoved
    }
}

/// タスクが終わったときの結果（`TaskHistory.finish`）。
public struct TaskHistoryOutcome: Sendable, Equatable {
    public var outcome: TaskHistoryEntry.Outcome
    public var endedAt: Date
    public var detail: String?
    public var summary: String?
    /// 今回の実行の分（続きなら前回までに足す）。
    public var costUSD: Double?
    /// 最初の指示からの累計（`TaskTranscript.fileChanges` は続きでも積み上げる）。
    public var fileChanges: [FileChange]

    public init(
        outcome: TaskHistoryEntry.Outcome,
        endedAt: Date,
        detail: String? = nil,
        summary: String? = nil,
        costUSD: Double? = nil,
        fileChanges: [FileChange] = []
    ) {
        self.outcome = outcome
        self.endedAt = endedAt
        self.detail = detail
        self.summary = summary
        self.costUSD = costUSD
        self.fileChanges = fileChanges
    }
}

/// サブエージェントごとの利用回数（ROADMAP 5-4、F5-6）。履歴に残っている分だけを数える。
public struct AgentUsage: Sendable, Equatable {
    public var runs = 0
    public var succeeded = 0
    public var failed = 0
    public var lastUsedAt: Date?

    public init() {}

    /// 成功の割合。成功か失敗で終わったものが無ければ nil（停止・中断は数えない）。
    public var successRate: Double? {
        let ended = succeeded + failed
        return ended > 0 ? Double(succeeded) / Double(ended) : nil
    }
}

/// タスクの履歴（新しく動いた順）。値型。保存は `TaskHistoryFile`。
public struct TaskHistory: Sendable, Equatable {
    /// 残す件数。古いものから消す。
    public static let maxEntries = 200
    static let maxPromptLength = 4000
    static let maxFollowUpLength = 2000
    static let maxFollowUps = 20
    static let maxSummaryLength = 500
    static let maxDetailLength = 300

    public private(set) var entries: [TaskHistoryEntry]

    public init(entries: [TaskHistoryEntry] = []) {
        self.entries = Array(entries.prefix(Self.maxEntries))
    }

    public func entry(id: UUID) -> TaskHistoryEntry? {
        entries.first { $0.id == id }
    }

    /// タスクを始めた。同じ ID があれば置き換える。
    public mutating func begin(_ entry: TaskHistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries { entries.removeLast(entries.count - Self.maxEntries) }
    }

    /// 終わったタスクを続けた。先頭に移す。記録が無ければ何もしない。
    public mutating func beginFollowUp(id: UUID, prompt: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        var entry = entries.remove(at: index)
        entry.followUps.append(Self.clip(prompt, to: Self.maxFollowUpLength))
        if entry.followUps.count > Self.maxFollowUps { entry.followUps.removeFirst(entry.followUps.count - Self.maxFollowUps) }
        entry.outcome = .running
        entry.endedAt = nil
        entry.detail = nil
        entries.insert(entry, at: 0)
    }

    /// タスクが終わった。記録が無ければ何もしない。
    public mutating func finish(id: UUID, with result: TaskHistoryOutcome) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        var entry = entries[index]
        entry.outcome = result.outcome
        entry.endedAt = result.endedAt
        entry.detail = result.detail.map { Self.clip($0, to: Self.maxDetailLength) }
        if let summary = result.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            entry.summary = Self.clip(summary, to: Self.maxSummaryLength)
        }
        if let cost = result.costUSD { entry.costUSD = (entry.costUSD ?? 0) + cost }
        if !result.fileChanges.isEmpty {
            let totals = FileChange.totals(result.fileChanges)
            entry.filesChanged = result.fileChanges.count
            entry.linesAdded = totals.added
            entry.linesRemoved = totals.removed
        }
        entries[index] = entry
    }

    /// 読み込んだとき、動いていることになっているもの（前回アプリが終わったときに動いていた）を中断にする。
    /// 変わったものがあれば true。
    @discardableResult
    public mutating func markRunningAsInterrupted() -> Bool {
        var changed = false
        for index in entries.indices where entries[index].outcome == .running {
            entries[index].outcome = .interrupted
            changed = true
        }
        return changed
    }

    public mutating func removeAll() {
        entries.removeAll()
    }

    /// `agent` を指定したタスクの利用回数。`projectIDs` を渡すとそのプロジェクトのタスクだけを数える。
    public func usage(agent: String, projectIDs: Set<UUID>? = nil) -> AgentUsage {
        var usage = AgentUsage()
        for entry in entries where entry.agent == agent {
            if let projectIDs, !projectIDs.contains(entry.projectID) { continue }
            usage.runs += 1
            if entry.outcome.isSuccess { usage.succeeded += 1 }
            if entry.outcome.isFailure { usage.failed += 1 }
            usage.lastUsedAt = max(usage.lastUsedAt ?? entry.startedAt, entry.startedAt)
        }
        return usage
    }

    static func clip(_ text: String, to length: Int) -> String {
        text.count > length ? String(text.prefix(length)) + "…" : text
    }
}

/// タスクの履歴の保存先（`~/Library/Application Support/NotchAgent/history.json`）。
///
/// アプリ自身のファイルなので確認なしで書くが、読めなかったファイルは上書きしない（呼び出し側が保存を止める）。
/// 指示文を含むのでパーミッションは 0600。
public enum TaskHistoryFile {
    public static let fileName = "history.json"
    public static let currentVersion = 1

    public static func path(home: String) -> String {
        let base = home.hasSuffix("/") ? String(home.dropLast()) : home
        return "\(base)/Library/Application Support/\(HookBridge.supportDirectoryName)/\(fileName)"
    }

    /// ファイルが無ければ空の履歴。
    public static func load(from path: String) throws(ProjectRegistryFile.LoadError) -> TaskHistory {
        guard FileManager.default.fileExists(atPath: path) else { return TaskHistory() }
        guard let data = FileManager.default.contents(atPath: path) else { throw .unreadable(path) }
        return try decode(data)
    }

    public static func decode(_ data: Data) throws(ProjectRegistryFile.LoadError) -> TaskHistory {
        let header: Header
        do {
            header = try JSONDecoder().decode(Header.self, from: data)
        } catch {
            throw .invalid(ProjectRegistryFile.describe(error))
        }
        guard header.version <= currentVersion else { throw .newerVersion(header.version) }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return TaskHistory(entries: try decoder.decode(Contents.self, from: data).entries)
        } catch {
            throw .invalid(ProjectRegistryFile.describe(error))
        }
    }

    public static func encode(_ history: TaskHistory) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(Contents(version: currentVersion, entries: history.entries))
        data.append(0x0A)
        return data
    }

    /// 一時ファイルに書いて置き換える。新しく作るときはフォルダも作り、パーミッションは 0600。
    public static func save(_ history: TaskHistory, to path: String) throws {
        let data = try encode(history)
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
        var entries: [TaskHistoryEntry]
    }
}
