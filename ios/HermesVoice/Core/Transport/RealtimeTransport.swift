import Foundation

struct RealtimeCredential: Equatable, Sendable {
    var sessionId: String
    var clientSecret: String
    var model: String
    /// Deadline for *establishing* the connection — OpenAI ephemeral
    /// client secrets are short-lived. This is NOT the call's lifetime;
    /// see `SessionCoordinator.callLifetimeSeconds` for that. Conflating
    /// the two was a real bug in an earlier version of this file: rotating
    /// based on credential expiry would fire far too early or too late
    /// relative to when the call actually needs to rotate for OpenAI's
    /// ~60-minute Realtime session cap.
    var connectDeadline: Date
}

enum TransportConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case failed(String)
}

/// The seam between the reducer/coordinator layer and an actual WebRTC
/// engine. This protocol is real and is what `SessionCoordinator` codes
/// against; `WebRTCRealtimeTransport` is the concrete boundary — see its
/// doc comment for exactly what is and isn't wired up. [SCAFFOLDED at the
/// binary level, IMPLEMENTED at the protocol/signaling level]
///
/// `@MainActor`-isolated: every conforming type (`WebRTCRealtimeTransport`)
/// and its only caller (`SessionCoordinator`) live on the main actor, and
/// the mutable `onServerEvent`/`onConnectionStateChange` callback slots are
/// exactly the kind of shared mutable state that needs single-threaded
/// confinement rather than an `@unchecked Sendable` promise. A real
/// `WebRTCEngine` conformance backed by a WebRTC library must hop back to
/// the main actor before invoking its own callbacks, since libwebrtc calls
/// back on its own threads — that requirement is called out again on
/// `WebRTCEngine` itself.
@MainActor
protocol RealtimeTransport: AnyObject, Sendable {
    var onServerEvent: ((RealtimeServerEvent) -> Void)? { get set }
    var onConnectionStateChange: ((TransportConnectionState) -> Void)? { get set }

    func connect(with credential: RealtimeCredential) async throws
    func send(_ event: RealtimeClientEvent) throws
    func disconnect() async
}
