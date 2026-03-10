//
//  GroupCallView.swift
//  janus-test
//
//  Created by jameel on 03/03/26.
//

// GroupCallView.swift
// SwiftUI conversion of GroupCallViewController
// Supports: publisher/guest roles, PK battle, multi-room viewing

import SwiftUI
import WebRTC
import Combine

// MARK: - RTCVideoView SwiftUI Wrapper
struct VideoFeedView: UIViewRepresentable {
    let track: RTCVideoTrack?

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView()
        view.videoContentMode = .scaleAspectFill
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        if let old = context.coordinator.currentTrack {
            old.removeRenderer(uiView)
        }
        if let newTrack = track {
            newTrack.addRenderer(uiView)
            context.coordinator.currentTrack = newTrack
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator {
        var currentTrack: RTCVideoTrack?
    }
}

struct LocalVideoView: UIViewRepresentable {
    let view: RTCMTLVideoView
    func makeUIView(context: Context) -> RTCMTLVideoView { view }
    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {}
}

// MARK: - ViewModel
@MainActor
final class GroupCallViewModel: ObservableObject {

    @Published var isConnected = false
    @Published var hasJoined = false
    @Published var remoteTracks: [UInt64: RTCVideoTrack] = [:]
    @Published var participants: [Participant] = []
    @Published var broadcastEnded = false
    @Published var errorMessage: String? = nil
    @Published var isAudioMuted = false
    @Published var isVideoMuted = false
    @Published var isGuestPublishing = false
    @Published var isPKActive = false
    @Published var showLeaveConfirmation = false

    let config: Config
    private var roomManager: VideoRoomManager!
    private let localRTCView = RTCMTLVideoView()

    init(config: Config) {
        self.config = config
        roomManager = VideoRoomManager(janusURL: config.janusURL)
        roomManager.delegate = self
    }

    func start() {
        roomManager.startLocalPreview(renderer: localRTCView)
        roomManager.connect()
    }

    func stop() {
        roomManager.disconnect()
    }

    func toggleAudio() {
        isAudioMuted.toggle()
        roomManager.muteAudio(isAudioMuted)
    }

    func toggleVideo() {
        isVideoMuted.toggle()
        roomManager.muteVideo(isVideoMuted)
    }

    func toggleGuestPublish() {
        guard config.role == .guest else { return }
        isGuestPublishing ? roomManager.guestStopPublishing() : roomManager.guestStartPublishing()
        isGuestPublishing.toggle()
    }

    func leaveAsGuest() {
        roomManager.guestLeaveRoom(roomId: config.roomId)
    }

    func leaveAsPublisher() {
        roomManager.publisherLeaveRoom(roomId: config.roomId)
    }

    func endPK() {
        roomManager.endPKBattle()
        isPKActive = false
    }

    func localRendererView() -> RTCMTLVideoView { localRTCView }
}

// MARK: - VideoRoomManagerDelegate

extension GroupCallViewModel: VideoRoomManagerDelegate {

    func videoRoomManager(_ mgr: VideoRoomManager) {
        switch config.role {
        case .guest:
            roomManager.joinRoomAsGuest(roomId: config.roomId, displayName: config.displayName)
        case .publisher:
            roomManager.joinRoomAsPublisher(roomId: config.roomId, displayName: config.displayName)
        }
    }
    
    func videoRoomManager(_ mgr: VideoRoomManager, didJoinRoom roomId: UInt64, asRole role: UserRole) {
        hasJoined = true
        isConnected = true
        if let pkRoomId = config.pkRoomId, role == .publisher {
            mgr.startPKBattle(localRoomId: config.roomId, remoteRoomId: pkRoomId, displayName: config.displayName)
            isPKActive = true
        }
        if !config.multiRoomIds.isEmpty {
            mgr.joinMultipleRooms(roomIds: config.multiRoomIds, displayName: config.displayName)
        }
    }

