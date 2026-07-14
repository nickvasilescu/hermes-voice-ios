import Foundation
import Security

/// Stores the operator-entered single-user bootstrap credential in Keychain.
/// It is never read from the application bundle, Info.plist, UserDefaults,
/// or an xcconfig. Multi-user deployments should replace this seam with
/// their identity-provider or App Attest token source.
actor BootstrapCredentialStore {
    private let service = "com.hermesvoice.app.bootstrapCredential"
    private let account = "default"

    func load() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }

    func save(_ value: String) {
        SecItemDelete(baseQuery() as CFDictionary)
        guard !value.isEmpty else { return }
        var query = baseQuery()
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    func clear() { SecItemDelete(baseQuery() as CFDictionary) }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
