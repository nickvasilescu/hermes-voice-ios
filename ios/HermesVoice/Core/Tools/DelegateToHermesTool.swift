import Foundation

struct DelegateToHermesTool: HermesTool {
    let name = "delegate_to_hermes"

    var definition: RealtimeToolDefinition {
        RealtimeToolDefinition(
            name: name,
            description: "Hand a durable task off to Hermes. Returns immediately with a task id; Hermes works asynchronously and reports progress/completion via task status updates that the app narrates back to you.",
            parametersJSON: [
                "type": "object",
                "properties": [
                    "instruction": ["type": "string", "description": "What Hermes should do, in natural language."],
                    "context": ["type": "object", "description": "Optional structured context (e.g. extracted entities, prior task ids to reference)."],
                ],
                "required": ["instruction"],
            ]
        )
    }

    func execute(callId: String, argumentsJSON: String, backend: BackendClientProtocol, sessionToken: String) async throws -> String {
        let args = try decodeArguments(argumentsJSON)
        guard let instruction = args["instruction"] as? String, !instruction.isEmpty else {
            throw ToolError.invalidArguments("delegate_to_hermes requires a non-empty instruction")
        }
        let context = (args["context"] as? [String: Any]).map { dict in
            dict.mapValues { AnyCodable($0) }
        }
        // Using the Realtime call_id as the idempotency key ties bridge-side
        // dedupe (PROTOCOL.md §2 clientRequestId) directly to Realtime's own
        // retry semantics: if the same function call is ever replayed, the
        // bridge returns the original task instead of spawning a duplicate.
        // (SessionReducer also dedupes by call_id before this ever runs —
        // this is defense in depth, not the only guard.)
        let task = try await backend.createTask(sessionToken: sessionToken, instruction: instruction, context: context, clientRequestId: callId)
        return encodeSummary(task)
    }
}
