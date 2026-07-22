import Foundation

/// Wraps the concrete bridge client with the client-session recovery policy.
///
/// A bridge restart intentionally forgets its in-memory session-token hashes,
/// while the iPhone can still hold the old token in Keychain. Every protected
/// request therefore gets exactly one recovery attempt after a `401`:
///
/// 1. invalidate the cached client session;
/// 2. mint a fresh session with the operator's Keychain bootstrap credential;
/// 3. retry the original request once with the fresh token.
///
/// A second `401` is returned to the caller. There is no retry loop, and a
/// bootstrap `401` remains visible so the UI can ask for a corrected bootstrap
/// credential. [IMPLEMENTED]
actor ReauthenticatingBackendClient: BackendClientProtocol {
    private let base: BackendClientProtocol
    private let sessionManager: ClientSessionManager
    private let bootstrapCredential: @Sendable () async -> String?
    private var inFlightRecovery: Task<StoredClientSession, Error>?

    init(
        base: BackendClientProtocol,
        sessionManager: ClientSessionManager,
        bootstrapCredential: @escaping @Sendable () async -> String?
    ) {
        self.base = base
        self.sessionManager = sessionManager
        self.bootstrapCredential = bootstrapCredential
    }

    func bootstrapSession(bootstrapCredential: String?) async throws -> MintedClientSession {
        try await base.bootstrapSession(bootstrapCredential: bootstrapCredential)
    }

    func mintRealtimeSession(sessionToken: String, voice: String?) async throws -> RealtimeSessionResponse {
        try await withOneUnauthorizedRecovery(initialToken: sessionToken) { token in
            try await self.base.mintRealtimeSession(sessionToken: token, voice: voice)
        }
    }

    func createTask(sessionToken: String, instruction: String, context: [String: AnyCodable]?, clientRequestId: String?) async throws -> HermesTask {
        try await withOneUnauthorizedRecovery(initialToken: sessionToken) { token in
            try await self.base.createTask(
                sessionToken: token,
                instruction: instruction,
                context: context,
                clientRequestId: clientRequestId
            )
        }
    }

    func getTask(sessionToken: String, taskId: String) async throws -> HermesTask {
        try await withOneUnauthorizedRecovery(initialToken: sessionToken) { token in
            try await self.base.getTask(sessionToken: token, taskId: taskId)
        }
    }

    func listTasks(sessionToken: String, status: HermesTaskStatus?) async throws -> [HermesTask] {
        try await withOneUnauthorizedRecovery(initialToken: sessionToken) { token in
            try await self.base.listTasks(sessionToken: token, status: status)
        }
    }

    func followup(sessionToken: String, taskId: String, message: String) async throws -> HermesTask {
        try await withOneUnauthorizedRecovery(initialToken: sessionToken) { token in
            try await self.base.followup(sessionToken: token, taskId: taskId, message: message)
        }
    }

    func cancel(sessionToken: String, taskId: String, reason: String?) async throws -> HermesTask {
        try await withOneUnauthorizedRecovery(initialToken: sessionToken) { token in
            try await self.base.cancel(sessionToken: token, taskId: taskId, reason: reason)
        }
    }

    func approve(sessionToken: String, taskId: String, approvalId: String, decision: ApprovalDecision, note: String?) async throws -> HermesTask {
        try await withOneUnauthorizedRecovery(initialToken: sessionToken) { token in
            try await self.base.approve(
                sessionToken: token,
                taskId: taskId,
                approvalId: approvalId,
                decision: decision,
                note: note
            )
        }
    }

    private func withOneUnauthorizedRecovery<T>(
        initialToken: String,
        operation: @escaping (String) async throws -> T
    ) async throws -> T {
        do {
            return try await operation(initialToken)
        } catch {
            guard Self.isUnauthorized(error) else { throw error }
            let freshToken = try await recoverSession(rejectedToken: initialToken)
            // Deliberately no catch/retry here: this is the one retry.
            return try await operation(freshToken)
        }
    }

    private func recoverSession(rejectedToken: String) async throws -> String {
        // Another request may already have recovered while this request was
        // waiting for its 401 response. Reuse that newer token instead of
        // invalidating it and minting a second client session.
        let snapshot = await sessionManager.recoverySnapshot()
        if let current = snapshot.current, current.sessionToken != rejectedToken {
            return current.sessionToken
        }
        if let inFlightRecovery {
            return try await inFlightRecovery.value.sessionToken
        }

        let base = self.base
        let manager = sessionManager
        let credential = bootstrapCredential
        let observedGeneration = snapshot.generation
        let task = Task<StoredClientSession, Error> {
            guard await manager.sessionGeneration() == observedGeneration else {
                if let current = await manager.currentSession(), current.sessionToken != rejectedToken {
                    return current
                }
                throw CancellationError()
            }
            // This is atomic inside ClientSessionManager. If another REST or
            // SSE path already replaced `rejectedToken`, its fresh session is
            // deliberately left intact and `ensureSession` reuses it.
            let didInvalidate = await manager.invalidate(ifCurrentTokenMatches: rejectedToken)
            if !didInvalidate,
               let current = await manager.currentSession(),
               current.sessionToken != rejectedToken {
                return current
            }
            let recoveryGeneration = await manager.sessionGeneration()
            let expectedRecoveryGeneration = observedGeneration &+ (didInvalidate ? 1 : 0)
            guard recoveryGeneration == expectedRecoveryGeneration else {
                if let current = await manager.currentSession(), current.sessionToken != rejectedToken {
                    return current
                }
                throw CancellationError()
            }
            return try await manager.ensureSession(expectedGeneration: recoveryGeneration) {
                try await base.bootstrapSession(bootstrapCredential: await credential())
            }
        }
        inFlightRecovery = task
        defer { inFlightRecovery = nil }
        return try await task.value.sessionToken
    }

    private static func isUnauthorized(_ error: Error) -> Bool {
        guard case BackendClientError.http(status: 401, code: _, detail: _) = error else {
            return false
        }
        return true
    }
}
