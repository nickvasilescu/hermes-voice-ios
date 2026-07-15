import XCTest
@testable import HermesVoice

/// Exercises `SessionCoordinator` against a fake `RealtimeTransport` so
/// these run with no network and no real WebRTC engine.
@MainActor
final class SessionCoordinatorTests: XCTestCase {
    func testStartEstablishesACallAndForwardsPostHandshakeEvents() async throws {
        let factory = FakeTransportFactory()
        let coordinator = makeCoordinator(factory: factory)

        var established = false
        coordinator.onCallEstablished = { established = true }
        var receivedEvents: [RealtimeServerEvent] = []
        coordinator.onServerEvent = { receivedEvents.append($0) }

        let result = await coordinator.start(voice: nil)
        guard case .success = result else { return XCTFail("expected success, got \(result)") }
        XCTAssertTrue(established)

        let transport = try XCTUnwrap(factory.transports.first)
        XCTAssertEqual(transport.connectCallCount, 1)
        // session.update must have been sent during the handshake.
        XCTAssertTrue(transport.sentEvents.contains { if case .sessionUpdate = $0 { return true }; return false })

        // Post-handshake wire events are forwarded to the store.
        transport.simulate(.responseAudioTranscriptDelta(text: "hello"))
        XCTAssertEqual(receivedEvents, [.responseAudioTranscriptDelta(text: "hello")])
    }

    func testFailedHandshakeReturnsFailureAndFiresNoEstablishedCallback() async throws {
        let factory = FakeTransportFactory()
        factory.nextShouldFailHandshake = true
        let coordinator = makeCoordinator(factory: factory)

        var established = false
        coordinator.onCallEstablished = { established = true }

        let result = await coordinator.start(voice: nil)
        guard case .failure = result else { return XCTFail("expected failure") }
        XCTAssertFalse(established)
    }

    func testRotateSwapsPrimaryAndDisconnectsTheOldTransportOnly() async throws {
        let factory = FakeTransportFactory()
        let coordinator = makeCoordinator(factory: factory)
        _ = await coordinator.start(voice: nil)
        let original = try XCTUnwrap(factory.transports.first)

        var establishedCount = 0
        coordinator.onCallEstablished = { establishedCount += 1 }
        var receivedEvents: [RealtimeServerEvent] = []
        coordinator.onServerEvent = { receivedEvents.append($0) }

        await coordinator.rotate(voice: nil)

        XCTAssertEqual(factory.transports.count, 2, "rotation should have created exactly one candidate transport")
        let candidate = factory.transports[1]

        XCTAssertTrue(original.didDisconnect, "the retired primary must be disconnected after a successful swap")
        XCTAssertFalse(candidate.didDisconnect)
        XCTAssertEqual(establishedCount, 1, "rotate's own onCallEstablished fire is separate from start's; only counting rotate's here")

        // Events from the OLD (retired) transport must be ignored post-swap —
        // this is the generation-stale-callback guard.
        original.simulate(.responseAudioTranscriptDelta(text: "should be ignored"))
        XCTAssertTrue(receivedEvents.isEmpty)

        // Events from the NEW primary must be delivered.
        candidate.simulate(.responseAudioTranscriptDelta(text: "should arrive"))
        XCTAssertEqual(receivedEvents, [.responseAudioTranscriptDelta(text: "should arrive")])
    }

    func testFailedRotationLeavesTheExistingPrimaryLiveAndUndisturbed() async throws {
        let factory = FakeTransportFactory()
        let coordinator = makeCoordinator(factory: factory)
        _ = await coordinator.start(voice: nil)
        let original = try XCTUnwrap(factory.transports.first)

        factory.nextShouldFailHandshake = true
        var receivedEvents: [RealtimeServerEvent] = []
        coordinator.onServerEvent = { receivedEvents.append($0) }

        await coordinator.rotate(voice: nil)

        XCTAssertFalse(original.didDisconnect, "a failed rotation must not tear down the still-working primary")
        original.simulate(.responseAudioTranscriptDelta(text: "still primary"))
        XCTAssertEqual(receivedEvents, [.responseAudioTranscriptDelta(text: "still primary")])
    }

