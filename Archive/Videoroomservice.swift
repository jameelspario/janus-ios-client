//
//  Videoroomservice.swift
//  janus-test
//
//  Created by jameel on 03/03/26.
//

// VideoRoomService.swift
// Wraps Janus VideoRoom plugin for publishing and subscribing

import Foundation
import WebRTC
import Combine

// MARK: - VideoRoomService
final class VideoRoomService: NSObject {

    // MARK: - Constants
    private enum Plugin {
        static let videoRoom = "janus.plugin.videoroom"
    }

    // MARK: - Properties
    private let signaling: JanusSignalingManager
    private let webRTC: WebRTCManager

    // handleId -> publisher handleId (our publishing handle)
    private var publishHandleId: Int64 = 0
    // feedId -> subscriber handleId map
    private var subscriberHandles: [Int64: Int64] = [:]

    private var currentRoomId: Int = 0
    private var localFeedId: Int64 = 0

    private let eventSubject = PassthroughSubject<VideoRoomEvent, Never>()
    var eventPublisher: AnyPublisher<VideoRoomEvent, Never> { eventSubject.eraseToAnyPublisher() }

    // MARK: - Init
    init(signaling: JanusSignalingManager, webRTC: WebRTCManager) {
        self.signaling = signaling
        self.webRTC = webRTC
        super.init()
        signaling.delegate = self
        webRTC.delegate = self
    }

    // MARK: - Join Room as Publisher
    func joinAsPublisher(roomId: Int, displayName: String, pin: String? = nil) async throws {
        let handleId = try await signaling.attachPlugin(Plugin.videoRoom)
        publishHandleId = handleId

        // Create peer connection for publishing
        guard let pc = webRTC.createPeerConnection(handleId: handleId) else {
            throw JanusError.pluginAttachFailed
        }

        // Add local media tracks
        webRTC.addLocalTracks(to: pc)

        var body: [String: Any] = [
            "request": "join",
            "room": roomId,
            "ptype": "publisher",
            "display": displayName
        ]
        if let pin = pin { body["pin"] = pin }

        let response = try await signaling.sendMessage(handleId: handleId, body: body)
        handleJoinResponse(response)
        currentRoomId = roomId
    }

    // MARK: - Publish Feed
    func publish(audioEnabled: Bool = true, videoEnabled: Bool = true) async throws {
        guard publishHandleId != 0 else { throw JanusError.signalingError("Not joined as publisher") }
        guard let pc = webRTC.peerConnection(for: publishHandleId) else { throw JanusError.invalidResponse }

        // Create offer
        let offer = try await webRTC.createOffer(for: publishHandleId)
        try await webRTC.setLocalDescription(offer, for: publishHandleId)

        let jsep: [String: Any] = ["type": offer.type.stringValue, "sdp": offer.sdp]
        let body: [String: Any] = [
            "request": "configure",
            "audio": audioEnabled,
            "video": videoEnabled
        ]

        _ = try await signaling.sendMessage(handleId: publishHandleId, body: body, jsep: jsep)
    }

    // MARK: - Subscribe to Remote Feed
    func subscribe(to feedId: Int64, roomId: Int) async throws {
        let handleId = try await signaling.attachPlugin(Plugin.videoRoom)
        subscriberHandles[feedId] = handleId
        _ = webRTC.createPeerConnection(handleId: handleId)

        let body: [String: Any] = [
            "request": "join",
            "room": roomId,
            "ptype": "subscriber",
            "feed": feedId
        ]
        _ = try await signaling.sendMessage(handleId: handleId, body: body)
    }

    // MARK: - Unsubscribe from Feed
    func unsubscribe(feedId: Int64) async throws {
        guard let handleId = subscriberHandles[feedId] else { return }
        let body: [String: Any] = ["request": "unsubscribe"]
        _ = try? await signaling.sendMessage(handleId: handleId, body: body)
        webRTC.removePeerConnection(handleId: handleId)
        subscriberHandles.removeValue(forKey: feedId)
    }

