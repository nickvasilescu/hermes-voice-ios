import Foundation

/// A compact projection of `HermesTask` sent back to the Realtime model as
/// a tool result. Deliberately smaller than the full `HermesTask` (no
/// `history`) — the model needs enough to narrate, not the whole audit
/// trail, and every token here is spoken-conversation latency.
struct HermesTaskSummary: Codable {
    var taskId: String
    var status: HermesTaskStatus
    var summary: String?
    var progress: HermesTaskProgress?
    var pendingApproval: HermesPendingApproval?
    var error: HermesTaskError?

    init(task: HermesTask) {
        taskId = task.id
        status = task.status
        summary = task.summary
        progress = task.progress
        pendingApproval = task.pendingApproval
        error = task.error
    }
}

enum ToolError: Error {
    case invalidArguments(String)
}

/// One of the five Realtime-facing tools. Each implementation is a thin
/// translation from Realtime function-call arguments to a `BackendClient`
/// call — see docs/PROTOCOL.md §3 for the exact schema each `definition`
/// must match. [IMPLEMENTED]
///
/// `Sendable`: every conformance is a stateless struct (see the five
/// `*Tool` types), so this is trivially, provably safe to share across
/// concurrency domains — `ToolRegistry.allTools` is a `static let` array of
/// these existentials.
protocol HermesTool: Sendable {
    var name: String { get }
    var definition: RealtimeToolDefinition { get }
    /// `sessionToken` is supplied by the caller (`ToolRegistry.execute`,
    /// ultimately `HermesVoiceStore`) from `ClientSessionManager` — never a
    /// Realtime-model-controlled argument, same rule as the old
    /// `hermesSessionId` (see CLAUDE.md "Non-negotiables").
    func execute(callId: String, argumentsJSON: String, backend: BackendClientProtocol, sessionToken: String) async throws -> String
}

extension HermesTool {
    /// Realtime function-call arguments always arrive as a JSON *object*
    /// string; this centralizes the boilerplate of turning that into a
    /// `[String: Any]` every tool needs.
    func decodeArguments(_ json: String) throws -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw ToolError.invalidArguments(json)
        }
        return object
    }

    func encodeSummary(_ task: HermesTask) -> String {
        let summary = HermesTaskSummary(task: task)
        let data = (try? JSONEncoder().encode(summary)) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