    func testRotateBeforeAnyStartIsASafeNoOp() async throws {
        // There is nothing to rotate before a call has ever been
        // established — this must not create a transport or crash.
        let factory = FakeTransportFactory()
        let coordinator = makeCoordinator(factory: factory)

        await coordinator.rotate(voice: nil)

        XCTAssertEqual(factory.transports.count, 0)
    }

    func testRotationBootstrap401PromptsWithoutDroppingTheCurrentCall() async throws {
        let factory = FakeTransportFactory()
        let backend = RotationUnauthorizedBackend()
        let coordinator = SessionCoordinator(
            backend: backend,
            sessionToken: { "st_test" },
            instructions: { "test instructions" },
            toolDefinitions: [],
            callLifetimeSeconds: 3600,
            makeTransport: { factory.makeTransport() }
        )
        let startResult = await coordinator.start(voice: nil)
        guard case .success = startResult else { return XCTFail("expected initial connection") }
        let original = try XCTUnwrap(factory.transports.first)

        var prompted = false
        coordinator.onBootstrapCredentialRequired = { prompted = true }
        await coordinator.rotate(voice: nil)

        XCTAssertTrue(prompted)
        XCTAssertFalse(original.didDisconnect, "an auth failure during rotation must leave the live call untouched")
        XCTAssertEqual(factory.transports.count, 1, "the credential failed before a replacement transport was created")
    }

    func testStartThenRotateGoThroughTheSameSerializedPathAndCreateExactlyOneTransportEach() async throws {
        // Regression test for the "actually track rotatingTransport" /
        // serialization bug: start and rotate share one AsyncMutex, so a
        // rotate issued only after start completes must see exactly the
        // primary start left behind, never a stray extra attempt.
        let factory = FakeTransportFactory()
        let coordinator = makeCoordinator(factory: factory)

        let startResult = await coordinator.start(voice: nil)
        guard case .success = startResult else { return XCTFail("expected start to succeed") }
        await coordinator.rotate(voice: nil)

        XCTAssertEqual(factory.transports.count, 2, "one transport from start, one from rotate — never a stray third")
    }
}

@MainActor
private func makeCoordinator(factory: FakeTransportFactory) -> SessionCoordinator {
    SessionCoordinator(
        backend: NeverCalledBackend(),
        sessionToken: { "st_test" },
        instructions: { "test instructions" },
        toolDefinitions: [],
        callLifetimeSeconds: 3600, // long enough that the timer never fires during a test
        makeTransport: { factory.makeTransport() }
    )
}

// MARK: - Test doubles

private actor NeverCalledBackend: BackendClientProtocol {
    func bootstrapSession(bootstrapCredential: String?) async throws -> MintedClientSession {
        MintedClientSession(sessionToken: "st_test", hermesSessionId: "hs_test", expiresAt: "2026-01-01T00:00:00.000Z")
    }
    func mintRealtimeSession(sessionToken: String, voice: String?) async throws -> RealtimeSessionResponse {
        RealtimeSessionResponse(
            sessionId: "sess_fake",
            model: "gpt-realtime-2.1",
            clientSecret: RealtimeClientSecret(value: "ek_fake", expiresAt: "2026-01-01T00:00:00.000Z"),
            createdAt: "2026-01-01T00:00:00.000Z",
            expiresInSeconds: 60
        )
    }
    func createTask(sessionToken: String, instruction: String, context: [String: AnyCodable]?, clientRequestId: String?) async throws -> HermesTask {
        fatalError("not exercised in SessionCoordinatorTests")
    }
    func getTask(sessionToken: String, taskId: String) async throws -> HermesTask { fatalError("not exercised") }
    func listTasks(sessionToken: String, status: HermesTaskStatus?) async throws -> [HermesTask] { fatalError("not exercised") }
    func followup(sessionToken: String, taskId: String, message: String) async throws -> HermesTask { fatalError("not exercised") }
    func cancel(sessionToken: String, taskId: String, reason: String?) async throws -> HermesTask { fatalError("not exercised") }
    func approve(sessionToken: String, taskId: String, approvalId: String, decision: ApprovalDecision, note: String?) async throws -> HermesTask { fatalError("not exercised") }
}

