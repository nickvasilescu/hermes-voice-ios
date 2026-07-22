import XCTest
@testable import HermesVoice

/// Pure reducer tests — no networking, no WebRTC, no XCUIApplication.
/// Run with `xcodebuild test -scheme HermesVoice` (or in Xcode).
final class SessionReducerTests: XCTestCase {
    func makeState() -> SessionState {
        SessionState(toolDefinitions: [])
    }

    func testSessionCreatedAndUpdatedAreNoOpsHere() {
        // SessionCoordinator consumes these internally during its
        // handshake — see SessionReducer's doc comment. If one somehow
        // reaches the reducer anyway, it must be a harmless no-op, not a
        // crash or a stray effect.
        var state = makeState()
        XCTAssertEqual(SessionReducer.reduce(&state, .wire(.sessionCreated(sessionId: "sess_openai_1"))), [])
        XCTAssertEqual(SessionReducer.reduce(&state, .wire(.sessionUpdated)), [])
    }

    func testCallEstablishedTransitionsConnectingToListening() {
        var state = makeState()
        state.phase = .connecting
        let effects = SessionReducer.reduce(&state, .callEstablished)

        XCTAssertEqual(state.phase, .listening)
        XCTAssertTrue(state.isCallEstablished)
        XCTAssertTrue(effects.isEmpty)
    }

    func testCallEstablishedIsIdempotentDuringAnOngoingCall() {
        // A routine successful rotation fires .callEstablished again while
        // the phase is already mid-conversation (e.g. .thinking) — it must
        // not reset an in-progress turn back to .listening.
        var state = makeState()
        state.phase = .thinking
        _ = SessionReducer.reduce(&state, .callEstablished)
        XCTAssertEqual(state.phase, .thinking)
    }

    func testCallEstablishmentFailedSetsFailedPhase() {
        var state = makeState()
        let effects = SessionReducer.reduce(&state, .callEstablishmentFailed("no engine configured"))
        XCTAssertEqual(state.phase, .failed("no engine configured"))
        XCTAssertFalse(state.isCallEstablished)
        XCTAssertFalse(effects.isEmpty)
    }

    func testSpeechStartedDuringAssistantSpeechIsBargeIn() {
        var state = makeState()
        state.phase = .assistantSpeaking
        let effects = SessionReducer.reduce(&state, .wire(.inputAudioBufferSpeechStarted))

        XCTAssertEqual(state.phase, .userSpeaking)
        XCTAssertTrue(effects.contains { if case .log = $0 { return true }; return false })
    }

    func testFunctionCallArgumentsDoneQueuesToolAndRequestsExecution() {
        var state = makeState()
        state.phase = .thinking
        let effects = SessionReducer.reduce(
            &state,
            .wire(.functionCallArgumentsDone(callId: "call_1", name: "delegate_to_hermes", argumentsJSON: "{}"))
        )

        XCTAssertEqual(state.pendingToolCalls.map(\.callId), ["call_1"])
        XCTAssertEqual(effects, [.executeTool(callId: "call_1", name: "delegate_to_hermes", argumentsJSON: "{}")])
    }

    func testDelegationAppearsOptimisticallyBeforeToolExecutionCompletes() {
        var state = makeState()
        let arguments = #"{"instruction":"Prepare tomorrow's briefing"}"#

        _ = SessionReducer.reduce(
            &state,
            .wire(.functionCallArgumentsDone(callId: "call_optimistic", name: "delegate_to_hermes", argumentsJSON: arguments))
        )

        XCTAssertEqual(state.pendingDelegations["call_optimistic"]?.instruction, "Prepare tomorrow's briefing")
        XCTAssertEqual(state.pendingDelegations["call_optimistic"]?.status, .sending)
    }

    func testDuplicateCallIdIsIgnoredAcrossAllFiveTools() {
        // Regression test: a duplicate function-call delivery (Realtime
        // retry, replayed event after reconnect, etc.) must not be
        // dispatched twice, regardless of which of the five tools it
        // names — dedup happens centrally by call_id, not per-tool.
        for toolName in ["delegate_to_hermes", "get_hermes_task_status", "send_followup_to_hermes", "cancel_hermes_task", "approve_hermes_action"] {
            var state = makeState()
            let first = SessionReducer.reduce(&state, .wire(.functionCallArgumentsDone(callId: "call_dup", name: toolName, argumentsJSON: "{}")))
            XCTAssertEqual(first.count, 1, "first delivery of \(toolName) should dispatch exactly one executeTool effect")

            let second = SessionReducer.reduce(&state, .wire(.functionCallArgumentsDone(callId: "call_dup", name: toolName, argumentsJSON: "{}")))
            XCTAssertTrue(second.allSatisfy { if case .executeTool = $0 { return false }; return true }, "duplicate call_id for \(toolName) must not re-dispatch executeTool")
            XCTAssertEqual(state.pendingToolCalls.count, 1, "duplicate delivery must not double-queue the pending call for \(toolName)")
        }
    }