    // MARK: - Unpublish (stay in room as guest)
    func unpublish() async throws {
        guard publishHandleId != 0 else { return }
        let body: [String: Any] = ["request": "unpublish"]
        _ = try await signaling.sendMessage(handleId: publishHandleId, body: body)
        webRTC.stopCapture()
        webRTC.setLocalVideoEnabled(false)
        eventSubject.send(.unpublished)
    }

    // MARK: - Leave Room
    func leaveRoom() async throws {
        // Notify server of leave
        if publishHandleId != 0 {
            let body: [String: Any] = ["request": "leave"]
            _ = try? await signaling.sendMessage(handleId: publishHandleId, body: body)
            webRTC.removePeerConnection(handleId: publishHandleId)
            publishHandleId = 0
        }

        // Clean up all subscribers
        for (feedId, handleId) in subscriberHandles {
            let body: [String: Any] = ["request": "unsubscribe"]
            _ = try? await signaling.sendMessage(handleId: handleId, body: body)
            webRTC.removePeerConnection(handleId: handleId)
        }
        subscriberHandles.removeAll()
        currentRoomId = 0
    }

    // MARK: - Host Ends Broadcast
    func endBroadcast() async throws {
        // Destroy the room (host only action)
        guard publishHandleId != 0 else { return }
        let body: [String: Any] = [
            "request": "destroy",
            "room": currentRoomId
        ]
        _ = try? await signaling.sendMessage(handleId: publishHandleId, body: body)
        try await leaveRoom()
        eventSubject.send(.broadcastEnded)
    }

    // MARK: - Media Controls
    func toggleVideo(_ enabled: Bool) {
        webRTC.setLocalVideoEnabled(enabled)
        Task {
            guard publishHandleId != 0 else { return }
            let body: [String: Any] = ["request": "configure", "video": enabled]
            _ = try? await signaling.sendMessage(handleId: publishHandleId, body: body)
        }
    }

    func toggleAudio(_ enabled: Bool) {
        webRTC.setLocalAudioEnabled(enabled)
        Task {
            guard publishHandleId != 0 else { return }
            let body: [String: Any] = ["request": "configure", "audio": enabled]
            _ = try? await signaling.sendMessage(handleId: publishHandleId, body: body)
        }
    }

    // MARK: - Subscribe to Answer
    private func sendSubscriberAnswer(handleId: Int64, jsep: [String: Any]) async throws {
        try await webRTC.setRemoteDescription(jsep, for: handleId)
        let answer = try await webRTC.createAnswer(for: handleId)
        try await webRTC.setLocalDescription(answer, for: handleId)

        let answerJsep: [String: Any] = ["type": answer.type.stringValue, "sdp": answer.sdp]
        let body: [String: Any] = ["request": "start", "room": currentRoomId]
        _ = try await signaling.sendMessage(handleId: handleId, body: body, jsep: answerJsep)
    }

    // MARK: - Join Response Handler
    private func handleJoinResponse(_ response: [String: Any]) {
        guard
            let pluginData = response["plugindata"] as? [String: Any],
            let data = pluginData["data"] as? [String: Any],
            let videoroom = data["videoroom"] as? String,
            videoroom == "joined"
        else { return }

        let feedId = data["id"] as? Int64 ?? 0
        localFeedId = feedId
        let publishers = data["publishers"] as? [[String: Any]] ?? []
        eventSubject.send(.joined(feedId: feedId, publishers: publishers))
    }
}

// MARK: - JanusSignalingDelegate
extension VideoRoomService: JanusSignalingDelegate {

    func signalingManager(_ manager: JanusSignalingManager, didReceiveEvent event: [String: Any], handleId: Int64) {
        guard let videoroom = event["videoroom"] as? String else { return }

        switch videoroom {
        case "event":
            handleVideoRoomEvent(event, handleId: handleId)
        case "attached":
            // Subscriber got attached, wait for JSEP
            break
        default:
            break
        }
    }

