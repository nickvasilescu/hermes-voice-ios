import SwiftUI

/// Persistent task activity surface. It is intentionally visible even before
/// the first task so delegation never feels like work disappeared into a
/// hidden rail.
struct TaskRailView: View {
    let viewModel: TaskRailViewModel
    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.items.count > 2 {
                Button {
                    withAnimation(.snappy) { isExpanded.toggle() }
                } label: {
                    activityHeader
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Collapse activity" : "Expand activity")
            } else {
                activityHeader
            }

            Divider().opacity(0.5)

            if viewModel.items.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "waveform.badge.mic")
                        .foregroundStyle(.secondary)
                    Text("Tasks you delegate will appear here immediately.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(16)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visibleItems) { item in
                            TaskActivityRow(item: item)
                            if item.id != visibleItems.last?.id { Divider().padding(.leading, 48) }
                        }
                    }
                }
                .frame(maxHeight: isExpanded ? 290 : 154)
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        }
        .padding(.horizontal, 16)
    }

    private var visibleItems: [TaskActivityItem] {
        isExpanded ? viewModel.items : Array(viewModel.items.prefix(2))
    }

    private var activityHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "list.bullet.clipboard")
                .foregroundStyle(.secondary)
            Text("Activity")
                .font(.headline)
            if viewModel.activeCount > 0 {
                Text("\(viewModel.activeCount)")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.blue.opacity(0.22), in: Capsule())
                    .foregroundStyle(.blue)
            }
            Spacer()
            if viewModel.items.count > 2 {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .padding(16)
    }
}

private struct TaskActivityRow: View {
    let item: TaskActivityItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbolName)
                .font(.body.weight(.semibold))
                .foregroundStyle(statusColor)
                .frame(width: 24, height: 24)
                .symbolEffect(.pulse, options: .repeating, isActive: item.state == .sending || item.state == .running)

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.instruction)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                    Spacer(minLength: 6)
                    Text(item.state.displayLabel)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(statusColor)
                }

                if let detail = item.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if let percent = item.progressPercent {
                    ProgressView(value: max(0, min(percent, 100)), total: 100)
                        .tint(statusColor)
                        .accessibilityLabel("\(Int(percent)) percent complete")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.instruction), \(item.state.displayLabel)\(item.detail.map { ", \($0)" } ?? "")")
    }

    private var symbolName: String {
        switch item.state {
        case .sending: return "arrow.up.circle.fill"
        case .queued: return "clock.fill"
        case .running: return "gearshape.2.fill"
        case .waitingApproval: return "exclamationmark.shield.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .canceled: return "minus.circle.fill"
        }
    }

    private var statusColor: Color {
        switch item.state {
        case .sending, .queued, .running: return .blue
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
    ], pendingDelegations: [
        PendingDelegation(callId: "call_2", instruction: "Prepare tomorrow's briefing")
    ]))
    .padding(.vertical)
    .background(Color.black)
}
