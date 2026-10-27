import AgentKit
import Foundation

/// 指示のテンプレートを読み書きする（ROADMAP 5-5、F2-6）。保存先は `templates.json`。
///
/// 読めなかったファイルは上書きしない（この間は保存・削除できない）。
@MainActor
final class PromptTemplateStore {
    let model: NotchModel
    private let filePath: String

    init(model: NotchModel, home: String = NSHomeDirectory()) {
        self.model = model
        filePath = PromptTemplateFile.path(home: home)
        model.onSaveTemplate = { [weak self] template in self?.save(template) ?? ["保存できません。"] }
        model.onDeleteTemplate = { [weak self] id in self?.delete(id) }
    }

    func load() {
        do {
            model.templates = try PromptTemplateFile.load(from: filePath)
            model.templateLoadError = nil
        } catch {
            model.templateLoadError = switch error {
            case .unreadable(let path): "\(path) を読めませんでした。テンプレートは保存できません。"
            case .invalid(let detail): "テンプレートのファイルが壊れています（\(detail)）。テンプレートは保存できません。"
            case .newerVersion(let version): "新しいバージョンのアプリで保存されたテンプレートです（形式 \(version)）。アプリを更新してください。"
            }
        }
    }

    /// 保存できなければ理由を返す。
    private func save(_ template: PromptTemplate) -> [String] {
        if let error = model.templateLoadError { return [error] }
        var updated = model.templates
        do {
            try updated.upsert(template)
        } catch {
            return error.issues.map(\.message)
        }
        return write(updated)
    }

    private func delete(_ id: PromptTemplate.ID) {
        guard model.templateLoadError == nil else { return }
        var updated = model.templates
        guard updated.remove(id: id) != nil else { return }
        _ = write(updated)
    }

    private func write(_ library: PromptTemplateLibrary) -> [String] {
        do {
            try PromptTemplateFile.save(library, to: filePath)
        } catch {
            return ["保存できませんでした: \(error.localizedDescription)"]
        }
        model.templates = library
        return []
    }
}
