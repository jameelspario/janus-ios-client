//
//  VideoRoomManager.swift
//  janus-test
//
//  Created by jameel on 03/03/26.
//

// VideoRoomManager.swift
// High-level VideoRoom plugin manager.
// Handles: join as publisher/guest, publish/unpublish, subscribe to feeds,
// host leave → end broadcast, PK feature, multi-room viewing.

import Foundation
import WebRTC
import Combine

@MainActor
protocol VideoRoomManagerDelegate: AnyObject {
    func videoRoomManager(_ mgr: VideoRoomManager)
    func videoRoomManager(_ mgr: VideoRoomManager, didJoinRoom roomId: UInt64, asRole role: UserRole)
    func videoRoomManager(_ mgr: VideoRoomManager, didPublisherJoin participant: Participant, inRoom roomId: UInt64)
    func videoRoomManager(_ mgr: VideoRoomManager, didPublisherLeave participantId: UInt64, inRoom roomId: UInt64)
    func videoRoomManager(_ mgr: VideoRoomManager, didReceiveVideoTrack track: RTCVideoTrack, forFeedId feedId: UInt64, inRoom roomId: UInt64)
    func videoRoomManager(_ mgr: VideoRoomManager, didRemoveVideoTrack feedId: UInt64, inRoom roomId: UInt64)
    func videoRoomManager(_ mgr: VideoRoomManager, broadcastEndedInRoom roomId: UInt64)
    func videoRoomManager(_ mgr: VideoRoomManager, didError error: JanusError)
    func videoRoomManager(_ mgr: VideoRoomManager, didUpdateParticipants participants: [Participant], inRoom roomId: UInt64)
}

final class VideoRoomManager: NSObject {

    // MARK: - Public
    weak var delegate: VideoRoomManagerDelegate?
    private(set) var currentRole: UserRole = .guest
    private(set) var localParticipantId: UInt64 = 0

    // MARK: - Private State
    private let session: JanusSession
    private let rtcManager: WebRTCManager

    // Publisher handle per room
    private var publisherHandles: [UInt64: UInt64] = [:]     // roomId -> handleId
    // Subscriber handle per feed: feedId -> handleId
    private var subscriberHandles: [UInt64: UInt64] = [:]
    // Participants per room
    private var roomParticipants: [UInt64: [UInt64: Participant]] = [:] // roomId -> [participantId: Participant]
    // Track which rooms we're in
    private var joinedRooms: Set<UInt64> = []
    // Multi-room entries (for PK / viewer joining multiple rooms)
    private var multiRoomEntries: [UInt64: MultiRoomEntry] = [:]
    // PK session state
    private var pkSession: PKSession?

    private let lock = NSLock()

    // MARK: - Init
    init(janusURL: URL) {
        session = JanusSession(url: janusURL)
        rtcManager = WebRTCManager()
        super.init()
        session.delegate = self
        rtcManager.delegate = self
    }

    // MARK: - Connect
    func connect() {
        session.connect()
    }

    func disconnect() {
        session.disconnect()
        rtcManager.stopLocalMedia()
    }

    // MARK: - Start Local Preview
    func startLocalPreview(renderer: RTCVideoRenderer) {
        rtcManager.startLocalMedia(videoRenderer: renderer)
    }

    func setLocalRenderer(_ renderer: RTCVideoRenderer) {
        rtcManager.setLocalVideoRenderer(renderer)
    }

    func muteAudio(_ muted: Bool) { rtcManager.setAudioEnabled(!muted) }
    func muteVideo(_ muted: Bool) { rtcManager.setVideoEnabled(!muted) }

    // MARK: - Join Room as Publisher
    /// Joins a VideoRoom as publisher (creates + publishes your feed).
    func joinRoomAsPublisher(roomId: UInt64, displayName: String, pin: String? = nil) {
        currentRole = .publisher
        attachAndJoin(roomId: roomId, displayName: displayName, role: .publisher, pin: pin)
    }

    // MARK: - Join Room as Guest
    /// Joins a VideoRoom as subscriber/guest. Subscribes to existing publishers.
    func joinRoomAsGuest(roomId: UInt64, displayName: String, pin: String? = nil) {
        currentRole = .guest
        attachAndJoin(roomId: roomId, displayName: displayName, role: .guest, pin: pin)
    }

    // MARK: - Guest Publish (optional self-video)
    /// A guest can choose to start publishing their own video at any time.
    func guestStartPublishing() {
        guard currentRole == .guest,
              let roomId = joinedRooms.first,
              let handleId = publisherHandles[roomId] else { return }
        publishFeed(handleId: handleId, roomId: roomId)
    }

