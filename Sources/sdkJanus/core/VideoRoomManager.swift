//
//  VideoRoomManager.swift
//

import Foundation
import Combine
import WebRTC

// MARK: - VideoRoomManagerDelegate
@MainActor
protocol VideoRoomManagerDelegate: AnyObject {
    /// Janus session created; caller should now join a room.
    func videoRoomManager(_ mgr: VideoRoomManager)

    func videoRoomManager(_ mgr: VideoRoomManager, didJoinRoom roomId: Int, asRole role: UserRole)
    func videoRoomManager(_ mgr: VideoRoomManager, didConfigure roomId: Int, asRole role: UserRole)

    func videoRoomManager(_ mgr: VideoRoomManager, didPublisherJoin participant: JanusParticipant, inRoom roomId: Int)
    func videoRoomManager(_ mgr: VideoRoomManager, didPublisherLeave participantId: UInt64, inRoom roomId: Int)
    func videoRoomManager(_ mgr: VideoRoomManager, didReceiveVideoTrack track: RTCVideoTrack, forFeedId feedId: UInt64, inRoom roomId: Int)
    func videoRoomManager(_ mgr: VideoRoomManager, didRemoveVideoTrack feedId: UInt64, inRoom roomId: Int)
    func videoRoomManager(_ mgr: VideoRoomManager, broadcastEndedInRoom roomId: Int)
    func videoRoomManager(_ mgr: VideoRoomManager, didError error: JanusError)
    func videoRoomManager(_ mgr: VideoRoomManager, didUpdateParticipants participants: [JanusParticipant], inRoom roomId: Int)
}

// MARK: - VideoRoomManager
/// Thin orchestrator that owns a registry of `JanusRoom` objects and routes
/// Janus / WebRTC signals to the correct room.
///
/// Responsibilities:
/// - Create / tear down `JanusRoom` instances on demand.
/// - Route every incoming Janus event and JSEP to the room that owns the handle.
/// - Route every WebRTC track event to the room that owns the feed.
/// - Manage PK state (local room + remote PK room run in parallel).
///
/// It does **not** contain any per-room state; all that lives in `JanusRoom`.
final class VideoRoomManager: NSObject, @unchecked Sendable {

    // MARK: - Public
    weak var delegate: VideoRoomManagerDelegate?
    private(set) var currentRole:        UserRole = .guest
    private(set) var localParticipantId: UInt64   = 0

    // MARK: - Private: shared infrastructure
    private let session:    JanusSession
    private let rtcManager: WebRTCManager
    private let config:     SDKConfig
    private let DEBUG:      Bool
    private var connectionConfig:      ConnectionConfig? = nil
    
    // MARK: - Private: room registry  (protected by roomLock)
    private var rooms: [Int: JanusRoom] = [:]   // roomId → JanusRoom
    private let roomLock = NSLock()

    // MARK: - Init
    init(config: SDKConfig) {
        self.config     = config
        self.DEBUG      = config.DEBUG
        self.session    = JanusSession(url: config.janusURL)
        self.rtcManager = WebRTCManager(config: config)
        super.init()
        session.delegate    = self
        rtcManager.delegate = self
    }

    // =========================================================================
    // MARK: - Connection
    // =========================================================================

    func connect(
        config: ConnectionConfig = ConnectionConfig()
    ) {
        self.connectionConfig = config
        session.connect()
    }

    func disconnect() {
        allRooms.forEach { $0.leave() }
        withRoomLock { rooms = [:] }
        session.disconnect()
        rtcManager.stopLocalMedia()
    }

    // =========================================================================
    // MARK: - Local media
    // =========================================================================

    func startLocalMedia(mediaMode: MediaMode = .audioVideo, renderer: RTCVideoRenderer?) {
        rtcManager.startLocalMedia(mediaMode: mediaMode, videoRenderer: renderer)
    }

