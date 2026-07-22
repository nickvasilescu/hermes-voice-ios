import XCTest
@testable import HermesVoice

final class ToolRegistryTests: XCTestCase {
    func testExactlyFiveToolsAreRegistered() {
        XCTAssertEqual(ToolRegistry.allTools.count, 5)
        XCTAssertEqual(Set(ToolRegistry.allTools.map(\.name)), [
            "delegate_to_hermes",
            "get_hermes_task_status",
            "send_followup_to_hermes",
            "cancel_hermes_task",
            "approve_hermes_action",
        ])
    }

    func testToolLookupByName() {
        XCTAssertTrue(ToolRegistry.tool(named: "delegate_to_hermes") is DelegateToHermesTool)
        XCTAssertNil(ToolRegistry.tool(named: "not_a_real_tool"))
    }

    func testToolDefinitionsExplainTheTaskThreadBoundary() {
        XCTAssertTrue(DelegateToHermesTool().definition.description.contains("new, independent"))
        XCTAssertTrue(SendFollowupToHermesTool().definition.description.contains("same objective"))
        XCTAssertTrue(SendFollowupToHermesTool().definition.description.contains("same Hermes conversation"))
    }

    func testDelegateToHermesUsesCallIdAsIdempotencyKey() async throws {
        let backend = FakeBackendClient()
        _ = try await ToolRegistry.execute(
            name: "delegate_to_hermes",
            callId: "call_abc",
            argumentsJSON: "{\"instruction\":\"book a table\"}",
            backend: backend,
            sessionToken: "st_test"
        )
        let lastInstruction = await backend.lastInstruction
        let lastClientRequestId = await backend.lastClientRequestId
        let lastSessionToken = await backend.lastSessionToken
        XCTAssertEqual(lastClientRequestId, "call_abc")
        XCTAssertEqual(lastInstruction, "book a table")
        XCTAssertEqual(lastSessionToken, "st_test")
    }

    func testDelegateToHermesRejectsMissingInstruction() async {
        let backend = FakeBackendClient()
        do {
            _ = try await ToolRegistry.execute(name: "delegate_to_hermes", callId: "call_1", argumentsJSON: "{}", backend: backend, sessionToken: "st_test")
            XCTFail("expected invalidArguments")
        } catch ToolError.invalidArguments {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testApproveHermesActionRejectsInvalidDecision() async {
        let backend = FakeBackendClient()
        do {
            _ = try await ToolRegistry.execute(
                name: "approve_hermes_action",
                callId: "call_1",
                argumentsJSON: "{\"taskId\":\"task_1\",\"approvalId\":\"appr_1\",\"decision\":\"maybe\"}",
                backend: backend,
                sessionToken: "st_test"
            )
            XCTFail("expected invalidArguments")
        } catch ToolError.invalidArguments {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testGetHermesTaskStatusReturnsCompactSummaryJSON() async throws {
        let backend = FakeBackendClient()
        let result = try await ToolRegistry.execute(
            name: "get_hermes_task_status",
            callId: "call_1",
            argumentsJSON: "{\"taskId\":\"task_1\"}",
            backend: backend,
            sessionToken: "st_test"
        )
        XCTAssertTrue(result.outputJSON.contains("\"taskId\":\"task_1\""))
        XCTAssertFalse(result.outputJSON.contains("history"), "tool output should be the compact summary, not the full task with history")
        XCTAssertEqual(result.task.id, "task_1", "the local UI should receive the authoritative task alongside compact model JSON")
    }

    func testUnknownToolNameThrows() async {
        let backend = FakeBackendClient()
        do {
            _ = try await ToolRegistry.execute(name: "delete_everything", callId: "call_1", argumentsJSON: "{}", backend: backend, sessionToken: "st_test")
            XCTFail("expected invalidArguments for an unregistered tool name")
        } catch ToolError.invalidArguments {
            // expected — see CLAUDE.md "keep the five tools exactly five"
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

/// An actor, not a class with plain `var`s: `BackendClientProtocol`
/// requires `Sendable`, and this test double's mutable state is read back
/// from the test method after the tool call completes — an actor makes
/// that provably race-free with no `@unchecked Sendable` needed, the same
/// reasoning as the real `BackendClient`.
private actor FakeBackendClient: BackendClientProtocol {
    private(set) var lastInstruction: String?
    private(set) var lastClientRequestId: String?
    private(set) var lastSessionToken: String?

    func bootstrapSession(bootstrapCredential: String?) async throws -> MintedClientSession {
        MintedClientSession(sessionToken: "st_fake", hermesSessionId: "hs_fake", expiresAt: "2026-01-01T00:00:00Z")
    }

    func mintRealtimeSession(sessionToken: String, voice: String?) async throws -> RealtimeSessionResponse {
        fatalError("not exercised in ToolRegistryTests")
    }

    func createTask(sessionToken: String, instruction: String, context: [String: AnyCodable]?, clientRequestId: String?) async throws -> HermesTask {
        lastInstruction = instruction
        lastClientRequestId = clientRequestId
        lastSessionToken = sessionToken
        return Self.fixtureTask(id: "task_1", instruction: instruction)
    }

    func getTask(sessionToken: String, taskId: String) async throws -> HermesTask {
        lastSessionToken = sessionToken
        return Self.fixtureTask(id: taskId, instruction: "x")
    }

    func listTasks(sessionToken: String, status: HermesTaskStatus?) async throws -> [HermesTask] { [] }

    func followup(sessionToken: String, taskId: String, message: String) async throws -> HermesTask {
        Self.fixtureTask(id: taskId, instruction: "x")
    }

    func cancel(sessionToken: String, taskId: String, reason: String?) async throws -> HermesTask {
        var task = Self.fixtureTask(id: taskId, instruction: "x")
        task.status = .canceled
        return task
    }

    func approve(sessionToken: String, taskId: String, approvalId: String, decision: ApprovalDecision, note: String?) async throws -> HermesTask {
        Self.fixtureTask(id: taskId, instruction: "x")
    }

    static func fixtureTask(id: String, instruction: String) -> HermesTask {
        HermesTask(
            id: id, hermesSessionId: "hs_test", status: .queued, instruction: instruction,
            summary: nil, progress: nil, result: nil, error: nil, pendingApproval: nil,
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
            history: [HermesTaskHistoryEntry(at: "2026-01-01T00:00:00Z", kind: "created", message: "Task created.")]
        )
    }
}
