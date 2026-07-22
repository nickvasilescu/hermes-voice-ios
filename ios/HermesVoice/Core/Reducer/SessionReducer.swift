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
            if let clientRequestId = task.clientRequestId {
                state.pendingDelegations[clientRequestId] = nil
            }
            // Only narrate once the Realtime call is live, and only when the
            // task's narratable fingerprint changed (hydration + SSE replays
            // must not spam response.create).
            guard state.isCallEstablished else { return [] }
            let fingerprint = SessionState.narrationFingerprint(for: task)
            guard state.lastNarratedFingerprints[task.id] != fingerprint else { return [] }
            guard let prompt = SessionState.narrationPrompt(for: task) else { return [] }
            state.lastNarratedFingerprints[task.id] = fingerprint
            guard state.voiceMode == .active else {
                state.hasDeferredResponse = true
                return []
            }
            return [
                .sendClientEvent(.conversationMessage(role: "user", text: prompt)),
                .sendClientEvent(.responseCreate),
            ]

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

        case let .toolResultReady(callId, result):
            state.pendingToolCalls.removeAll { $0.callId == callId }
            state.pendingDelegations[callId] = nil
            if let clientRequestId = result.task.clientRequestId {
                state.pendingDelegations[clientRequestId] = nil
            }
            state.tasks[result.task.id] = result.task
            var effects: [Effect] = [
                .sendClientEvent(.functionCallOutput(callId: callId, outputJSON: result.outputJSON)),
            ]
            if state.voiceMode == .active {
                effects.append(.sendClientEvent(.responseCreate))
            } else {
                state.hasDeferredResponse = true
            }
            return effects

        case let .toolExecutionFailed(callId, message):
            state.pendingToolCalls.removeAll { $0.callId == callId }
            if var pending = state.pendingDelegations[callId] {
                pending.status = .failed(message)
                state.pendingDelegations[callId] = pending
            }
            var effects: [Effect] = [
                .sendClientEvent(.functionCallOutput(callId: callId, outputJSON: ToolErrorOutput(error: message).jsonString())),
                .log("tool \(callId) failed: \(message)"),
            ]
            if state.voiceMode == .active {
                effects.insert(.sendClientEvent(.responseCreate), at: 1)
            } else {
                state.hasDeferredResponse = true
            }
            return effects

        case .stopSpeakingRequested:
            guard state.isCallEstablished,
                  let responseId = state.activeResponseId else { return [] }
            state.activeResponseId = nil
            state.lastAssistantTranscript = ""
            state.phase = .listening
            return [
                .sendClientEvent(.responseCancel(responseId: responseId)),
                .sendClientEvent(.outputAudioBufferClear),
            ]

        case .pauseVoiceRequested:
            guard state.voiceMode == .active else { return [] }
            state.voiceMode = .paused
            var effects: [Effect] = [.setMicrophoneEnabled(false)]
            if let responseId = state.activeResponseId {
                effects.append(.sendClientEvent(.responseCancel(responseId: responseId)))
                effects.append(.sendClientEvent(.outputAudioBufferClear))
            }
            state.activeResponseId = nil
            state.lastAssistantTranscript = ""
            if state.isCallEstablished { state.phase = .listening }
            return effects

        case .resumeVoiceRequested:
            guard state.voiceMode == .paused else { return [] }
            state.voiceMode = .active
            var effects: [Effect] = [.setMicrophoneEnabled(true)]
            if state.isCallEstablished, state.hasDeferredResponse {
                state.hasDeferredResponse = false
                effects.append(.sendClientEvent(.conversationMessage(role: "user", text: state.deferredResponsePrompt)))
                effects.append(.sendClientEvent(.responseCreate))
            }
            return effects
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
            guard state.voiceMode == .active else { return [] }
            let interruptedResponseId = state.activeResponseId
            let wasBargeIn = interruptedResponseId != nil || state.phase == .assistantSpeaking
            state.phase = .userSpeaking
            return wasBargeIn
                ? [.log("realtime speech_started interrupted active response \(interruptedResponseId ?? "unknown"); possible user barge-in or speaker echo")]
                : []

        case .inputAudioBufferSpeechStopped:
            guard state.voiceMode == .active else { return [] }
            state.phase = .thinking
            return []

        case let .responseCreated(responseId):
            state.activeResponseId = responseId
            if state.phase != .assistantSpeaking { state.phase = .thinking }
            return []

        case let .functionCallArgumentsDone(callId, name, argumentsJSON):
            guard state.markCallIdSeenIfNew(callId) else {
                return [.log("ignoring duplicate function call \(callId) (\(name))")]
            }
            state.pendingToolCalls.append(PendingToolCall(callId: callId, name: name, argumentsJSON: argumentsJSON))
            if name == "delegate_to_hermes", let instruction = delegationInstruction(from: argumentsJSON) {
                state.pendingDelegations[callId] = PendingDelegation(callId: callId, instruction: instruction)
            }
            state.phase = .thinking
            return [.executeTool(callId: callId, name: name, argumentsJSON: argumentsJSON)]

        case let .responseAudioTranscriptDelta(text):
            guard state.voiceMode == .active else { return [] }
            state.phase = .assistantSpeaking
            state.lastAssistantTranscript += text
            return []

        case .responseDone:
            state.activeResponseId = nil
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

    private static func delegationInstruction(from argumentsJSON: String) -> String? {
        guard let data = argumentsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let instruction = object["instruction"] as? String else { return nil }
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
