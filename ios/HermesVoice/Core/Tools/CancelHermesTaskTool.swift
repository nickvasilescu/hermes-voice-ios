import Foundation

struct CancelHermesTaskTool: HermesTool {
    let name = "cancel_hermes_task"

    var definition: RealtimeToolDefinition {
        RealtimeToolDefinition(
            name: name,
            description: "Cancel a Hermes task the user no longer wants performed.",
            parametersJSON: [
                "type": "object",
                "properties": [
                    "taskId": ["type": "string"],
                    "reason": ["type": "string"],
                ],
                "required": ["taskId"],
            ]
        )
    }

    func execute(callId: String, argumentsJSON: String, backend: BackendClientProtocol, sessionToken: String) async throws -> String {
        let args = try decodeArguments(argumentsJSON)
        guard let taskId = args["taskId"] as? String, !taskId.isEmpty else {
            throw ToolError.invalidArguments("cancel_hermes_task requires taskId")
        }
        let task = try await backend.cancel(sessionToken: sessionToken, taskId: taskId, reason: args["reason"] as? String)
        return encodeSummary(task)
    }
}