    func videoRoomManager(_ mgr: VideoRoomManager, didPublisherJoin participant: Participant, inRoom roomId: UInt64) {}

    func videoRoomManager(_ mgr: VideoRoomManager, didPublisherLeave participantId: UInt64, inRoom roomId: UInt64) {
        participants.removeAll { $0.id == participantId }
    }

    func videoRoomManager(_ mgr: VideoRoomManager, didReceiveVideoTrack track: RTCVideoTrack, forFeedId feedId: UInt64, inRoom roomId: UInt64) {
        remoteTracks[feedId] = track
    }

    func videoRoomManager(_ mgr: VideoRoomManager, didRemoveVideoTrack feedId: UInt64, inRoom roomId: UInt64) {
        remoteTracks.removeValue(forKey: feedId)
    }

    func videoRoomManager(_ mgr: VideoRoomManager, broadcastEndedInRoom roomId: UInt64) {
        if config.role == .guest { broadcastEnded = true }
    }

    func videoRoomManager(_ mgr: VideoRoomManager, didError error: JanusError) {
        errorMessage = error.localizedDescription
    }

    func videoRoomManager(_ mgr: VideoRoomManager, didUpdateParticipants participants: [Participant], inRoom roomId: UInt64) {
        self.participants = participants
    }
}

struct Config {
    
    static let signalingServerURL = "wss://janus.conf.meetecho.com/ws"
    static let defaultRoomID: UInt64 = 1234
    static let defaultDisplayName = "iOS User"
    enum WebRTC {
        static let iceServers = ["stun:stun.l.google.com:19302", "stun:stun1.l.google.com:19302"]
    }
    
    let janusURL: URL
    let roomId: UInt64
    let displayName: String
    let role: UserRole
    var pin: String? = nil
    var pkRoomId: UInt64? = nil
    var multiRoomIds: [UInt64] = []
}
// MARK: - GroupCallView
struct GroupCallView: View {

    
    @StateObject private var vm: GroupCallViewModel
    @Environment(\.dismiss) private var dismiss

    init(config: Config) {
        _vm = StateObject(wrappedValue: GroupCallViewModel(config: config))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                GeometryReader { geo in
                    videoContentArea(size: geo.size)
                }
                controlsBar
            }

            if vm.broadcastEnded { broadcastEndedOverlay }
        }
        .onAppear { vm.start() }
        .onDisappear { vm.stop() }
        .alert("End Broadcast?", isPresented: $vm.showLeaveConfirmation) {
            Button("End Broadcast", role: .destructive) { vm.leaveAsPublisher(); dismiss() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Leaving as host will end the broadcast for all viewers.")
        }
        .alert("Error", isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(vm.errorMessage ?? "")
        }
        .preferredColorScheme(.dark)
        .statusBar(hidden: true)
    }

