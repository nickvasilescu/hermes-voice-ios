import Foundation

struct GetHermesTaskStatusTool: HermesTool {
    let name = "get_hermes_task_status"

    var definition: RealtimeToolDefinition {
        RealtimeToolDefinition(
            name: name,
            description: "Check on a previously delegated Hermes task.",
            parametersJSON: [
                "type": "object",
                "properties": ["taskId": ["type": "string"]],
                "required": ["taskId"],
            ]
        )
    }

    func execute(callId: String, argumentsJSON: String, backend: BackendClientProtocol, sessionToken: String) async throws -> HermesToolExecutionResult {
        let args = try decodeArguments(argumentsJSON)
        guard let taskId = args["taskId"] as? String, !taskId.isEmpty else {
            throw ToolError.invalidArguments("get_hermes_task_status requires taskId")
        }
        let task = try await backend.getTask(sessionToken: sessionToken, taskId: taskId)
        return encodeResult(task)
    }
}
