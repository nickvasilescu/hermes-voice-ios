import Foundation
import SwiftUI

/// Imperative lifecycle shell for the reducer, bridge, SSE subscription, and
/// Realtime coordinator. Every asynchronous callback is scoped to a monotonic
/// lifecycle generation so Reset/Stop is a hard cancellation boundary.
@MainActor
final class HermesVoiceStore: ObservableObject {
    @Published private(set) var state: SessionState
    @Published var bootstrapCredentialInput = ""
    @Published private(set) var needsBootstrapCredential = false

    private let backend: BackendClientProtocol
    private let sessionManager: ClientSessionManager
    private let bootstrapCredentialStore: BootstrapCredentialStore
    private let coordinator: SessionCoordinator
    private let sseClient: SSEClient
    private let sseReconnectDelaysNanoseconds: [UInt64]

    private var lifecycleGeneration: UInt64 = 0
    private var callbacksEnabled = false
    private var startTask: Task<Void, Never>?
    private var sseReconnectTask: Task<Void, Never>?
    private var toolTasks: [UUID: Task<Void, Never>] = [:]
    private var sseReconnectAttempt = 0
    private var sseAuthRecoveryUsed = false

    init(
        backend: BackendClientProtocol,
        sessionManager: ClientSessionManager,
        bootstrapCredentialStore: BootstrapCredentialStore,
        coordinator: SessionCoordinator,
        initialState: SessionState = SessionState(),
        instructionsHolder: SessionInstructionsHolder? = nil,
        sseClient: SSEClient = SSEClient(),
        sseReconnectDelaysNanoseconds: [UInt64] = [
            1_000_000_000,
            2_000_000_000,
            4_000_000_000,
            8_000_000_000,
            15_000_000_000,
        ]
    ) {
        self.state = initialState
        self.backend = backend
        self.sessionManager = sessionManager
        self.bootstrapCredentialStore = bootstrapCredentialStore
        self.coordinator = coordinator
        self.sseClient = sseClient
        self.sseReconnectDelaysNanoseconds = sseReconnectDelaysNanoseconds.isEmpty ? [15_000_000_000] : sseReconnectDelaysNanoseconds

        instructionsHolder?.store = self

        coordinator.onServerEvent = { [weak self] event in
            Task { @MainActor in
                guard let self, self.callbacksEnabled else { return }
                self.dispatch(.wire(event))
            }
        }
        coordinator.onCallEstablished = { [weak self] in
            Task { @MainActor in
                guard let self, self.callbacksEnabled else { return }
                self.dispatch(.callEstablished)
            }
        }
        coordinator.onDisconnected = { [weak self] reason in
            Task { @MainActor in
                guard let self, self.callbacksEnabled else { return }
                self.dispatch(.transportDisconnected(reason: reason))
            }
        }
        coordinator.onBootstrapCredentialRequired = { [weak self] in
            Task { @MainActor in
                guard let self, self.callbacksEnabled else { return }
                self.needsBootstrapCredential = true
            }
        }
    }

    /// Idempotent for one lifecycle generation.
    func start() {
        guard startTask == nil else { return }
        callbacksEnabled = true
        coordinator.setMicrophoneEnabled(state.voiceMode == .active)
        state.phase = .connecting
        let generation = lifecycleGeneration
        startTask = Task { [weak self] in
            await self?.runStart(generation: generation)
        }
    }

    func stop() {
        beginLifecycleTransition(clearSession: false, restart: false, credentialToSave: nil)
    }

    func stopSpeaking() {
        dispatch(.stopSpeakingRequested)
    }

    func pauseVoice() {
        dispatch(.pauseVoiceRequested)
    }

    func resumeVoice() {
        dispatch(.resumeVoiceRequested)
    }

    func saveBootstrapCredentialAndRetry() {
        let value = bootstrapCredentialInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        bootstrapCredentialInput = ""
        beginLifecycleTransition(clearSession: true, restart: true, credentialToSave: value)
    }

    /// Debug/operator escape hatch for a bridge restart or deliberate token
    /// revocation. The separately stored bootstrap credential is retained.
    func resetClientSession() {
        beginLifecycleTransition(clearSession: true, restart: true, credentialToSave: nil)
    }