    // MARK: Top Bar
    private var topBar: some View {
        HStack(spacing: 10) {
            // Live indicator
            HStack(spacing: 6) {
                LiveDot(isLive: vm.hasJoined)
                Text(vm.hasJoined ? "LIVE" : "Connecting...")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(vm.hasJoined ? .red : .gray)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())

            Spacer()

            // Viewer count
            if !vm.participants.isEmpty {
                Label("\(vm.participants.count)", systemImage: "person.2.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
            }

            // PK badge
            if vm.isPKActive {
                Text("⚔️ PK")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        LinearGradient(colors: [.orange, .red], startPoint: .leading, endPoint: .trailing),
                        in: Capsule()
                    )
            }

            // Role badge
            Text(vm.config.role == .publisher ? "HOST" : "GUEST")
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .foregroundStyle(vm.config.role == .publisher ? .black : .white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(vm.config.role == .publisher ? Color.yellow : Color.white.opacity(0.2), in: Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: Video Content Area
    @ViewBuilder
    private func videoContentArea(size: CGSize) -> some View {
        if vm.isPKActive {
            pkLayout(size: size)
        } else {
            standardLayout(size: size)
        }
    }

    // Standard grid layout
    @ViewBuilder
    private func standardLayout(size: CGSize) -> some View {
        ZStack(alignment: .bottomTrailing) {
            if vm.remoteTracks.isEmpty {
                waitingView
            } else {
                remoteVideoGrid(size: size)
            }
            localPiPView.padding(12)
        }
    }

    private func remoteVideoGrid(size: CGSize) -> some View {
        let tracks = Array(vm.remoteTracks)
        let cols = tracks.count <= 1 ? 1 : tracks.count <= 4 ? 2 : 3
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: cols),
            spacing: 4
        ) {
            ForEach(tracks, id: \.key) { feedId, track in
                RemoteFeedTile(
                    feedId: feedId,
                    track: track,
                    participant: vm.participants.first { $0.id == feedId }
                )
                .aspectRatio(9/16, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(4)
    }

    // PK side-by-side layout
    @ViewBuilder
    private func pkLayout(size: CGSize) -> some View {
        let tracks = Array(vm.remoteTracks)
        let half = tracks.count / 2 + tracks.count % 2
        HStack(spacing: 0) {
            // Left: local room
            VStack(spacing: 3) {
                ForEach(tracks.prefix(half), id: \.key) { feedId, track in
                    RemoteFeedTile(feedId: feedId, track: track, participant: nil)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                if tracks.isEmpty { pkPlaceholder("Your Room") }
            }

            // VS divider
            ZStack {
                LinearGradient(colors: [.orange, .red, .orange], startPoint: .top, endPoint: .bottom)
                    .frame(width: 3)
                Text("VS")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(.red, in: RoundedRectangle(cornerRadius: 4))
            }
            .frame(width: 34)

            // Right: remote room
            VStack(spacing: 3) {
                ForEach(tracks.suffix(tracks.count - half), id: \.key) { feedId, track in
                    RemoteFeedTile(feedId: feedId, track: track, participant: nil)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                if tracks.count < 2 { pkPlaceholder("Remote Room") }
            }
        }
        .padding(4)
        .overlay(alignment: .bottomTrailing) {
            localPiPView.padding(12)
        }
    }

    private func pkPlaceholder(_ label: String) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.white.opacity(0.05))
            .aspectRatio(9/16, contentMode: .fit)
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: "video.slash").foregroundStyle(.white.opacity(0.25))
                    Text(label).font(.caption).foregroundStyle(.white.opacity(0.35))
                }
            }
    }

    // Local PiP thumbnail
    private var localPiPView: some View {
        LocalVideoView(view: vm.localRendererView())
            .frame(width: 90, height: 130)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.25), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
            .opacity(vm.isVideoMuted ? 0.4 : 1)
            .overlay(alignment: .topTrailing) {
                if vm.isVideoMuted {
                    Image(systemName: "video.slash.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(.black.opacity(0.7), in: Circle())
                        .padding(4)
                }
            }
    }

    // Waiting state
    private var waitingView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "video.fill")
                .font(.system(size: 36))
                .foregroundStyle(.white.opacity(0.2))
            Text(vm.config.role == .publisher ? "Starting broadcast…" : "Waiting for host…")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Controls Bar
    private var controlsBar: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                .frame(height: 28)
                .allowsHitTesting(false)

            HStack(spacing: 18) {
                ControlButton(icon: vm.isAudioMuted ? "mic.slash.fill" : "mic.fill",
                              label: vm.isAudioMuted ? "Unmute" : "Mute",
                              tint: vm.isAudioMuted ? .red : .white) { vm.toggleAudio() }

                ControlButton(icon: vm.isVideoMuted ? "video.slash.fill" : "video.fill",
                              label: vm.isVideoMuted ? "Cam On" : "Cam Off",
                              tint: vm.isVideoMuted ? .red : .white) { vm.toggleVideo() }

                if vm.config.role == .guest {
                    ControlButton(
                        icon: vm.isGuestPublishing ? "stop.circle.fill" : "dot.radiowaves.left.and.right",
                        label: vm.isGuestPublishing ? "Stop Live" : "Go Live",
                        tint: vm.isGuestPublishing ? .orange : .green
                    ) { vm.toggleGuestPublish() }
                }

                if vm.isPKActive {
                    ControlButton(icon: "xmark.circle.fill", label: "End PK", tint: .orange) { vm.endPK() }
                }

                Spacer()

                // Leave / End broadcast
                Button {
                    vm.config.role == .publisher ? (vm.showLeaveConfirmation = true) : { vm.leaveAsGuest(); dismiss() }()
                } label: {
                    Label(vm.config.role == .publisher ? "End" : "Leave",
                          systemImage: vm.config.role == .publisher ? "stop.fill" : "arrow.left.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(Color.red.opacity(0.85), in: Capsule())
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color.black)
        }
    }

    // MARK: Broadcast Ended Overlay
    private var broadcastEndedOverlay: some View {
        ZStack {
            Color.black.opacity(0.88).ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.red)
                Text("Broadcast Ended")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                Text("The host has ended the broadcast.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.55))
                Button { dismiss() } label: {
                    Text("Leave Room")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 180, height: 50)
                        .background(Color.red, in: RoundedRectangle(cornerRadius: 14))
                }
                .padding(.top, 8)
            }
        }
    }
}

