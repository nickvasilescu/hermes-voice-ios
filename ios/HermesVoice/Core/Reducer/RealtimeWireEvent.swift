import Foundation

/// Raw OpenAI Realtime protocol messages exchanged over the WebRTC data
/// channel (`oai-events`). [IMPLEMENTED] as a deliberately partial,
/// hand-decoded subset — just what this app's reducer needs to drive turn-
/// taking, barge-in, and the five tool calls. Anything else arrives as
/// `.unknown(type:)` and is ignored rather than crashing on an unrecognized
/// shape (the full event set is large and evolves with the API).
enum RealtimeServerEvent: Equatable, Sendable {
    case sessionCreated(sessionId: String)
    case sessionUpdated
    case inputAudioBufferSpeechStarted
    case inputAudioBufferSpeechStopped
    case responseCreated(responseId: String)
    case functionCallArgumentsDone(callId: String, name: String, argumentsJSON: String)
    case responseAudioTranscriptDelta(text: String)
    case responseDone
    case errorEvent(message: String)
    case unknown(type: String)

    static func decode(fromJSONObject object: [String: Any]) -> RealtimeServerEvent {
        guard let type = object["type"] as? String else { return .unknown(type: "?") }
        switch type {
        case "session.created":
            let sessionId = (object["session"] as? [String: Any])?["id"] as? String ?? ""
            return .sessionCreated(sessionId: sessionId)
        case "session.updated":
            return .sessionUpdated
        case "input_audio_buffer.speech_started":
            return .inputAudioBufferSpeechStarted
        case "input_audio_buffer.speech_stopped":
            return .inputAudioBufferSpeechStopped
        case "response.created":
            let responseId = (object["response"] as? [String: Any])?["id"] as? String ?? ""
            return .responseCreated(responseId: responseId)
        case "response.function_call_arguments.done":
            let callId = object["call_id"] as? String ?? ""
            let name = object["name"] as? String ?? ""
            let arguments = object["arguments"] as? String ?? "{}"
            return .functionCallArgumentsDone(callId: callId, name: name, argumentsJSON: arguments)
        case "response.audio_transcript.delta":
            return .responseAudioTranscriptDelta(text: object["delta"] as? String ?? "")
        case "response.done":
            return .responseDone
        case "error":
            let message = (object["error"] as? [String: Any])?["message"] as? String ?? "unknown realtime error"
            return .errorEvent(message: message)
        default:
            return .unknown(type: type)
        }
    }

    static func decode(fromData data: Data) -> RealtimeServerEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return decode(fromJSONObject: object)
    }
}

/// Tools registered on the session, encoded exactly per docs/PROTOCOL.md §3.
///
/// `@unchecked Sendable`: `parametersJSON` is typed `[String: Any]` because
/// Swift has no first-class JSON Schema type, but every value in it is a
/// literal (String/Bool/[String: Any]/[Any]) constructed fresh inside each
/// tool's `definition` computed property and never mutated afterward — no
/// reference types ever go in here, so sharing an already-built instance
/// across threads is safe.
struct RealtimeToolDefinition: Equatable, @unchecked Sendable {
    var name: String
    var description: String
    /// A JSON Schema object (already `[String: Any]`-shaped), kept opaque
    /// here since Swift has no first-class JSON Schema type.
    var parametersJSON: [String: Any]

    static func == (lhs: RealtimeToolDefinition, rhs: RealtimeToolDefinition) -> Bool {
        lhs.name == rhs.name && lhs.description == rhs.description
    }
}

enum RealtimeClientEvent: Equatable, @unchecked Sendable {
    case sessionUpdate(instructions: String, tools: [RealtimeToolDefinition], voice: String?)
    case functionCallOutput(callId: String, outputJSON: String)
    case responseCreate

    func toJSONObject() -> [String: Any] {
        switch self {
        case let .sessionUpdate(instructions, tools, voice):
            var session: [String: Any] = [
                "type": "realtime",
                "instructions": instructions,
                "tools": tools.map { tool in
                    [
                        "type": "function",
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.parametersJSON,
                    ] as [String: Any]
                },
            ]
            if let voice {
                session["audio"] = ["output": ["voice": voice]]
            }
            return ["type": "session.update", "session": session]
        case let .functionCallOutput(callId, outputJSON):
            return [
                "type": "conversation.item.create",
                "item": [
                    "type": "function_call_output",
                    "call_id": callId,
                    "output": outputJSON,
                ],
            ]
        case .responseCreate:
            return ["type": "response.create"]
        }
    }

    func toData() -> Data {
        (try? JSONSerialization.data(withJSONObject: toJSONObject())) ?? Data()
    }

    static func == (lhs: RealtimeClientEvent, rhs: RealtimeClientEvent) -> Bool {
        NSDictionary(dictionary: lhs.toJSONObject()).isEqual(to: rhs.toJSONObject())
    }
}
