import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: HermesVoiceStore

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()
                AmbientOrbView(phase: store.state.phase, voiceMode: store.state.voiceMode)
                VoiceControlBar(store: store)
                Spacer(minLength: 8)
                TaskRailView(viewModel: TaskRailViewModel(
                    tasks: store.state.sortedTasks,
                    pendingDelegations: Array(store.state.pendingDelegations.values)
                ))
                    .padding(.bottom, 24)
            }

#if DEBUG
            if !isReadmeDemo {
                VStack {
                    HStack {
                        Spacer()
                        Button("Reset client session") { store.resetClientSession() }
                            .font(.caption)
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("reset-client-session")
                    }
                    Spacer()
                }
                .padding()
            }
#endif

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

#if DEBUG
    private var isReadmeDemo: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--readme-demo-active")
            || arguments.contains("--readme-demo-paused")
    }
#endif
}

private struct VoiceControlBar: View {
    @ObservedObject var store: HermesVoiceStore

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                if store.state.voiceMode == .active, store.state.activeResponseId != nil {
                    Button {
                        store.stopSpeaking()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .frame(minWidth: 86)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .accessibilityHint("Stops the current spoken response immediately")
                }

                if store.state.voiceMode == .paused {
                    Button {
                        store.resumeVoice()
                    } label: {
                        Label("Resume voice", systemImage: "play.fill")
                            .frame(minWidth: 132)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .accessibilityHint("Turns the microphone and voice responses back on")
                } else {
                    Button {
                        store.pauseVoice()
                    } label: {
                        Label("Pause voice", systemImage: "pause.fill")
                            .frame(minWidth: 132)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!store.state.isCallEstablished)
                    .accessibilityHint("Pauses the microphone and spoken responses while Hermes tasks continue")
                }
            }
            .controlSize(.large)

            if store.state.voiceMode == .paused {
                Text("Microphone and narration are paused. Hermes tasks keep running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal)
    }
}

#Preview {
    let backend = BackendClient(config: BridgeConfig(baseURL: URL(string: "http://localhost:8787")!))
    let sessionManager = ClientSessionManager(persistence: InMemorySessionPersistence())
    let bootstrapCredentialStore = BootstrapCredentialStore()
    let instructionsHolder = SessionInstructionsHolder()
    RootView()
        .environmentObject(HermesVoiceStore(
            backend: backend,
            sessionManager: sessionManager,
            bootstrapCredentialStore: bootstrapCredentialStore,
            coordinator: SessionCoordinator(
                backend: backend,
                sessionToken: { try await sessionManager.ensureSession { try await backend.bootstrapSession() }.sessionToken },
                instructions: { instructionsHolder.current() },
                toolDefinitions: ToolRegistry.realtimeToolDefinitions,
                makeTransport: { WebRTCRealtimeTransport(engine: makeWebRTCEngine()) }
            ),
            instructionsHolder: instructionsHolder
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
