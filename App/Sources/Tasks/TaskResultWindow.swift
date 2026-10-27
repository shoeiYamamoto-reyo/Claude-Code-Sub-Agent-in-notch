import AgentKit
import AppKit
import SwiftUI

/// タスクの結果を見るウインドウ（ROADMAP 3-4、F2-3）。実行中も出力に合わせて更新される。
/// 終わったタスクは、ここから追加の指示で続けられる（ROADMAP 3-6、F2-4）。
@MainActor
final class TaskResultViewer {
    let model: NotchModel
    private var window: NSWindow?

    init(model: NotchModel) {
        self.model = model
        model.onShowTask = { [weak self] id in self?.show(id) }
    }

    func show(_ id: UUID) {
        guard model.tasks.contains(where: { $0.id == id }) else { return }
        let view = TaskResultView(
            model: model,
            taskID: id,
            projectDirectory: model.projects.project(id: model.tasks.first { $0.id == id }?.projectID ?? UUID())?.directory
        )
        if let window {
            window.contentView = NSHostingView(rootView: view)
        } else {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 520),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "タスクの結果"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: view)
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct TaskResultView: View {
    let model: NotchModel
    let taskID: UUID
    let projectDirectory: String?

    @State private var followUp = ""
    @State private var problem: String?

    init(model: NotchModel, taskID: UUID, projectDirectory: String?) {
        self.model = model
        self.taskID = taskID
        self.projectDirectory = projectDirectory
    }

    var body: some View {
        if let task = model.tasks.first(where: { $0.id == taskID }) {
            content(task)
        } else {
            Text("このタスクは一覧から消えました。")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func content(_ task: TaskRun) -> some View {
        let transcript = task.transcript
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text([task.projectName, task.agent].compactMap { $0 }.joined(separator: " · "))
                    .font(.title3.bold())
                Text(TaskResultSummary.stateText(task))
                    .foregroundStyle(TaskResultSummary.isError(task) ? .red : .secondary)
                Spacer()
                if task.state == .running {
                    Button("停止") { model.onStopTask?(task.id) }
                }
            }
            Text(TaskResultSummary.details(task))
                .font(.caption)
                .foregroundStyle(.secondary)

            GroupBox(task.followUps.isEmpty ? "指示" : "指示（\(task.followUps.count + 1) 回）") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.prompt)
                        .lineLimit(4)
                    ForEach(Array(task.followUps.enumerated()), id: \.offset) { _, prompt in
                        Text("↳ " + prompt)
                            .lineLimit(3)
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox(task.isActive ? "最新の応答" : "最後の応答") {
                ScrollView {
                    Text(transcript.lastAssistantText ?? task.restoredSummary ?? (task.isActive ? "まだ応答はありません。" : "応答はありませんでした。"))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 120)
            }

            GroupBox(changesTitle(transcript)) {
                if transcript.fileChanges.isEmpty {
                    Text("ありません。")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(transcript.fileChanges) { change in
                                FileChangeRow(change: change, projectDirectory: projectDirectory)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                }
            }

            if !task.isActive {
                continueBox(task)
            }

            HStack {
                Text("出力: \(ProjectPath.abbreviate(task.outputPath))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("出力を Finder で表示") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: task.outputPath)])
                }
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 460)
    }

    /// 追加の指示で同じセッションを続ける（`--resume`）。
    private func continueBox(_ task: TaskRun) -> some View {
        GroupBox("追加の指示で続ける") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .bottom) {
                    TextField("同じ会話の続きとして指示します（⌘Return で続ける）", text: $followUp, axis: .vertical)
                        .lineLimit(1...5)
                        .textFieldStyle(.roundedBorder)
                    Button("続ける") { continueTask(task) }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(followUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let problem {
                    Label(problem, systemImage: "exclamationmark.circle")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func continueTask(_ task: TaskRun) {
        guard let onContinue = model.onContinueTask else { return }
        problem = onContinue(task.id, followUp)
        if problem == nil { followUp = "" }
    }
}

/// 一覧の行と結果ウインドウで共通の表示。
enum TaskResultSummary {
    /// プロセスは正常に終わったが、`result` がエラーだったものも含めてエラー扱いにする。
    static func isError(_ task: TaskRun) -> Bool {
        if case .failed = task.state { return true }
        return task.state == .finished && task.transcript.result?.isError == true
    }

    static func stateText(_ task: TaskRun) -> String {
        if task.state == .finished, let result = task.transcript.result, result.isError {
            return "エラー（\(result.subtype ?? "不明")）"
        }
        return task.state.displayName
    }

    /// 一覧の 1 行: 実行中はツール、終わったら最後の応答、エラーならその理由。
    static func oneLine(_ task: TaskRun) -> String {
        if case .failed(let message) = task.state {
            return ToolSummary.oneLine(message) ?? message
        }
        let transcript = task.transcript
        if task.isActive, let tool = transcript.currentTool {
            return "▸ " + tool.name
        }
        if !task.isActive, let text = transcript.lastAssistantText ?? task.restoredSummary, let line = ToolSummary.oneLine(text) {
            return line
        }
        return TaskCommand.displayName(for: task.prompt)
    }

    static func details(_ task: TaskRun) -> String {
        let transcript = task.transcript
        var parts: [String] = [task.startedAt.formatted(date: .omitted, time: .shortened) + " 開始"]
        if let model = transcript.model { parts.append(model) }
        if let result = transcript.result {
            if let duration = result.durationMilliseconds {
                parts.append(Duration.milliseconds(Int64(duration)).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated)))
            }
            if let turns = result.turns { parts.append("\(turns) ターン") }
            if let cost = result.costUSD { parts.append(String(format: "$%.4f", cost)) }
        }
        parts.append("ツール \(transcript.toolUseCount) 回")
        return parts.joined(separator: " · ")
    }

    static func relative(_ path: String, to directory: String?) -> String {
        guard let directory, ProjectPath.isInside(path, directory: directory), path != directory else {
            return ProjectPath.abbreviate(path)
        }
        return String(path.dropFirst(directory.count).drop { $0 == "/" })
    }
}

private func changesTitle(_ transcript: TaskTranscript) -> String {
    guard !transcript.fileChanges.isEmpty else { return "変更したファイル" }
    let totals = FileChange.totals(transcript.fileChanges)
    return "変更したファイル（\(transcript.fileChanges.count)、+\(totals.added) −\(totals.removed)）"
}

/// 変更したファイル 1 つ。「差分」を開くと、編集ごとの差分（前後 3 行）を出す（ROADMAP 5-3、F3-6）。
private struct FileChangeRow: View {
    let change: FileChange
    let projectDirectory: String?
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(change.edits.enumerated()), id: \.offset) { _, edit in
                    if edit.kind == .write {
                        Text("ファイル全体を書き込み（前の内容は分からないので、すべて追加として数えます）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(edit.hunks.enumerated()), id: \.offset) { _, hunk in
                        ScrollView(.horizontal) {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(hunk.enumerated()), id: \.offset) { _, line in
                                    DiffLineView(line: line)
                                }
                            }
                            .padding(6)
                        }
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    if edit.isTruncated {
                        Text("長いので途中までです。").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        } label: {
            HStack(spacing: 8) {
                Button(TaskResultSummary.relative(change.path, to: projectDirectory)) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: change.path)])
                }
                .buttonStyle(.link)
                .help("Finder で表示: \(change.path)")
                Text("+\(change.added)").foregroundStyle(.green)
                Text("−\(change.removed)").foregroundStyle(.red)
                if change.edits.count > 1 {
                    Text("\(change.edits.count) 回").foregroundStyle(.secondary)
                }
            }
            .font(.callout.monospacedDigit())
        }
    }
}
