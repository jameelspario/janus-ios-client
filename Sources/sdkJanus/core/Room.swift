//
//  Room.swift
//
//

import Foundation
import Combine
import WebRTC

// MARK: - JanusRoomDelegate
/// All callbacks are dispatched to the main actor.
@MainActor
protocol JanusRoomDelegate: AnyObject {

    /// Room joined successfully; `myFeedId` is our publisher slot ID.
    func janusRoom(_ room: JanusRoom, didJoinWithFeedId myFeedId: UInt64)

    /// Publisher's offer was accepted and stream is live (configured event).
    func janusRoom(_ room: JanusRoom, didConfigure roomId: Int)

    /// Called whenever the participant list changes (add or remove).
    func janusRoom(_ room: JanusRoom, didUpdateParticipants participants: [JanusParticipant])

    /// A remote participant left this room.
    func janusRoom(_ room: JanusRoom, didParticipantLeave feedId: UInt64)

    /// The room was destroyed or all publishers left (guest-only perspective).
    func janusRoom(_ room: JanusRoom, broadcastDidEnd roomId: Int)

    /// Any recoverable or fatal error within this room.
    func janusRoom(_ room: JanusRoom, didFailWithError error: JanusError)
}

// MARK: - JanusRoom
/// Manages the complete lifecycle of **one** Janus VideoRoom connection.
///
/// Responsibilities:
/// - Attaches and tracks a single publisher plugin-handle.
/// - Attaches and tracks one subscriber plugin-handle **per remote feed**.
/// - Owns the participant roster for this room.
/// - Routes incoming Janus events and JSEP messages to the correct peer connection.
/// - Exposes simple verbs: `join`, `startPublishing`, `stopPublishing`,
///   `subscribeFeed`, `leave`.
///
/// It does **not** create or own `JanusSession` or `WebRTCManager` — those are
/// shared infrastructure passed in at init time.
final class JanusRoom: @unchecked Sendable {

    // MARK: - Identity

    let roomId:        Int
    let role:          UserRole
    let mediaMode:     MediaMode
    let isRoomCreator: Bool


    // MARK: - Observed state

    private(set) var state:    RoomState = .idle
    private(set) var myFeedId: UInt64   = 0

    // MARK: - Handle registry (protected by `lock`)

    private var publisherHandleId:   UInt64?
    private var subscriberHandles:   [UInt64: UInt64] = [:] // feedId → handleId
    private let lock = NSLock()

    // MARK: - Participant roster

    private(set) var participants: [UInt64: JanusParticipant] = [:]
    private(set) var tracks:       [UInt64: RTCVideoTrack] = [:]

    // MARK: - Configuration

    private let displayName: String
//    private let pin:         String?
    private let config:      SDKConfig

    // MARK: - Room-creation retry guard

    private var roomCreateAttempts    = 0
    private let maxRoomCreateAttempts = 3

    // MARK: - Dependencies (shared, not owned)

    private let session:    JanusSession
    private let rtcManager: WebRTCManager

    weak var delegate: (any JanusRoomDelegate)?

    // MARK: - Init

    init(
        roomId:        Int,
        role:          UserRole,
        mediaMode:     MediaMode = .audioVideo,
        isRoomCreator: Bool = false,
        displayName:   String,
        config:        SDKConfig,
        session:       JanusSession,
        rtcManager:    WebRTCManager
    ) {
        self.roomId        = roomId
        self.role          = role
        self.mediaMode     = mediaMode
        self.isRoomCreator = isRoomCreator
        self.displayName   = displayName
        self.config        = config
        self.session       = session
        self.rtcManager    = rtcManager
    }

    // =========================================================================
    // MARK: - Handle Ownership Queries
    // =========================================================================

    /// Returns `true` if this room owns `handleId` (publisher or any subscriber).
    func owns(handleId: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if publisherHandleId == handleId { return true }
        return subscriberHandles.values.contains(handleId)
    }

    /// Returns `true` if this room has an active subscriber for `feedId`.
    func containsSubscriberFeed(_ feedId: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return subscriberHandles[feedId] != nil
    }