    func testDifferentCallIdsForTheSameToolAreBothDispatched() {
        var state = makeState()
        let first = SessionReducer.reduce(&state, .wire(.functionCallArgumentsDone(callId: "call_1", name: "get_hermes_task_status", argumentsJSON: "{}")))
        let second = SessionReducer.reduce(&state, .wire(.functionCallArgumentsDone(callId: "call_2", name: "get_hermes_task_status", argumentsJSON: "{}")))
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(state.pendingToolCalls.count, 2)
    }

    func testResponseDoneReturnsToListeningOnlyWhenNoPendingToolCalls() {
        var state = makeState()
        state.phase = .thinking
        state.pendingToolCalls = [PendingToolCall(callId: "call_1", name: "x", argumentsJSON: "{}")]
        _ = SessionReducer.reduce(&state, .wire(.responseDone))
        XCTAssertEqual(state.phase, .thinking, "should stay thinking while a tool call is still pending")

        state.pendingToolCalls = []
        _ = SessionReducer.reduce(&state, .wire(.responseDone))
        XCTAssertEqual(state.phase, .listening)
    }

    func testToolResultReadySendsOutputThenRequestsAResponse() {
        var state = makeState()
        state.pendingToolCalls = [PendingToolCall(callId: "call_1", name: "x", argumentsJSON: "{}")]

        state.pendingDelegations["call_1"] = PendingDelegation(callId: "call_1", instruction: "do it")
        let task = makeTask(id: "task_1", status: .queued, clientRequestId: "call_1")
        let result = HermesToolExecutionResult(outputJSON: "{\"ok\":true}", task: task)

        let effects = SessionReducer.reduce(&state, .toolResultReady(callId: "call_1", result: result))

        XCTAssertTrue(state.pendingToolCalls.isEmpty)
        XCTAssertTrue(state.pendingDelegations.isEmpty)
        XCTAssertEqual(state.tasks["task_1"], task)
        XCTAssertEqual(effects, [
            .sendClientEvent(.functionCallOutput(callId: "call_1", outputJSON: "{\"ok\":true}")),
            .sendClientEvent(.responseCreate),
        ])
    }

    func testTaskSSEReconcilesMatchingOptimisticDelegation() {
        var state = makeState()
        state.pendingDelegations["call_1"] = PendingDelegation(callId: "call_1", instruction: "do it")
        let task = makeTask(id: "task_1", status: .running, clientRequestId: "call_1")

        _ = SessionReducer.reduce(&state, .taskUpdated(task))

        XCTAssertTrue(state.pendingDelegations.isEmpty)
        XCTAssertEqual(state.tasks[task.id], task)
    }

    func testStopSpeakingCancelsResponseThenClearsBufferedAudio() {
        var state = makeState()
        state.isCallEstablished = true
        state.phase = .assistantSpeaking
        state.activeResponseId = "resp_1"

        let effects = SessionReducer.reduce(&state, .stopSpeakingRequested)

        XCTAssertEqual(state.phase, .listening)
        XCTAssertNil(state.activeResponseId)
        XCTAssertEqual(effects, [
            .sendClientEvent(.responseCancel(responseId: "resp_1")),
            .sendClientEvent(.outputAudioBufferClear),
        ])
    }

    func testPauseStopsAudioAndMicrophoneButDefersHermesNarrationUntilResume() {
        var state = makeState()
        state.isCallEstablished = true
        state.phase = .assistantSpeaking
        state.activeResponseId = "resp_1"

        let pauseEffects = SessionReducer.reduce(&state, .pauseVoiceRequested)
        XCTAssertEqual(state.voiceMode, .paused)
        XCTAssertEqual(pauseEffects, [
            .setMicrophoneEnabled(false),
            .sendClientEvent(.responseCancel(responseId: "resp_1")),
            .sendClientEvent(.outputAudioBufferClear),
        ])

        let completed = makeTask(id: "task_1", status: .completed, summary: "Briefing ready")
        let updateEffects = SessionReducer.reduce(&state, .taskUpdated(completed))
        XCTAssertTrue(updateEffects.isEmpty)
        XCTAssertTrue(state.hasDeferredResponse)

        let resumeEffects = SessionReducer.reduce(&state, .resumeVoiceRequested)
        XCTAssertEqual(state.voiceMode, .active)
        XCTAssertEqual(resumeEffects.first, .setMicrophoneEnabled(true))
        XCTAssertEqual(resumeEffects.last, .sendClientEvent(.responseCreate))
        XCTAssertFalse(state.hasDeferredResponse)
    }

