//
//  Models.swift
//  janus-test
//
//  Created by jameel on 03/03/26.
//

// Models.swift
// Domain models for rooms, participants, and roles

import Foundation
import WebRTC
import Combine

// MARK: - User Role
enum ParticipantRole: String, Codable, Equatable {
    case host        // Original room creator — controls broadcast lifecycle
    case publisher   // Actively publishing video
    case guest       // Watching only (can become publisher)

    var canPublish: Bool { self == .host || self == .publisher }
    var canEndBroadcast: Bool { self == .host }
}

// MARK: - Room Type
enum RoomType {
    case standard        // Normal group call
    case pkBattle        // Two hosts compete in split-screen
    case multiView       // Spectator watching multiple rooms
}

// MARK: - Participant
final class Participant: ObservableObject, Identifiable {
    let id: String           // userId
    let displayName: String
    @Published var role: ParticipantRole
    @Published var isVideoEnabled: Bool = true
    @Published var isAudioEnabled: Bool = true
    @Published var videoTrack: RTCVideoTrack?
    @Published var isLocal: Bool = false

    // Janus handle for this feed subscription
    var handleId: Int64 = 0
    var feedId: Int64 = 0    // Janus publisher feedId

    init(id: String, displayName: String, role: ParticipantRole, isLocal: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.role = role
        self.isLocal = isLocal
    }
}

// MARK: - Room
final class Room: ObservableObject, Identifiable {
    let id: String           // roomId (Janus videoroom id)
    let title: String
    @Published var participants: [Participant] = []
    @Published var isActive: Bool = false
    @Published var isBroadcastEnded: Bool = false

    var roomType: RoomType = .standard
    var janusRoomId: Int      // Numeric Janus room id

    // PK battle partner room id (if any)
    var pkPartnerRoomId: String?

    init(id: String, title: String, janusRoomId: Int) {
        self.id = id
        self.title = title
        self.janusRoomId = janusRoomId
    }

    var publishers: [Participant] {
        participants.filter { $0.role.canPublish }
    }

    var guests: [Participant] {
        participants.filter { $0.role == .guest }
    }

    var host: Participant? {
        participants.first { $0.role == .host }
    }
}

// MARK: - Session State
enum SessionState: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting
    case failed(String)
}

// MARK: - Publish State
enum PublishState {
    case unpublished
    case publishing
    case published
    case failed(Error)
}

// MARK: - Video Room Event
enum VideoRoomEvent {
    case joined(feedId: Int64, publishers: [[String: Any]])
    case publisherJoined(publisher: [String: Any])
    case publisherLeft(feedId: Int64)
    case remoteJsep(feedId: Int64, jsep: [String: Any])
    case configured
    case started
    case unpublished
    case leaving
    case broadcastEnded
    case error(String)
}

// MARK: - PK Session
struct PKSession {
    let hostRoomId: String
    let guestRoomId: String
    var startedAt: Date = Date()

    // The handle in the guest room the host subscribes to
    var guestHandleId: Int64 = 0
    var hostHandleId: Int64 = 0
}

// MARK: - Multi Room Entry
struct MultiRoomEntry: Identifiable {
    let id: String = UUID().uuidString
    let roomId: String
    let title: String
    var publisherFeedId: Int64?
    var handleId: Int64 = 0
    var videoTrack: RTCVideoTrack?
}
