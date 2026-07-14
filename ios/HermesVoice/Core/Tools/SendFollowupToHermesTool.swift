import Foundation

struct SendFollowupToHermesTool: HermesTool {
    let name = "send_followup_to_hermes"

    var definition: RealtimeToolDefinition {
        RealtimeToolDefinition(
            name: name,
            description: "Send additional information or a clarification to a task Hermes is already working on.",
            parametersJSON: [
                "type": "object",
                "properties": [
                    "taskId": ["type": "string"],
                    "message": ["type": "string"],
                ],
                "required": ["taskId", "message"],
            ]
        )
    }

    func execute(callId: String, argumentsJSON: String, backend: BackendClientProtocol, sessionToken: String) async throws -> String {
        let args = try decodeArguments(argumentsJSON)
        guard let taskId = args["taskId"] as? String, !taskId.isEmpty else {
            throw ToolError.invalidArguments("send_followup_to_hermes requires taskId")
        }
        guard let message = args["message"] as? String, !message.isEmpty else {
            throw ToolError.invalidArguments("send_followup_to_hermes requires message")
        }
        let task = try await backend.followup(sessionToken: sessionToken, taskId: taskId, message: message)
        return encodeSummary(task)
    }
}