    func setLocalRenderer(_ renderer: RTCVideoRenderer) {
        rtcManager.setLocalVideoRenderer(renderer)
    }

    var currentLocalVideoTrack: RTCVideoTrack? { rtcManager.currentLocalVideoTrack }

    func muteAudio(_ muted: Bool) { rtcManager.setAudioEnabled(!muted) }
    func muteVideo(_ muted: Bool) { rtcManager.setVideoEnabled(!muted) }
    func switchCamera(_ rear: Bool) {  rtcManager.switchCamera(rear) }

    // =========================================================================
    // MARK: - Room entry points
    // =========================================================================

    // MARK: Publisher
    func joinRoomAsPublisher(roomId: Int, displayName: String) {
        joinRoom(roomId: roomId, displayName: displayName, role: .publisher, mediaMode: .audioVideo)
    }

    // MARK: Guest
    func joinRoomAsGuest(roomId: Int, displayName: String) {
        joinRoom(roomId: roomId, displayName: displayName, role: .guest, mediaMode: .audioVideo)
    }
    
    func joinRoom(roomId: Int, displayName: String, role: UserRole) {
        joinRoom(roomId: roomId, displayName: displayName, role: role, mediaMode: .audioVideo, isRoomCreator: false)
    }

    func joinRoom(roomId: Int, displayName: String, role: UserRole, mediaMode: MediaMode, isRoomCreator: Bool = false) {
        currentRole = role
        makeRoom(roomId: roomId, role: role, mediaMode: mediaMode, isRoomCreator: isRoomCreator, displayName: displayName).join()
    }

    // MARK: Guest publish on demand
    /// Guest starts broadcasting their own camera feed (can be toggled).
    func guestStartPublishing() {
        primaryRoom?.startPublishing()
    }

    /// Guest stops broadcasting while remaining in the room as a subscriber.
    func guestStopPublishing() {
        primaryRoom?.stopPublishing()
    }

    // =========================================================================
    // MARK: - Leave
    // =========================================================================

    func publisherLeaveRoom(roomId: Int) {
        guard let room = withRoomLock({ rooms[roomId] }) else { return }
        room.leave()
        withRoomLock { rooms.removeValue(forKey: roomId) }
        Task { @MainActor in delegate?.videoRoomManager(self, broadcastEndedInRoom: roomId) }
    }

    func guestLeaveRoom(roomId: Int) {
        withRoomLock { rooms[roomId] }?.leave()
        withRoomLock { rooms.removeValue(forKey: roomId) }
        Task { @MainActor in delegate?.videoRoomManager(self, broadcastEndedInRoom: roomId) }
    }

    // =========================================================================
    // MARK: - Private: Room factory
    // =========================================================================

    @discardableResult
    private func makeRoom(
        roomId:      Int,
        role:        UserRole,
        mediaMode:   MediaMode = .audioVideo,
        isRoomCreator: Bool = false,
        displayName: String
    ) -> JanusRoom {
        let room = JanusRoom(
            roomId:      roomId,
            role:        role,
            mediaMode:   mediaMode,
            isRoomCreator: isRoomCreator,
            displayName: displayName,
            config:      config,
            session:     session,
            rtcManager:  rtcManager
        )
        room.delegate = self
        withRoomLock { rooms[roomId] = room }
        return room
    }

    // =========================================================================
    // MARK: - Private: Routing helpers
    // =========================================================================

    /// The first room joined — the user's primary room.
    private var primaryRoom: JanusRoom? {
        withRoomLock { rooms.values.first }
    }
    
    func getRoom(_ roomId: Int) -> JanusRoom? {
        withRoomLock { rooms[roomId] }
    }

    /// All registered rooms (snapshot, safe to iterate outside lock).
    private var allRooms: [JanusRoom] {
        withRoomLock { Array(rooms.values) }
    }

    /// Find the room that owns `handleId` (publisher or subscriber handle).
    private func room(owning handleId: UInt64) -> JanusRoom? {
        withRoomLock { rooms.values.first { $0.owns(handleId: handleId) } }
    }