    /// Returns the feedId associated with a subscriber handle, if any.
    func feedId(forSubscriberHandle handleId: UInt64) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return subscriberHandles.first(where: { $0.value == handleId })?.key
    }
    
    // =========================================================================
    // MARK: - Track Accessors (room-scoped)
    // =========================================================================
 
    /// Returns the live video track for `feedId`, or `nil` if not yet received.
    func track(for feedId: UInt64) -> RTCVideoTrack? {
        tracks[feedId]
    }
 
    /// Snapshot of all currently live tracks in this room (feedId → track).
    var allTracks: [UInt64: RTCVideoTrack] { tracks }

    // =========================================================================
    // MARK: - Public Verbs
    // =========================================================================

    // MARK: Join

    /// Attach a publisher plugin-handle and join the room.
    /// Publisher role auto-starts publishing after join.
    /// Guest role only subscribes to existing publishers.
    func join() {
        guard state == .idle else { return }
        state = .joining
        attachPlugin { [weak self] handleId in
            guard let self else { return }
            self.locked { self.publisherHandleId = handleId }
            self.sendJoinMessage(handleId: handleId)
        }
    }

    // MARK: Publish

    /// Create a publisher peer-connection and produce an SDP offer.
    /// The offer is delivered via `WebRTCManagerDelegate.didProduceOffer`,
    /// which calls back into `handleOfferProduced(_:handleId:)`.
    func startPublishing() {
        guard let handleId = locked({ publisherHandleId }) else { return }
        _ = rtcManager.createPublisherPeerConnection(handleId: handleId, mediaMode: mediaMode)
        rtcManager.createOffer(handleId: handleId)
    }

    /// Unpublish without leaving the room (guest can call this on demand).
    func stopPublishing() {
        guard let handleId = locked({ publisherHandleId }) else { return }
        let body: [String: Any] = ["request": "unpublish"]
        session.sendMessage(body, handleId: handleId)
        rtcManager.removePeerConnection(handleId: handleId)
    }

    // MARK: Subscribe

    /// Attach a dedicated subscriber handle for `feedId` and start the ICE dance.
    func subscribeFeed(feedId: UInt64) {
        attachPlugin { [weak self] subHandleId in
            guard let self else { return }
            self.locked { self.subscriberHandles[feedId] = subHandleId }
            _ = self.rtcManager.createSubscriberPeerConnection(handleId: subHandleId, feedId: feedId)
            let audio = self.mediaMode != .videoOnly
            let video = self.mediaMode != .audioOnly
            let body: [String: Any] = [
                "request": "join",
                "room":    self.roomId,
                "ptype":   "subscriber",
                "feed":    feedId,
                "audio":   audio,
                "video":   video
            ]
            self.session.sendMessage(body, handleId: subHandleId)
        }
    }

    // MARK: Leave

    /// Gracefully detach all handles and tear down every peer connection.
    func leave() {
        guard state == .joined || state == .joining else { return }
        state = .leaving

        let pubHandle: UInt64?
        let subs:      [UInt64: UInt64]
        lock.lock()
        pubHandle = publisherHandleId
        subs      = subscriberHandles
        publisherHandleId  = nil
        subscriberHandles  = [:]
        lock.unlock()

        if let h = pubHandle {
            session.sendMessage(["request": "leave"], handleId: h)
            rtcManager.removePeerConnection(handleId: h)
            session.detachHandle(h)
        }
        for (_, h) in subs {
            rtcManager.removePeerConnection(handleId: h)
            session.detachHandle(h)
        }

        participants = [:]
        tracks       = [:]
        state        = .idle
    }

    // =========================================================================
    // MARK: - Incoming Message Routing  (called by VideoRoomManager)
    // =========================================================================

    /// Route a Janus plugin-event payload to the appropriate handler.
    func handleEvent(_ event: [String: Any], forHandle handleId: UInt64) {
        guard let pluginData = event["plugindata"] as? [String: Any],
              let data       = pluginData["data"] as? [String: Any] else { return }

        let eventType = data["videoroom"] as? String ?? ""
        switch eventType {
        case "joined":
            handleJoined(data: data, handleId: handleId)
        case "event":
            handleRoomEvent(data: data, handleId: handleId)
        case "attached":
            // Janus will follow with a JSEP offer; nothing to do here.
            
            break
        case "destroyed":
            leave()
            Task { @MainActor in self.delegate?.janusRoom(self, broadcastDidEnd: self.roomId) }
        default:
            break
        }
    }

    /// Route a JSEP (SDP offer or answer) to the correct peer connection.
    func handleJSEP(_ jsep: [String: Any], forHandle handleId: UInt64) {
        guard let sdpString = jsep["sdp"]  as? String,
              let sdpType   = jsep["type"] as? String else { return }

        let type      = sdpType == "offer" ? RTCSdpType.offer : RTCSdpType.answer
        let remoteSDP = RTCSessionDescription(type: type, sdp: sdpString)

        if type == .offer {
            // Subscriber receiving an offer from Janus → produce answer.
            rtcManager.setRemoteDescription(remoteSDP, handleId: handleId) { [weak self] _ in
                guard let self else { return }
                self.rtcManager.createAnswer(handleId: handleId, mediaMode: self.mediaMode)
            }
        } else {
            // Publisher receiving the answer from Janus.
            rtcManager.setRemoteDescription(remoteSDP, handleId: handleId)
        }
    }

    // MARK: WebRTC callbacks (forwarded by VideoRoomManager)

    /// Called when WebRTC delivers a remote video track for a feed in this room.
    func handleTrackReceived(_ track: RTCVideoTrack, feedId: UInt64) {
        tracks[feedId] = track
    }

    /// Called when a remote track is removed.
    func handleTrackRemoved(feedId: UInt64) {
        tracks.removeValue(forKey: feedId)
    }

    // MARK: SDP produced by WebRTC (forwarded by VideoRoomManager)

    /// Send our publish offer to Janus.
    func handleOfferProduced(_ sdp: RTCSessionDescription, handleId: UInt64) {
        let jsep: [String: Any] = ["type": "offer", "sdp": sdp.sdp]
        let audio = mediaMode != .videoOnly
        let video = mediaMode != .audioOnly
        let body: [String: Any] = ["request": "publish", "audio": audio, "video": video]
        session.sendMessage(body, handleId: handleId, jsep: jsep)
    }

    /// Send the subscriber answer to Janus.
    func handleAnswerProduced(_ sdp: RTCSessionDescription, handleId: UInt64) {
        let jsep: [String: Any] = ["type": "answer", "sdp": sdp.sdp]
        let body: [String: Any] = ["request": "start"]
        session.sendMessage(body, handleId: handleId, jsep: jsep)
    }

    // =========================================================================
    // MARK: - Private: Join flow
    // =========================================================================

    private func sendJoinMessage(handleId: UInt64) {
        var body: [String: Any] = [
            "request": role == .publisher ? "joinandconfigure" : "join",
            "room":    roomId,
            "ptype":   "publisher",
            "display": displayName
        ]

        session.sendMessage(body, handleId: handleId) { [weak self] response in
            guard let self else { return }
            self.processJoinResponse(response, handleId: handleId)
        }
    }

    private func processJoinResponse(_ response: [String: Any], handleId: UInt64) {
        guard let pluginData = response["plugindata"] as? [String: Any],
              let data       = pluginData["data"] as? [String: Any] else { return }

        let event = data["videoroom"] as? String ?? ""

        if event == "joined" {
            let id = data["id"] as? UInt64 ?? 0
            myFeedId = id
            state    = .joined

            // Subscribe to any publishers already in the room.
            if let publishers = data["publishers"] as? [[String: Any]] {
                for pub in publishers { processNewPublisher(pub) }
            }

            Task { @MainActor in self.delegate?.janusRoom(self, didJoinWithFeedId: id) }

            // Publisher auto-starts; guests wait to be asked.
//            if role == .publisher { startPublishing() }

        } else if event == "event" {
            if let errorCode = data["error_code"] as? Int {
                switch errorCode {
                case 426 where isRoomCreator && roomCreateAttempts < maxRoomCreateAttempts:
                    // Room not found → create it and retry join.
                    roomCreateAttempts += 1
                    createAndRejoin(handleId: handleId)
                default:
                    let msg = data["error"] as? String ?? "Error \(errorCode)"
                    let error: JanusError = errorCode == 426 ? .roomNotFound : .roomJoinFailed(msg)
                    Task { @MainActor in self.delegate?.janusRoom(self, didFailWithError: error) }
                }
            }
        } else if let error = data["error"] as? String {
            Task { @MainActor in self.delegate?.janusRoom(self, didFailWithError: .roomJoinFailed(error)) }
        }
    }

    // MARK: - Private: Room creation on-demand

    private func createAndRejoin(handleId: UInt64) {
        let body: [String: Any] = [
            "request":    "create",
            "room":       roomId,
            "ptype":      "publisher",
            "publishers": 10_000,
            "display":    displayName
        ]
        session.sendMessage(body, handleId: handleId) { [weak self] response in
            guard let self else { return }
            guard let pluginData = response["plugindata"] as? [String: Any],
                  let data       = pluginData["data"] as? [String: Any],
                  (data["videoroom"] as? String) == "created" else { return }
            self.sendJoinMessage(handleId: handleId)
        }
    }

    // =========================================================================
    // MARK: - Private: Event handling
    // =========================================================================

    private func handleJoined(data: [String: Any], handleId: UInt64) {
        // This path is hit when Janus sends a full "joined" event asynchronously
        // (e.g. after a mid-session publisher list refresh). Subscribe to new ones.
        if let publishers = data["publishers"] as? [[String: Any]] {
            for pub in publishers { processNewPublisher(pub) }
        }
    }

    private func handleRoomEvent(data: [String: Any], handleId: UInt64) {
        // New publishers joined the room while we're already in it.
        if let publishers = data["publishers"] as? [[String: Any]] {
            for pub in publishers { processNewPublisher(pub) }
        }
        // A publisher unpublished their feed (but is still in the room).
        if let unpublished = data["unpublished"] as? UInt64 {
            removeParticipant(feedId: unpublished)
        }
        // A publisher left the room entirely.
        if let leaving = data["leaving"] as? UInt64 {
            removeParticipant(feedId: leaving)
            checkBroadcastEnd()
        }
        // Our publish offer was accepted → stream is live.
        if (data["configured"] as? String) == "ok" {
            let rid = data["room"] as? Int ?? roomId
            Task { @MainActor in self.delegate?.janusRoom(self, didConfigure: rid) }
        }
    }

    private func processNewPublisher(_ pub: [String: Any]) {
        guard let pubId = pub["id"] as? UInt64 else { return }
        let name = pub["display"] as? String ?? "Unknown"
        let participant = JanusParticipant(
            id:           pubId,
            displayName:  name,
            isPublishing: true,
            isAudioMuted: false,
            isVideoMuted: false,
            role:         .publisher,
            roomId:       roomId
        )
        participants[pubId] = participant
        notifyParticipantsUpdated()
        subscribeFeed(feedId: pubId)
    }

    private func removeParticipant(feedId: UInt64) {
        participants.removeValue(forKey: feedId)
        tracks.removeValue(forKey: feedId)
        
        lock.lock()
        let subHandle = subscriberHandles.removeValue(forKey: feedId)
        lock.unlock()

        if let h = subHandle {
            rtcManager.removePeerConnection(handleId: h)
            session.detachHandle(h)
        }

        Task { @MainActor in self.delegate?.janusRoom(self, didParticipantLeave: feedId) }
        notifyParticipantsUpdated()
    }

    private func checkBroadcastEnd() {
        // Guests view the room: if all publishers leave, the broadcast is over.
        if participants.isEmpty && role == .guest {
            Task { @MainActor in self.delegate?.janusRoom(self, broadcastDidEnd: self.roomId) }
        }
    }

    private func notifyParticipantsUpdated() {
        let list = Array(participants.values)
        Task { @MainActor in self.delegate?.janusRoom(self, didUpdateParticipants: list) }
    }

    // =========================================================================
    // MARK: - Private: Helpers
    // =========================================================================

    private func attachPlugin(completion: @escaping (UInt64) -> Void) {
        session.attachPlugin(.videoRoom) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let handleId): completion(handleId)
            case .failure(let error):
                Task { @MainActor in self.delegate?.janusRoom(self, didFailWithError: error) }
            }
        }
    }

    /// Thread-safe getter/setter wrapper.
    @discardableResult
    private func locked<T>(_ block: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return block()
    }
}

