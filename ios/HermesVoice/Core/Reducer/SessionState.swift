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

/// Voice capture/output is independent from Hermes task execution. Pausing
/// voice must leave REST, SSE, and tool work running in the background.
enum VoiceMode: Equatable {
    case active
    case paused
}

struct PendingToolCall: Equatable, Identifiable {
    var id: String { callId }
    var callId: String
    var name: String
    var argumentsJSON: String
}

enum PendingDelegationStatus: Equatable {
    case sending
    case failed(String)
}

/// Optimistic task activity created as soon as Realtime delegates work. It
/// is replaced by the authoritative Task returned by REST or SSE.
struct PendingDelegation: Equatable, Identifiable {
    var id: String { callId }
    var callId: String
    var instruction: String
    var status: PendingDelegationStatus = .sending
    var createdAt: Date = Date()
}

/// Everything the pure reducer needs to decide what happens next. This is
/// deliberately Foundation-only (Date, no UIKit/SwiftUI/networking types),
/// so it's usable from a plain `swift test` target once Xcode is available.
/// [IMPLEMENTED]
struct SessionState: Equatable {
    var phase: ConversationPhase = .idle
    var voiceMode: VoiceMode = .active
    var activeResponseId: String?
    /// Server-assigned (see docs/PROTOCOL.md §2) — set once via
    /// `.hermesSessionAssigned` after `ClientSessionManager` bootstraps.
    /// Empty string before that; nothing round-trips it back to the
    /// server, it exists here purely for display/logging.
    var hermesSessionId: String = ""
    var isCallEstablished: Bool = false
    var pendingToolCalls: [PendingToolCall] = []
    var pendingDelegations: [String: PendingDelegation] = [:]
    var tasks: [String: HermesTask] = [:]
    /// Fingerprint of the last Hermes update we already asked Realtime to
    /// narrate, keyed by task id — prevents duplicate speech on SSE replay
    /// or identical progress ticks.
    var lastNarratedFingerprints: [String: String] = [:]
    var lastAssistantTranscript: String = ""
    var hasDeferredResponse: Bool = false
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

    /// In-flight / approval tasks for rotation recap (PROTOCOL.md §6).
    var activeTasksForRecap: [HermesTask] {
        sortedTasks.filter { !$0.status.isTerminal }
    }

    /// A bounded, factual recap injected on resume when tool/task updates
    /// arrived while speech was paused.
    var deferredResponsePrompt: String {
        let recent = sortedTasks.prefix(5)
        guard !recent.isEmpty else {
            return "Voice output was paused while work continued. Resume briefly, using any pending tool result, and then listen."
        }
        let lines = recent.map { task in
            let detail = task.progress?.message ?? task.summary ?? task.error?.message ?? task.status.rawValue
            return "- \(task.instruction): \(task.status.rawValue) — \(detail)"
        }
        return "Voice output was paused while Hermes kept working. Briefly summarize only the latest relevant changes, then listen:\n"
            + lines.joined(separator: "\n")
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

    /// Appends a short task-rail recap for session.update on (re)connect /
    /// rotation, per PROTOCOL.md §6.
    static func instructionsWithTaskRecap(base: String, tasks: [HermesTask]) -> String {
        let active = tasks.filter { !$0.status.isTerminal }
        guard !active.isEmpty else { return base }
        let lines = active.map { task -> String in
            let progress = task.progress?.message ?? task.summary ?? task.status.rawValue
            return "- \(task.id): \(task.instruction) [\(task.status.rawValue)] \(progress)"
        }
        return base
            + "\n\n\(active.count) Hermes task\(active.count == 1 ? " is" : "s are") in flight. "
            + "Continue the conversation with that context; do not re-ask for details you already have:\n"
            + lines.joined(separator: "\n")
    }

    /// Short prompt injected so Realtime narrates a Hermes update out loud.
    static func narrationPrompt(for task: HermesTask) -> String? {
        switch task.status {
        case .waitingApproval:
            let action = task.pendingApproval?.action ?? "an action"
            return "Hermes needs your approval for \(action) on task \"\(task.instruction)\". Read it back briefly and ask for an explicit yes or no."
        case .completed:
            let summary = task.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = (summary?.isEmpty == false) ? summary! : "Done."
            return "Hermes finished: \(body). Narrate this to the user in one short sentence."
        case .failed:
            let message = task.error?.message ?? "something went wrong"
            return "Hermes failed: \(message). Tell the user briefly."
        case .canceled:
            return "Hermes canceled the task \"\(task.instruction)\". Acknowledge briefly."
        case .running, .queued:
            if let message = task.progress?.message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
                return "Hermes update on \"\(task.instruction)\": \(message). Narrate this briefly if useful; otherwise stay quiet."
            }
            if let summary = task.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
                return "Hermes update on \"\(task.instruction)\": \(summary). Narrate this briefly if useful; otherwise stay quiet."
            }
            return nil
        }
    }

    static func narrationFingerprint(for task: HermesTask) -> String {
        let progress = task.progress?.message ?? ""
        let summary = task.summary ?? ""
        let approval = task.pendingApproval?.approvalId ?? ""
        let error = task.error?.message ?? ""
        return "\(task.status.rawValue)|\(progress)|\(summary)|\(approval)|\(error)|\(task.updatedAt)"
    }

    static let defaultInstructions = """
    You are the voice of Hermes. You handle the live conversation, speech, \
    and turn-taking yourself. For any durable task, memory lookup, or \
    side-effecting action, delegate to Hermes with delegate_to_hermes \
    rather than trying to do it yourself. Start a new task for a new, \
    independent objective. When the user adds information, corrects, or \
    clarifies an existing active task, use send_followup_to_hermes with that \
    task id so the work stays in the same Hermes conversation. Long Hermes \
    tasks run in the background: acknowledge the delegation, keep talking naturally, and \
    narrate progress/completion when it arrives. Always read back a \
    pending approval and get an explicit yes/no before calling \
    approve_hermes_action.
    """
}
