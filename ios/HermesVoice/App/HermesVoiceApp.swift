import SwiftUI

@main
struct HermesVoiceApp: App {
    @StateObject private var store: HermesVoiceStore
    private let isReadmeDemo: Bool

    @MainActor
    init() {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let isReadmeDemo = arguments.contains("--readme-demo-active")
            || arguments.contains("--readme-demo-paused")
        let initialState = isReadmeDemo
            ? SessionState.readmeDemo(paused: arguments.contains("--readme-demo-paused"))
            : SessionState()
#else
        let isReadmeDemo = false
        let initialState = SessionState()
#endif
        self.isReadmeDemo = isReadmeDemo
        let rawBackend = BackendClient(config: BridgeConfig(baseURL: Config.bridgeBaseURL))
        let sessionManager = ClientSessionManager(persistence: KeychainSessionStore())
        let bootstrapCredentialStore = BootstrapCredentialStore()
        let backend = ReauthenticatingBackendClient(
            base: rawBackend,
            sessionManager: sessionManager,
            bootstrapCredential: { await bootstrapCredentialStore.load() }
        )
        let instructionsHolder = SessionInstructionsHolder()
        // WebRTC engine is wired via Stasel — see
        // Core/Transport/StaselWebRTCEngine.swift. The nil fallback keeps
        // previews/test configurations honest when WebRTC is unavailable.
        let coordinator = SessionCoordinator(
            backend: backend,
            sessionToken: {
                try await sessionManager.ensureSession {
                    try await rawBackend.bootstrapSession(bootstrapCredential: await bootstrapCredentialStore.load())
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
            initialState: initialState,
            instructionsHolder: instructionsHolder
        ))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .onAppear {
                    if !isReadmeDemo { store.start() }
                }
        }
    }
}
