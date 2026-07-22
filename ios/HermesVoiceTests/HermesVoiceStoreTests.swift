import XCTest
@testable import HermesVoice

@MainActor
final class HermesVoiceStoreTests: XCTestCase {
    func testCleanSSEEOFRetriesWithCappedBackoffSequence() async throws {
        let persistence = StoreSessionPersistence()
        await persistence.save(validStoredSession(token: "st_existing", id: "hs_existing"))
        let manager = ClientSessionManager(persistence: persistence)
        let backend = StoreBackend()
        let source = StoreSSESource(mode: .alwaysEOF)
        let store = makeStore(
            backend: backend,
            manager: manager,
            source: source,
            reconnectDelays: [0]
        )

        store.start()
        let didRetry = await waitUntil { await source.openCount() >= 3 }
        let bootstrapCount = await backend.bootstrapCount()

        XCTAssertTrue(didRetry)
        XCTAssertFalse(store.needsBootstrapCredential)
        XCTAssertEqual(bootstrapCount, 0)
        store.stop()
    }

    func testSecondSSE401PromptsAfterExactlyOneRecoveryMint() async throws {
        let persistence = StoreSessionPersistence()
        await persistence.save(validStoredSession(token: "st_stale", id: "hs_stale"))
        let manager = ClientSessionManager(persistence: persistence)
        let backend = StoreBackend()
        let source = StoreSSESource(mode: .alwaysUnauthorized)
        let store = makeStore(backend: backend, manager: manager, source: source)

        store.start()
        let didPrompt = await waitUntil { store.needsBootstrapCredential }
        let openCount = await source.openCount()
        let bootstrapCount = await backend.bootstrapCount()
        let currentToken = await manager.currentToken()
        let authorizationHeaders = await source.authorizationHeaders()

        XCTAssertTrue(didPrompt)
        XCTAssertEqual(openCount, 2, "the second 401 must stop instead of entering a recovery loop")
        XCTAssertEqual(bootstrapCount, 1, "SSE auth recovery gets exactly one fresh client-session mint")
        XCTAssertEqual(currentToken, "st_fresh")
        XCTAssertEqual(authorizationHeaders, ["Bearer st_stale", "Bearer st_fresh"])
        store.stop()
    }

    func testResetRetiresInFlightBootstrapAndIgnoresItsLateCompletion() async throws {
        let persistence = StoreSessionPersistence()
        let manager = ClientSessionManager(persistence: persistence)
        let sequence = StoreBootstrapSequence()
        let backend = StoreBackend(bootstrapSequence: sequence)
        let source = StoreSSESource(mode: .holdOpen)
        let store = makeStore(backend: backend, manager: manager, source: source)

        store.start()
        let firstStarted = await waitUntil { await sequence.firstCallIsWaiting() }
        XCTAssertTrue(firstStarted)
        store.resetClientSession()
        let reachedFresh = await waitUntil { store.state.hermesSessionId == "hs_fresh" }
        XCTAssertTrue(reachedFresh)

        await sequence.releaseFirstWithStaleSession()
        try await Task.sleep(nanoseconds: 30_000_000)

        let currentToken = await manager.currentToken()
        let persistedToken = await persistence.load()?.sessionToken
        XCTAssertEqual(store.state.hermesSessionId, "hs_fresh")
        XCTAssertEqual(currentToken, "st_fresh")
        XCTAssertEqual(persistedToken, "st_fresh")
        store.stop()
    }

    func testRealtimeReconnect401RequestsBootstrapCredential() async throws {
        let persistence = StoreSessionPersistence()
        await persistence.save(validStoredSession(token: "st_existing", id: "hs_existing"))
        let manager = ClientSessionManager(persistence: persistence)
        let backend = StoreBackend(rejectRealtimeAfterFirstMint: true)
        let source = StoreSSESource(mode: .holdOpen)
        let transportFactory = StoreTransportFactory()
        let store = makeStore(
            backend: backend,
            manager: manager,
            source: source,
            transportFactory: transportFactory
        )

        store.start()
        let established = await waitUntil { store.state.isCallEstablished }
        XCTAssertTrue(established)
        transportFactory.first?.simulate(.disconnected)

        let didPrompt = await waitUntil { store.needsBootstrapCredential }
        let mintCount = await backend.realtimeMintCount()
        XCTAssertTrue(didPrompt, "a reconnect 401 must surface the bootstrap-credential prompt")
        XCTAssertEqual(mintCount, 2)
        store.stop()
    }

