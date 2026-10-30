import AgentKit
import Foundation

/// サブエージェントのキャラの見た目を `agent-looks.json` に保存する（ROADMAP 5-8、F5-8）。
///
/// 定義ファイルには書かない（リポジトリで共有される定義を汚さないため）。アプリ自身のファイルなので選んだらすぐ書く。
/// 読めなかったファイルは上書きしない（この間は選んでもメモリの中だけで変える）。
@MainActor
final class AgentLookStore {
    let model: NotchModel
    private let filePath: String
    private var canSave = true

    init(model: NotchModel, home: String = NSHomeDirectory()) {
        self.model = model
        filePath = AgentLookFile.path(home: home)
        model.onSetAgentLook = { [weak self] path, look in self?.set(look, for: path) }
    }

    func load() {
        do {
            model.agentLooks = try AgentLookFile.load(from: filePath)
            canSave = true
            model.agentLookError = nil
        } catch {
            canSave = false
            model.agentLookError = switch error {
            case .unreadable(let path): "\(path) を読めませんでした。キャラの見た目は保存しません。"
            case .invalid(let detail): "キャラの見た目のファイルが壊れています（\(detail)）。見た目は保存しません。"
            case .newerVersion(let version): "新しいバージョンのアプリで保存された見た目です（形式 \(version)）。アプリを更新してください。"
            }
        }
    }

    func set(_ look: AgentLook, for path: String) {
        model.agentLooks.set(look, for: path)
        guard canSave else { return }
        do {
            try AgentLookFile.save(model.agentLooks, to: filePath)
            // 前に保存できなかったときの知らせを消す（読めなかったときは canSave が false なのでここに来ない）。
            model.agentLookError = nil
        } catch {
            model.agentLookError = "キャラの見た目を保存できませんでした: \(error.localizedDescription)"
        }
    }
}