    /// A guest can stop publishing without leaving the room.
    func guestStopPublishing() {
        guard let roomId = joinedRooms.first,
              let handleId = publisherHandles[roomId] else { return }
        unpublishFeed(handleId: handleId, roomId: roomId)
    }

    // MARK: - Publisher Leave (ends broadcast for all)
    func publisherLeaveRoom(roomId: UInt64) {
        guard let handleId = publisherHandles[roomId] else { return }
        let body: [String: Any] = ["request": "leave"]
        session.sendMessage(body, handleId: handleId)
        cleanupRoom(roomId: roomId)
        Task { @MainActor in
            delegate?.videoRoomManager(self, broadcastEndedInRoom: roomId)
        }
    }

    // MARK: - Guest Leave Room (stays optional, room continues)
    func guestLeaveRoom(roomId: UInt64) {
        guard let handleId = publisherHandles[roomId] else { return }
        let body: [String: Any] = ["request": "leave"]
        session.sendMessage(body, handleId: handleId)
        cleanupRoom(roomId: roomId)
    }

    // MARK: - Multi-Room Join (View multiple rooms simultaneously — PK viewers)
    func joinMultipleRooms(roomIds: [UInt64], displayName: String) {
        for roomId in roomIds {
            guard multiRoomEntries[roomId] == nil else { continue }
            var entry = MultiRoomEntry(roomId: roomId, participants: [], isJoined: false)
            multiRoomEntries[roomId] = entry
            attachAndJoin(roomId: roomId, displayName: displayName, role: .guest, pin: nil)
        }
    }

    func leaveMultiRoom(roomId: UInt64) {
        guestLeaveRoom(roomId: roomId)
        multiRoomEntries.removeValue(forKey: roomId)
    }

    // MARK: - PK Feature
    /// Start a PK battle — host joins their own room + another host's room simultaneously.
    func startPKBattle(localRoomId: UInt64, remoteRoomId: UInt64, displayName: String) {
        pkSession = PKSession(localRoomId: localRoomId, remoteRoomId: remoteRoomId, isActive: true)
        // Join remote room as subscriber to show their feed side-by-side
        joinMultipleRooms(roomIds: [localRoomId, remoteRoomId], displayName: displayName)
    }

    func endPKBattle() {
        guard let pk = pkSession else { return }
        leaveMultiRoom(roomId: pk.remoteRoomId)
        pkSession = nil
    }