    func testRealtimeStopEventsEncodeExactWebRTCProtocolShapes() {
        let cancel = RealtimeClientEvent.responseCancel(responseId: "resp_1").toJSONObject()
        XCTAssertEqual(cancel["type"] as? String, "response.cancel")
        XCTAssertEqual(cancel["response_id"] as? String, "resp_1")
        XCTAssertEqual(RealtimeClientEvent.outputAudioBufferClear.toJSONObject()["type"] as? String, "output_audio_buffer.clear")
    }

    func testSessionUpdateUsesSpeakerphoneTolerantVADWithoutDroppingVoice() throws {
        let clientEvent = RealtimeClientEvent.sessionUpdate(
            instructions: "test",
            tools: [],
            voice: "marin"
        )
        let event = clientEvent.toJSONObject()

        let session = try XCTUnwrap(event["session"] as? [String: Any])
        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        let input = try XCTUnwrap(audio["input"] as? [String: Any])
        let turnDetection = try XCTUnwrap(input["turn_detection"] as? [String: Any])
        let output = try XCTUnwrap(audio["output"] as? [String: Any])

        XCTAssertEqual(turnDetection["type"] as? String, "server_vad")
        XCTAssertEqual(turnDetection["threshold"] as? NSDecimalNumber, NSDecimalNumber(string: "0.7"))
        XCTAssertEqual(turnDetection["prefix_padding_ms"] as? Int, 300)
        XCTAssertEqual(turnDetection["silence_duration_ms"] as? Int, 700)
        XCTAssertEqual(turnDetection["create_response"] as? Bool, true)
        XCTAssertEqual(turnDetection["interrupt_response"] as? Bool, true)
        XCTAssertEqual(output["voice"] as? String, "marin")

        let encoded = String(decoding: clientEvent.toData(), as: UTF8.self)
        XCTAssertTrue(encoded.contains(#""threshold":0.7"#))
        XCTAssertFalse(encoded.contains("0.69999999999999996"))
    }

    func testSpeechStartedDuringActiveResponseLogsPossibleEcho() {
        var state = makeState()
        state.phase = .thinking
        state.activeResponseId = "resp_1"

        let effects = SessionReducer.reduce(&state, .wire(.inputAudioBufferSpeechStarted))

        XCTAssertEqual(state.phase, .userSpeaking)
        XCTAssertEqual(effects, [
            .log("realtime speech_started interrupted active response resp_1; possible user barge-in or speaker echo"),
        ])
    }

    func testToolExecutionFailedProducesValidJSONEvenWithAwkwardCharactersInTheMessage() {
        // Regression test: this used to be hand-built as
        // "{\"error\":\"\(message)\"}" with no escaping, which produced
        // invalid JSON for any message containing a quote, backslash, or
        // control character. It's JSONEncoder-serialized now.
        var state = makeState()
        state.pendingToolCalls = [PendingToolCall(callId: "call_1", name: "x", argumentsJSON: "{}")]
        let trickyMessage = "boom: \"quoted\", \\backslash\\, and a\nnewline"

        let effects = SessionReducer.reduce(&state, .toolExecutionFailed(callId: "call_1", message: trickyMessage))

        guard case let .sendClientEvent(.functionCallOutput(callId, outputJSON)) = effects[0] else {
            return XCTFail("expected the first effect to be a functionCallOutput, got \(effects)")
        }
        XCTAssertEqual(callId, "call_1")
        let data = Data(outputJSON.utf8)
        let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        XCTAssertEqual(decoded?["error"], trickyMessage, "output must be valid, round-trippable JSON")
        XCTAssertEqual(effects[1], .sendClientEvent(.responseCreate))
    }

    func testTransportDisconnectedWhileActiveSchedulesReconnectWithBackoff() {
        var state = makeState()
        state.phase = .listening
        state.reconnectAttempt = 0

        let effects = SessionReducer.reduce(&state, .transportDisconnected(reason: "network blip"))

        XCTAssertEqual(state.phase, .reconnecting)
        XCTAssertEqual(state.reconnectAttempt, 1)
        XCTAssertTrue(effects.contains(.scheduleReconnect(after: 1.0)))
    }

    func testTransportDisconnectedWhileIdleDoesNothing() {
        var state = makeState()
        state.phase = .idle
        let effects = SessionReducer.reduce(&state, .transportDisconnected(reason: nil))
        XCTAssertEqual(effects, [])
        XCTAssertEqual(state.phase, .idle)
    }

    func testBackoffDelayCapsAtThirtySeconds() {
        XCTAssertEqual(SessionReducer.backoffDelay(forAttempt: 0), 1)
        XCTAssertEqual(SessionReducer.backoffDelay(forAttempt: 3), 8)
        XCTAssertEqual(SessionReducer.backoffDelay(forAttempt: 10), 30)
    }

    func testHermesSessionAssignedRecordsTheServerAssignedId() {
        var state = makeState()
        XCTAssertEqual(state.hermesSessionId, "")
        let effects = SessionReducer.reduce(&state, .hermesSessionAssigned("hs_abc123"))
        XCTAssertEqual(state.hermesSessionId, "hs_abc123")
        XCTAssertEqual(effects, [])
    }

    func testTaskUpdatedMergesIntoStateByTaskId() {
        var state = makeState()
        let task = HermesTask(
            id: "task_1", hermesSessionId: "hs_test", status: .running, instruction: "x",
            summary: nil, progress: nil, result: nil, error: nil, pendingApproval: nil,
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z", history: []
        )
        let effects = SessionReducer.reduce(&state, .taskUpdated(task))
        XCTAssertEqual(state.tasks["task_1"], task)
        XCTAssertEqual(effects, [], "no narration before the Realtime call is established")
    }

    func testTaskUpdatedNarratesCompletionOnceCallIsLive() {
        var state = makeState()
        state.isCallEstablished = true
        state.phase = .listening
        let task = HermesTask(
            id: "task_1", hermesSessionId: "hs_test", status: .completed, instruction: "book a table",
            summary: "Table for 2 at 7pm", progress: nil, result: nil, error: nil, pendingApproval: nil,
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:01Z", history: []
        )
        let effects = SessionReducer.reduce(&state, .taskUpdated(task))
        XCTAssertEqual(effects.count, 2)
        guard case let .sendClientEvent(first) = effects[0],
              case let .conversationMessage(role, text) = first else {
            return XCTFail("expected conversationMessage effect")
        }
        XCTAssertEqual(role, "user")
        XCTAssertTrue(text.contains("Table for 2 at 7pm"))
        XCTAssertEqual(effects[1], .sendClientEvent(.responseCreate))

        let again = SessionReducer.reduce(&state, .taskUpdated(task))
        XCTAssertEqual(again, [], "identical fingerprint must not re-narrate")
    }

    func testInstructionsWithTaskRecapListsActiveTasks() {
        let task = HermesTask(
            id: "task_1", hermesSessionId: "hs_test", status: .running, instruction: "book a table",
            summary: nil, progress: HermesTaskProgress(percent: 50, message: "calling restaurant"),
            result: nil, error: nil, pendingApproval: nil,
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:01Z", history: []
        )
        let text = SessionState.instructionsWithTaskRecap(base: "base", tasks: [task])
        XCTAssertTrue(text.contains("1 Hermes task is in flight"))
        XCTAssertTrue(text.contains("book a table"))
        XCTAssertTrue(text.contains("calling restaurant"))
    }

    func testErrorEventTransitionsToFailed() {
        var state = makeState()
        _ = SessionReducer.reduce(&state, .wire(.errorEvent(message: "boom")))
        XCTAssertEqual(state.phase, .failed("boom"))
        XCTAssertEqual(state.lastError, "boom")
    }


    private func makeTask(
        id: String,
        status: HermesTaskStatus,
        clientRequestId: String? = nil,
        summary: String? = nil
    ) -> HermesTask {
        HermesTask(
            id: id,
            hermesSessionId: "hs_test",
            status: status,
            instruction: "do it",
            clientRequestId: clientRequestId,
            summary: summary,
            progress: nil,
            result: nil,
            error: nil,
            pendingApproval: nil,
            createdAt: "2026-01-01T00:00:00Z",
            updatedAt: "2026-01-01T00:00:01Z",
            history: []
        )
    }
}