// =========================================================================
// MARK: - Public Room Client API Wrapper
// =========================================================================

@MainActor
public class Room: ObservableObject, @unchecked Sendable {
    @Published public private(set) var connectionState: ConnectionState = .disconnected
    @Published public private(set) var localParticipant: LocalParticipant?
    @Published public private(set) var remoteParticipants: [String: RemoteParticipant] = [:]
    
    public weak var delegate: RoomDelegate?
    
    private var roomManager: VideoRoomManager?
    private var primaryRoomId: Int?
    private var currentConfig: SDKConfig?
    
    public init() {}
    
    public func connect(
        url: URL,
        roomId: Int,
        displayName: String,
        role: UserRole,
        isRoomCreator: Bool = false,
        roomConfigs: [RoomConfig] = []
    ) async throws {
        connectionState = .connecting
        delegate?.room(self, didUpdate: .connecting)
        
        let sdkConfig = SDKConfig(
            iceServers: nil,
            janusURL: url,
            roomId: roomId,
            displayName: displayName,
            role: role,
            localUName: displayName,
            roomConfigs: roomConfigs,
            isRoomCreator: isRoomCreator
        )
        self.currentConfig = sdkConfig
        self.primaryRoomId = roomId
        
        let manager = VideoRoomManager(config: sdkConfig)
        self.roomManager = manager
        manager.delegate = self
        
        manager.connect()
    }
    
