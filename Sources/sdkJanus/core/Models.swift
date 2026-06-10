
import Foundation
import WebRTC

public extension Notification.Name {
    static let remoteStreamUpdate = Notification.Name("remoteStreamUpdateNotification")
    static let categorySelectionChanged = Notification.Name("categorySelectionChanged")
    
}

// MARK: - User Role
public enum UserRole: Sendable {
    case publisher  // Controls room; video/audio is broadcast to all
    case guest      // Views publisher(s); can optionally publish own feed
}

public enum MediaMode: String, Codable, Sendable {
    case audioVideo = "audio_video"
    case audioOnly = "audio_only"
    case videoOnly = "video_only"
}

public struct RoomConfig: Equatable, Sendable {
    public let roomId: Int
    public let role: UserRole
    public let mediaMode: MediaMode
    public let isRoomCreator: Bool
    
    public init(roomId: Int, role: UserRole = .guest, mediaMode: MediaMode = .audioVideo, isRoomCreator: Bool = false) {
        self.roomId = roomId
        self.role = role
        self.mediaMode = mediaMode
        self.isRoomCreator = isRoomCreator
    }
}

// MARK: - Room State
enum RoomState {
    case idle, joining, joined, leaving, ended
}

// MARK: - Participant
public struct JanusParticipant: Identifiable, Equatable, Hashable, Sendable {
    public let id: UInt64          // Janus publisher/feed ID
    public let displayName: String
    public var isPublishing: Bool
    public var isAudioMuted: Bool
    public var isVideoMuted: Bool
    public var role: UserRole
    public var roomId: Int

    public init(
        id: UInt64,
        displayName: String,
        isPublishing: Bool,
        isAudioMuted: Bool,
        isVideoMuted: Bool,
        role: UserRole,
        roomId: Int
    ) {
        self.id = id
        self.displayName = displayName
        self.isPublishing = isPublishing
        self.isAudioMuted = isAudioMuted
        self.isVideoMuted = isVideoMuted
        self.role = role
        self.roomId = roomId
    }

    public static func == (lhs: JanusParticipant, rhs: JanusParticipant) -> Bool {
        lhs.id == rhs.id && lhs.roomId == rhs.roomId
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(roomId)
    }
}

// MARK: - Room Info
struct RoomInfo: Identifiable {
    let id: UInt64
    var pin: String?
    var participants: [JanusParticipant]
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









// ─────────────────────────────────────────────────────────────────────────────
// MARK: - SDKConfig
// ─────────────────────────────────────────────────────────────────────────────

public struct SDKConfig {

    public var iceServersDictionary: [[String: Any]]? = nil
    public let janusURL:    URL
    public let roomId:      Int
    public let displayName: String
    public let role:        UserRole
    public var multiRoomIds: [Int] = []
    public let localUserName: String
    public let DEBUG: Bool = false
    public var roomConfigs: [RoomConfig] = []
    public let isRoomCreator: Bool

    public init(
        iceServers:   [[String: Any]]?,
        janusURL:     URL,
        roomId:       Int,
        displayName:  String,
        role:         UserRole,
        localUName:   String,
        multiRoomIds: [Int]  = [],
        roomConfigs:  [RoomConfig] = [],
        isRoomCreator: Bool = false
    ) {
        self.iceServersDictionary = iceServers
        self.janusURL             = janusURL
        self.roomId               = roomId
        self.displayName          = displayName
        self.role                 = role
        self.localUserName        = localUName
        self.multiRoomIds         = multiRoomIds
        self.roomConfigs          = roomConfigs
        self.isRoomCreator        = isRoomCreator
    }

    static func buildIceServers(from dictionaries: [[String: Any]]?) -> [RTCIceServer] {
        guard let dictionaries else { return [] }
        return dictionaries.compactMap { dict in
            guard let urls = dict["urls"] as? String else { return nil }
            return RTCIceServer(
                urlStrings: [urls],
                username:   dict["username"]   as? String ?? "",
                credential: dict["credential"] as? String ?? ""
            )
        }
    }
}

public struct ConnectionConfig {
    public let autoJoinRoom:        Bool
    public let autoPublishStream:   Bool
    public let autoSubscribeStream: Bool

    public init(
        autoJoinRoom: Bool = true,
        autoPublishStream: Bool = true,
        autoSubscribeStream: Bool = true
    ) {
        self.autoJoinRoom = autoJoinRoom
        self.autoPublishStream = autoPublishStream
        self.autoSubscribeStream = autoSubscribeStream
    }
}



extension RTCVideoTrack: @unchecked Sendable {}
