import Foundation

public class Participant: ObservableObject, Identifiable, @unchecked Sendable {
    public let id: String
    @Published public var displayName: String
    @Published public internal(set) var isSpeaking: Bool = false
    @Published public internal(set) var trackPublications: [String: TrackPublication] = [:]
    
    init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

public class LocalParticipant: Participant {
    private weak var room: Room?
    
    init(id: String, displayName: String, room: Room) {
        self.room = room
        super.init(id: id, displayName: displayName)
    }
    
    public func setCamera(enabled: Bool) async throws {
        guard let room = room else { return }
        try await room.setLocalCameraEnabled(enabled)
    }
    
    public func setMicrophone(enabled: Bool) async throws {
        guard let room = room else { return }
        try await room.setLocalMicrophoneEnabled(enabled)
    }
    
    public func publish() async throws {
        guard let room = room else { return }
        try await room.publish()
    }
    
    public func unpublish() async throws {
        guard let room = room else { return }
        try await room.unpublish()
    }
}

public class RemoteParticipant: Participant {
    // Exposes remote participant streams
}