    public func disconnect() async {
        roomManager?.disconnect()
        roomManager = nil
        primaryRoomId = nil
        currentConfig = nil
        localParticipant = nil
        remoteParticipants = [:]
        connectionState = .disconnected
        delegate?.room(self, didUpdate: .disconnected)
    }
    
    func publish() async throws {
        guard let manager = roomManager, let roomId = primaryRoomId else { return }
        if let room = manager.getRoom(roomId) {
            manager.startLocalMedia(mediaMode: .audioVideo, renderer: nil)
            room.startPublishing()
        }
    }
    
    func unpublish() async throws {
        guard let manager = roomManager, let roomId = primaryRoomId else { return }
        if let room = manager.getRoom(roomId) {
            room.stopPublishing()
            if let local = localParticipant {
                self.objectWillChange.send()
                let pubs = local.trackPublications
                local.trackPublications.removeAll()
                for (_, pub) in pubs {
                    delegate?.room(self, participant: local, didUnpublish: pub)
                }
            }
        }
    }
    
    // MARK: - Internal Hardware Toggles (called by LocalParticipant)
    
    func setLocalCameraEnabled(_ enabled: Bool) async throws {
        guard let manager = roomManager, let roomId = primaryRoomId else { return }
        if enabled {
            if manager.currentLocalVideoTrack == nil {
                if let room = manager.getRoom(roomId) {
                    manager.startLocalMedia(mediaMode: .audioVideo, renderer: nil)
                    room.startPublishing()
                }
            } else {
                manager.muteVideo(false)
            }
        } else {
            manager.muteVideo(true)
        }
        
        if let local = localParticipant {
            self.objectWillChange.send()
            for (_, pub) in local.trackPublications where pub.kind == .video {
                pub.isMuted = !enabled
                pub.track?.isMuted = !enabled
                delegate?.room(self, participant: local, didUpdate: !enabled, for: pub)
            }
        }
    }
    
