import Foundation
import SwiftUI

/// The imperative shell: owns `SessionState`, feeds `SessionEvent`s through
/// `SessionReducer`, and interprets the resulting `Effect`s by driving
/// `BackendClient`, `SSEClient`, and `SessionCoordinator`. This is the only
/// class in the app that mutates `SessionState`. [IMPLEMENTED]
@MainActor
final class HermesVoiceStore: ObservableObject {
    @Published private(set) var state = SessionState()
    @Published var bootstrapCredentialInput = ""
    @Published private(set) var needsBootstrapCredential = false

    private let backend: BackendClientProtocol
    private let sessionManager: ClientSessionManager
    private let bootstrapCredentialStore: BootstrapCredentialStore
    private let coordinator: SessionCoordinator
    private let sseClient = SSEClient()

    /// Guards against `start()` being called more than once concurrently
    /// or redundantly (e.g. `onAppear` firing again after a view
    /// re-composition) — it should mint/connect/subscribe exactly once per
    /// app session, not once per call.
    private var startTask: Task<Void, Never>?

    init(
        backend: BackendClientProtocol,
        sessionManager: ClientSessionManager,
        bootstrapCredentialStore: BootstrapCredentialStore,
        coordinator: SessionCoordinator,
        instructionsHolder: SessionInstructionsHolder? = nil
    ) {
        self.backend = backend
        self.sessionManager = sessionManager
        self.bootstrapCredentialStore = bootstrapCredentialStore
        self.coordinator = coordinator

        instructionsHolder?.store = self

        coordinator.onServerEvent = { [weak self] event in
            Task { @MainActor in self?.dispatch(.wire(event)) }
        }
        coordinator.onCallEstablished = { [weak self] in
            Task { @MainActor in self?.dispatch(.callEstablished) }
        }
        coordinator.onDisconnected = { [weak self] reason in
            Task { @MainActor in self?.dispatch(.transportDisconnected(reason: reason)) }
        }
        coordinator.onBootstrapCredentialRequired = { [weak self] in
            Task { @MainActor in self?.needsBootstrapCredential = true }
        }
    }

    /// Idempotent: a second call while the first is still starting (or
    /// after it already finished) is a no-op rather than a second
    /// bootstrap/mint/connect/SSE-subscribe cycle.
    func start() {
        guard startTask == nil else { return }
        state.phase = .connecting
        startTask = Task { [weak self] in
            await self?.runStart()
        }
    }

    func stop() {
        startTask?.cancel()
        startTask = nil
        Task { await coordinator.teardown() }
        Task { await sseClient.disconnect() }
        state = SessionState(systemInstructions: state.systemInstructions, toolDefinitions: state.toolDefinitions, voice: state.voice)
    }

    func saveBootstrapCredentialAndRetry() {
        let value = bootstrapCredentialInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        Task {
            await bootstrapCredentialStore.save(value)
            bootstrapCredentialInput = ""
            needsBootstrapCredential = false
            startTask = nil
            start()
        }
    }

    /// Debug/operator escape hatch for a bridge restart or deliberate token
    /// revocation. Clears only the minted client session; the separately
    /// stored bootstrap credential remains in Keychain.
    func resetClientSession() {
        startTask?.cancel()
        startTask = Task { [weak self] in
            guard let self else { return }
            await coordinator.teardown()
            await sseClient.disconnect()
            await sessionManager.invalidate()
            state = SessionState(
                systemInstructions: state.systemInstructions,
                toolDefinitions: state.toolDefinitions,
                voice: state.voice
            )
            needsBootstrapCredential = false
            startTask = nil
            start()
        }
    }

    private func bootstrapSession() async throws -> MintedClientSession {
        let credential = await bootstrapCredentialStore.load()
        return try await backend.bootstrapSession(bootstrapCredential: credential)
    }

    private func runStart() async {
        do {
            let session = try await sessionManager.ensureSession { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.bootstrapSession()
            }
            dispatch(.hermesSessionAssigned(session.hermesSessionId))
        } catch {
            if case BackendClientError.http(status: 401, code: _, detail: _) = error {
                needsBootstrapCredential = true
            }
            dispatch(.callEstablishmentFailed("could not bootstrap a client session: \(error)"))
            return
        }

        subscribeToTaskEvents()
        await hydrateTasks()

        let result = await coordinator.start(voice: state.voice)
        switch result {
        case .success:
            break // .callEstablished arrives via the coordinator callback
        case let .failure(error):
            if error.requiresBootstrapCredential {
                needsBootstrapCredential = true
            }
            dispatch(.callEstablishmentFailed(error.message))
        }
    }

