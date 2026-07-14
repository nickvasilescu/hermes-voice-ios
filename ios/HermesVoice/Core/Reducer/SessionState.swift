import Foundation

/// Where the app is in the conversation turn-taking cycle. Realtime (not
/// Hermes) drives every transition here — see docs/PROTOCOL.md §1.
enum ConversationPhase: Equatable {
    case idle
    case connecting
    case listening
    case userSpeaking
    case thinking
    case assistantSpeaking
    case reconnecting
    case failed(String)
}

struct PendingToolCall: Equatable, Identifiable {
    var id: String { callId }
    var callId: String
    var name: String
    var argumentsJSON: String
}

/// Everything the pure reducer needs to decide what happens next. This is
/// deliberately Foundation-only (Date, no UIKit/SwiftUI/networking types),
/// so it's usable from a plain `swift test` target once Xcode is available.
/// [IMPLEMENTED]
struct SessionState: Equatable {
    var phase: ConversationPhase = .idle
    /// Server-assigned (see docs/PROTOCOL.md §2) — set once via
    /// `.hermesSessionAssigned` after `ClientSessionManager` bootstraps.
    /// Empty string before that; nothing round-trips it back to the
    /// server, it exists here purely for display/logging.
    var hermesSessionId: String = ""
    var isCallEstablished: Bool = false
    var pendingToolCalls: [PendingToolCall] = []
    var tasks: [String: HermesTask] = [:]
    var lastAssistantTranscript: String = ""
    var lastError: String?
    var reconnectAttempt: Int = 0

    /// Bounded record of `call_id`s already dispatched to a tool, so a
    /// duplicate `response.function_call_arguments.done` delivery (a
    /// Realtime retry, a reconnect replaying a buffered event, etc.) is
    /// not executed twice — across all five tools uniformly, since dedup
    /// happens here before dispatch-by-name. Capped rather than growing
    /// forever for the lifetime of a long conversation.
    private(set) var seenCallIds: [String] = []
    private static let maxTrackedCallIds = 200

    /// Static session configuration the reducer needs; set once at store
    /// construction, never mutated by the reducer itself.
    var systemInstructions: String
    var toolDefinitions: [RealtimeToolDefinition]
    var voice: String?

    init(
        systemInstructions: String = SessionState.defaultInstructions,
        toolDefinitions: [RealtimeToolDefinition] = ToolRegistry.realtimeToolDefinitions,
        voice: String? = "marin"
    ) {
        self.systemInstructions = systemInstructions
        self.toolDefinitions = toolDefinitions
        self.voice = voice
    }

    var sortedTasks: [HermesTask] {
        tasks.values.sorted { $0.createdAt > $1.createdAt }
    }

    /// Returns `true` (and records the id) the first time this `callId` is
    /// seen; `false` on any repeat.
    mutating func markCallIdSeenIfNew(_ callId: String) -> Bool {
        guard !seenCallIds.contains(callId) else { return false }
        seenCallIds.append(callId)
        if seenCallIds.count > Self.maxTrackedCallIds {
            seenCallIds.removeFirst(seenCallIds.count - Self.maxTrackedCallIds)
        }
        return true
    }

    static let defaultInstructions = """
    You are the voice of Hermes. You handle the live conversation, speech, \
    and turn-taking yourself. For any durable task, memory lookup, or \
    side-effecting action, delegate to Hermes with delegate_to_hermes \
    rather than trying to do it yourself. Long Hermes tasks run in the \
    background: acknowledge the delegation, keep talking naturally, and \
    narrate progress/completion when it arrives. Always read back a \
    pending approval and get an explicit yes/no before calling \
    approve_hermes_action.
    """
}
