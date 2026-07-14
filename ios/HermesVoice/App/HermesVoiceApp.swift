import SwiftUI

@main
struct HermesVoiceApp: App {
    @StateObject private var store: HermesVoiceStore

    @MainActor
    init() {
        let backend = BackendClient(config: BridgeConfig(baseURL: Config.bridgeBaseURL))
        let sessionManager = ClientSessionManager(persistence: KeychainSessionStore())
        let bootstrapCredentialStore = BootstrapCredentialStore()
        let instructionsHolder = SessionInstructionsHolder()
        // WebRTC engine is wired via Stasel when available — see
        // Core/Transport/StaselWebRTCEngine.swift. Until the package is
        // resolved at build time, `makeWebRTCEngine()` may still return nil
        // and voice stays scaffolded.
        let coordinator = SessionCoordinator(
            backend: backend,
            sessionToken: {
                try await sessionManager.ensureSession {
                    try await backend.bootstrapSession(bootstrapCredential: await bootstrapCredentialStore.load())
                }.sessionToken
            },
            instructions: { instructionsHolder.current() },
            toolDefinitions: ToolRegistry.realtimeToolDefinitions,
            makeTransport: { WebRTCRealtimeTransport(engine: makeWebRTCEngine()) }
        )
        _store = StateObject(wrappedValue: HermesVoiceStore(
            backend: backend,
            sessionManager: sessionManager,
            bootstrapCredentialStore: bootstrapCredentialStore,
            coordinator: coordinator,
            instructionsHolder: instructionsHolder
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