    func testResetSuppressesLateToolResultFromRetiredGeneration() async throws {
        let persistence = StoreSessionPersistence()
        await persistence.save(validStoredSession(token: "st_existing", id: "hs_existing"))
        let manager = ClientSessionManager(persistence: persistence)
        let taskSequence = StoreTaskSequence()
        let backend = StoreBackend(taskSequence: taskSequence)
        let source = StoreSSESource(mode: .holdOpen)
        let transportFactory = StoreTransportFactory()
        let store = makeStore(
            backend: backend,
            manager: manager,
            source: source,
            transportFactory: transportFactory
        )

        store.start()
        let established = await waitUntil { store.state.isCallEstablished }
        XCTAssertTrue(established)
        transportFactory.first?.simulate(
            .functionCallArgumentsDone(
                callId: "call_stale",
                name: "delegate_to_hermes",
                argumentsJSON: #"{"instruction":"do it"}"#
            )
        )
        let toolStarted = await waitUntil { await taskSequence.isWaiting() }
        XCTAssertTrue(toolStarted)

        store.resetClientSession()
        let reachedFresh = await waitUntil { store.state.hermesSessionId == "hs_fresh" }
        XCTAssertTrue(reachedFresh)
        await taskSequence.release()
        try await Task.sleep(nanoseconds: 30_000_000)

        let sentEvents = transportFactory.transports.flatMap(\.sentEvents)
        XCTAssertFalse(sentEvents.contains { event in
            if case .functionCallOutput(callId: "call_stale", outputJSON: _) = event { return true }
            return false
        })
        store.stop()
    }

    func testDelegatedTaskAppearsImmediatelyAndReconcilesWithRESTResult() async throws {
        let persistence = StoreSessionPersistence()
        await persistence.save(validStoredSession(token: "st_existing", id: "hs_existing"))
        let manager = ClientSessionManager(persistence: persistence)
        let taskSequence = StoreTaskSequence()
        let backend = StoreBackend(taskSequence: taskSequence)
        let source = StoreSSESource(mode: .holdOpen)
        let transportFactory = StoreTransportFactory()
        let store = makeStore(
            backend: backend,
            manager: manager,
            source: source,
            transportFactory: transportFactory
        )

        store.start()
        let established = await waitUntil { store.state.isCallEstablished }
        XCTAssertTrue(established)
        transportFactory.first?.simulate(
            .functionCallArgumentsDone(
                callId: "call_live",
                name: "delegate_to_hermes",
                argumentsJSON: #"{"instruction":"prepare the brief"}"#
            )
        )

        let appearedOptimistically = await waitUntil { store.state.pendingDelegations["call_live"] != nil }
        XCTAssertTrue(appearedOptimistically)
        XCTAssertTrue(store.state.tasks.isEmpty)

        await taskSequence.release(callId: "call_live", taskId: "task_live")
        let reconciled = await waitUntil { store.state.tasks["task_live"] != nil }
        XCTAssertTrue(reconciled)
        XCTAssertTrue(store.state.pendingDelegations.isEmpty)
        store.stop()
    }