private actor RotationUnauthorizedBackend: BackendClientProtocol {
    private var mintCount = 0

    func bootstrapSession(bootstrapCredential: String?) async throws -> MintedClientSession {
        fatalError("not exercised")
    }

    func mintRealtimeSession(sessionToken: String, voice: String?) async throws -> RealtimeSessionResponse {
        mintCount += 1
        if mintCount > 1 {
            throw BackendClientError.http(status: 401, code: "unauthorized", detail: nil)
        }
        return RealtimeSessionResponse(
            sessionId: "sess_initial",
            model: "gpt-realtime-2.1",
            clientSecret: RealtimeClientSecret(value: "ek_initial", expiresAt: "2026-01-01T00:00:00.000Z"),
            createdAt: "2026-01-01T00:00:00.000Z",
            expiresInSeconds: 60
        )
    }

    func createTask(sessionToken: String, instruction: String, context: [String: AnyCodable]?, clientRequestId: String?) async throws -> HermesTask { fatalError("not exercised") }
    func getTask(sessionToken: String, taskId: String) async throws -> HermesTask { fatalError("not exercised") }
    func listTasks(sessionToken: String, status: HermesTaskStatus?) async throws -> [HermesTask] { fatalError("not exercised") }
    func followup(sessionToken: String, taskId: String, message: String) async throws -> HermesTask { fatalError("not exercised") }
    func cancel(sessionToken: String, taskId: String, reason: String?) async throws -> HermesTask { fatalError("not exercised") }
    func approve(sessionToken: String, taskId: String, approvalId: String, decision: ApprovalDecision, note: String?) async throws -> HermesTask { fatalError("not exercised") }
}

@MainActor
private final class FakeTransportFactory {
    private(set) var transports: [FakeRealtimeTransport] = []
    var nextShouldFailHandshake = false

    func makeTransport() -> RealtimeTransport {
        let transport = FakeRealtimeTransport(shouldFailHandshake: nextShouldFailHandshake)
        nextShouldFailHandshake = false
        transports.append(transport)
        return transport
    }
}

/// Auto-completes the session.created → session.update → session.updated
/// handshake synchronously within `connect`/`send`, so tests don't need
/// real network timing.
@MainActor
private final class FakeRealtimeTransport: RealtimeTransport, @unchecked Sendable {
    var onServerEvent: ((RealtimeServerEvent) -> Void)?
    var onConnectionStateChange: ((TransportConnectionState) -> Void)?

    private(set) var connectCallCount = 0
    private(set) var sentEvents: [RealtimeClientEvent] = []
    private(set) var didDisconnect = false
    private let shouldFailHandshake: Bool

    init(shouldFailHandshake: Bool) {
        self.shouldFailHandshake = shouldFailHandshake
    }

    func connect(with credential: RealtimeCredential) async throws {
        connectCallCount += 1
        if shouldFailHandshake {
            onConnectionStateChange?(.failed("simulated handshake failure"))
            return
        }
        onServerEvent?(.sessionCreated(sessionId: "sess_fake"))
    }

    func send(_ event: RealtimeClientEvent) throws {
        sentEvents.append(event)
        if case .sessionUpdate = event, !shouldFailHandshake {
            onServerEvent?(.sessionUpdated)
        }
    }

    func disconnect() async {
        didDisconnect = true
    }

    /// Test hook: simulate a post-handshake server event arriving.
    func simulate(_ event: RealtimeServerEvent) {
        onServerEvent?(event)
    }
}
