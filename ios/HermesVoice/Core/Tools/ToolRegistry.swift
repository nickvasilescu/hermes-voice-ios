import Foundation

/// The complete, closed set of five tools exposed to Realtime. Do not add a
/// sixth here as a convenience — extend one of the five or push the
/// capability into Hermes itself (see CLAUDE.md "Non-negotiables").
/// [IMPLEMENTED]
enum ToolRegistry {
    static let allTools: [HermesTool] = [
        DelegateToHermesTool(),
        GetHermesTaskStatusTool(),
        SendFollowupToHermesTool(),
        CancelHermesTaskTool(),
        ApproveHermesActionTool(),
    ]

    static let realtimeToolDefinitions: [RealtimeToolDefinition] = allTools.map(\.definition)

    private static let byName: [String: HermesTool] = Dictionary(
        uniqueKeysWithValues: allTools.map { ($0.name, $0) }
    )

    static func tool(named name: String) -> HermesTool? {
        byName[name]
    }

    /// `hermesSessionId` is never passed here because it is never a
    /// model-visible parameter — it's resolved server-side from
    /// `sessionToken`, which itself comes from `ClientSessionManager` /
    /// app state, never from Realtime function arguments. See CLAUDE.md
    /// "Non-negotiables". Duplicate `call_id` delivery is guarded upstream
    /// by `SessionReducer` (see its `seenCallIds` handling) — this function
    /// assumes it is only ever invoked once per `call_id`.
    static func execute(name: String, callId: String, argumentsJSON: String, backend: BackendClientProtocol, sessionToken: String) async throws -> String {
        guard let tool = tool(named: name) else {
            throw ToolError.invalidArguments("unknown tool: \(name)")
        }
        return try await tool.execute(callId: callId, argumentsJSON: argumentsJSON, backend: backend, sessionToken: sessionToken)
    }
}
