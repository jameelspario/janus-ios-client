//
//  JanusModels.swift
//  janus-test
//
//  Created by jameel on 03/03/26.
//

// JanusModels.swift
// Core data models, enums, and error types

import Foundation
import WebRTC

// MARK: - User Role
enum UserRole {
    case publisher  // Controls room; video/audio is broadcast to all
    case guest      // Views publisher(s); can optionally publish own feed
}

// MARK: - Room State
enum RoomState {
    case idle, joining, joined, leaving, ended
}

// MARK: - Participant
struct Participant: Identifiable, Equatable, Hashable {
    let id: UInt64          // Janus publisher/feed ID
    let displayName: String
    var isPublishing: Bool
    var isAudioMuted: Bool
    var isVideoMuted: Bool
    var role: UserRole
    var roomId: UInt64

    static func == (lhs: Participant, rhs: Participant) -> Bool {
        lhs.id == rhs.id && lhs.roomId == rhs.roomId
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(roomId)
    }
}

// MARK: - Room Info
struct RoomInfo: Identifiable {
    let id: UInt64
    var pin: String?
    var participants: [Participant]
    var isActive: Bool
    var isPKRoom: Bool
}

// MARK: - Multi-Room Entry (for PK / multi-room viewer)
struct MultiRoomEntry {
    let roomId: UInt64
    var publisherHandleId: UInt64?
    var subscriberHandleId: UInt64?
    var participants: [Participant]
    var isJoined: Bool
}

// MARK: - PK Session
struct PKSession {
    let localRoomId: UInt64
    let remoteRoomId: UInt64
    var isActive: Bool
}

// MARK: - Janus Plugin
enum JanusPlugin: String {
    case videoRoom = "janus.plugin.videoroom"
}

// MARK: - Janus Error
enum JanusError: LocalizedError {
    case connectionFailed
    case sessionCreationFailed
    case pluginAttachFailed
    case roomJoinFailed(String)
    case publishFailed(String)
    case subscribeFailed(String)
    case messageParsingFailed
    case unknownError(String)
    case roomNotFound
    case iceFailure
    case alreadyInRoom

    var errorDescription: String? {
        switch self {
        case .connectionFailed:          return "WebSocket connection failed"
        case .sessionCreationFailed:     return "Janus session creation failed"
        case .pluginAttachFailed:        return "Plugin attach failed"
        case .roomJoinFailed(let msg):   return "Room join failed: \(msg)"
        case .publishFailed(let msg):    return "Publish failed: \(msg)"
        case .subscribeFailed(let msg):  return "Subscribe failed: \(msg)"
        case .messageParsingFailed:      return "Failed to parse Janus message"
        case .unknownError(let msg):     return "Unknown error: \(msg)"
        case .roomNotFound:              return "Room not found"
        case .iceFailure:                return "ICE connection failure"
        case .alreadyInRoom:             return "Already joined this room"
        }
    }
}
