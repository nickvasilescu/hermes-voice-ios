import SwiftUI

/// A single ambient shape that communicates conversation phase at a glance
/// — the primary UI surface, deliberately not a chat transcript. Pulses
/// while listening, tightens while thinking, glows while the assistant
/// speaks. [IMPLEMENTED]
struct AmbientOrbView: View {
    let phase: ConversationPhase
    let voiceMode: VoiceMode

    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [color.opacity(0.9), color.opacity(0.2)],
                        center: .center,
                        startRadius: 4,
                        endRadius: 140
                    )
                )
                .frame(width: 220, height: 220)
                .scaleEffect(voiceMode == .paused ? 0.96 : (pulse ? 1.06 : 0.94))
                .animation(
                    .easeInOut(duration: animationDuration).repeatForever(autoreverses: true),
                    value: pulse
                )
                .onAppear { pulse = true }

            Text(label)
                .font(.headline)
                .foregroundStyle(.white)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Hermes voice, \(label)")
    }

    private var color: Color {
        if voiceMode == .paused { return .indigo }
        switch phase {
        case .idle: return .gray
        case .connecting, .reconnecting: return .yellow
        case .listening: return .blue
        case .userSpeaking: return .green
        case .thinking: return .purple
        case .assistantSpeaking: return .teal
        case .failed: return .red
        }
    }

    private var animationDuration: Double {
        switch phase {
        case .userSpeaking, .assistantSpeaking: return 0.5
        case .thinking: return 0.7
        default: return 1.6
        }
    }

    private var label: String {
        if voiceMode == .paused { return "Paused" }
        switch phase {
        case .idle: return "Idle"
        case .connecting: return "Connecting…"
        case .listening: return "Listening"
        case .userSpeaking: return "Listening to you"
        case .thinking: return "Thinking"
        case .assistantSpeaking: return "Speaking"
        case .reconnecting: return "Reconnecting…"
        case let .failed(message): return "Error: \(message)"
        }
    }
}

#Preview {
    AmbientOrbView(phase: .listening, voiceMode: .active)
        .padding()
        .background(Color.black)
}
