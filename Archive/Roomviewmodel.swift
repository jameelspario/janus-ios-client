//
//  Roomviewmodel.swift
//  janus-test
//
//  Created by jameel on 03/03/26.
//

// RoomViewModel.swift
// Orchestrates room session, participant management, and role transitions

import Foundation
import Combine
import WebRTC

@MainActor
final class RoomViewModel: ObservableObject {

    // MARK: - Published State
    @Published var room: Room
    @Published var localParticipant: Participant
    @Published var sessionState: SessionState = .disconnected
    @Published var publishState: PublishState = .unpublished
    @Published var error: String?
    @Published var isBroadcastEnded: Bool = false

    // MARK: - Services
    let videoRoomService: VideoRoomService
    let webRTC: WebRTCManager

    // MARK: - Private
    private var cancellables = Set<AnyCancellable>()
    private let serverURL: URL
    private let signaling: JanusSignalingManager

    // MARK: - Init
    init(serverURL: URL, room: Room, localUser: Participant) {
        self.serverURL = serverURL
        self.room = room
        self.localParticipant = localUser

        signaling = JanusSignalingManager(serverURL: serverURL)
        webRTC = WebRTCManager()
        videoRoomService = VideoRoomService(signaling: signaling, webRTC: webRTC)

        setupEventHandling()
        setupVideoTrackHandling()
    }

    // MARK: - Connect & Join
    func connect() async {
        sessionState = .connecting
        do {
            try await signaling.connect()
            sessionState = .connected

            // Setup media for publishers/hosts
            if localParticipant.role.canPublish {
                webRTC.setupLocalMedia()
                webRTC.startCapture()
            }

            try await videoRoomService.joinAsPublisher(
                roomId: room.janusRoomId,
                displayName: localParticipant.displayName
            )
        } catch {
            sessionState = .failed(error.localizedDescription)
            self.error = error.localizedDescription
        }
    }

    // MARK: - Publish (host/publisher starts streaming)
    func startPublishing() async {
        guard localParticipant.role.canPublish else { return }
        publishState = .publishing
        do {
            try await videoRoomService.publish()
            publishState = .published
            localParticipant.isVideoEnabled = true
        } catch {
            publishState = .failed(error)
            self.error = error.localizedDescription
        }
    }

    // MARK: - Guest becomes Publisher
    func promoteToPublisher() async {
        guard localParticipant.role == .guest else { return }
        localParticipant.role = .publisher
        webRTC.setupLocalMedia()
        webRTC.startCapture()
        await startPublishing()
    }

    // MARK: - Unpublish (stay in room as guest)
    func unpublish() async {
        do {
            try await videoRoomService.unpublish()
            publishState = .unpublished
            localParticipant.role = .guest
            localParticipant.isVideoEnabled = false
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Leave Room
    func leaveRoom() async {
        do {
            try await videoRoomService.leaveRoom()
            signaling.disconnect()
            sessionState = .disconnected
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Host Ends Broadcast (kicks everyone)
    func endBroadcast() async {
        guard localParticipant.role == .host else { return }
        do {
            try await videoRoomService.endBroadcast()
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Media Controls
    func toggleVideo() {
        let newState = !localParticipant.isVideoEnabled
        localParticipant.isVideoEnabled = newState
        videoRoomService.toggleVideo(newState)
    }

    func toggleAudio() {
        let newState = !localParticipant.isAudioEnabled
        localParticipant.isAudioEnabled = newState
        videoRoomService.toggleAudio(newState)
    }

    func switchCamera() {
        webRTC.switchCamera()
    }

    // MARK: - Event Handling
    private func setupEventHandling() {
        videoRoomService.eventPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleVideoRoomEvent(event)
            }
            .store(in: &cancellables)
    }

    private func handleVideoRoomEvent(_ event: VideoRoomEvent) {
        switch event {
        case .joined(let feedId, let publishers):
            room.isActive = true
            // Subscribe to existing publishers
            Task {
                for publisher in publishers {
                    guard let pubFeedId = publisher["id"] as? Int64 else { continue }
                    await subscribeToPublisher(feedId: pubFeedId, publisher: publisher)
                }
                // Start publishing if role allows
                if localParticipant.role.canPublish {
                    await startPublishing()
                }
            }

        case .publisherJoined(let publisher):
            Task {
                guard let feedId = publisher["id"] as? Int64 else { return }
                await subscribeToPublisher(feedId: feedId, publisher: publisher)
            }

        case .publisherLeft(let feedId):
            removeParticipant(withFeedId: feedId)
            Task { try? await videoRoomService.unsubscribe(feedId: feedId) }

        case .broadcastEnded:
            isBroadcastEnded = true
            room.isBroadcastEnded = true
            Task { await leaveRoom() }

        case .unpublished:
            publishState = .unpublished

        case .error(let msg):
            self.error = msg

        default:
            break
        }
    }

    private func subscribeToPublisher(feedId: Int64, publisher: [String: Any]) async {
        let displayName = publisher["display"] as? String ?? "User"
        let participant = Participant(id: "\(feedId)", displayName: displayName, role: .publisher)
        participant.feedId = feedId

        await MainActor.run {
            if !room.participants.contains(where: { $0.feedId == feedId }) {
                room.participants.append(participant)
            }
        }

        do {
            try await videoRoomService.subscribe(to: feedId, roomId: room.janusRoomId)
        } catch {
            print("Failed to subscribe to feed \(feedId): \(error)")
        }
    }

    private func removeParticipant(withFeedId feedId: Int64) {
        room.participants.removeAll { $0.feedId == feedId }
    }

    // MARK: - Video Track Notification Handler
    private func setupVideoTrackHandling() {
        NotificationCenter.default.publisher(for: .videoTrackReceived)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard
                    let self = self,
                    let feedId = notification.userInfo?["feedId"] as? Int64,
                    let track = notification.userInfo?["track"] as? RTCVideoTrack
                else { return }

                if let participant = self.room.participants.first(where: { $0.feedId == feedId }) {
                    participant.videoTrack = track
                }
            }
            .store(in: &cancellables)
    }
}