// MARK: - Remote Feed Tile

struct RemoteFeedTile: View {
    let feedId: UInt64
    let track: RTCVideoTrack
    let participant: Participant?

    var body: some View {
        ZStack(alignment: .bottom) {
            VideoFeedView(track: track)

            // Name label
            if let name = participant?.displayName {
                HStack(spacing: 4) {
                    if participant?.role == .publisher {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.yellow)
                    }
                    Text(name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(8)
            }

            // Audio muted indicator
            if participant?.isAudioMuted == true {
                Image(systemName: "mic.slash.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(.black.opacity(0.6), in: Circle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(6)
            }
        }
    }
}

// MARK: - Control Button

struct ControlButton: View {
    let icon: String
    let label: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack {
                    Circle().fill(tint.opacity(0.15)).frame(width: 48, height: 48)
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(tint)
                }
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(tint.opacity(0.8))
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Live Dot Indicator

struct LiveDot: View {
    let isLive: Bool
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(isLive ? Color.red : Color.gray)
            .frame(width: 8, height: 8)
            .overlay(
                isLive ? Circle()
                    .stroke(Color.red.opacity(0.4), lineWidth: 4)
                    .scaleEffect(pulse ? 2.2 : 1)
                    .opacity(pulse ? 0 : 0.6)
                    .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false), value: pulse)
                : nil
            )
            .onAppear { if isLive { pulse = true } }
            .onChange(of: isLive) { pulse = $0 }
    }
}

// MARK: - Static Factory Helpers

extension GroupCallView {
    static func asPublisher(url: URL, roomId: UInt64, displayName: String, pin: String? = nil) -> GroupCallView {
        .init(config: .init(janusURL: url, roomId: roomId, displayName: displayName, role: .publisher, pin: pin))
    }
    static func asGuest(url: URL, roomId: UInt64, displayName: String, pin: String? = nil) -> GroupCallView {
        .init(config: .init(janusURL: url, roomId: roomId, displayName: displayName, role: .guest, pin: pin))
    }
    static func asPKHost(url: URL, localRoomId: UInt64, remoteRoomId: UInt64, displayName: String) -> GroupCallView {
        .init(config: .init(janusURL: url, roomId: localRoomId, displayName: displayName, role: .publisher, pkRoomId: remoteRoomId))
    }
    static func asMultiRoomViewer(url: URL, roomIds: [UInt64], displayName: String) -> GroupCallView {
        .init(config: .init(janusURL: url, roomId: roomIds[0], displayName: displayName, role: .guest, multiRoomIds: roomIds))
    }
}
