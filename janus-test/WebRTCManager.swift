//
//  WebRTCManager.swift
//  janus-test
//
//  Created by jameel on 03/03/26.
//

// WebRTCManager.swift
// Manages per-handle PeerConnections (publisher + N subscriber connections).
// One instance per room handle pair.

import Foundation
import WebRTC

protocol WebRTCManagerDelegate: AnyObject {
    func webRTCManager(_ manager: WebRTCManager, didGenerateICECandidate candidate: RTCIceCandidate, forHandle handleId: UInt64)
    func webRTCManager(_ manager: WebRTCManager, didProduceOffer sdp: RTCSessionDescription, forHandle handleId: UInt64)
    func webRTCManager(_ manager: WebRTCManager, didProduceAnswer sdp: RTCSessionDescription, forHandle handleId: UInt64)
    func webRTCManager(_ manager: WebRTCManager, didReceiveRemoteTrack track: RTCVideoTrack, forFeedId feedId: UInt64)
    func webRTCManager(_ manager: WebRTCManager, didRemoveRemoteTrack forFeedId: UInt64)
    func webRTCManagerICEConnectionFailed(_ manager: WebRTCManager, handleId: UInt64)
}

final class WebRTCManager: NSObject {

    // MARK: - Public
    weak var delegate: WebRTCManagerDelegate?

    // MARK: - Private
    private let factory: RTCPeerConnectionFactory
    private var peerConnections: [UInt64: RTCPeerConnection] = [:]  // handleId -> PeerConnection
    private var localVideoTrack: RTCVideoTrack?
    private var localAudioTrack: RTCAudioTrack?
    private var capturer: RTCCameraVideoCapturer?
    private var feedIdMap: [UInt64: UInt64] = [:]  // handleId -> feedId (for subscribers)
    private let pcLock = NSLock()

    private static let iceServers: [RTCIceServer] = [
        RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"]),
        RTCIceServer(urlStrings: ["stun:stun1.l.google.com:19302"])
    ]

    // MARK: - Init
    override init() {
        RTCInitializeSSL()
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        factory = RTCPeerConnectionFactory(encoderFactory: encoderFactory, decoderFactory: decoderFactory)
        super.init()
    }

    deinit {
        stopLocalMedia()
        RTCCleanupSSL()
    }

    // MARK: - Local Media
    func startLocalMedia(videoRenderer: RTCVideoRenderer? = nil) {
        let audioSource = factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        localAudioTrack = factory.audioTrack(with: audioSource, trackId: "audio0")

        let videoSource = factory.videoSource()
        

        localVideoTrack = factory.videoTrack(with: videoSource, trackId: "video0")
        if let renderer = videoRenderer {
            localVideoTrack?.addRenderer(renderer)
        }

        #if targetEnvironment(simulator)
            // ✅ Skip capture on simulator — no camera hardware
            print("[WebRTC] Simulator detected, skipping camera capture")
        #else
            capturer = RTCCameraVideoCapturer(delegate: videoSource)
            guard let device = selectFrontCamera() else { return }
            let format = selectBestFormat(for: device)
            let fps = selectBestFPS(for: format)
            capturer?.startCapture(with: device, format: format, fps: fps)
        #endif
    }

    func stopLocalMedia() {
        capturer?.stopCapture()
        capturer = nil
        localVideoTrack = nil
        localAudioTrack = nil
    }

    func setLocalVideoRenderer(_ renderer: RTCVideoRenderer) {
        localVideoTrack?.addRenderer(renderer)
    }

    func setAudioEnabled(_ enabled: Bool) {
        localAudioTrack?.isEnabled = enabled
    }

    func setVideoEnabled(_ enabled: Bool) {
        localVideoTrack?.isEnabled = enabled
        capturer?.captureSession.isRunning == true ? nil : capturer?.stopCapture()
    }

    // MARK: - PeerConnection Lifecycle
    func createPublisherPeerConnection(handleId: UInt64) -> RTCPeerConnection {
        let pc = makePeerConnection(handleId: handleId)
        if let audioTrack = localAudioTrack {
            pc.add(audioTrack, streamIds: ["stream0"])
        }
        if let videoTrack = localVideoTrack {
            pc.add(videoTrack, streamIds: ["stream0"])
        }
        return pc
    }

