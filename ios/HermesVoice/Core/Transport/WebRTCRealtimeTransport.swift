import Foundation

/// The minimal surface `WebRTCRealtimeTransport` needs from a WebRTC
/// engine: create a peer connection with one audio track and one data
/// channel, do local/remote SDP description exchange, and hand back
/// data-channel messages/state. This is intentionally *not* Google's
/// `RTCPeerConnection` API directly — it's a narrow protocol so the engine
/// itself (libwebrtc via a binary xcframework, e.g.
/// https://github.com/stasel/WebRTC) can be swapped in without touching
/// anything above this file.
///
/// [IMPLEMENTED] via `StaselWebRTCEngine` (Stasel WebRTC SPM package).
/// Tests and previews may still inject `nil` / a fake transport; production
/// wiring uses `makeWebRTCEngine()`.
///
/// `@MainActor`: a real implementation's callbacks (`onDataChannelMessage`,
/// `onDataChannelOpen`, `onConnectionStateChange`) will fire from
/// libwebrtc's own internal threads — the implementation is responsible
/// for hopping back to the main actor (e.g. `Task { @MainActor in ... }`)
/// before invoking them, so that everything above this protocol boundary
/// can stay simply, provably main-actor-confined instead of reaching for
/// `@unchecked Sendable` to paper over cross-thread callback delivery.
@MainActor
protocol WebRTCEngine: AnyObject {
    func createPeerConnection() throws
    func addLocalAudioTrack() throws
    func createDataChannel(label: String) throws
    func createOffer() async throws -> String // SDP
    func setLocalDescription(sdp: String) async throws
    func setRemoteDescription(sdp: String) async throws
    func sendOnDataChannel(_ data: Data) throws
    func close()

    var onDataChannelMessage: ((Data) -> Void)? { get set }
    var onDataChannelOpen: (() -> Void)? { get set }
    var onConnectionStateChange: ((TransportConnectionState) -> Void)? { get set }
}

enum WebRTCTransportError: Error {
    case noEngineConfigured
    case sdpExchangeFailed(status: Int, detail: String?)
    case notConnected
    case credentialExpired
    case invalidSDPAnswer
}

/// Concrete `RealtimeTransport`. The parts that are genuinely implemented
/// here: minting-credential handling, the HTTPS SDP offer/answer exchange
/// against OpenAI's Realtime **calls** API
/// (`POST https://api.openai.com/v1/realtime/calls`, `Content-Type:
/// application/sdp`, `Authorization: Bearer <ephemeral client secret>`,
/// body = local SDP offer, response body = remote SDP answer — the model
/// is already bound to the ephemeral credential from `bridge/`'s
/// `POST /v1/realtime/session`, so it is not repeated as a query parameter
/// here), and translating data-channel bytes to/from
/// `RealtimeServerEvent`/`RealtimeClientEvent`. An earlier version of this
/// file called the legacy `GET/POST /v1/realtime?model=...` SDP endpoint;
/// that shape is no longer current and has been replaced.
///
/// What's NOT implemented: the actual `WebRTCEngine` — see that protocol's
/// doc comment. Without one injected, `connect(with:)` throws
/// `.noEngineConfigured` rather than silently pretending to work.
/// [SCAFFOLDED at the binary level, IMPLEMENTED at the signaling level]
/// `@unchecked Sendable`: this class is `@MainActor`-isolated, and every
/// stored/mutable property (`callId`, the two callback slots inherited
/// from the protocol) is only ever read or written while isolated to the
/// main actor — that isolation IS the proof of safety `@unchecked Sendable`
/// asks for. This is needed because `SessionCoordinator` passes transport
/// instances through `Task`/`TaskGroup` APIs that require `Sendable`
/// operations even though, in practice, every hop stays on the main actor.
@MainActor
final class WebRTCRealtimeTransport: RealtimeTransport, @unchecked Sendable {
    var onServerEvent: ((RealtimeServerEvent) -> Void)?
    var onConnectionStateChange: ((TransportConnectionState) -> Void)?

    /// The `call_id` OpenAI returns for this call, when present (used by a
    /// future explicit hangup via `DELETE /v1/realtime/calls/{call_id}` —
    /// not implemented here; today teardown is just closing the peer
    /// connection locally, see `disconnect()`).
    private(set) var callId: String?

    private let engine: WebRTCEngine?
    private let session: URLSession
    private let callsEndpoint: URL

    init(
        engine: WebRTCEngine?,
        session: URLSession = .shared,
        callsEndpoint: URL = URL(string: "https://api.openai.com/v1/realtime/calls")!
    ) {
        self.engine = engine
        self.session = session
        self.callsEndpoint = callsEndpoint
    }

    func connect(with credential: RealtimeCredential) async throws {
        guard let engine else { throw WebRTCTransportError.noEngineConfigured }
        guard credential.connectDeadline > Date() else { throw WebRTCTransportError.credentialExpired }

        engine.onConnectionStateChange = { [weak self] state in
            self?.onConnectionStateChange?(state)
        }
        engine.onDataChannelMessage = { [weak self] data in
            guard let event = RealtimeServerEvent.decode(fromData: data) else { return }
            self?.onServerEvent?(event)
        }

        try engine.createPeerConnection()
        try engine.addLocalAudioTrack()
        try engine.createDataChannel(label: "oai-events")

        let offerSDP = try await engine.createOffer()
        guard credential.connectDeadline > Date() else { throw WebRTCTransportError.credentialExpired }
        try await engine.setLocalDescription(sdp: offerSDP)

        let answerSDP = try await exchangeSDP(offer: offerSDP, credential: credential)
        guard credential.connectDeadline > Date() else { throw WebRTCTransportError.credentialExpired }
        try await engine.setRemoteDescription(sdp: answerSDP)
    }

    func send(_ event: RealtimeClientEvent) throws {
        guard let engine else { throw WebRTCTransportError.notConnected }
        try engine.sendOnDataChannel(event.toData())
    }

    func disconnect() async {
        engine?.close()
    }

    private func exchangeSDP(offer: String, credential: RealtimeCredential) async throws -> String {
        guard credential.connectDeadline > Date() else { throw WebRTCTransportError.credentialExpired }
        var request = URLRequest(url: callsEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/sdp", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(credential.clientSecret)", forHTTPHeaderField: "authorization")
        request.httpBody = Data(offer.utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw WebRTCTransportError.sdpExchangeFailed(status: status, detail: String(data: data, encoding: .utf8))
        }
        guard credential.connectDeadline > Date() else { throw WebRTCTransportError.credentialExpired }
        guard let answer = String(data: data, encoding: .utf8), !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WebRTCTransportError.invalidSDPAnswer
        }
        callId = http.value(forHTTPHeaderField: "Location")?.split(separator: "/").last.map(String.init)
        return answer
    }
}
