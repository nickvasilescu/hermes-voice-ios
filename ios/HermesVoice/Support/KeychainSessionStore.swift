import Foundation
import Security

/// Persists the bridge-minted client session (see docs/PROTOCOL.md §2 and
/// docs/SECURITY.md). This is the ONLY place the session token is ever
/// written to disk, and it goes to Keychain, never `UserDefaults`,
/// `Info.plist`, or an `.xcconfig` — those are readable from an app bundle
/// or backup without device unlock; Keychain items using
/// `kSecAttrAccessibleAfterFirstUnlock` are not. [IMPLEMENTED]
struct StoredClientSession: Codable, Equatable, Sendable {
    var sessionToken: String
    var hermesSessionId: String
    var expiresAt: Date
}

/// Narrow persistence seam so this is testable without touching the real
/// Keychain (see `ClientSessionManagerTests.swift`).
protocol ClientSessionPersisting: Sendable {
    func load() async -> StoredClientSession?
    func save(_ session: StoredClientSession) async
    func clear() async
}

actor KeychainSessionStore: ClientSessionPersisting {
    private let service: String
    private let account: String

    init(service: String = "com.hermesvoice.app.clientSession", account: String = "default") {
        self.service = service
        self.account = account
    }

    func load() -> StoredClientSession? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(StoredClientSession.self, from: data)
    }

    func save(_ session: StoredClientSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        clear()

        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(query as CFDictionary, nil)
    }

    func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
