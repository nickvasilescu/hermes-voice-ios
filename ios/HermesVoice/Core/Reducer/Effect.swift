import Foundation

/// Everything the reducer wants done to the outside world. The reducer
/// itself never performs I/O — `HermesVoiceStore` (the imperative shell)
/// interprets these. Keeping this list closed and small is what makes the
/// reducer testable without a network or a WebRTC stack. [IMPLEMENTED]
///
/// Note what is deliberately NOT here: minting a credential, connecting a
/// transport, and scheduling rotation. Those are `SessionCoordinator`'s
/// job end-to-end (see its doc comment) — the reducer only ever hears
/// "connected" or "disconnected, please reconnect after this backoff,"
/// never the mechanics of how a connection is established or rotated.
enum Effect: Equatable {
    case sendClientEvent(RealtimeClientEvent)
    case executeTool(callId: String, name: String, argumentsJSON: String)
    case scheduleReconnect(after: TimeInterval)
    case log(String)
}

/// Inputs to the reducer: raw Realtime wire events (post-handshake — see
/// `SessionCoordinator`, which consumes `session.created`/`session.updated`
/// itself and never forwards them here), plus app-level lifecycle events
/// (bridge task updates, transport state) that also need to move the state
/// machine.
enum SessionEvent: Equatable {
    case wire(RealtimeServerEvent)
    case taskUpdated(HermesTask)
    /// Fired once, right after `ClientSessionManager` bootstraps. Purely
    /// informational state (see `SessionState.hermesSessionId`) — no
    /// effects.
    case hermesSessionAssigned(String)
    /// A call (initial or post-rotation) is up and ready. Idempotent to
    /// receive more than once — a successful rotation fires this again but
    /// conversation phase is already `.listening`, so it's a no-op past
    /// the first time.
    case callEstablished
    case callEstablishmentFailed(String)
    case transportDisconnected(reason: String?)
    case toolResultReady(callId: String, outputJSON: String)
    case toolExecutionFailed(callId: String, message: String)
}
