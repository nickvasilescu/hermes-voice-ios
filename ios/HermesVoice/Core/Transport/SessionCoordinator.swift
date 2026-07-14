import Foundation

/// Owns the whole lifecycle of "a live Realtime call": minting a
/// credential, connecting a transport, completing the `session.created` →
/// `session.update` → `session.updated` handshake, make-before-break
/// rotation before OpenAI's ~60-minute session cap, and reconnect-with-
/// backoff on unexpected disconnects. [IMPLEMENTED]
///
/// This is intentionally an imperative shell around `RealtimeTransport`,
/// not modeled inside `SessionReducer` — see that file's doc comment for
/// why. `HermesVoiceStore` only ever hears about two things from here:
/// `onServerEvent` (post-handshake wire events worth reacting to — audio,
/// tool calls, errors) and `onDisconnected` (the active call dropped and
/// needs the reducer's reconnect-backoff effect). Routine successful
/// rotation is invisible to the store on purpose: the call keeps running
/// throughout, so there is nothing for the conversation state machine to
/// react to.
///
/// Correctness properties, each of which was a real bug in an earlier
/// version of this file:
/// - **Serialized**: `start`, `rotate`, and reconnect all run inside
///   `AsyncMutex`, so two can never interleave and race to set
///   `primaryTransport`.
/// - **Generation-tagged callbacks**: every transport is stamped with a
///   monotonic generation at creation. Its callbacks close over that
///   generation and are dropped by `deliver`/`handleConnectionStateChange`
///   once `currentGeneration` has moved past it — a retired transport's
///   late callback can never be mistaken for the current one's.
/// - **Candidate readiness gate**: rotation only swaps in the candidate
///   transport after ITS OWN `session.created` → `session.update` →
///   `session.updated` handshake completes (`handshake(_:generation:
///   credential:)`, shared with `start`) — not merely after the SDP
///   exchange returns. `session.update` is always sent to the transport
///   being handshaked, so during rotation it correctly goes to the
///   candidate, never the still-live primary.
/// - **`rotatingTransport` is actually tracked**: assigned the moment the
///   candidate is created (before its handshake even starts), so
///   `teardown()` can find and disconnect an in-flight candidate rather
///   than leaking it.
/// - **Call lifetime ≠ credential expiry**: `RealtimeCredential.
///   connectDeadline` (from the ephemeral client secret) only bounds how
///   long connecting may take. Rotation is scheduled from
///   `callLifetimeSeconds` after the call actually became established
///   (`callEstablishedAt`), independent of credential expiry.
/// `@unchecked Sendable`: `@MainActor`-isolated, so every stored property
/// here is only ever touched while confined to the main actor. That
/// isolation is the proof — the same justification as
/// `WebRTCRealtimeTransport`. Needed so `self` can be captured by the
/// `@Sendable` closures `Task`/`TaskGroup` APIs require (see
/// `withTimeout`), even though those closures never actually leave the
/// main actor in practice.
@MainActor
final class SessionCoordinator: @unchecked Sendable {
    /// Default well under OpenAI's ~60-minute Realtime session cap —
    /// rotate the established call itself on this cadence. This is
    /// unrelated to (and shorter than) any single ephemeral credential's
    /// own expiry, which only matters for how long *connecting* may take.
    /// `nonisolated` so it can be used as a default argument (defaults are
    /// evaluated in a nonisolated context).
    nonisolated static let defaultCallLifetimeSeconds: TimeInterval = 55 * 60
    private static let handshakeTimeoutSeconds: TimeInterval = 15
    private static let rotationRetryDelaySeconds: TimeInterval = 30

    /// Failure type for `start` / reconnect — `Result`'s `Failure` must be
    /// `Error`, so a bare `String` is illegal.
    struct ConnectError: Error, Equatable, CustomStringConvertible {
        let message: String
        var description: String { message }
        init(_ message: String) { self.message = message }
    }

    private let backend: BackendClientProtocol
    private let sessionToken: @Sendable () async throws -> String
    private let makeTransport: @MainActor () -> RealtimeTransport
    private let instructions: String
    private let toolDefinitions: [RealtimeToolDefinition]
    private let callLifetimeSeconds: TimeInterval