    /// Invalidates callbacks immediately, then serially tears down every I/O
    /// leg before an optional restart. A new subscription can therefore never
    /// be canceled by cleanup from the previous generation.
    private func beginLifecycleTransition(
        clearSession: Bool,
        restart: Bool,
        credentialToSave: String?
    ) {
        lifecycleGeneration &+= 1
        let transitionGeneration = lifecycleGeneration
        callbacksEnabled = false

        startTask?.cancel()
        sseReconnectTask?.cancel()
        sseReconnectTask = nil
        for task in toolTasks.values { task.cancel() }
        toolTasks.removeAll()

        let configuration = (
            instructions: state.systemInstructions,
            tools: state.toolDefinitions,
            voice: state.voice
        )
        state = SessionState(
            systemInstructions: configuration.instructions,
            toolDefinitions: configuration.tools,
            voice: configuration.voice
        )
        needsBootstrapCredential = false
        sseReconnectAttempt = 0
        sseAuthRecoveryUsed = false

        startTask = Task { [weak self] in
            guard let self else { return }
            guard self.lifecycleGeneration == transitionGeneration else { return }
            if let credentialToSave {
                await bootstrapCredentialStore.save(credentialToSave)
                guard self.lifecycleGeneration == transitionGeneration else { return }
            }
            await coordinator.teardown()
            guard self.lifecycleGeneration == transitionGeneration else { return }
            await sseClient.disconnect()
            guard self.lifecycleGeneration == transitionGeneration else { return }
            if clearSession {
                await sessionManager.invalidate()
            } else {
                await sessionManager.cancelPendingBootstrap()
            }
            guard self.lifecycleGeneration == transitionGeneration else { return }
            self.startTask = nil
            if restart { self.start() }
        }
    }

    private func bootstrapSession() async throws -> MintedClientSession {
        let credential = await bootstrapCredentialStore.load()
        return try await backend.bootstrapSession(bootstrapCredential: credential)
    }

    private func runStart(generation: UInt64) async {
        do {
            let session = try await sessionManager.ensureSession { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.bootstrapSession()
            }
            try Task.checkCancellation()
            guard isActive(generation) else { return }
            dispatch(.hermesSessionAssigned(session.hermesSessionId))

            await subscribeToTaskEvents(generation: generation, sessionToken: session.sessionToken)
            await hydrateTasks(generation: generation)
            try Task.checkCancellation()
            guard isActive(generation) else { return }

            let result = await coordinator.start(voice: state.voice)
            guard isActive(generation) else { return }
            switch result {
            case .success:
                break // coordinator callback dispatches callEstablished
            case let .failure(error):
                if error.requiresBootstrapCredential { needsBootstrapCredential = true }
                dispatch(.callEstablishmentFailed(error.message))
            }
        } catch is CancellationError {
            // Reset/Stop is an expected cancellation boundary, not a user error.
        } catch {
            guard isActive(generation) else { return }
            if Self.isUnauthorized(error) { needsBootstrapCredential = true }
            dispatch(.callEstablishmentFailed("could not bootstrap a client session: \(error)"))
        }
    }

    private func hydrateTasks(generation: UInt64) async {
        do {
            let token = try await sessionManager.ensureSession { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.bootstrapSession()
            }.sessionToken
            let tasks = try await backend.listTasks(sessionToken: token, status: nil)
            try Task.checkCancellation()
            guard isActive(generation) else { return }
            for task in tasks { dispatch(.taskUpdated(task)) }
        } catch is CancellationError {
            return
        } catch {
            guard isActive(generation) else { return }
            if Self.isUnauthorized(error) { needsBootstrapCredential = true }
            Log.error("could not hydrate tasks: \(error)")
        }
    }

    // MARK: - SSE lifecycle

    private func subscribeToTaskEvents(generation: UInt64, sessionToken: String? = nil) async {
        guard isActive(generation) else { return }
        let token: String
        do {
            if let sessionToken {
                token = sessionToken
            } else {
                token = try await sessionManager.ensureSession { [weak self] in
                    guard let self else { throw CancellationError() }
                    return try await self.bootstrapSession()
                }.sessionToken
            }
        } catch is CancellationError {
            return
        } catch {
            guard isActive(generation) else { return }
            if Self.isUnauthorized(error) { needsBootstrapCredential = true }
            Log.error("could not subscribe to task events: \(error)")
            return
        }
        guard isActive(generation) else { return }

        await sseClient.connect(
            to: Config.bridgeBaseURL.appendingPathComponent("v1/events"),
            sessionToken: token,
            onEvent: { [weak self] sseEvent in
                guard sseEvent.name.hasPrefix("task."), let data = sseEvent.data.data(using: .utf8),
                      let task = try? JSONDecoder().decode(HermesTask.self, from: data) else { return }
                Task { @MainActor in
                    guard let self, self.isActive(generation) else { return }
                    // A real event proves the stream is stable; a rapid
                    // connect-then-EOF must not reset exponential backoff.
                    self.sseReconnectAttempt = 0
                    self.dispatch(.taskUpdated(task))
                }
            },
            onDisconnect: { [weak self] error in
                Task { @MainActor in
                    await self?.sseDidDisconnect(error, rejectedToken: token, generation: generation)
                }
            }
        )
    }

