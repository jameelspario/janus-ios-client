import Foundation

public class TrackPublication: ObservableObject, Identifiable, @unchecked Sendable {
    public let sid: String
    public let name: String
    public let kind: TrackKind
    
    @Published public internal(set) var track: Track?
    @Published public internal(set) var isMuted: Bool = false
    
    public var id: String { sid }
    
    public var isSubscribed: Bool { track != nil }
    
    public init(sid: String, name: String, kind: TrackKind, track: Track? = nil) {
        self.sid = sid
        self.name = name
        self.kind = kind
        self.track = track
        self.isMuted = track?.isMuted ?? false
    }
}