    private let mutex = AsyncMutex()
    private var generationCounter = 0
    private var currentGeneration = -1
    private var primaryTransport: RealtimeTransport?
    private var rotatingTransport: RealtimeTransport?
    private var rotatingGeneration: Int?
    private var callEstablishedAt: Date?
    private var rotationTimer: Timer?
    private var reconnectTask: Task<Void, Never>?

    var onServerEvent: ((RealtimeServerEvent) -> Void)?
    var onCallEstablished: (() -> Void)?
    var onDisconnected: ((String?) -> Void)?

    init(
        backend: BackendClientProtocol,
        sessionToken: @escaping @Sendable () async throws -> String,
        instructions: String,
        toolDefinitions: [RealtimeToolDefinition],
        callLifetimeSeconds: TimeInterval = SessionCoordinator.defaultCallLifetimeSeconds,
        makeTransport: @escaping @MainActor () -> RealtimeTransport
    ) {
        self.backend = backend
        self.sessionToken = sessionToken
        self.instructions = instructions
        self.toolDefinitions = toolDefinitions
        self.callLifetimeSeconds = callLifetimeSeconds
        self.makeTransport = makeTransport
    }

    /// Establishes the first call. Safe to call more than once — later
    /// calls replace whatever (possibly dead) transport is current. Callers
    /// that want true no-op idempotency on top of this belong at the
    /// `HermesVoiceStore` layer (see its `start()`), which already knows
    /// whether it has ever called this.
    func start(voice: String?) async -> Result<Void, ConnectError> {
        await mutex.withLock { await self.connectNewPrimary(voice: voice) }
    }

    func send(_ event: RealtimeClientEvent) {
        try? primaryTransport?.send(event)
    }

