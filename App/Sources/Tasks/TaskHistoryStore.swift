import AgentKit
import Foundation

/// タスクの履歴を記録し、`history.json` に保存する（ROADMAP 5-4、F3-8）。
///
/// `TaskRunner` が始めたとき・続けたとき・終わったときに呼ぶ。変わるたびに書く（小さなファイルなので待たない）。
/// 前回動いていたままのものは、読み込んだときに「中断」にする。
/// 読めなかったファイルは上書きしない（この間はメモリの中だけで記録する）。
@MainActor
final class TaskHistoryStore {
    let model: NotchModel
    private let filePath: String
    private var canSave = true

    init(model: NotchModel, home: String = NSHomeDirectory()) {
        self.model = model
        filePath = TaskHistoryFile.path(home: home)
        model.onClearTaskHistory = { [weak self] in self?.clear() }
    }

    func load() {
        do {
            var history = try TaskHistoryFile.load(from: filePath)
            canSave = true
            model.taskHistoryError = nil
            let changed = history.markRunningAsInterrupted()
            model.taskHistory = history
            if changed { save() }
        } catch {
            canSave = false
            model.taskHistoryError = Self.message(for: error)
        }
    }

    func begin(_ run: TaskRun) {
        model.taskHistory.begin(TaskHistoryEntry(
            id: run.id,
            projectID: run.projectID,
            projectName: run.projectName,
            agent: run.agent,
            prompt: run.prompt,
            startedAt: run.startedAt
        ))
        save()
    }

    func beginFollowUp(_ id: UUID, prompt: String) {
        model.taskHistory.beginFollowUp(id: id, prompt: prompt)
        save()
    }

    func finish(_ run: TaskRun) {
        let transcript = run.transcript
        let outcome: TaskHistoryEntry.Outcome
        var detail: String?
        switch run.state {
        case .running, .stopping:
            return
        case .finished:
            if let result = transcript.result, result.isError {
                outcome = .error
                detail = result.subtype
            } else {
                outcome = .finished
            }
        case .stopped:
            outcome = .stopped
        case .failed(let message):
            outcome = .failed
            detail = message
        }
        model.taskHistory.finish(id: run.id, with: TaskHistoryOutcome(
            outcome: outcome,
            endedAt: run.endedAt ?? Date(),
            detail: detail,
            summary: transcript.lastAssistantText,
            costUSD: transcript.result?.costUSD,
            fileChanges: transcript.fileChanges
        ))
        save()
    }

    /// 設定画面の「履歴を消去」。読めなかったファイルは消さない（読めるようになるまで触らない）。
    func clear() {
        model.taskHistory.removeAll()
        save()
    }

    private func save() {
        guard canSave else { return }
        do {
            try TaskHistoryFile.save(model.taskHistory, to: filePath)
        } catch {
            model.taskHistoryError = "履歴を保存できませんでした: \(error.localizedDescription)"
        }
    }

    private static func message(for error: ProjectRegistryFile.LoadError) -> String {
        switch error {
        case .unreadable(let path): "\(path) を読めませんでした。履歴は保存しません。"
        case .invalid(let detail): "履歴のファイルが壊れています（\(detail)）。履歴は保存しません。"
        case .newerVersion(let version): "新しいバージョンのアプリで保存された履歴です（形式 \(version)）。アプリを更新してください。"
        }
    }
}
