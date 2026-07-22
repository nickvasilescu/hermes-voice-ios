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
    /// Invalidates work that crossed an operator reset/stop boundary. A task
    /// may ignore cooperative cancellation, so cancellation alone is not a
    /// sufficient stale-write guard.
    private var generation: UInt64 = 0

    init(persistence: ClientSessionPersisting) {
        self.persistence = persistence
    }

    /// Returns a valid session, restoring from persistence or minting a
    /// fresh one via `bootstrap` if necessary. Concurrent callers await the
    /// same in-flight mint rather than each triggering their own.
    func ensureSession(bootstrap: @escaping @Sendable () async throws -> MintedClientSession) async throws -> StoredClientSession {
        if let current, current.expiresAt > Date() {
            return current
        }
        let requestedGeneration = generation
        if let restored = await persistence.load(), restored.expiresAt > Date() {
            try Task.checkCancellation()
            guard generation == requestedGeneration else { throw CancellationError() }
            current = restored
            return restored
        }
        if let inFlightBootstrap {
            let stored = try await inFlightBootstrap.value
            try Task.checkCancellation()
            guard generation == requestedGeneration else { throw CancellationError() }
            if current == nil {
                current = stored
                await persistence.save(stored)
                guard generation == requestedGeneration else {
                    await persistence.clear()
                    throw CancellationError()
                }
            }
            return stored
        }

        let bootstrapGeneration = generation
        let task = Task<StoredClientSession, Error> {
            try Task.checkCancellation()
            let minted = try await bootstrap()
            try Task.checkCancellation()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let expiresAt = formatter.date(from: minted.expiresAt) ?? Date().addingTimeInterval(3600)
            return StoredClientSession(
                sessionToken: minted.sessionToken,
                hermesSessionId: minted.hermesSessionId,
                expiresAt: expiresAt
            )
        }
        inFlightBootstrap = task
        defer {
            if generation == bootstrapGeneration {
                inFlightBootstrap = nil
            }
        }

        let stored = try await task.value
        try Task.checkCancellation()
        guard generation == bootstrapGeneration else { throw CancellationError() }
        if current != stored {
            current = stored
            await persistence.save(stored)
        }
        // `persistence.save` is an actor hop. If Reset ran while it was in
        // progress, erase the stale write before returning it to a caller.
        guard generation == bootstrapGeneration else {
            await persistence.clear()
            throw CancellationError()
        }
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

    func currentSession() -> StoredClientSession? {
        current
    }

    /// Snapshot used to prevent an asynchronous recovery that began before a
    /// Reset from initiating a new bootstrap after that Reset completed.
    func sessionGeneration() -> UInt64 {
        generation
    }

    func recoverySnapshot() -> (generation: UInt64, current: StoredClientSession?) {
        (generation, current)
    }

    func ensureSession(
        expectedGeneration: UInt64,
        bootstrap: @escaping @Sendable () async throws -> MintedClientSession
    ) async throws -> StoredClientSession {
        guard generation == expectedGeneration else { throw CancellationError() }
        return try await ensureSession(bootstrap: bootstrap)
    }

    /// Clears a rejected token only when it is still current. If another REST
    /// or SSE request already recovered, the fresh token is preserved and the
    /// caller can reuse it. A nil current value is safe to clear only when no
    /// newer bootstrap is in flight; this also removes a stale persisted token
    /// before the manager has restored it in this process.
    @discardableResult
    func invalidate(ifCurrentTokenMatches rejectedToken: String) async -> Bool {
        if let current, current.sessionToken != rejectedToken {
            return false
        }
        if current == nil, inFlightBootstrap != nil {
            return false
        }
        await invalidate()
        return true
    }

    /// Operator/reset invalidation. Cancels the shared bootstrap and advances
    /// the generation before clearing persistence, so even a non-cooperative
    /// bootstrap completion cannot install its stale result afterward.
    func invalidate() async {
        generation &+= 1
        inFlightBootstrap?.cancel()
        inFlightBootstrap = nil
        current = nil
        await persistence.clear()
    }

    /// Stops an unfinished bootstrap without discarding an already valid
    /// session. Used when the app is stopped but the operator did not request
    /// a credential reset.
    func cancelPendingBootstrap() {
        guard inFlightBootstrap != nil else { return }
        generation &+= 1
        inFlightBootstrap?.cancel()
        inFlightBootstrap = nil
    }
}