    func setLocalMicrophoneEnabled(_ enabled: Bool) async throws {
        guard let manager = roomManager else { return }
        manager.muteAudio(!enabled)
        
        if let local = localParticipant {
            self.objectWillChange.send()
            for (_, pub) in local.trackPublications where pub.kind == .audio {
                pub.isMuted = !enabled
                pub.track?.isMuted = !enabled
                delegate?.room(self, participant: local, didUpdate: !enabled, for: pub)
            }
        }
    }
}

// MARK: - VideoRoomManagerDelegate
extension Room: VideoRoomManagerDelegate {
    
    func videoRoomManager(_ mgr: VideoRoomManager) {
        // Session created
    }
    
    func videoRoomManager(_ mgr: VideoRoomManager, didJoinRoom roomId: Int, asRole role: UserRole) {
        guard roomId == primaryRoomId else { return }
        
        connectionState = .connected
        delegate?.room(self, didUpdate: .connected)
        
        let localId = String(mgr.localParticipantId)
        let localName = currentConfig?.displayName ?? "Local"
        let local = LocalParticipant(id: localId, displayName: localName, room: self)
        
        self.localParticipant = local
    }
    
    func videoRoomManager(_ mgr: VideoRoomManager, didConfigure roomId: Int, asRole role: UserRole) {
        guard roomId == primaryRoomId, let local = localParticipant else { return }
        
        self.objectWillChange.send()
        
        if let localVideo = mgr.currentLocalVideoTrack {
            let sid = "local-video"
            let track = VideoTrack(sid: sid, rtcTrack: localVideo)
            let publication = TrackPublication(sid: sid, name: "camera", kind: .video, track: track)
            local.trackPublications[sid] = publication
            delegate?.room(self, participant: local, didPublish: publication)
        }
        
        let sidAudio = "local-audio"
        let trackAudio = Track(sid: sidAudio, kind: .audio)
        let publicationAudio = TrackPublication(sid: sidAudio, name: "microphone", kind: .audio, track: trackAudio)
        local.trackPublications[sidAudio] = publicationAudio
        delegate?.room(self, participant: local, didPublish: publicationAudio)
    }
    