    func scheduleReconnect(after delay: TimeInterval, voice: String?, onReconnected: @escaping (Result<Void, ConnectError>) -> Void) {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            let result = await self.mutex.withLock { await self.connectNewPrimary(voice: voice) }
            onReconnected(result)
        }
    }

    func teardown() async {
        rotationTimer?.invalidate()
        rotationTimer = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        await mutex.withLock {
            currentGeneration = -1
            let primary = self.primaryTransport
            let rotating = self.rotatingTransport
            self.primaryTransport = nil
            self.rotatingTransport = nil
            self.rotatingGeneration = nil
            self.callEstablishedAt = nil
            await primary?.disconnect()
            await rotating?.disconnect()
        }
    }

    // MARK: - Establishing a call (shared by first start and reconnect)

    private func connectNewPrimary(voice: String?) async -> Result<Void, ConnectError> {
        do {
            let credential = try await mintCredential(voice: voice)
            let generation = nextGeneration()
            let stale = primaryTransport
            let transport = try await establishAndHandshake(credential: credential, generation: generation) { _ in }
            currentGeneration = generation
            primaryTransport = transport
            callEstablishedAt = Date()
            if let stale { await stale.disconnect() }
            scheduleNextRotation()
            onCallEstablished?()
            return .success(())
        } catch {
            return .failure(ConnectError(String(describing: error)))
        }
    }

    // MARK: - Rotation

    /// Not `private`: exercised directly by SessionCoordinatorTests (there is no
    /// other seam to trigger a rotation deterministically in a test without
    /// waiting out a real `callLifetimeSeconds` timer).
    func rotate(voice: String?) async {
        await mutex.withLock { [self] in
            guard primaryTransport != nil else { return }
            do {
                let credential = try await mintCredential(voice: voice)
                let candidateGeneration = nextGeneration()
                let candidate = try await establishAndHandshake(credential: credential, generation: candidateGeneration) { transport in
                    self.rotatingTransport = transport
                    self.rotatingGeneration = candidateGeneration
                }

                let old = primaryTransport
                currentGeneration = candidateGeneration
                primaryTransport = candidate
                rotatingTransport = nil
                rotatingGeneration = nil
                callEstablishedAt = Date()
                scheduleNextRotation()
                await old?.disconnect()
                onCallEstablished?()
            } catch {
                // The old primary is untouched and still live — a failed
                // rotation attempt does not tear down a working call.
                if let rotating = rotatingTransport {
                    await rotating.disconnect()
                }
                rotatingTransport = nil
                rotatingGeneration = nil
                scheduleRotationRetry(voice: voice)
            }
        }
    }

    private func scheduleNextRotation() {
        rotationTimer?.invalidate()
        rotationTimer = Timer.scheduledTimer(withTimeInterval: callLifetimeSeconds, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.rotate(voice: nil) }
        }
    }

    private func scheduleRotationRetry(voice: String?) {
        rotationTimer?.invalidate()
        rotationTimer = Timer.scheduledTimer(withTimeInterval: Self.rotationRetryDelaySeconds, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.rotate(voice: voice) }
        }
    }

    // MARK: - Handshake (session.created → session.update → session.updated)

    private func mintCredential(voice: String?) async throws -> RealtimeCredential {
        let token = try await sessionToken()
        let response = try await backend.mintRealtimeSession(sessionToken: token, voice: voice)
        return RealtimeCredential(
            sessionId: response.sessionId,
            clientSecret: response.clientSecret.value,
            model: response.model,
            connectDeadline: Date().addingTimeInterval(TimeInterval(response.expiresInSeconds))
        )
    }

    private func nextGeneration() -> Int {
        generationCounter += 1
        return generationCounter
    }

    /// Creates a transport, hands it to `track` immediately (so a caller
    /// can record it — e.g. as `rotatingTransport` — before the handshake
    /// even starts), connects it, and blocks until `session.updated` is
    /// received on THAT transport. Once the handshake completes, the
    /// transport's callbacks are switched to generation-gated forwarding
    /// via `deliver`/`handleConnectionStateChange`.
    private func establishAndHandshake(
        credential: RealtimeCredential,
        generation: Int,
        track: (RealtimeTransport) -> Void
    ) async throws -> RealtimeTransport {
        guard credential.connectDeadline > Date() else { throw WebRTCTransportError.credentialExpired }
        let transport = makeTransport()
        track(transport)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            var timeoutTask: Task<Void, Never>?
            let finish: (Result<Void, Error>) -> Void = { result in
                guard !resumed else { return }
                resumed = true
                timeoutTask?.cancel()
                switch result {
                case .success: continuation.resume()
                case let .failure(error): continuation.resume(throwing: error)
                }
            }

            transport.onServerEvent = { event in
                switch event {
                case .sessionCreated:
                    try? transport.send(.sessionUpdate(instructions: self.instructions, tools: self.toolDefinitions, voice: nil))
                case .sessionUpdated:
                    finish(.success(()))
                case let .errorEvent(message):
                    finish(.failure(WebRTCTransportError.sdpExchangeFailed(status: -1, detail: message)))
                default:
                    break
                }
            }
            transport.onConnectionStateChange = { state in
                if case let .failed(reason) = state {
                    finish(.failure(WebRTCTransportError.sdpExchangeFailed(status: -1, detail: reason)))
                }
            }

            timeoutTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(Self.handshakeTimeoutSeconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                finish(.failure(TimeoutError(seconds: Self.handshakeTimeoutSeconds)))
            }

            Task {
                do {
                    guard credential.connectDeadline > Date() else { throw WebRTCTransportError.credentialExpired }
                    try await transport.connect(with: credential)
                } catch {
                    finish(.failure(error))
                }
            }
        }

        transport.onServerEvent = { [weak self] event in
            self?.deliver(event, generation: generation)
        }
        transport.onConnectionStateChange = { [weak self] state in
            self?.handleConnectionStateChange(state, generation: generation)
        }
        return transport
    }

    private func deliver(_ event: RealtimeServerEvent, generation: Int) {
        guard generation == currentGeneration else { return } // retired transport, ignore
        onServerEvent?(event)
    }

    private func handleConnectionStateChange(_ state: TransportConnectionState, generation: Int) {
        guard generation == currentGeneration else { return } // retired transport, ignore
        switch state {
        case let .failed(reason):
            onDisconnected?(reason)
        case .disconnected:
            onDisconnected?(nil)
        case .connected, .connecting:
            break
        }
    }
}
