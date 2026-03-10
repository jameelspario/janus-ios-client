//
//  Multiroomservice.swift
//  janus-test
//
//  Created by jameel on 03/03/26.
//

// MultiRoomService.swift
// Allows a user to join multiple rooms simultaneously as spectator

import Foundation
import Combine
import WebRTC

// MARK: - MultiRoomEntry (extended)
final class MultiRoomEntry2: ObservableObject, Identifiable {
    let id: String = UUID().uuidString
    let roomConfig: RoomConfig
    @Published var participants: [Participant] = []
    @Published var isConnected: Bool = false
    @Published var error: String?

    var viewModel: RoomViewModel?

    struct RoomConfig {
        let roomId: String
        let janusRoomId: Int
        let title: String
    }

    init(config: RoomConfig) {
        self.roomConfig = config
    }
}

// MARK: - MultiRoomService
@MainActor
final class MultiRoomService: ObservableObject {

    // MARK: - Published
    @Published var rooms: [MultiRoomEntry2] = []
    @Published var maxRoomsReached: Bool = false

    private let serverURL: URL
    private let maxRooms: Int
    private var cancellables = Set<AnyCancellable>()

    private let localUserId: String
    private let localDisplayName: String

    // MARK: - Init
    init(serverURL: URL, localUserId: String, localDisplayName: String, maxRooms: Int = 6) {
        self.serverURL = serverURL
        self.localUserId = localUserId
        self.localDisplayName = localDisplayName
        self.maxRooms = maxRooms
    }

    // MARK: - Join Room
    func joinRoom(janusRoomId: Int, title: String) async throws {
        guard rooms.count < maxRooms else {
            maxRoomsReached = true
            throw JanusError.signalingError("Maximum rooms (\(maxRooms)) reached")
        }

        // Prevent duplicate joins
        guard !rooms.contains(where: { $0.roomConfig.janusRoomId == janusRoomId }) else {
            throw JanusError.signalingError("Already joined room \(janusRoomId)")
        }

        let config = MultiRoomEntry2.RoomConfig(
            roomId: UUID().uuidString,
            janusRoomId: janusRoomId,
            title: title
        )
        let entry = MultiRoomEntry2(config: config)
        rooms.append(entry)

        // Create a spectator view model for this room
        let room = Room(id: config.roomId, title: title, janusRoomId: janusRoomId)
        room.roomType = .multiView

        let spectator = Participant(
            id: "spectator_\(localUserId)_\(janusRoomId)",
            displayName: localDisplayName,
            role: .guest,
            isLocal: true
        )

        let viewModel = RoomViewModel(serverURL: serverURL, room: room, localUser: spectator)
        entry.viewModel = viewModel

        // Observe room participants
        viewModel.$room
            .receive(on: DispatchQueue.main)
            .sink { [weak entry] updatedRoom in
                entry?.participants = updatedRoom.participants
            }
            .store(in: &cancellables)

        viewModel.$sessionState
            .receive(on: DispatchQueue.main)
            .sink { [weak entry] state in
                if case .connected = state { entry?.isConnected = true }
                else if case .disconnected = state { entry?.isConnected = false }
                else if case .failed(let msg) = state { entry?.error = msg }
            }
            .store(in: &cancellables)

        await viewModel.connect()
    }

    // MARK: - Leave Room
    func leaveRoom(janusRoomId: Int) async {
        guard let index = rooms.firstIndex(where: { $0.roomConfig.janusRoomId == janusRoomId }) else { return }
        let entry = rooms[index]
        await entry.viewModel?.leaveRoom()
        rooms.remove(at: index)
        maxRoomsReached = rooms.count >= maxRooms
    }

    // MARK: - Leave All Rooms
    func leaveAllRooms() async {
        await withTaskGroup(of: Void.self) { group in
            for entry in rooms {
                group.addTask { await entry.viewModel?.leaveRoom() }
            }
        }
        rooms.removeAll()
        maxRoomsReached = false
    }

    // MARK: - Get Room Entry
    func entry(for janusRoomId: Int) -> MultiRoomEntry2? {
        rooms.first { $0.roomConfig.janusRoomId == janusRoomId }
    }

    // MARK: - Get Video Track for Room/Feed
    func videoTrack(roomId: Int, feedId: Int64) -> RTCVideoTrack? {
        entry(for: roomId)?.participants.first(where: { $0.feedId == feedId })?.videoTrack
    }
}
