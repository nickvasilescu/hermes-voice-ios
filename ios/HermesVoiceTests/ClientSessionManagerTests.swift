import XCTest
@testable import HermesVoice

/// See SessionReducerTests.swift for the note on why these are written but
/// not run in this repo's environment. Uses an in-memory
/// `ClientSessionPersisting` double instead of the real Keychain, which
/// isn't reliably usable from a plain logic-test bundle.
final class ClientSessionManagerTests: XCTestCase {
    func testEnsureSessionBootstrapsOnceAndReusesTheResult() async throws {
        let persistence = InMemorySessionPersistence()
        let manager = ClientSessionManager(persistence: persistence)
        var bootstrapCallCount = 0

        let bootstrap: @Sendable () async throws -> MintedClientSession = {
            bootstrapCallCount += 1
            return MintedClientSession(sessionToken: "st_1", hermesSessionId: "hs_1", expiresAt: farFutureISO8601())
        }

        let first = try await manager.ensureSession(bootstrap: bootstrap)
        let second = try await manager.ensureSession(bootstrap: bootstrap)

        XCTAssertEqual(first.sessionToken, "st_1")
        XCTAssertEqual(second.sessionToken, "st_1")
        XCTAssertEqual(bootstrapCallCount, 1, "a still-valid session must not trigger a second bootstrap call")
    }

    func testEnsureSessionPersistsToTheStore() async throws {
        let persistence = InMemorySessionPersistence()
        let manager = ClientSessionManager(persistence: persistence)

        _ = try await manager.ensureSession {
            MintedClientSession(sessionToken: "st_1", hermesSessionId: "hs_1", expiresAt: farFutureISO8601())
        }

        let stored = await persistence.load()
        XCTAssertEqual(stored?.sessionToken, "st_1")
    }

    func testEnsureSessionRestoresFromPersistenceAcrossManagerInstances() async throws {
        let persistence = InMemorySessionPersistence()
        let first = ClientSessionManager(persistence: persistence)
        _ = try await first.ensureSession {
            MintedClientSession(sessionToken: "st_1", hermesSessionId: "hs_1", expiresAt: farFutureISO8601())
        }

        // Simulates a fresh app launch: a new manager, same underlying store.
        let second = ClientSessionManager(persistence: persistence)
        var bootstrapCalled = false
        let restored = try await second.ensureSession {
            bootstrapCalled = true
            return MintedClientSession(sessionToken: "st_should_not_be_used", hermesSessionId: "hs_should_not_be_used", expiresAt: farFutureISO8601())
        }

        XCTAssertEqual(restored.sessionToken, "st_1")
        XCTAssertFalse(bootstrapCalled, "a still-valid persisted session must be reused instead of re-bootstrapping")
    }

    func testEnsureSessionReBootstrapsAnExpiredPersistedSession() async throws {
        let persistence = InMemorySessionPersistence()
        await persistence.save(StoredClientSession(sessionToken: "st_expired", hermesSessionId: "hs_old", expiresAt: Date(timeIntervalSince1970: 0)))
        let manager = ClientSessionManager(persistence: persistence)

        let fresh = try await manager.ensureSession {
            MintedClientSession(sessionToken: "st_fresh", hermesSessionId: "hs_new", expiresAt: farFutureISO8601())
        }

        XCTAssertEqual(fresh.sessionToken, "st_fresh")
    }

    func testConcurrentEnsureSessionCallsShareOneInFlightBootstrap() async throws {
        let persistence = InMemorySessionPersistence()
        let manager = ClientSessionManager(persistence: persistence)
        let counter = CallCounter()

        async let a: StoredClientSession = manager.ensureSession {
            await counter.increment()
            try? await Task.sleep(nanoseconds: 20_000_000)
            return MintedClientSession(sessionToken: "st_race", hermesSessionId: "hs_race", expiresAt: farFutureISO8601())
        }
        async let b: StoredClientSession = manager.ensureSession {
            await counter.increment()
            try? await Task.sleep(nanoseconds: 20_000_000)
            return MintedClientSession(sessionToken: "st_race", hermesSessionId: "hs_race", expiresAt: farFutureISO8601())
        }

        let (resultA, resultB) = try await (a, b)
        XCTAssertEqual(resultA.sessionToken, "st_race")
        XCTAssertEqual(resultB.sessionToken, "st_race")
        let count = await counter.value
        XCTAssertEqual(count, 1, "two concurrent callers before any session exists should share a single bootstrap")
    }

    func testInvalidateClearsBothMemoryAndPersistence() async throws {
        let persistence = InMemorySessionPersistence()
        let manager = ClientSessionManager(persistence: persistence)
        _ = try await manager.ensureSession {
            MintedClientSession(sessionToken: "st_1", hermesSessionId: "hs_1", expiresAt: farFutureISO8601())
        }

        await manager.invalidate()

        let token = await manager.currentToken()
        let stored = await persistence.load()
        XCTAssertNil(token)
        XCTAssertNil(stored)
    }
}

private func farFutureISO8601() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date().addingTimeInterval(3600))
}

private actor CallCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor InMemorySessionPersistence: ClientSessionPersisting {
    private var stored: StoredClientSession?
    func load() async -> StoredClientSession? { stored }
    func save(_ session: StoredClientSession) async { stored = session }
    func clear() async { stored = nil }
}
