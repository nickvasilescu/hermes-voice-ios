import Foundation

/// The pure core of the app: `(State, Event) -> effects`, with `State`
/// mutated in place like a typical reducer. No networking, no WebRTC, no
/// SwiftUI — this file only depends on Foundation and the other files in
/// `Core/Reducer`. That's what makes `SessionReducerTests.swift` runnable
/// as a plain unit test, independent of the transport/WebRTC boundary
/// described in `Core/Transport`. [IMPLEMENTED]
///
/// Honest scope note: this reducer models conversation turn-taking state
/// (listening/thinking/speaking, tool-call bookkeeping, barge-in
/// detection) for whatever the *current* call is. It does not model
/// credential minting, transport connection, the `session.created` →
/// `session.update` → `session.updated` handshake, or rotation
/// choreography across two live transports at once — all of that is
/// `SessionCoordinator`'s job end-to-end (see its doc comment), and this
/// reducer only ever hears the outcome via `.callEstablished` /
/// `.callEstablishmentFailed` / `.transportDisconnected`. In particular,
/// `.wire(.sessionCreated)` and `.wire(.sessionUpdated)` should never
/// actually reach `reduce` in practice — `SessionCoordinator` consumes
/// both internally during its handshake — the cases below exist only as a
/// harmless fallback, not a code path this app relies on.
enum SessionReducer {
    static func reduce(_ state: inout SessionState, _ event: SessionEvent) -> [Effect] {
        switch event {
        case let .wire(serverEvent):
            return reduceWire(&state, serverEvent)

        case let .taskUpdated(task):
            state.tasks[task.id] = task
            return []

        case let .hermesSessionAssigned(id):
            state.hermesSessionId = id
            return []

        case .callEstablished:
            state.isCallEstablished = true
            state.reconnectAttempt = 0
            state.lastError = nil
            // Idempotent: a routine successful rotation fires this again
            // while already `.listening`, which is a no-op past the first
            // time — see docs/PROTOCOL.md §6.
            if state.phase == .connecting || state.phase == .reconnecting || state.phase == .idle {
                state.phase = .listening
            }
            return []

        case let .callEstablishmentFailed(message):
            state.isCallEstablished = false
            state.phase = .failed(message)
            state.lastError = message
            return [.log("call establishment failed: \(message)")]

        case let .transportDisconnected(reason):
            state.isCallEstablished = false
            let wasIntentional = state.phase == .idle
            guard !wasIntentional else { return [] }
            state.phase = .reconnecting
            let delay = backoffDelay(forAttempt: state.reconnectAttempt)
            state.reconnectAttempt += 1
            var effects: [Effect] = [.scheduleReconnect(after: delay)]
            if let reason { effects.append(.log("transport disconnected: \(reason)")) }
            return effects

        case let .toolResultReady(callId, outputJSON):
            state.pendingToolCalls.removeAll { $0.callId == callId }
            return [
                .sendClientEvent(.functionCallOutput(callId: callId, outputJSON: outputJSON)),
                .sendClientEvent(.responseCreate),
            ]

        case let .toolExecutionFailed(callId, message):
            state.pendingToolCalls.removeAll { $0.callId == callId }
            return [
                .sendClientEvent(.functionCallOutput(callId: callId, outputJSON: ToolErrorOutput(error: message).jsonString())),
                .sendClientEvent(.responseCreate),
                .log("tool \(callId) failed: \(message)"),
            ]
        }
    }

    private static func reduceWire(_ state: inout SessionState, _ event: RealtimeServerEvent) -> [Effect] {
        switch event {
        case .sessionCreated, .sessionUpdated:
            // Consumed internally by SessionCoordinator's handshake; see
            // this type's doc comment. Nothing to do if one somehow
            // arrives here anyway.
            return []

        case .inputAudioBufferSpeechStarted:
            let wasBargeIn = state.phase == .assistantSpeaking
            state.phase = .userSpeaking
            return wasBargeIn ? [.log("barge-in: user spoke over assistant audio")] : []

        case .inputAudioBufferSpeechStopped:
            state.phase = .thinking
            return []

        case .responseCreated:
            if state.phase != .assistantSpeaking { state.phase = .thinking }
            return []

        case let .functionCallArgumentsDone(callId, name, argumentsJSON):
            guard state.markCallIdSeenIfNew(callId) else {
                return [.log("ignoring duplicate function call \(callId) (\(name))")]
            }
            state.pendingToolCalls.append(PendingToolCall(callId: callId, name: name, argumentsJSON: argumentsJSON))
            state.phase = .thinking
            return [.executeTool(callId: callId, name: name, argumentsJSON: argumentsJSON)]

        case let .responseAudioTranscriptDelta(text):
            state.phase = .assistantSpeaking
            state.lastAssistantTranscript += text
            return []

        case .responseDone:
            state.lastAssistantTranscript = ""
            state.phase = state.pendingToolCalls.isEmpty ? .listening : .thinking
            return []

        case let .errorEvent(message):
            state.phase = .failed(message)
            state.lastError = message
            return [.log("realtime error: \(message)")]

        case .unknown:
            return []
        }
    }

    /// 1s, 2s, 4s, 8s, ... capped at 30s, per docs/PROTOCOL.md §6.
    static func backoffDelay(forAttempt attempt: Int) -> TimeInterval {
        min(30.0, pow(2.0, Double(attempt)))
    }
}

/// A single-field error payload sent back to Realtime as a
/// `function_call_output` when a tool throws. `JSONEncoder`-serialized,
/// never hand-built with string escaping — a hand-escaped
/// `"{\"error\":\"\(message)\"}"` was a real bug in an earlier version of
/// this file (a message containing control characters or unpaired
/// surrogates would have produced invalid JSON).
private struct ToolErrorOutput: Encodable {
    var error: String

    func jsonString() -> String {
        let data = (try? JSONEncoder().encode(self)) ?? Data("{\"error\":\"unknown error\"}".utf8)
        return String(data: data, encoding: .utf8) ?? "{\"error\":\"unknown error\"}"
    }
}