    private func makeStore(
        backend: StoreBackend,
        manager: ClientSessionManager,
        source: StoreSSESource,
        transportFactory suppliedTransportFactory: StoreTransportFactory? = nil,
        reconnectDelays: [UInt64] = [0]
    ) -> HermesVoiceStore {
        let transportFactory = suppliedTransportFactory ?? StoreTransportFactory()
        let coordinator = SessionCoordinator(
            backend: backend,
            sessionToken: {
                try await manager.ensureSession {
                    try await backend.bootstrapSession(bootstrapCredential: nil)
                }.sessionToken
            },
            instructions: { "test" },
            toolDefinitions: [],
            callLifetimeSeconds: 3_600,
            makeTransport: { transportFactory.make() }
        )
        let sse = SSEClient { request, _ in await source.open(request: request) }
        return HermesVoiceStore(
            backend: backend,
            sessionManager: manager,
            bootstrapCredentialStore: BootstrapCredentialStore(),
            coordinator: coordinator,
            sseClient: sse,
            sseReconnectDelaysNanoseconds: reconnectDelays
        )
    }

    private func waitUntil(
        timeoutIterations: Int = 500,
        condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        for _ in 0..<timeoutIterations {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }
}

private func validStoredSession(token: String, id: String) -> StoredClientSession {
    StoredClientSession(sessionToken: token, hermesSessionId: id, expiresAt: Date().addingTimeInterval(3_600))
}

private actor StoreSessionPersistence: ClientSessionPersisting {
    private var stored: StoredClientSession?
    func load() async -> StoredClientSession? { stored }
    func save(_ session: StoredClientSession) async { stored = session }
    func clear() async { stored = nil }
}

private actor StoreBootstrapSequence {
    private var callCount = 0
    private var firstContinuation: CheckedContinuation<MintedClientSession, Never>?

    func mint() async -> MintedClientSession {
        callCount += 1
        if callCount == 1 {
            return await withCheckedContinuation { firstContinuation = $0 }
        }
        return mintedSession(token: "st_fresh", id: "hs_fresh")
    }

    func firstCallIsWaiting() -> Bool { firstContinuation != nil }

    func releaseFirstWithStaleSession() {
        firstContinuation?.resume(returning: mintedSession(token: "st_stale", id: "hs_stale"))
        firstContinuation = nil
    }
}

private actor StoreBackend: BackendClientProtocol {
    private let bootstrapSequence: StoreBootstrapSequence?
    private let taskSequence: StoreTaskSequence?
    private let rejectRealtimeAfterFirstMint: Bool
    private var bootstraps = 0
    private var realtimeMints = 0

    init(
        bootstrapSequence: StoreBootstrapSequence? = nil,
        taskSequence: StoreTaskSequence? = nil,
        rejectRealtimeAfterFirstMint: Bool = false
    ) {
        self.bootstrapSequence = bootstrapSequence
        self.taskSequence = taskSequence
        self.rejectRealtimeAfterFirstMint = rejectRealtimeAfterFirstMint
    }

    func bootstrapCount() -> Int { bootstraps }
    func realtimeMintCount() -> Int { realtimeMints }

    func bootstrapSession(bootstrapCredential: String?) async throws -> MintedClientSession {
        bootstraps += 1
        if let bootstrapSequence { return await bootstrapSequence.mint() }
        return mintedSession(token: "st_fresh", id: "hs_fresh")
    }

    func mintRealtimeSession(sessionToken: String, voice: String?) async throws -> RealtimeSessionResponse {
        realtimeMints += 1
        if rejectRealtimeAfterFirstMint, realtimeMints > 1 {
            throw BackendClientError.http(status: 401, code: "unauthorized", detail: nil)
        }
        return RealtimeSessionResponse(
            sessionId: "rs_test",
            model: "gpt-realtime-test",
            clientSecret: RealtimeClientSecret(value: "ek_test", expiresAt: futureStoreISO8601()),
            createdAt: futureStoreISO8601(),
            expiresInSeconds: 60
        )
    }

    func listTasks(sessionToken: String, status: HermesTaskStatus?) async throws -> [HermesTask] { [] }
    func createTask(sessionToken: String, instruction: String, context: [String: AnyCodable]?, clientRequestId: String?) async throws -> HermesTask {
        guard let taskSequence else { fatalError("not exercised") }
        return await taskSequence.waitForRelease()
    }
    func getTask(sessionToken: String, taskId: String) async throws -> HermesTask { fatalError("not exercised") }
    func followup(sessionToken: String, taskId: String, message: String) async throws -> HermesTask { fatalError("not exercised") }
    func cancel(sessionToken: String, taskId: String, reason: String?) async throws -> HermesTask { fatalError("not exercised") }
    func approve(sessionToken: String, taskId: String, approvalId: String, decision: ApprovalDecision, note: String?) async throws -> HermesTask { fatalError("not exercised") }
}

private func mintedSession(token: String, id: String) -> MintedClientSession {
    MintedClientSession(sessionToken: token, hermesSessionId: id, expiresAt: futureStoreISO8601())
}

private func futureStoreISO8601() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date().addingTimeInterval(3_600))
}