    /// `GET /v1/tasks` so the rail (and rotation recap) reflect work that
    /// outlived a previous app launch. Dispatched before the call is
    /// established so `.taskUpdated` merges state without narrating.
    private func hydrateTasks() async {
        do {
            let token = try await sessionManager.ensureSession { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.bootstrapSession()
            }.sessionToken
            let tasks = try await backend.listTasks(sessionToken: token, status: nil)
            for task in tasks {
                dispatch(.taskUpdated(task))
            }
        } catch {
            if Self.isUnauthorized(error) {
                needsBootstrapCredential = true
            }
            Log.error("could not hydrate tasks: \(error)")
        }
    }

    /// Every state change funnels through here — the one place that calls
    /// the pure reducer and then interprets its effects.
    private func dispatch(_ event: SessionEvent) {
        let effects = SessionReducer.reduce(&state, event)
        for effect in effects { perform(effect) }
    }

    private func perform(_ effect: Effect) {
        switch effect {
        case let .sendClientEvent(clientEvent):
            coordinator.send(clientEvent)

        case let .executeTool(callId, name, argumentsJSON):
            Task { await runTool(callId: callId, name: name, argumentsJSON: argumentsJSON) }

        case let .scheduleReconnect(delay):
            coordinator.scheduleReconnect(after: delay, voice: state.voice) { [weak self] result in
                Task { @MainActor in
                    switch result {
                    case .success:
                        self?.dispatch(.callEstablished)
                    case let .failure(error):
                        self?.dispatch(.callEstablishmentFailed(error.message))
                    }
                }
            }

        case let .log(message):
            Log.info(message)
        }
    }

    private func runTool(callId: String, name: String, argumentsJSON: String) async {
        do {
            let token = try await sessionManager.ensureSession { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.bootstrapSession()
            }.sessionToken
            let outputJSON = try await ToolRegistry.execute(name: name, callId: callId, argumentsJSON: argumentsJSON, backend: backend, sessionToken: token)
            dispatch(.toolResultReady(callId: callId, outputJSON: outputJSON))
        } catch {
            if Self.isUnauthorized(error) {
                needsBootstrapCredential = true
            }
            dispatch(.toolExecutionFailed(callId: callId, message: String(describing: error)))
        }
    }

    private func subscribeToTaskEvents(retryUnauthorized: Bool = true) {
        Task {
            let token: String
            do {
                token = try await sessionManager.ensureSession { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.bootstrapSession()
            }.sessionToken
            } catch {
                Log.error("could not subscribe to task events: \(error)")
                return
            }
            await sseClient.connect(
                to: Config.bridgeBaseURL.appendingPathComponent("v1/events"),
                sessionToken: token,
                onEvent: { [weak self] sseEvent in
                    guard sseEvent.name.hasPrefix("task."), let data = sseEvent.data.data(using: .utf8) else { return }
                    guard let task = try? JSONDecoder().decode(HermesTask.self, from: data) else { return }
                    Task { @MainActor in self?.dispatch(.taskUpdated(task)) }
                },
                onDisconnect: { [weak self] error in
                    if let error { Log.error("SSE disconnected: \(error)") }
                    guard retryUnauthorized, let error, Self.isUnauthorized(error) else { return }
                    Task { @MainActor in
                        await self?.recoverSessionAndResubscribe()
                    }
                    // A dedicated reconnect/backoff loop for the SSE leg
                    // (independent of Realtime rotation, per PROTOCOL.md §6)
                    // is intentionally not implemented in this MVP; the app
                    // currently relies on a fresh subscribe on next
                    // `start()`. See docs/ARCHITECTURE.md "Known limitations".
                }
            )
        }
    }

    private func recoverSessionAndResubscribe() async {
        do {
            await sessionManager.invalidate()
            let session = try await sessionManager.ensureSession { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.bootstrapSession()
            }
            dispatch(.hermesSessionAssigned(session.hermesSessionId))
            subscribeToTaskEvents(retryUnauthorized: false)
            await hydrateTasks()
        } catch {
            if Self.isUnauthorized(error) {
                needsBootstrapCredential = true
            }
            Log.error("could not recover SSE client session: \(error)")
        }
    }

    nonisolated private static func isUnauthorized(_ error: Error) -> Bool {
        guard case BackendClientError.http(status: 401, code: _, detail: _) = error else {
            return false
        }
        return true
    }
}
