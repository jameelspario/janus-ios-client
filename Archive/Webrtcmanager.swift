//
//  Webrtcmanager.swift
//  janus-test
//
//  Created by jameel on 03/03/26.
//

// WebRTCManager.swift
// Manages WebRTC peer connections, media tracks, and ICE negotiation

import Foundation
import WebRTC

// MARK: - WebRTC Configuration
struct WebRTCConfiguration {
    static let defaultIceServers: [RTCIceServer] = [
        RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"]),
        RTCIceServer(urlStrings: ["stun:stun1.l.google.com:19302"])
    ]

    static func makeConfiguration(iceServers: [RTCIceServer] = defaultIceServers) -> RTCConfiguration {
        let config = RTCConfiguration()
        config.iceServers = iceServers
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        config.continualGatheringPolicy = .gatherContinually
        return config
    }
}

// MARK: - Media Constraints
struct MediaConstraints {
    static let offerConstraints: RTCMediaConstraints = RTCMediaConstraints(
        mandatoryConstraints: [
            kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueFalse,
            kRTCMediaConstraintsOfferToReceiveVideo: kRTCMediaConstraintsValueFalse
        ],
        optionalConstraints: nil
    )

    static let answerConstraints: RTCMediaConstraints = RTCMediaConstraints(
        mandatoryConstraints: nil,
        optionalConstraints: nil
    )
}

// MARK: - WebRTC Delegate
protocol WebRTCManagerDelegate: AnyObject {
    func webRTCManager(_ manager: WebRTCManager, didGenerateCandidate candidate: RTCIceCandidate, handleId: Int64)
    func webRTCManager(_ manager: WebRTCManager, didChangeConnectionState state: RTCIceConnectionState, handleId: Int64)
    func webRTCManager(_ manager: WebRTCManager, didReceiveRemoteTrack track: RTCVideoTrack, handleId: Int64)
    func webRTCManager(_ manager: WebRTCManager, didRemoveRemoteTrack handleId: Int64)
}

// MARK: - WebRTCManager
final class WebRTCManager: NSObject {

    // MARK: - Properties
    private let factory: RTCPeerConnectionFactory
    private var peerConnections: [Int64: RTCPeerConnection] = [:]
    private var localVideoTrack: RTCVideoTrack?
    private var localAudioTrack: RTCAudioTrack?
    private var videoCapturer: RTCCameraVideoCapturer?
    private var videoSource: RTCVideoSource?
    private let mediaQueue = DispatchQueue(label: "com.webrtc.media")

    weak var delegate: WebRTCManagerDelegate?

    // MARK: - Init
    override init() {
        RTCInitializeSSL()
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        factory = RTCPeerConnectionFactory(encoderFactory: encoderFactory, decoderFactory: decoderFactory)
        super.init()
    }

    deinit {
        RTCCleanupSSL()
    }