    func signalingManager(_ manager: JanusSignalingManager, didReceiveJsep jsep: [String: Any], handleId: Int64) {
        let sdpType = jsep["type"] as? String ?? ""

        if sdpType == "offer" {
            // Subscriber received offer from Janus — create answer
            Task {
                do {
                    try await sendSubscriberAnswer(handleId: handleId, jsep: jsep)
                } catch {
                    print("Failed to answer subscriber offer: \(error)")
                }
            }
        } else if sdpType == "answer" {
            // Publisher received answer from Janus
            Task {
                do {
                    try await webRTC.setRemoteDescription(jsep, for: handleId)
                } catch {
                    print("Failed to set remote description: \(error)")
                }
            }
        }
    }

    func signalingManager(_ manager: JanusSignalingManager, handleDidHangup handleId: Int64) {
        webRTC.removePeerConnection(handleId: handleId)
    }

    func signalingManager(_ manager: JanusSignalingManager, didDisconnectWithError error: Error?) {
        eventSubject.send(.error(error?.localizedDescription ?? "Disconnected"))
    }

    // MARK: - VideoRoom Event Parsing
    private func handleVideoRoomEvent(_ event: [String: Any], handleId: Int64) {
        // New publisher joined
        if let publishers = event["publishers"] as? [[String: Any]], !publishers.isEmpty {
            for publisher in publishers {
                eventSubject.send(.publisherJoined(publisher: publisher))
            }
        }

        // Publisher left
        if let leaving = event["leaving"] as? Int64 {
            eventSubject.send(.publisherLeft(feedId: leaving))
        }
        if let unpublished = event["unpublished"] as? Int64 {
            eventSubject.send(.publisherLeft(feedId: unpublished))
        }

        // Check for room destruction (host left)
        if let destroyed = event["destroyed"] as? Int {
            print("Room \(destroyed) was destroyed")
            eventSubject.send(.broadcastEnded)
        }

        // Own status updates
        if let configured = event["configured"] as? String, configured == "ok" {
            eventSubject.send(.configured)
        }
    }
}

// MARK: - WebRTCManagerDelegate
extension VideoRoomService: WebRTCManagerDelegate {

    func webRTCManager(_ manager: WebRTCManager, didGenerateCandidate candidate: RTCIceCandidate, handleId: Int64) {
        let candidateDict: [String: Any] = [
            "candidate": candidate.sdp,
            "sdpMid": candidate.sdpMid ?? "",
            "sdpMLineIndex": candidate.sdpMLineIndex
        ]
        Task { try? await signaling.sendTrickle(handleId: handleId, candidate: candidateDict) }
    }

    func webRTCManager(_ manager: WebRTCManager, didChangeConnectionState state: RTCIceConnectionState, handleId: Int64) {
        print("ICE state changed for handle \(handleId): \(state.rawValue)")
    }

    func webRTCManager(_ manager: WebRTCManager, didReceiveRemoteTrack track: RTCVideoTrack, handleId: Int64) {
        // Find feedId for this handleId
        let feedId = subscriberHandles.first(where: { $0.value == handleId })?.key ?? 0
        guard feedId != 0 else { return }
        eventSubject.send(.remoteJsep(feedId: feedId, jsep: [:]))
        // Post notification so RoomViewModel can update participant video track
        NotificationCenter.default.post(
            name: .videoTrackReceived,
            object: nil,
            userInfo: ["feedId": feedId, "track": track]
        )
    }

    func webRTCManager(_ manager: WebRTCManager, didRemoveRemoteTrack handleId: Int64) {
        let feedId = subscriberHandles.first(where: { $0.value == handleId })?.key ?? 0
        if feedId != 0 {
            eventSubject.send(.publisherLeft(feedId: feedId))
        }
    }
}

// MARK: - Notification Names
extension Notification.Name {
    static let videoTrackReceived = Notification.Name("videoTrackReceived")
}