private actor StoreSSESource {
    enum Mode: Sendable { case alwaysEOF, alwaysUnauthorized, holdOpen }

    private let mode: Mode
    private var opens = 0
    private var headers: [String] = []
    private var heldContinuations: [AsyncThrowingStream<String, Error>.Continuation] = []

    init(mode: Mode) { self.mode = mode }

    func open(request: URLRequest) -> SSEStreamResponse {
        opens += 1
        headers.append(request.value(forHTTPHeaderField: "authorization") ?? "")
        switch mode {
        case .alwaysEOF:
            return SSEStreamResponse(statusCode: 200, lines: AsyncThrowingStream { $0.finish() })
        case .alwaysUnauthorized:
            return SSEStreamResponse(statusCode: 401, lines: AsyncThrowingStream { $0.finish() })
        case .holdOpen:
            let stream = AsyncThrowingStream<String, Error> { continuation in
                heldContinuations.append(continuation)
            }
            return SSEStreamResponse(statusCode: 200, lines: stream)
        }
    }

    func openCount() -> Int { opens }
    func authorizationHeaders() -> [String] { headers }
}

private actor StoreTaskSequence {
    private var continuation: CheckedContinuation<HermesTask, Never>?

    func waitForRelease() async -> HermesTask {
        await withCheckedContinuation { continuation = $0 }
    }

    func isWaiting() -> Bool { continuation != nil }

    func release(callId: String = "call_stale", taskId: String = "task_stale") {
        continuation?.resume(returning: HermesTask(
            id: taskId,
            hermesSessionId: "hs_existing",
            status: .queued,
            instruction: "do it",
            clientRequestId: callId,
            summary: nil,
            progress: nil,
            result: nil,
            error: nil,
            pendingApproval: nil,
            createdAt: futureStoreISO8601(),
            updatedAt: futureStoreISO8601(),
            history: []
        ))
        continuation = nil
    }
}

@MainActor
private final class StoreRealtimeTransport: RealtimeTransport, @unchecked Sendable {
    var onServerEvent: ((RealtimeServerEvent) -> Void)?
    var onConnectionStateChange: ((TransportConnectionState) -> Void)?
    private(set) var sentEvents: [RealtimeClientEvent] = []
    private(set) var microphoneEnabledValues: [Bool] = []

    func connect(with credential: RealtimeCredential) async throws {
        onServerEvent?(.sessionCreated(sessionId: credential.sessionId))
    }

    func send(_ event: RealtimeClientEvent) throws {
        sentEvents.append(event)
        if case .sessionUpdate = event { onServerEvent?(.sessionUpdated) }
    }

    func setMicrophoneEnabled(_ enabled: Bool) {
        microphoneEnabledValues.append(enabled)
    }

    func disconnect() async {}

    func simulate(_ state: TransportConnectionState) {
        onConnectionStateChange?(state)
    }

    func simulate(_ event: RealtimeServerEvent) {
        onServerEvent?(event)
    }
}

@MainActor
private final class StoreTransportFactory {
    private(set) var transports: [StoreRealtimeTransport] = []
    var first: StoreRealtimeTransport? { transports.first }

    func make() -> RealtimeTransport {
        let transport = StoreRealtimeTransport()
        transports.append(transport)
        return transport
    }
}