    func videoRoomManager(_ mgr: VideoRoomManager, didPublisherJoin participant: JanusParticipant, inRoom roomId: Int) {
        // Handled via didUpdateParticipants.
    }
    
    func videoRoomManager(_ mgr: VideoRoomManager, didUpdateParticipants list: [JanusParticipant], inRoom roomId: Int) {
        guard roomId == primaryRoomId else { return }
        
        for p in list {
            let pid = String(p.id)
            if pid == localParticipant?.id { continue }
            
            if remoteParticipants[pid] == nil {
                self.objectWillChange.send()
                let remote = RemoteParticipant(id: pid, displayName: p.displayName)
                remoteParticipants[pid] = remote
                delegate?.room(self, participantDidConnect: remote)
            }
        }
    }
    
    func videoRoomManager(_ mgr: VideoRoomManager, didPublisherLeave participantId: UInt64, inRoom roomId: Int) {
        guard roomId == primaryRoomId else { return }
        let pid = String(participantId)
        if remoteParticipants[pid] != nil {
            self.objectWillChange.send()
            if let remote = remoteParticipants.removeValue(forKey: pid) {
                delegate?.room(self, participantDidDisconnect: remote)
            }
        }
    }
    
    func videoRoomManager(_ mgr: VideoRoomManager, didReceiveVideoTrack track: RTCVideoTrack, forFeedId feedId: UInt64, inRoom roomId: Int) {
        guard roomId == primaryRoomId else { return }
        let pid = String(feedId)
        
        self.objectWillChange.send()
        
        var participant: Participant? = remoteParticipants[pid]
        if participant == nil {
            let remote = RemoteParticipant(id: pid, displayName: "Guest-\(feedId)")
            remoteParticipants[pid] = remote
            delegate?.room(self, participantDidConnect: remote)
            participant = remote
        }
        
        guard let p = participant else { return }
        
        let sid = "video-\(feedId)"
        let vTrack = VideoTrack(sid: sid, rtcTrack: track)
        let publication = TrackPublication(sid: sid, name: "video", kind: .video, track: vTrack)
        p.trackPublications[sid] = publication
        delegate?.room(self, participant: p, didPublish: publication)
    }
    
    func videoRoomManager(_ mgr: VideoRoomManager, didRemoveVideoTrack feedId: UInt64, inRoom roomId: Int) {
        guard roomId == primaryRoomId else { return }
        let pid = String(feedId)
        if let p = remoteParticipants[pid] {
            let sid = "video-\(feedId)"
            if let pub = p.trackPublications.removeValue(forKey: sid) {
                self.objectWillChange.send()
                delegate?.room(self, participant: p, didUnpublish: pub)
            }
        }
    }
    
    func videoRoomManager(_ mgr: VideoRoomManager, broadcastEndedInRoom roomId: Int) {
        guard roomId == primaryRoomId else { return }
        Task {
            await disconnect()
        }
    }
    
    func videoRoomManager(_ mgr: VideoRoomManager, didError error: JanusError) {
        print("[LiveKit Room] internal error: \(error.localizedDescription)")
    }
}