    // MARK: - Private: Attach Plugin + Join Room
    private func attachAndJoin(roomId: UInt64, displayName: String, role: UserRole, pin: String?) {
        session.attachPlugin(.videoRoom) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let handleId):
                self.lock.lock()
                self.publisherHandles[roomId] = handleId
                self.lock.unlock()
                self.joinRoom(roomId: roomId, handleId: handleId, displayName: displayName, role: role, pin: pin)
            case .failure(let error):
                Task { @MainActor in self.delegate?.videoRoomManager(self, didError: error) }
            }
        }
    }

    private func joinRoom(roomId: UInt64, handleId: UInt64, displayName: String, role: UserRole, pin: String?) {
        var body: [String: Any] = [
            "request": role == .publisher ? "joinandconfigure" : "join",
            "room": roomId,
            "ptype": "publisher",
            "display": displayName
        ]
        if let pin { body["pin"] = pin }

        session.sendMessage(body, handleId: handleId) { [weak self] response in
            guard let self else { return }
            self.handleJoinResponse(response: response, roomId: roomId, handleId: handleId, role: role)
        }
    }

    private func handleJoinResponse(response: [String: Any], roomId: UInt64, handleId: UInt64, role: UserRole) {
        guard let pluginData = response["plugindata"] as? [String: Any],
              let data = pluginData["data"] as? [String: Any] else { return }

        let event = data["videoroom"] as? String ?? ""
        if event == "joined" {
            let myId = data["id"] as? UInt64 ?? 0
            localParticipantId = myId
            joinedRooms.insert(roomId)
            roomParticipants[roomId] = [:]

            // Process existing publishers
            if let publishers = data["publishers"] as? [[String: Any]] {
                for pub in publishers {
                    processNewPublisher(pub, roomId: roomId)
                }
            }

            Task { @MainActor in
                self.delegate?.videoRoomManager(self, didJoinRoom: roomId, asRole: role)
            }

            // If publisher role, start publishing immediately
            if role == .publisher {
                publishFeed(handleId: handleId, roomId: roomId)
            }
        } else if let error = data["error"] as? String {
            Task { @MainActor in
                self.delegate?.videoRoomManager(self, didError: .roomJoinFailed(error))
            }
        }
    }

    // MARK: - Publish
    private func publishFeed(handleId: UInt64, roomId: UInt64) {
        _ = rtcManager.createPublisherPeerConnection(handleId: handleId)
        rtcManager.createOffer(handleId: handleId)
        // Offer delivery handled in WebRTCManagerDelegate → didProduceOffer
    }

    private func unpublishFeed(handleId: UInt64, roomId: UInt64) {
        let body: [String: Any] = ["request": "unpublish"]
        session.sendMessage(body, handleId: handleId)
        rtcManager.removePeerConnection(handleId: handleId)
    }

    // MARK: - Subscribe to a Publisher Feed
    private func subscribeFeed(feedId: UInt64, roomId: UInt64) {
        session.attachPlugin(.videoRoom) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let subHandleId):
                self.lock.lock()
                self.subscriberHandles[feedId] = subHandleId
                self.lock.unlock()

                _ = self.rtcManager.createSubscriberPeerConnection(handleId: subHandleId, feedId: feedId)

                let body: [String: Any] = [
                    "request": "join",
                    "room": roomId,
                    "ptype": "subscriber",
                    "feed": feedId
                ]
                self.session.sendMessage(body, handleId: subHandleId)

            case .failure(let error):
                Task { @MainActor in self.delegate?.videoRoomManager(self, didError: error) }
            }
        }
    }

    // MARK: - Process New Publisher from Event
    private func processNewPublisher(_ pub: [String: Any], roomId: UInt64) {
        guard let pubId = pub["id"] as? UInt64 else { return }
        let displayName = pub["display"] as? String ?? "Unknown"
        let participant = Participant(
            id: pubId,
            displayName: displayName,
            isPublishing: true,
            isAudioMuted: false,
            isVideoMuted: false,
            role: .publisher,
            roomId: roomId
        )
        lock.lock()
        roomParticipants[roomId]?[pubId] = participant
        lock.unlock()

        Task { @MainActor in
            self.delegate?.videoRoomManager(self, didPublisherJoin: participant, inRoom: roomId)
            let all = Array(self.roomParticipants[roomId]?.values ?? [:].values)
            self.delegate?.videoRoomManager(self, didUpdateParticipants: all, inRoom: roomId)
        }
        subscribeFeed(feedId: pubId, roomId: roomId)
    }

    // MARK: - Cleanup
    private func cleanupRoom(roomId: UInt64) {
        lock.lock()
        let publisherHandleId = publisherHandles.removeValue(forKey: roomId)
        let participants = roomParticipants.removeValue(forKey: roomId) ?? [:]
        joinedRooms.remove(roomId)
        lock.unlock()

        if let handleId = publisherHandleId {
            rtcManager.removePeerConnection(handleId: handleId)
            session.detachHandle(handleId)
        }
        for (feedId, subHandleId) in subscriberHandles where participants[feedId] != nil {
            rtcManager.removePeerConnection(handleId: subHandleId)
            session.detachHandle(subHandleId)
            subscriberHandles.removeValue(forKey: feedId)
        }
    }
}

// MARK: - JanusSessionDelegate
extension VideoRoomManager: JanusSessionDelegate {

    func janusSessionDidConnect(_ session: JanusSession) {
        session.createSession { [weak self] result in
            if case .success = result {
                Task { @MainActor in
                    self?.delegate?.videoRoomManager(self!)
                }
            }
            if case .failure(let error) = result {
                Task { @MainActor in self?.delegate?.videoRoomManager(self!, didError: error) }
            }
        }
    }

    func janusSessionDidDisconnect(_ session: JanusSession) {}

    func janusSession(_ session: JanusSession, didError error: JanusError) {
        Task { @MainActor in delegate?.videoRoomManager(self, didError: error) }
    }

    func janusSession(_ session: JanusSession, didReceiveJSEP jsep: [String: Any], forHandle handleId: UInt64) {
        guard let sdpString = jsep["sdp"] as? String,
              let sdpType = jsep["type"] as? String else { return }

        let type: RTCSdpType = sdpType == "offer" ? .offer : .answer
        let remoteSDP = RTCSessionDescription(type: type, sdp: sdpString)

        if type == .offer {
            // This is a subscriber getting an offer from Janus
            rtcManager.setRemoteDescription(remoteSDP, handleId: handleId) { [weak self] _ in
                self?.rtcManager.createAnswer(handleId: handleId)
            }
        } else {
            // Publisher getting answer back
            rtcManager.setRemoteDescription(remoteSDP, handleId: handleId)
        }
    }

