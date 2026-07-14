import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: HermesVoiceStore

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()
                AmbientOrbView(phase: store.state.phase)
                Spacer()
                TaskRailView(viewModel: TaskRailViewModel(tasks: store.state.sortedTasks))
                    .padding(.bottom, 24)
            }

            if store.needsBootstrapCredential {
                VStack(spacing: 14) {
                    Text("Connect to Hermes")
                        .font(.headline)
                    Text("Enter the bootstrap credential configured on your bridge. It is stored only in this device's Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    SecureField("Bootstrap credential", text: $store.bootstrapCredentialInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                    Button("Save and connect") { store.saveBootstrapCredentialAndRetry() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(24)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
                .padding(24)
            }
        }
        .preferredColorScheme(.dark)
    }
}

#Preview {
    let backend = BackendClient(config: BridgeConfig(baseURL: URL(string: "http://localhost:8787")!))
    let sessionManager = ClientSessionManager(persistence: InMemorySessionPersistence())
    let bootstrapCredentialStore = BootstrapCredentialStore()
    RootView()
        .environmentObject(HermesVoiceStore(
            backend: backend,
            sessionManager: sessionManager,
            bootstrapCredentialStore: bootstrapCredentialStore,
            coordinator: SessionCoordinator(
                backend: backend,
                sessionToken: { try await sessionManager.ensureSession { try await backend.bootstrapSession() }.sessionToken },
                instructions: SessionState.defaultInstructions,
                toolDefinitions: ToolRegistry.realtimeToolDefinitions,
                makeTransport: { WebRTCRealtimeTransport(engine: nil) }
            )
        ))
}

/// Preview-only in-memory stand-in for `KeychainSessionStore` — SwiftUI
/// previews shouldn't touch the real Keychain.
private actor InMemorySessionPersistence: ClientSessionPersisting {
    private var stored: StoredClientSession?
    func load() async -> StoredClientSession? { stored }
    func save(_ session: StoredClientSession) async { stored = session }
    func clear() async { stored = nil }
}