    /// Find the room that has an active subscriber for `feedId`.
    private func room(containingFeed feedId: UInt64) -> JanusRoom? {
        withRoomLock { rooms.values.first { $0.containsSubscriberFeed(feedId) } }
    }

    /// Thread-safe helper that locks, runs `block`, unlocks, and returns the result.
    @discardableResult
    private func withRoomLock<T>(_ block: () -> T) -> T {
        roomLock.lock()
        defer { roomLock.unlock() }
        return block()
    }

    // MARK: - Logging
    private func log(_ message: String) {
        if DEBUG { print("[VideoRoomManager] \(message)") }
    }
}

extension VideoRoomManager {
    
    func joinRoomOnCreateSession(){
        // Join main room if not overridden in roomConfigs
        if !config.roomConfigs.contains(where: { $0.roomId == config.roomId }) {
            switch config.role {
            case .publisher:
                joinRoom(
                    roomId:      config.roomId,
                    displayName: config.displayName,
                    role:        .publisher,
                    mediaMode:   .audioVideo,
                    isRoomCreator: config.isRoomCreator
                )
            case .guest:
                joinRoom(
                    roomId:      config.roomId,
                    displayName: config.displayName,
                    role:        .guest,
                    mediaMode:   .audioVideo,
                    isRoomCreator: config.isRoomCreator
                )
            }
        }
        
        // Also join all multiRoomIds as guest (since they are secondary viewing rooms)
        for mRoomId in config.multiRoomIds {
            joinRoom(
                roomId:      mRoomId,
                displayName: config.displayName,
                role:        .guest,
                mediaMode:   .audioVideo,
                isRoomCreator: false
            )
        }
        
        // Join any custom room configurations passed in config
        for roomConfig in config.roomConfigs {
            joinRoom(
                roomId:      roomConfig.roomId,
                displayName: config.displayName,
                role:        roomConfig.role,
                mediaMode:   roomConfig.mediaMode,
                isRoomCreator: roomConfig.isRoomCreator
            )
        }
    }
    
    func startPublishingOnJoinRoom(_ room: JanusRoom){
        if self.connectionConfig?.autoPublishStream == true {
            startLocalMedia(mediaMode: room.mediaMode, renderer: nil)
            room.startPublishing()
        }
    }
    
}

// MARK: - JanusSessionDelegate
extension VideoRoomManager: JanusSessionDelegate {

    func janusSessionDidConnect(_ session: JanusSession) {
        session.createSession { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                if connectionConfig?.autoJoinRoom == true {
                    joinRoomOnCreateSession()
                }
                Task { @MainActor in self.delegate?.videoRoomManager(self) }
            case .failure(let error):
                Task { @MainActor in self.delegate?.videoRoomManager(self, didError: error) }
            }
        }
    }

    func janusSessionDidDisconnect(_ session: JanusSession) {
        log("Session disconnected")
    }

    func janusSession(_ session: JanusSession, didError error: JanusError) {
        Task { @MainActor in delegate?.videoRoomManager(self, didError: error) }
    }

    /// Route JSEP to the room that owns the handle.
    func janusSession(_ session: JanusSession, didReceiveJSEP jsep: [String: Any], forHandle handleId: UInt64) {
        room(owning: handleId)?.handleJSEP(jsep, forHandle: handleId)
    }

    /// Route plugin events to the room that owns the handle.
    func janusSession(_ session: JanusSession, didReceiveEvent event: [String: Any], forHandle handleId: UInt64) {
        log("event received for handle \(handleId)")
        room(owning: handleId)?.handleEvent(event, forHandle: handleId)
    }
    
}

// MARK: - WebRTCManagerDelegate
extension VideoRoomManager: WebRTCManagerDelegate {