    func createSubscriberPeerConnection(handleId: UInt64, feedId: UInt64) -> RTCPeerConnection {
        pcLock.lock()
        feedIdMap[handleId] = feedId
        pcLock.unlock()
        return makePeerConnection(handleId: handleId)
    }

    func removePeerConnection(handleId: UInt64) {
        pcLock.lock()
        let pc = peerConnections.removeValue(forKey: handleId)
        feedIdMap.removeValue(forKey: handleId)
        pcLock.unlock()
        pc?.close()
    }

    // MARK: - Offer / Answer
    func createOffer(handleId: UInt64) {
        guard let pc = peerConnections[handleId] else { return }
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "false",
                "OfferToReceiveVideo": "false"
            ],
            optionalConstraints: nil
        )
        pc.offer(for: constraints) { [weak self] sdp, error in
            guard let self, let sdp else { return }
            pc.setLocalDescription(sdp) { _ in
                self.delegate?.webRTCManager(self, didProduceOffer: sdp, forHandle: handleId)
            }
        }
    }

    func createAnswer(handleId: UInt64) {
        guard let pc = peerConnections[handleId] else { return }
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "true",
                "OfferToReceiveVideo": "true"
            ],
            optionalConstraints: nil
        )
        pc.answer(for: constraints) { [weak self] sdp, error in
            guard let self, let sdp else { return }
            pc.setLocalDescription(sdp) { _ in
                self.delegate?.webRTCManager(self, didProduceAnswer: sdp, forHandle: handleId)
            }
        }
    }

    func setRemoteDescription(_ sdp: RTCSessionDescription, handleId: UInt64, completion: ((Error?) -> Void)? = nil) {
        peerConnections[handleId]?.setRemoteDescription(sdp, completionHandler: completion ?? { _ in })
    }

    func addICECandidate(_ candidate: RTCIceCandidate, handleId: UInt64) {
        peerConnections[handleId]?.add(candidate)
    }

    // MARK: - Private Helpers
    private func makePeerConnection(handleId: UInt64) -> RTCPeerConnection {
        let config = RTCConfiguration()
        config.iceServers = WebRTCManager.iceServers
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let pc = factory.peerConnection(with: config, constraints: constraints, delegate: self)!

        pcLock.lock()
        peerConnections[handleId] = pc
        pcLock.unlock()
        return pc
    }

    private func selectFrontCamera() -> AVCaptureDevice? {
        RTCCameraVideoCapturer.captureDevices().first { $0.position == .front }
    }

    private func selectBestFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format {
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        return formats.filter { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return dims.width <= 1280 && dims.height <= 720
        }.last ?? formats.last!
    }

    private func selectBestFPS(for format: AVCaptureDevice.Format) -> Int {
        let maxFPS = format.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 30
        return Int(min(maxFPS, 30))
    }
}

// MARK: - RTCPeerConnectionDelegate
extension WebRTCManager: RTCPeerConnectionDelegate {

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        let handleId = peerConnections.first(where: { $0.value === peerConnection })?.key ?? 0
        switch newState {
        case .failed, .disconnected:
            delegate?.webRTCManagerICEConnectionFailed(self, handleId: handleId)
        default: break
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let handleId = peerConnections.first(where: { $0.value === peerConnection })?.key ?? 0
        delegate?.webRTCManager(self, didGenerateICECandidate: candidate, forHandle: handleId)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        guard let videoTrack = rtpReceiver.track as? RTCVideoTrack else { return }
        let handleId = peerConnections.first(where: { $0.value === peerConnection })?.key ?? 0
        pcLock.lock()
        let feedId = feedIdMap[handleId] ?? handleId
        pcLock.unlock()
        DispatchQueue.main.async {
            self.delegate?.webRTCManager(self, didReceiveRemoteTrack: videoTrack, forFeedId: feedId)
        }
    }
}
