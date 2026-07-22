#if DEBUG
import Foundation

extension SessionState {
    /// Deterministic, network-free state used only to capture public README
    /// screenshots from the real SwiftUI hierarchy. Production builds do not
    /// compile this helper.
    static func readmeDemo(paused: Bool) -> SessionState {
        var state = SessionState()
        state.phase = paused ? .listening : .assistantSpeaking
        state.voiceMode = paused ? .paused : .active
        state.activeResponseId = paused ? nil : "demo_response"
        state.isCallEstablished = true
        state.hermesSessionId = "demo_session"

        let running = HermesTask(
            id: "demo_running",
            hermesSessionId: "demo_session",
            hermesThreadId: "demo_thread_running",
            status: .running,
            instruction: "Find the best nonstop flight for Friday",
            summary: nil,
            progress: HermesTaskProgress(percent: 62, message: "Comparing three good options"),
            result: nil,
            error: nil,
            pendingApproval: nil,
            createdAt: "2026-07-21T16:00:00Z",
            updatedAt: "2026-07-21T16:02:00Z",
            history: []
        )
        let approval = HermesTask(
            id: "demo_approval",
            hermesSessionId: "demo_session",
            hermesThreadId: "demo_thread_approval",
            status: .waitingApproval,
            instruction: "Send the project update to the team",
            summary: nil,
            progress: nil,
            result: nil,
            error: nil,
            pendingApproval: HermesPendingApproval(
                approvalId: "demo_approval_id",
                action: "Send the drafted message",
                details: nil,
                requestedAt: "2026-07-21T15:59:00Z"
            ),
            createdAt: "2026-07-21T15:58:00Z",
            updatedAt: "2026-07-21T16:01:00Z",
            history: []
        )
        let completed = HermesTask(
            id: "demo_completed",
            hermesSessionId: "demo_session",
            hermesThreadId: "demo_thread_completed",
            status: .completed,
            instruction: "Prepare tomorrow's briefing",
            summary: "Briefing ready",
            progress: nil,
            result: nil,
            error: nil,
            pendingApproval: nil,
            createdAt: "2026-07-21T15:30:00Z",
            updatedAt: "2026-07-21T15:45:00Z",
            history: []
        )
        state.tasks = [running.id: running, approval.id: approval, completed.id: completed]
        return state
    }
}
#endif