    private func sseDidDisconnect(_ error: Error?, rejectedToken: String, generation: UInt64) async {
        guard isActive(generation) else { return }
        if let error { Log.error("SSE disconnected: \(error)") }

        if let error, Self.isUnauthorized(error) {
            guard !sseAuthRecoveryUsed else {
                needsBootstrapCredential = true
                return
            }
            sseAuthRecoveryUsed = true
            do {
                let observedGeneration = await sessionManager.sessionGeneration()
                // Preserve a token already refreshed by a concurrent REST
                // request; otherwise retire precisely the rejected token.
                let didInvalidate = await sessionManager.invalidate(ifCurrentTokenMatches: rejectedToken)
                guard isActive(generation) else { return }
                if !didInvalidate,
                   let current = await sessionManager.currentSession(),
                   current.sessionToken != rejectedToken {
                    dispatch(.hermesSessionAssigned(current.hermesSessionId))
                    await subscribeToTaskEvents(generation: generation, sessionToken: current.sessionToken)
                    await hydrateTasks(generation: generation)
                    return
                }
                let recoveryGeneration = await sessionManager.sessionGeneration()
                let expectedRecoveryGeneration = observedGeneration &+ (didInvalidate ? 1 : 0)
                guard recoveryGeneration == expectedRecoveryGeneration else { throw CancellationError() }
                let fresh = try await sessionManager.ensureSession(expectedGeneration: recoveryGeneration) { [weak self] in
                    guard let self else { throw CancellationError() }
                    return try await self.bootstrapSession()
                }
                try Task.checkCancellation()
                guard isActive(generation) else { return }
                dispatch(.hermesSessionAssigned(fresh.hermesSessionId))
                await subscribeToTaskEvents(generation: generation, sessionToken: fresh.sessionToken)
                await hydrateTasks(generation: generation)
            } catch is CancellationError {
                return
            } catch {
                guard isActive(generation) else { return }
                if Self.isUnauthorized(error) { needsBootstrapCredential = true }
                Log.error("could not recover SSE client session: \(error)")
            }
            return
        }

        scheduleSSEReconnect(generation: generation)
    }

    /// Transport failures and clean EOF both reconnect independently of the
    /// Realtime call. Delays grow exponentially and cap at the final entry.
    private func scheduleSSEReconnect(generation: UInt64) {
        guard isActive(generation) else { return }
        sseReconnectTask?.cancel()
        let index = min(sseReconnectAttempt, sseReconnectDelaysNanoseconds.count - 1)
        let delay = sseReconnectDelaysNanoseconds[index]
        sseReconnectAttempt += 1
        sseReconnectTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                return
            }
            guard let self, self.isActive(generation) else { return }
            await self.subscribeToTaskEvents(generation: generation)
        }
    }

    // MARK: - Reducer effects

    private func dispatch(_ event: SessionEvent) {
        guard callbacksEnabled else { return }
        let effects = SessionReducer.reduce(&state, event)
        for effect in effects { perform(effect) }
    }

    private func perform(_ effect: Effect) {
        let generation = lifecycleGeneration
        switch effect {
        case let .sendClientEvent(clientEvent):
            coordinator.send(clientEvent)

        case let .setMicrophoneEnabled(enabled):
            coordinator.setMicrophoneEnabled(enabled)

        case let .executeTool(callId, name, argumentsJSON):
            let id = UUID()
            toolTasks[id] = Task { [weak self] in
                await self?.runTool(
                    id: id,
                    generation: generation,
                    callId: callId,
                    name: name,
                    argumentsJSON: argumentsJSON
                )
            }

        case let .scheduleReconnect(delay):
            coordinator.scheduleReconnect(after: delay, voice: state.voice) { [weak self] result in
                Task { @MainActor in
                    guard let self, self.isActive(generation) else { return }
                    switch result {
                    case .success:
                        self.dispatch(.callEstablished)
                    case let .failure(error):
                        if error.requiresBootstrapCredential { self.needsBootstrapCredential = true }
                        self.dispatch(.callEstablishmentFailed(error.message))
                    }
                }
            }

        case let .log(message):
            Log.info(message)
        }
    }

    private func runTool(
        id: UUID,
        generation: UInt64,
        callId: String,
        name: String,
        argumentsJSON: String
    ) async {
        defer { if isActive(generation) { toolTasks[id] = nil } }
        do {
            let token = try await sessionManager.ensureSession { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.bootstrapSession()
            }.sessionToken
            let result = try await ToolRegistry.execute(
                name: name,
                callId: callId,
                argumentsJSON: argumentsJSON,
                backend: backend,
                sessionToken: token
            )
            try Task.checkCancellation()
            guard isActive(generation) else { return }
            dispatch(.toolResultReady(callId: callId, result: result))
        } catch is CancellationError {
            return
        } catch {
            guard isActive(generation) else { return }
            if Self.isUnauthorized(error) { needsBootstrapCredential = true }
            dispatch(.toolExecutionFailed(callId: callId, message: String(describing: error)))
        }
    }

    private func isActive(_ generation: UInt64) -> Bool {
        callbacksEnabled && generation == lifecycleGeneration
    }

    nonisolated private static func isUnauthorized(_ error: Error) -> Bool {
        guard case BackendClientError.http(status: 401, code: _, detail: _) = error else { return false }
        return true
    }
}
