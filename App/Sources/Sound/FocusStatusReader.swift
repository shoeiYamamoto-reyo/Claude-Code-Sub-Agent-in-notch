import Foundation
import Intents
import Observation

/// macOS の集中モード中かを読む（ROADMAP 5-7、F0-8 の続き。`INFocusStatusCenter`）。
///
/// 常時は監視しない。音を鳴らす直前に `isFocused` を読むだけなので、待機中の CPU は使わない。
/// 許可を求めるのは設定画面のボタンを押したときだけ（起動時に許可ダイアログを出さない）。
/// 許可が無い・読めないときは「集中モードではない」として扱う（音は今までどおり鳴る）。
///
/// 集中モードの状態を読むには、アプリに「集中モードの状態」の entitlement が要る。署名なしのビルドでは
/// 許可が得られないことがある（5-9 で署名を整えるときに entitlement を入れる。docs/design/sound.md）。
@MainActor
@Observable
final class FocusStatusReader {
    enum Access: Equatable {
        case notDetermined
        case authorized
        case denied
        case restricted
    }

    private(set) var access: Access

    init() {
        access = Self.map(INFocusStatusCenter.default.authorizationStatus)
    }

    /// 集中モード中か。許可が無い・分からないときは false。
    var isFocused: Bool {
        guard access == .authorized else { return false }
        return INFocusStatusCenter.default.focusStatus.isFocused ?? false
    }

    /// 許可を求める（初回だけシステムのダイアログが出る）。
    func requestAccess() {
        // 完了ハンドラはメインスレッド以外で呼ばれることがあるので、@Sendable にしてメインに戻す。
        INFocusStatusCenter.default.requestAuthorization { @Sendable [weak self] status in
            let access = Self.map(status)
            guard let self else { return }
            Task { @MainActor in self.access = access }
        }
    }

    /// システム設定で許可を変えたあと（設定画面を開いたとき）に読み直す。
    func refresh() {
        access = Self.map(INFocusStatusCenter.default.authorizationStatus)
    }

    nonisolated private static func map(_ status: INFocusStatusAuthorizationStatus) -> Access {
        switch status {
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .restricted
        }
    }
}
