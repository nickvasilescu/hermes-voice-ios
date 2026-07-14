import Foundation

enum ClientSessionError: Error {
    case notBootstrapped
}

/// Owns the app's one client session: bootstrapping it from the bridge,
/// persisting it (via `ClientSessionPersisting` — Keychain in production),
/// and handing out the current bearer token to `BackendClient` on every
/// request. This is the seam that replaces the old client-chosen
/// `X-Hermes-Session-Id` header and the old bundled bearer token — see
/// docs/SECURITY.md. [IMPLEMENTED]
///
/// An actor, not a class: the token is read from arbitrary concurrent
/// request contexts (every `BackendClient` call) and written from exactly
/// one place (`ensureSession`), and actor isolation is what makes that
/// provably race-free without a manual lock or `@unchecked Sendable`.
actor ClientSessionManager {
    private let persistence: ClientSessionPersisting
    private var current: StoredClientSession?
    private var inFlightBootstrap: Task<StoredClientSession, Error>?

    init(persistence: ClientSessionPersisting) {
        self.persistence = persistence
    }

    /// Returns a valid session, restoring from persistence or minting a
    /// fresh one via `bootstrap` if necessary. Concurrent callers await the
    /// same in-flight mint rather than each triggering their own.
    func ensureSession(bootstrap: @Sendable () async throws -> MintedClientSession) async throws -> StoredClientSession {
        if let current, current.expiresAt > Date() {
            return current
        }
        if let restored = await persistence.load(), restored.expiresAt > Date() {
            current = restored
            return restored
        }
        if let inFlightBootstrap {
            return try await inFlightBootstrap.value
        }

        let task = Task<StoredClientSession, Error> {
            let minted = try await bootstrap()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let expiresAt = formatter.date(from: minted.expiresAt) ?? Date().addingTimeInterval(3600)
            let stored = StoredClientSession(
                sessionToken: minted.sessionToken,
                hermesSessionId: minted.hermesSessionId,
                expiresAt: expiresAt
            )
            await persistence.save(stored)
            return stored
        }
        inFlightBootstrap = task
        defer { inFlightBootstrap = nil }

        let stored = try await task.value
        current = stored
        return stored
    }

    /// Current token if a session has already been established this
    /// process lifetime; nil before the first `ensureSession` call. Used by
    /// `BackendClient` to attach `Authorization`.
    func currentToken() -> String? {
        current?.sessionToken
    }

    func currentHermesSessionId() -> String? {
        current?.hermesSessionId
    }

    func invalidate() async {
        current = nil
        await persistence.clear()
    }
}