    func webRTCManager(_ manager: WebRTCManager, didGenerateICECandidate candidate: RTCIceCandidate, forHandle handleId: UInt64) {
        session.sendTrickle(candidate: candidate, handleId: handleId)
    }

    /// Forward the offer to the room that owns the publisher handle.
    func webRTCManager(_ manager: WebRTCManager, didProduceOffer sdp: RTCSessionDescription, forHandle handleId: UInt64) {
        room(owning: handleId)?.handleOfferProduced(sdp, handleId: handleId)
    }

    /// Forward the answer to the room that owns the subscriber handle.
    func webRTCManager(_ manager: WebRTCManager, didProduceAnswer sdp: RTCSessionDescription, forHandle handleId: UInt64) {
        room(owning: handleId)?.handleAnswerProduced(sdp, handleId: handleId)
    }

    /// A remote track arrived; route to the room subscribed to that feed.
    func webRTCManager(_ manager: WebRTCManager, didReceiveRemoteTrack track: RTCVideoTrack, forFeedId feedId: UInt64) {
        log("didReceiveRemoteTrack for feedId \(feedId)")
        guard let targetRoom = room(containingFeed: feedId) else {
            log("⚠️ No room found for feedId \(feedId)")
            return
        }

        targetRoom.handleTrackReceived(track, feedId: feedId)

        Task { @MainActor in
            self.delegate?.videoRoomManager(
                self,
                didReceiveVideoTrack: track,
                forFeedId:            feedId,
                inRoom:               targetRoom.roomId
            )
        }
    }

    func webRTCManager(_ manager: WebRTCManager, didRemoveRemoteTrack forFeedId: UInt64) {
        guard let targetRoom = room(containingFeed: forFeedId) else { return }
        targetRoom.handleTrackRemoved(feedId: forFeedId)
        Task { @MainActor in
            self.delegate?.videoRoomManager(self, didRemoveVideoTrack: forFeedId, inRoom: targetRoom.roomId)
        }
    }

    func webRTCManagerICEConnectionFailed(_ manager: WebRTCManager, handleId: UInt64) {
        Task { @MainActor in delegate?.videoRoomManager(self, didError: .iceFailure) }
    }
}

// MARK: - JanusRoomDelegate
extension VideoRoomManager: JanusRoomDelegate {

    func janusRoom(_ room: JanusRoom, didJoinWithFeedId myFeedId: UInt64) {
        localParticipantId = myFeedId
        // should publish
        if config.role == .publisher {
            startPublishingOnJoinRoom(room)
        }
        Task { @MainActor in
            delegate?.videoRoomManager(self, didJoinRoom: room.roomId, asRole: room.role)
        }
    }

    func janusRoom(_ room: JanusRoom, didConfigure roomId: Int) {
        Task { @MainActor in
            delegate?.videoRoomManager(self, didConfigure: roomId, asRole: room.role)
        }
    }

    func janusRoom(_ room: JanusRoom, didUpdateParticipants participants: [JanusParticipant]) {
        Task { @MainActor in
            delegate?.videoRoomManager(self, didUpdateParticipants: participants, inRoom: room.roomId)
        }
    }

    func janusRoom(_ room: JanusRoom, didParticipantLeave feedId: UInt64) {
        Task { @MainActor in
            delegate?.videoRoomManager(self, didPublisherLeave: feedId, inRoom: room.roomId)
            delegate?.videoRoomManager(self, didRemoveVideoTrack: feedId, inRoom: room.roomId)
        }
    }

    func janusRoom(_ room: JanusRoom, broadcastDidEnd roomId: Int) {
        withRoomLock { rooms.removeValue(forKey: roomId) }
        Task { @MainActor in
            delegate?.videoRoomManager(self, broadcastEndedInRoom: roomId)
        }
    }

    func janusRoom(_ room: JanusRoom, didFailWithError error: JanusError) {
        Task { @MainActor in
            delegate?.videoRoomManager(self, didError: error)
        }
    }
}