    func janusSession(_ session: JanusSession, didReceiveEvent event: [String: Any], forHandle handleId: UInt64) {
        guard let pluginData = event["plugindata"] as? [String: Any],
              let data = pluginData["data"] as? [String: Any] else { return }

        let videoRoomEvent = data["videoroom"] as? String ?? ""

        // Find roomId for this handle
        lock.lock()
        let roomId = publisherHandles.first(where: { $0.value == handleId })?.key ?? 0
        lock.unlock()

        switch videoRoomEvent {
        case "event":
            // New publishers appeared
            if let publishers = data["publishers"] as? [[String: Any]] {
                for pub in publishers { processNewPublisher(pub, roomId: roomId) }
            }
            // Publisher unpublished / left
            if let unpublished = data["unpublished"] as? UInt64 {
                handlePublisherLeft(feedId: unpublished, roomId: roomId)
            }
            if let leaving = data["leaving"] as? UInt64 {
                handlePublisherLeft(feedId: leaving, roomId: roomId)
                // If it was the host (first publisher), end broadcast
                checkIfBroadcastShouldEnd(roomId: roomId)
            }

        case "attached":
            // Subscriber attached — Janus will now send an offer via JSEP
            break

        case "destroyed":
            Task { @MainActor in
                self.delegate?.videoRoomManager(self, broadcastEndedInRoom: roomId)
            }
            cleanupRoom(roomId: roomId)

        default:
            break
        }
    }

    private func handlePublisherLeft(feedId: UInt64, roomId: UInt64) {
        lock.lock()
        roomParticipants[roomId]?.removeValue(forKey: feedId)
        let subHandleId = subscriberHandles.removeValue(forKey: feedId)
        lock.unlock()

        if let handleId = subHandleId {
            rtcManager.removePeerConnection(handleId: handleId)
            session.detachHandle(handleId)
        }

        Task { @MainActor in
            self.delegate?.videoRoomManager(self, didPublisherLeave: feedId, inRoom: roomId)
            self.delegate?.videoRoomManager(self, didRemoveVideoTrack: feedId, inRoom: roomId)
        }
    }

    /// End broadcast if no publishers remain and local user was a host
    private func checkIfBroadcastShouldEnd(roomId: UInt64) {
        lock.lock()
        let remainingPublishers = roomParticipants[roomId]?.values.filter { $0.role == .publisher } ?? []
        lock.unlock()

        if remainingPublishers.isEmpty && currentRole == .guest {
            Task { @MainActor in
                self.delegate?.videoRoomManager(self, broadcastEndedInRoom: roomId)
            }
            cleanupRoom(roomId: roomId)
        }
    }
}

// MARK: - WebRTCManagerDelegate
extension VideoRoomManager: WebRTCManagerDelegate {

    func webRTCManager(_ manager: WebRTCManager, didGenerateICECandidate candidate: RTCIceCandidate, forHandle handleId: UInt64) {
        session.sendTrickle(candidate: candidate, handleId: handleId)
    }

    func webRTCManager(_ manager: WebRTCManager, didProduceOffer sdp: RTCSessionDescription, forHandle handleId: UInt64) {
        let jsep: [String: Any] = ["type": "offer", "sdp": sdp.sdp]
        let body: [String: Any] = [
            "request": "publish",
            "audio": true,
            "video": true,
//            "audiocodec": "opus",
//            "videocodec": "h264"
        ]
        session.sendMessage(body, handleId: handleId, jsep: jsep)
    }

    func webRTCManager(_ manager: WebRTCManager, didProduceAnswer sdp: RTCSessionDescription, forHandle handleId: UInt64) {
        let jsep: [String: Any] = ["type": "answer", "sdp": sdp.sdp]
        let body: [String: Any] = ["request": "start"]
        session.sendMessage(body, handleId: handleId, jsep: jsep)
    }

    func webRTCManager(_ manager: WebRTCManager, didReceiveRemoteTrack track: RTCVideoTrack, forFeedId feedId: UInt64) {
        // Determine roomId for this feed
        lock.lock()
        let roomId = roomParticipants.first(where: { $0.value[feedId] != nil })?.key ?? 0
        lock.unlock()

        Task { @MainActor in
            self.delegate?.videoRoomManager(self, didReceiveVideoTrack: track, forFeedId: feedId, inRoom: roomId)
        }
    }

    func webRTCManager(_ manager: WebRTCManager, didRemoveRemoteTrack forFeedId: UInt64) {
        lock.lock()
        let roomId = roomParticipants.first(where: { $0.value[forFeedId] != nil })?.key ?? 0
        lock.unlock()
        Task { @MainActor in
            self.delegate?.videoRoomManager(self, didRemoveVideoTrack: forFeedId, inRoom: roomId)
        }
    }

    func webRTCManagerICEConnectionFailed(_ manager: WebRTCManager, handleId: UInt64) {
        Task { @MainActor in delegate?.videoRoomManager(self, didError: .iceFailure) }
    }
}
