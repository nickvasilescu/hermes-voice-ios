import Foundation

#if canImport(WebRTC)
import WebRTC

/// Concrete `WebRTCEngine` backed by the Stasel WebRTC xcframework
/// (https://github.com/stasel/WebRTC). All libwebrtc callbacks are hopped
/// onto the main actor before invoking the protocol slots.
@MainActor
final class StaselWebRTCEngine: NSObject, WebRTCEngine {
    var onDataChannelMessage: ((Data) -> Void)?
    var onDataChannelOpen: (() -> Void)?
    var onConnectionStateChange: ((TransportConnectionState) -> Void)?

    private let factory: RTCPeerConnectionFactory
    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?
    private var localAudioTrack: RTCAudioTrack?

    override init() {
        RTCInitializeSSL()
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        self.factory = RTCPeerConnectionFactory(encoderFactory: encoderFactory, decoderFactory: decoderFactory)
        super.init()
    }

    func createPeerConnection() throws {
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        // OpenAI Realtime typically works with host candidates; STUN helps
        // on restrictive NATs without requiring a TURN secret in-app.
        config.iceServers = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            throw WebRTCTransportError.sdpExchangeFailed(status: -1, detail: "failed to create peer connection")
        }
        peerConnection = pc
        onConnectionStateChange?(.connecting)
    }

    func addLocalAudioTrack() throws {
        guard let peerConnection else {
            throw WebRTCTransportError.notConnected
        }
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "true",
                "OfferToReceiveVideo": "false",
            ],
            optionalConstraints: nil
        )
        let audioSource = factory.audioSource(with: constraints)
        let track = factory.audioTrack(with: audioSource, trackId: "hermes-audio")
        localAudioTrack = track
        peerConnection.add(track, streamIds: ["hermes-stream"])
    }

    func createDataChannel(label: String) throws {
        guard let peerConnection else {
            throw WebRTCTransportError.notConnected
        }
        let config = RTCDataChannelConfiguration()
        config.isOrdered = true
        guard let channel = peerConnection.dataChannel(forLabel: label, configuration: config) else {
            throw WebRTCTransportError.sdpExchangeFailed(status: -1, detail: "failed to create data channel \(label)")
        }
        channel.delegate = self
        dataChannel = channel
    }

    func createOffer() async throws -> String {
        guard let peerConnection else { throw WebRTCTransportError.notConnected }
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "true",
                "OfferToReceiveVideo": "false",
            ],
            optionalConstraints: nil
        )
        return try await withCheckedThrowingContinuation { continuation in
            peerConnection.offer(for: constraints) { sdp, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let sdp else {
                    continuation.resume(throwing: WebRTCTransportError.invalidSDPAnswer)
                    return
                }
                continuation.resume(returning: sdp.sdp)
            }
        }
    }

    func setLocalDescription(sdp: String) async throws {
        guard let peerConnection else { throw WebRTCTransportError.notConnected }
        let description = RTCSessionDescription(type: .offer, sdp: sdp)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peerConnection.setLocalDescription(description) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func setRemoteDescription(sdp: String) async throws {
        guard let peerConnection else { throw WebRTCTransportError.notConnected }
        let description = RTCSessionDescription(type: .answer, sdp: sdp)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peerConnection.setRemoteDescription(description) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func sendOnDataChannel(_ data: Data) throws {
        guard let dataChannel, dataChannel.readyState == .open else {
            throw WebRTCTransportError.notConnected
        }
        let buffer = RTCDataBuffer(data: data, isBinary: false)
        guard dataChannel.sendData(buffer) else {
            throw WebRTCTransportError.sdpExchangeFailed(status: -1, detail: "data channel send failed")
        }
    }

    func close() {
        dataChannel?.close()
        dataChannel = nil
        peerConnection?.close()
        peerConnection = nil
        localAudioTrack = nil
        onConnectionStateChange?(.disconnected)
    }
}

extension StaselWebRTCEngine: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        Task { @MainActor in
            switch newState {
            case .connecting, .new:
                self.onConnectionStateChange?(.connecting)
            case .connected:
                self.onConnectionStateChange?(.connected)
            case .disconnected:
                self.onConnectionStateChange?(.disconnected)
            case .failed:
                self.onConnectionStateChange?(.failed("peer connection failed"))
            case .closed:
                self.onConnectionStateChange?(.disconnected)
            @unknown default:
                break
            }
        }
    }
}

extension StaselWebRTCEngine: RTCDataChannelDelegate {
    nonisolated func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        Task { @MainActor in
            if dataChannel.readyState == .open {
                self.onDataChannelOpen?()
            }
        }
    }

    nonisolated func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        let data = buffer.data
        Task { @MainActor in
            self.onDataChannelMessage?(data)
        }
    }
}
#endif

/// Factory used by the app / previews. Returns a real Stasel engine when the
/// WebRTC package is linked; otherwise `nil` (signaling still works in tests
/// with a fake transport).
@MainActor
func makeWebRTCEngine() -> WebRTCEngine? {
    #if canImport(WebRTC)
    return StaselWebRTCEngine()
    #else
    return nil
    #endif
}
