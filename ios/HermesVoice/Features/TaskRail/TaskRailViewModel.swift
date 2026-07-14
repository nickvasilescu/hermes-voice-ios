import Foundation

/// Thin presentation adapter over `SessionState.tasks` — no networking of
/// its own, so it's trivially previewable/testable with fixture data.
/// [IMPLEMENTED]
struct TaskRailViewModel {
    let tasks: [HermesTask]

    init(tasks: [HermesTask]) {
        self.tasks = tasks
    }

    var isEmpty: Bool { tasks.isEmpty }
}

extension HermesTaskStatus {
    var displayLabel: String {
        switch self {
        case .queued: return "Queued"
        case .running: return "Running"
        case .waitingApproval: return "Needs approval"
        case .completed: return "Done"
        case .failed: return "Failed"
        case .canceled: return "Canceled"
        }
    }
}
