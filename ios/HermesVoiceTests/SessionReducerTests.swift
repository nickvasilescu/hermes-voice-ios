import XCTest
@testable import HermesVoice

/// Pure reducer tests — no networking, no WebRTC, no XCUIApplication.
/// NOTE: this repo was built in a Linux environment without Xcode or a
/// Swift toolchain, so these tests are written but have not been compiled
/// or run here. Run with `xcodebuild test -scheme HermesVoice` (or in
/// Xcode) before relying on them. See CLAUDE.md.
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

        let effects = SessionReducer.reduce(&state, .toolResultReady(callId: "call_1", outputJSON: "{\"ok\":true}"))

        XCTAssertTrue(state.pendingToolCalls.isEmpty)
        XCTAssertEqual(effects, [
            .sendClientEvent(.functionCallOutput(callId: "call_1", outputJSON: "{\"ok\":true}")),
            .sendClientEvent(.responseCreate),
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
        _ = SessionReducer.reduce(&state, .taskUpdated(task))
        XCTAssertEqual(state.tasks["task_1"], task)
    }

    func testErrorEventTransitionsToFailed() {
        var state = makeState()
        _ = SessionReducer.reduce(&state, .wire(.errorEvent(message: "boom")))
        XCTAssertEqual(state.phase, .failed("boom"))
        XCTAssertEqual(state.lastError, "boom")
    }
}