    // MARK: - Peer Connection Lifecycle
    func createPeerConnection(handleId: Int64, iceServers: [RTCIceServer] = WebRTCConfiguration.defaultIceServers) -> RTCPeerConnection? {
        let config = WebRTCConfiguration.makeConfiguration(iceServers: iceServers)
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: self) else { return nil }
        mediaQueue.async(flags: .barrier) { self.peerConnections[handleId] = pc }
        return pc
    }

    func removePeerConnection(handleId: Int64) {
        mediaQueue.async(flags: .barrier) {
            self.peerConnections[handleId]?.close()
            self.peerConnections.removeValue(forKey: handleId)
        }
    }

    func peerConnection(for handleId: Int64) -> RTCPeerConnection? {
        mediaQueue.sync { peerConnections[handleId] }
    }

    // MARK: - Local Media
    func setupLocalMedia(enableVideo: Bool = true, enableAudio: Bool = true) {
        if enableVideo { setupLocalVideo() }
        if enableAudio { setupLocalAudio() }
    }

    private func setupLocalVideo() {
        videoSource = factory.videoSource()
        guard let videoSource = videoSource else { return }
        videoCapturer = RTCCameraVideoCapturer(delegate: videoSource)
        localVideoTrack = factory.videoTrack(with: videoSource, trackId: "local_video_\(UUID().uuidString)")
    }

    private func setupLocalAudio() {
        let audioConstraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let audioSource = factory.audioSource(with: audioConstraints)
        localAudioTrack = factory.audioTrack(with: audioSource, trackId: "local_audio_\(UUID().uuidString)")
    }

    func addLocalTracks(to peerConnection: RTCPeerConnection) {
        let streamId = "local_stream_\(UUID().uuidString)"
        if let videoTrack = localVideoTrack {
            peerConnection.add(videoTrack, streamIds: [streamId])
        }
        if let audioTrack = localAudioTrack {
            peerConnection.add(audioTrack, streamIds: [streamId])
        }
    }

    // MARK: - Camera Control
    func startCapture(position: AVCaptureDevice.Position = .front,
                      videoFormat: AVCaptureDevice.Format? = nil,
                      fps: Int = 30) {
        guard
            let capturer = videoCapturer,
            let device = RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == position })
        else { return }

        let format = videoFormat ?? selectBestFormat(for: device)
        let fps = selectFPS(for: format, target: fps)
        capturer.startCapture(with: device, format: format, fps: fps)
    }

    func stopCapture() {
        videoCapturer?.stopCapture()
    }

    func switchCamera() {
        guard let capturer = videoCapturer else { return }
        let devices = RTCCameraVideoCapturer.captureDevices()
        guard devices.count > 1 else { return }
        // Toggle between front/back
        let current = capturer.captureSession.inputs
            .compactMap { $0 as? AVCaptureDeviceInput }
            .first?.device

        let next = devices.first { $0.uniqueID != current?.uniqueID }
        if let next = next {
            let format = selectBestFormat(for: next)
            let fps = selectFPS(for: format, target: 30)
            capturer.startCapture(with: next, format: format, fps: fps)
        }
    }

    // MARK: - Mute Controls
    func setLocalVideoEnabled(_ enabled: Bool) {
        localVideoTrack?.isEnabled = enabled
    }

    func setLocalAudioEnabled(_ enabled: Bool) {
        localAudioTrack?.isEnabled = enabled
    }

    var localVideoTrackRef: RTCVideoTrack? { localVideoTrack }
    var isVideoEnabled: Bool { localVideoTrack?.isEnabled ?? false }
    var isAudioEnabled: Bool { localAudioTrack?.isEnabled ?? false }

    // MARK: - SDP Offer/Answer
    func createOffer(for handleId: Int64) async throws -> RTCSessionDescription {
        guard let pc = peerConnection(for: handleId) else {
            throw JanusError.invalidResponse
        }
        return try await withCheckedThrowingContinuation { continuation in
            pc.offer(for: MediaConstraints.offerConstraints) { sdp, error in
                if let error = error { continuation.resume(throwing: error); return }
                guard let sdp = sdp else { continuation.resume(throwing: JanusError.invalidResponse); return }
                continuation.resume(returning: sdp)
            }
        }
    }

    func createAnswer(for handleId: Int64) async throws -> RTCSessionDescription {
        guard let pc = peerConnection(for: handleId) else {
            throw JanusError.invalidResponse
        }
        return try await withCheckedThrowingContinuation { continuation in
            pc.answer(for: MediaConstraints.answerConstraints) { sdp, error in
                if let error = error { continuation.resume(throwing: error); return }
                guard let sdp = sdp else { continuation.resume(throwing: JanusError.invalidResponse); return }
                continuation.resume(returning: sdp)
            }
        }
    }

    func setLocalDescription(_ sdp: RTCSessionDescription, for handleId: Int64) async throws {
        guard let pc = peerConnection(for: handleId) else { throw JanusError.invalidResponse }
        return try await withCheckedThrowingContinuation { continuation in
            pc.setLocalDescription(sdp) { error in
                if let error = error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            }
        }
    }

    func setRemoteDescription(_ sdpDict: [String: Any], for handleId: Int64) async throws {
        guard
            let pc = peerConnection(for: handleId),
            let type = sdpDict["type"] as? String,
            let sdpStr = sdpDict["sdp"] as? String,
            let sdpType = RTCSdpType.type(for: type)
        else { throw JanusError.invalidResponse }

        let sdp = RTCSessionDescription(type: sdpType, sdp: sdpStr)
        return try await withCheckedThrowingContinuation { continuation in
            pc.setRemoteDescription(sdp) { error in
                if let error = error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            }
        }
    }

    func addIceCandidate(_ candidateDict: [String: Any], for handleId: Int64) {
        guard
            let pc = peerConnection(for: handleId),
            let sdp = candidateDict["candidate"] as? String,
            let sdpMid = candidateDict["sdpMid"] as? String,
            let sdpMLineIndex = candidateDict["sdpMLineIndex"] as? Int32
        else { return }

        let candidate = RTCIceCandidate(sdp: sdp, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
        pc.add(candidate)
    }

    // MARK: - Format Helpers
    private func selectBestFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format {
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        let target = CMVideoDimensions(width: 1280, height: 720)
        return formats.min(by: {
            let d0 = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            let d1 = CMVideoFormatDescriptionGetDimensions($1.formatDescription)
            let diff0 = abs(d0.width - target.width) + abs(d0.height - target.height)
            let diff1 = abs(d1.width - target.width) + abs(d1.height - target.height)
            return diff0 < diff1
        }) ?? formats.last!
    }

    private func selectFPS(for format: AVCaptureDevice.Format, target: Int) -> Int {
        let maxFPS = format.videoSupportedFrameRateRanges
            .map { Int($0.maxFrameRate) }
            .max() ?? 30
        return min(maxFPS, target)
    }
}

// MARK: - RTCPeerConnectionDelegate
extension WebRTCManager: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let handleId = mediaQueue.sync {
            peerConnections.first(where: { $0.value === peerConnection })?.key ?? 0
        }
        guard handleId != 0 else { return }
        delegate?.webRTCManager(self, didGenerateCandidate: candidate, handleId: handleId)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        let handleId = mediaQueue.sync {
            peerConnections.first(where: { $0.value === peerConnection })?.key ?? 0
        }
        guard handleId != 0 else { return }
        delegate?.webRTCManager(self, didChangeConnectionState: newState, handleId: handleId)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        let handleId = mediaQueue.sync {
            peerConnections.first(where: { $0.value === peerConnection })?.key ?? 0
        }
        guard handleId != 0 else { return }
        if let videoTrack = stream.videoTracks.first {
            delegate?.webRTCManager(self, didReceiveRemoteTrack: videoTrack, handleId: handleId)
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        let handleId = mediaQueue.sync {
            peerConnections.first(where: { $0.value === peerConnection })?.key ?? 0
        }
        guard handleId != 0 else { return }
        delegate?.webRTCManager(self, didRemoveRemoteTrack: handleId)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

// MARK: - RTCSdpType Extension
extension RTCSdpType {
    static func type(for string: String) -> RTCSdpType? {
        switch string {
        case "offer": return .offer
        case "answer": return .answer
        case "pranswer": return .prAnswer
        case "rollback": return .rollback
        default: return nil
        }
    }

    var stringValue: String {
        switch self {
        case .offer: return "offer"
        case .answer: return "answer"
        case .prAnswer: return "pranswer"
        case .rollback: return "rollback"
        @unknown default: return "offer"
        }
    }
}
