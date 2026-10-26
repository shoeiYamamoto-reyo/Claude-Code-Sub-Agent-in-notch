import AgentKit
import Foundation
import Security

/// プロジェクトの秘密の環境変数を Keychain（ログインキーチェーンの汎用パスワード）に置く（F1-2）。
///
/// 項目名は `EnvironmentVariable.keychainAccount`。値はタスクを起動するときだけ読む（M3-3）。
/// 設定画面では「保存済みか」だけを調べ、値は読まない（読むとキーチェーンの確認が出ることがあるため）。
enum ProjectSecrets {
    static let service = "dev.notchagent.NotchAgent.project-env"

    struct KeychainError: LocalizedError {
        let status: OSStatus

        var errorDescription: String? {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain に保存できませんでした: \(message)"
        }
    }

    static func set(_ value: String, projectID: UUID, name: String) throws {
        let query = baseQuery(projectID: projectID, name: name)
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var item = query
            item[kSecValueData] = data
            item[kSecAttrLabel] = "Notch Agent: \(name)"
            item[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlocked
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        default:
            throw KeychainError(status: status)
        }
    }

    static func value(projectID: UUID, name: String) throws -> String? {
        var query = baseQuery(projectID: projectID, name: name)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return (result as? Data).map { String(decoding: $0, as: UTF8.self) }
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    /// 値を読まずに、保存済みかだけを調べる。
    static func exists(projectID: UUID, name: String) -> Bool {
        var query = baseQuery(projectID: projectID, name: name)
        query[kSecReturnAttributes] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func remove(projectID: UUID, name: String) {
        SecItemDelete(baseQuery(projectID: projectID, name: name) as CFDictionary)
    }

    private static func baseQuery(projectID: UUID, name: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: EnvironmentVariable.keychainAccount(projectID: projectID, name: name),
        ]
    }
}
