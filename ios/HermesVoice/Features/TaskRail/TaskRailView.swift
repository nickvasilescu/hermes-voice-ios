import SwiftUI

/// Horizontal rail of in-flight/recent Hermes tasks, secondary to the orb.
/// Tapping a card is a stand-in for a detail sheet (not implemented in this
/// MVP — see docs/ARCHITECTURE.md "Known limitations"). [IMPLEMENTED]
struct TaskRailView: View {
    let viewModel: TaskRailViewModel

    var body: some View {
        if viewModel.isEmpty {
            EmptyView()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(viewModel.tasks) { task in
                        TaskCard(task: task)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

private struct TaskCard: View {
    let task: HermesTask

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(task.instruction)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .foregroundStyle(.primary)

            Text(task.status.displayLabel)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(statusColor.opacity(0.18), in: Capsule())
                .foregroundStyle(statusColor)

            if let message = task.progress?.message {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .frame(width: 200, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var statusColor: Color {
        switch task.status {
        case .queued, .running: return .blue
        case .waitingApproval: return .orange
        case .completed: return .green
        case .failed: return .red
        case .canceled: return .gray
        }
    }
}

#Preview {
    TaskRailView(viewModel: TaskRailViewModel(tasks: [
        HermesTask(
            id: "task_1", hermesSessionId: "sess_1", status: .running,
            instruction: "Book a table for two at 7pm", summary: nil,
            progress: HermesTaskProgress(percent: 40, message: "Checking availability…"),
            result: nil, error: nil, pendingApproval: nil,
            createdAt: "", updatedAt: "", history: []
        ),
    ]))
    .padding()
}
