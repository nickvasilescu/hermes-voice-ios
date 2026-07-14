import SwiftUI

@main
struct HermesVoiceApp: App {
    @StateObject private var store: HermesVoiceStore

    @MainActor
    init() {
        let backend = BackendClient(config: BridgeConfig(baseURL: Config.bridgeBaseURL))
        let sessionManager = ClientSessionManager(persistence: KeychainSessionStore())
        let bootstrapCredentialStore = BootstrapCredentialStore()
        // No WebRTCEngine is wired up in this repo (see
        // Core/Transport/WebRTCRealtimeTransport.swift) — the app compiles
        // and its state machine is fully testable, but a real device build
        // needs a concrete engine injected here before voice actually works.
        let coordinator = SessionCoordinator(
            backend: backend,
            sessionToken: {
                try await sessionManager.ensureSession {
                    try await backend.bootstrapSession(bootstrapCredential: await bootstrapCredentialStore.load())
                }.sessionToken
            },
            instructions: SessionState.defaultInstructions,
            toolDefinitions: ToolRegistry.realtimeToolDefinitions,
            makeTransport: { WebRTCRealtimeTransport(engine: nil) }
        )
        _store = StateObject(wrappedValue: HermesVoiceStore(
            backend: backend,
            sessionManager: sessionManager,
            bootstrapCredentialStore: bootstrapCredentialStore,
            coordinator: coordinator
        ))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .onAppear { store.start() }
        }
    }
}
