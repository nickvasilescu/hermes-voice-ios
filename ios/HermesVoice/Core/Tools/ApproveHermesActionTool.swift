import Foundation

struct ApproveHermesActionTool: HermesTool {
    let name = "approve_hermes_action"

    var definition: RealtimeToolDefinition {
        RealtimeToolDefinition(
            name: name,
            description: "Approve or reject a sensitive action Hermes has paused on (e.g. before sending an email or spending money). Only call this after reading the pending approval back to the user and getting an explicit yes/no.",
            parametersJSON: [
                "type": "object",
                "properties": [
                    "taskId": ["type": "string"],
                    "approvalId": ["type": "string"],
                    "decision": ["type": "string", "enum": ["approve", "reject"]],
                    "note": ["type": "string"],
                ],
                "required": ["taskId", "approvalId", "decision"],
            ]
        )
    }

    func execute(callId: String, argumentsJSON: String, backend: BackendClientProtocol, sessionToken: String) async throws -> String {
        let args = try decodeArguments(argumentsJSON)
        guard let taskId = args["taskId"] as? String, !taskId.isEmpty else {
            throw ToolError.invalidArguments("approve_hermes_action requires taskId")
        }
        guard let approvalId = args["approvalId"] as? String, !approvalId.isEmpty else {
            throw ToolError.invalidArguments("approve_hermes_action requires approvalId")
        }
        guard let decisionRaw = args["decision"] as? String, let decision = ApprovalDecision(rawValue: decisionRaw) else {
            throw ToolError.invalidArguments("approve_hermes_action requires decision to be 'approve' or 'reject'")
        }
        let task = try await backend.approve(sessionToken: sessionToken, taskId: taskId, approvalId: approvalId, decision: decision, note: args["note"] as? String)
        return encodeSummary(task)
    }
}
