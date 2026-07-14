import Foundation

/// Holds live session instructions for `SessionCoordinator` handshakes /
/// rotations. The store weakly attaches itself so each `session.update`
/// can include the PROTOCOL.md §6 task-rail recap without the coordinator
/// owning `SessionState`.
@MainActor
final class SessionInstructionsHolder {
    let base: String
    weak var store: HermesVoiceStore?

    init(base: String = SessionState.defaultInstructions) {
        self.base = base
    }

    func current() -> String {
        SessionState.instructionsWithTaskRecap(base: base, tasks: store?.state.sortedTasks ?? [])
    }
}
