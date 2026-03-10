//
//  Pkbattleservice.swift
//  janus-test
//
//  Created by jameel on 03/03/26.
//

// PKBattleService.swift
// Manages PK (Player Kill) battle between two hosts in different rooms

import Foundation
import Combine
import WebRTC

// MARK: - PK Battle State
enum PKBattleState {
    case idle
    case inviting            // Sent invite, waiting for response
    case receiving(from: String)  // Received invite from someone
    case active(session: PKSession)
    case ended
}

// MARK: - PK Battle Delegate
protocol PKBattleServiceDelegate: AnyObject {
    func pkBattle(_ service: PKBattleService, didUpdateState state: PKBattleState)
    func pkBattle(_ service: PKBattleService, didReceiveGuestTrack track: RTCVideoTrack)
    func pkBattleDidEnd(_ service: PKBattleService)
}

// MARK: - PKBattleService
@MainActor
final class PKBattleService: ObservableObject {

    // MARK: - Published State
    @Published var battleState: PKBattleState = .idle
    @Published var guestVideoTrack: RTCVideoTrack?
    @Published var hostVideoTrack: RTCVideoTrack?

    // MARK: - Private
    private let serverURL: URL
    private var guestRoomViewModel: RoomViewModel?
    private var pkSession: PKSession?
    private var cancellables = Set<AnyCancellable>()

    // The local host's primary view model
    private weak var hostViewModel: RoomViewModel?

    weak var delegate: PKBattleServiceDelegate?

    // MARK: - Init
    init(serverURL: URL, hostViewModel: RoomViewModel) {
        self.serverURL = serverURL
        self.hostViewModel = hostViewModel
    }

    // MARK: - Start PK Battle
    /// Host initiates PK - connects to guest's room to receive their feed
    func startPKBattle(
        guestRoomId: Int,
        guestRoomTitle: String,
        localHostRoomId: String
    ) async {
        battleState = .inviting

        let guestRoom = Room(
            id: "pk_guest_\(guestRoomId)",
            title: guestRoomTitle,
            janusRoomId: guestRoomId
        )
        guestRoom.roomType = .pkBattle

        // Join guest room as spectator (guest role)
        let spectatorParticipant = Participant(
            id: "pk_spectator_\(UUID().uuidString)",
            displayName: "PK Spectator",
            role: .guest,
            isLocal: true
        )

        let guestVM = RoomViewModel(
            serverURL: serverURL,
            room: guestRoom,
            localUser: spectatorParticipant
        )

        self.guestRoomViewModel = guestVM
        observeGuestRoom(guestVM)

        await guestVM.connect()

        let session = PKSession(
            hostRoomId: localHostRoomId,
            guestRoomId: "\(guestRoomId)"
        )
        pkSession = session
        battleState = .active(session: session)
        delegate?.pkBattle(self, didUpdateState: battleState)
    }

    // MARK: - End PK Battle
    func endPKBattle() async {
        battleState = .ended
        await guestRoomViewModel?.leaveRoom()
        guestRoomViewModel = nil
        pkSession = nil
        guestVideoTrack = nil
        delegate?.pkBattleDidEnd(self)
    }

    // MARK: - Observe Guest Room
    private func observeGuestRoom(_ viewModel: RoomViewModel) {
        // Watch for participant video tracks in guest room
        NotificationCenter.default.publisher(for: .videoTrackReceived)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard
                    let self = self,
                    let track = notification.userInfo?["track"] as? RTCVideoTrack
                else { return }
                // First video track received from guest room = guest's stream
                self.guestVideoTrack = track
                self.delegate?.pkBattle(self, didReceiveGuestTrack: track)
            }
            .store(in: &cancellables)

        // Watch for broadcast end in guest room
        viewModel.$isBroadcastEnded
            .receive(on: DispatchQueue.main)
            .filter { $0 }
            .sink { [weak self] _ in
                Task { await self?.endPKBattle() }
            }
            .store(in: &cancellables)
    }

    // MARK: - Get Host Track
    var hostVideoTrackRef: RTCVideoTrack? {
        hostViewModel?.webRTC.localVideoTrackRef
    }

    // MARK: - PK Active Check
    var isActive: Bool {
        if case .active = battleState { return true }
        return false
    }
}
