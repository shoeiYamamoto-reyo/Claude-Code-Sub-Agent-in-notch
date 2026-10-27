import Observation
import ServiceManagement

/// ログイン時に起動する（F6-4、ROADMAP 5-1）。`SMAppService.mainApp` に登録するだけで、ヘルパーは使わない。
///
/// 状態はシステム設定（「一般」→「ログイン項目」）でも変えられるので、設定画面を開くたびに読み直す。
@MainActor
@Observable
final class LoginItem {
    enum State: Equatable {
        case enabled
        case disabled
        /// 登録したが、システム設定で許可されていない。
        case requiresApproval
        /// アプリが /Applications などにない（開発中のビルドなど）と登録できないことがある。
        case unavailable
    }

    private(set) var state: State = .disabled
    private(set) var lastError: String?

    init() {
        refresh()
    }

    func refresh() {
        state = switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .disabled
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }

    func setEnabled(_ enabled: Bool) {
        lastError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
