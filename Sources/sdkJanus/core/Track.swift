import Foundation
import WebRTC

public enum TrackKind: String, Sendable {
    case audio
    case video
}

public class Track: NSObject, ObservableObject, @unchecked Sendable {
    public let sid: String
    public let kind: TrackKind
    @Published public internal(set) var isMuted: Bool = false
    
    init(sid: String, kind: TrackKind) {
        self.sid = sid
        self.kind = kind
    }
}

public class VideoTrack: Track {
    public let rtcTrack: RTCVideoTrack
    
    public init(sid: String, rtcTrack: RTCVideoTrack) {
        self.rtcTrack = rtcTrack
        super.init(sid: sid, kind: .video)
    }
}

public class AudioTrack: Track {
    public let rtcTrack: RTCAudioTrack
    
    public init(sid: String, rtcTrack: RTCAudioTrack) {
        self.rtcTrack = rtcTrack
        super.init(sid: sid, kind: .audio)
    }
}
