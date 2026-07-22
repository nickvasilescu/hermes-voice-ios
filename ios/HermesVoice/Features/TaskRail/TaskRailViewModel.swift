import Foundation

enum TaskActivityState: Equatable {
    case sending
    case queued
    case running
    case waitingApproval
    case completed
    case failed
    case canceled
}

struct TaskActivityItem: Equatable, Identifiable {
    var id: String
    var instruction: String
    var state: TaskActivityState
    var detail: String?
    var progressPercent: Double?
}

/// Combines optimistic delegations with authoritative bridge tasks. The
/// reducer removes a pending row by `clientRequestId` as soon as REST or SSE
/// returns its real task, so this adapter never has to guess by instruction.
struct TaskRailViewModel {
    let items: [TaskActivityItem]

    init(tasks: [HermesTask], pendingDelegations: [PendingDelegation] = []) {
        let pendingItems = pendingDelegations
            .sorted { $0.createdAt > $1.createdAt }
            .map { pending in
                switch pending.status {
                case .sending:
                    return TaskActivityItem(
                        id: "pending:\(pending.callId)",
                        instruction: pending.instruction,
                        state: .sending,
                        detail: "Sending to Hermes…",
                        progressPercent: nil
                    )
                case let .failed(message):
                    return TaskActivityItem(
                        id: "pending:\(pending.callId)",
                        instruction: pending.instruction,
                        state: .failed,
                        detail: message,
                        progressPercent: nil
                    )
                }
            }

        let taskItems = tasks.map { task in
            TaskActivityItem(
                id: task.id,
                instruction: task.instruction,
                state: TaskActivityState(task.status),
                detail: task.pendingApproval?.action
                    ?? task.progress?.message
                    ?? task.summary
                    ?? task.error?.message,
                progressPercent: task.progress?.percent
            )
        }
        items = pendingItems + taskItems
    }

    var activeCount: Int {
        items.filter { item in
            switch item.state {
            case .sending, .queued, .running, .waitingApproval: return true
            case .completed, .failed, .canceled: return false
            }
        }.count
    }
}

private extension TaskActivityState {
    init(_ status: HermesTaskStatus) {
        switch status {
        case .queued: self = .queued
        case .running: self = .running
        case .waitingApproval: self = .waitingApproval
        case .completed: self = .completed
        case .failed: self = .failed
        case .canceled: self = .canceled
        }
    }
}

extension TaskActivityState {
    var displayLabel: String {
        switch self {
        case .sending: return "Sending"
        case .queued: return "Queued"
        case .running: return "Running"
        case .waitingApproval: return "Needs approval"
        case .completed: return "Done"
        case .failed: return "Failed"
        case .canceled: return "Canceled"
        }
    }
}
