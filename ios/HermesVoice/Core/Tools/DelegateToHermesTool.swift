import Foundation

struct DelegateToHermesTool: HermesTool {
    let name = "delegate_to_hermes"

    var definition: RealtimeToolDefinition {
        RealtimeToolDefinition(
            name: name,
            description: "Start a new, independent durable objective in Hermes. Use this for unrelated work, not to add information or corrections to an existing task; use send_followup_to_hermes for those. Returns immediately with a task id while Hermes works asynchronously.",
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

    func execute(callId: String, argumentsJSON: String, backend: BackendClientProtocol, sessionToken: String) async throws -> HermesToolExecutionResult {
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
        return encodeResult(task)
    }
}
