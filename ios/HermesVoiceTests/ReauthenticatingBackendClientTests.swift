import XCTest
@testable import HermesVoice

final class ReauthenticatingBackendClientTests: XCTestCase {
    func testProtected401InvalidatesBootstrapsAndRetriesExactlyOnce() async throws {
        let base = RecoveryBackend(protectedFailures: 1)
        let manager = ClientSessionManager(persistence: RecoveryPersistence())
        let client = ReauthenticatingBackendClient(
            base: base,
            sessionManager: manager,
            bootstrapCredential: { "operator-secret" }
        )

        let tasks = try await client.listTasks(sessionToken: "st_stale", status: nil)

        XCTAssertEqual(tasks, [])
        let counts = await base.counts()
        XCTAssertEqual(counts.bootstrap, 1)
        XCTAssertEqual(counts.list, 2)
        let currentToken = await manager.currentToken()
        XCTAssertEqual(currentToken, "st_fresh")
    }

    func testASecondProtected401IsReturnedWithoutAnotherRetry() async throws {
        let base = RecoveryBackend(protectedFailures: 2)
        let manager = ClientSessionManager(persistence: RecoveryPersistence())
        let client = ReauthenticatingBackendClient(
            base: base,
            sessionManager: manager,
            bootstrapCredential: { "operator-secret" }
        )

        do {
            _ = try await client.listTasks(sessionToken: "st_stale", status: nil)
            XCTFail("expected the one retry to fail")
        } catch let BackendClientError.http(status, _, _) {
            XCTAssertEqual(status, 401)
        }

        let counts = await base.counts()
        XCTAssertEqual(counts.bootstrap, 1)
        XCTAssertEqual(counts.list, 2)
    }

    func testNon401DoesNotInvalidateOrBootstrap() async throws {
        let base = RecoveryBackend(protectedFailures: 0, terminalStatus: 500)
        let manager = ClientSessionManager(persistence: RecoveryPersistence())
        let client = ReauthenticatingBackendClient(
            base: base,
            sessionManager: manager,
            bootstrapCredential: { "operator-secret" }
        )

        do {
            _ = try await client.listTasks(sessionToken: "st_current", status: nil)
            XCTFail("expected server error")
        } catch let BackendClientError.http(status, _, _) {
            XCTAssertEqual(status, 500)
        }

        let counts = await base.counts()
        XCTAssertEqual(counts.bootstrap, 0)
        XCTAssertEqual(counts.list, 1)
    }

    func testBootstrap401RemainsVisibleForCredentialPrompt() async throws {
        let base = RecoveryBackend(protectedFailures: 1, bootstrapStatus: 401)
        let manager = ClientSessionManager(persistence: RecoveryPersistence())
        let client = ReauthenticatingBackendClient(
            base: base,
            sessionManager: manager,
            bootstrapCredential: { "wrong-secret" }
        )

        do {
            _ = try await client.listTasks(sessionToken: "st_stale", status: nil)
            XCTFail("expected bootstrap rejection")
        } catch let BackendClientError.http(status, _, _) {
            XCTAssertEqual(status, 401)
        }

        let counts = await base.counts()
        XCTAssertEqual(counts.bootstrap, 1)
        XCTAssertEqual(counts.list, 1)
    }

    func testConcurrentProtected401sShareOneRecoveryMint() async throws {
        let base = RecoveryBackend(protectedFailures: 2, bootstrapDelayNanoseconds: 30_000_000)
        let manager = ClientSessionManager(persistence: RecoveryPersistence())
        let client = ReauthenticatingBackendClient(
            base: base,
            sessionManager: manager,
            bootstrapCredential: { "operator-secret" }
        )

        async let first = client.listTasks(sessionToken: "st_stale", status: nil)
        async let second = client.listTasks(sessionToken: "st_stale", status: nil)
        _ = try await (first, second)

        let counts = await base.counts()
        XCTAssertEqual(counts.bootstrap, 1)
        XCTAssertEqual(counts.list, 4)
    }
}

private actor RecoveryPersistence: ClientSessionPersisting {
    private var stored: StoredClientSession?
    func load() async -> StoredClientSession? { stored }
    func save(_ session: StoredClientSession) async { stored = session }
    func clear() async { stored = nil }
}

private actor RecoveryBackend: BackendClientProtocol {
    private var protectedFailures: Int
    private let terminalStatus: Int?
    private let bootstrapStatus: Int?
    private let bootstrapDelayNanoseconds: UInt64
    private var bootstrapCallCount = 0
    private var listCallCount = 0

    init(
        protectedFailures: Int,
        terminalStatus: Int? = nil,
        bootstrapStatus: Int? = nil,
        bootstrapDelayNanoseconds: UInt64 = 0
    ) {
        self.protectedFailures = protectedFailures
        self.terminalStatus = terminalStatus
        self.bootstrapStatus = bootstrapStatus
        self.bootstrapDelayNanoseconds = bootstrapDelayNanoseconds
    }

    func counts() -> (bootstrap: Int, list: Int) {
        (bootstrapCallCount, listCallCount)
    }

    func bootstrapSession(bootstrapCredential: String?) async throws -> MintedClientSession {
        bootstrapCallCount += 1
        if bootstrapDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: bootstrapDelayNanoseconds)
        }
        if let bootstrapStatus {
            throw BackendClientError.http(status: bootstrapStatus, code: "unauthorized", detail: nil)
        }
        return MintedClientSession(
            sessionToken: "st_fresh",
            hermesSessionId: "hs_fresh",
            expiresAt: futureISO8601()
        )
    }

    func listTasks(sessionToken: String, status: HermesTaskStatus?) async throws -> [HermesTask] {
        listCallCount += 1
        if protectedFailures > 0 {
            protectedFailures -= 1
            throw BackendClientError.http(status: 401, code: "unauthorized", detail: nil)
        }
        if let terminalStatus {
            throw BackendClientError.http(status: terminalStatus, code: "server_error", detail: nil)
        }
        guard sessionToken == "st_fresh" else {
            throw BackendClientError.http(status: 401, code: "unauthorized", detail: nil)
        }
        return []
    }

    func mintRealtimeSession(sessionToken: String, voice: String?) async throws -> RealtimeSessionResponse { fatalError("not exercised") }
    func createTask(sessionToken: String, instruction: String, context: [String: AnyCodable]?, clientRequestId: String?) async throws -> HermesTask { fatalError("not exercised") }
    func getTask(sessionToken: String, taskId: String) async throws -> HermesTask { fatalError("not exercised") }
    func followup(sessionToken: String, taskId: String, message: String) async throws -> HermesTask { fatalError("not exercised") }
    func cancel(sessionToken: String, taskId: String, reason: String?) async throws -> HermesTask { fatalError("not exercised") }
    func approve(sessionToken: String, taskId: String, approvalId: String, decision: ApprovalDecision, note: String?) async throws -> HermesTask { fatalError("not exercised") }
}

private func futureISO8601() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date().addingTimeInterval(3600))
}
