import Foundation


public enum ConnectionState: Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting

    public var stringValue: String {
        switch self {
        case .disconnected:
            return "disconnected"
        case .connecting:
            return "connecting"
        case .connected:
            return "connected"
        case .reconnecting:
            return "reconnecting"
        }
    }
}
public protocol RoomDelegate: AnyObject {
    func room(_ room: Room, didUpdate connectionState: ConnectionState)
    func room(_ room: Room, participantDidConnect participant: RemoteParticipant)
    func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant)
    func room(_ room: Room, participant: Participant, didPublish publication: TrackPublication)
    func room(_ room: Room, participant: Participant, didUnpublish publication: TrackPublication)
    func room(_ room: Room, participant: Participant, didUpdate isMuted: Bool, for publication: TrackPublication)
}

public extension RoomDelegate {
    func room(_ room: Room, didUpdate connectionState: ConnectionState) {}
    func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {}
    func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {}
    func room(_ room: Room, participant: Participant, didPublish publication: TrackPublication) {}
    func room(_ room: Room, participant: Participant, didUnpublish publication: TrackPublication) {}
    func room(_ room: Room, participant: Participant, didUpdate isMuted: Bool, for publication: TrackPublication) {}
}
