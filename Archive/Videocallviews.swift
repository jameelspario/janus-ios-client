//
//  Videocallviews.swift
//  janus-test
//
//  Created by jameel on 03/03/26.
//

// VideoCallViews.swift
// SwiftUI views for group video call, PK battle, and multi-room

import SwiftUI
import WebRTC

// MARK: - RTCVideoView (UIViewRepresentable)
struct RTCVideoViewRepresentable: UIViewRepresentable {
    let videoTrack: RTCVideoTrack?
    var contentMode: UIView.ContentMode = .scaleAspectFill

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView()
        view.videoContentMode = contentMode
        view.clipsToBounds = true
        return view
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        if let track = videoTrack {
//            track.removeRenderer(uiView)
            track.addRenderer(uiView)
        }
    }

    static func dismantleUIView(_ uiView: RTCMTLVideoView, coordinator: ()) {
        uiView.renderFrame(nil)
    }
}

// MARK: - Group Call View
struct GroupCallView: View {
    @StateObject var viewModel: RoomViewModel
    @State private var showLeaveConfirm = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // Top bar
                topBar

                // Video grid
                videoGrid
                    .frame(maxHeight: .infinity)

                // Controls
                controlBar
                    .padding(.bottom, 20)
            }
        }
        .task { await viewModel.connect() }
        .alert("End Broadcast?", isPresented: $showLeaveConfirm) {
            if viewModel.localParticipant.role == .host {
                Button("End for Everyone", role: .destructive) {
                    Task { await viewModel.endBroadcast() }
                }
            }
            Button("Leave", role: .destructive) {
                Task { await viewModel.leaveRoom() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(viewModel.localParticipant.role == .host
                 ? "Ending the broadcast will disconnect all viewers."
                 : "You will leave the broadcast.")
        }
        .overlay {
            if viewModel.isBroadcastEnded {
                broadcastEndedOverlay
            }
        }
    }

    // MARK: - Top Bar
    private var topBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.room.title)
                    .font(.headline)
                    .foregroundColor(.white)
                Label("\(viewModel.room.participants.count + 1)", systemImage: "person.2.fill")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            Spacer()
            Button {
                showLeaveConfirm = true
            } label: {
                Image(systemName: "xmark")
                    .foregroundColor(.white)
                    .padding(8)
                    .background(Color.white.opacity(0.2))
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.7))
    }

    // MARK: - Video Grid
    private var videoGrid: some View {
        let publishers = viewModel.room.publishers
        let totalFeeds = publishers.count + 1 // +1 for local

        return ScrollView {
            LazyVGrid(columns: gridColumns(for: totalFeeds), spacing: 4) {
                // Local video tile
                videoTile(
                    participant: viewModel.localParticipant,
                    isLocal: true
                )

                // Remote publisher tiles
                ForEach(publishers) { participant in
                    videoTile(participant: participant, isLocal: false)
                }
            }
            .padding(4)
        }
    }

    private func videoTile(participant: Participant, isLocal: Bool) -> some View {
        ZStack {
            Color(white: 0.1)

            if isLocal && viewModel.localParticipant.isVideoEnabled {
                RTCVideoViewRepresentable(videoTrack: viewModel.webRTC.localVideoTrackRef)
                    .aspectRatio(9/16, contentMode: .fit)
            } else if !isLocal, let track = participant.videoTrack {
                RTCVideoViewRepresentable(videoTrack: track)
                    .aspectRatio(9/16, contentMode: .fit)
            } else {
                avatarPlaceholder(name: participant.displayName)
            }

            // Overlay: name + role badge
            VStack {
                Spacer()
                HStack {
                    Text(participant.displayName)
                        .font(.caption)
                        .foregroundColor(.white)
                        .lineLimit(1)

                    if participant.role == .host {
                        Text("HOST")
                            .font(.caption2)
                            .foregroundColor(.yellow)
                            .padding(.horizontal, 4)
                            .background(Color.black.opacity(0.5))
                            .cornerRadius(3)
                    }

                    Spacer()

                    if !participant.isAudioEnabled {
                        Image(systemName: "mic.slash.fill")
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
                .padding(6)
                .background(LinearGradient(
                    gradient: Gradient(colors: [.clear, .black.opacity(0.7)]),
                    startPoint: .top, endPoint: .bottom
                ))
            }
        }
        .aspectRatio(9/16, contentMode: .fit)
        .cornerRadius(8)
        .clipped()
    }

    private func avatarPlaceholder(name: String) -> some View {
        ZStack {
            Color(white: 0.15)
            Text(name.prefix(1).uppercased())
                .font(.system(size: 40, weight: .semibold))
                .foregroundColor(.white)
        }
    }

    private func gridColumns(for count: Int) -> [GridItem] {
        count <= 1 ? [GridItem(.flexible())] :
        count <= 4 ? [GridItem(.flexible()), GridItem(.flexible())] :
                     [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
    }

    // MARK: - Control Bar
    private var controlBar: some View {
        HStack(spacing: 24) {
            // Mic toggle
            controlButton(
                icon: viewModel.localParticipant.isAudioEnabled ? "mic.fill" : "mic.slash.fill",
                color: viewModel.localParticipant.isAudioEnabled ? .white : .red
            ) { viewModel.toggleAudio() }

            // Camera toggle
            controlButton(
                icon: viewModel.localParticipant.isVideoEnabled ? "video.fill" : "video.slash.fill",
                color: viewModel.localParticipant.isVideoEnabled ? .white : .red
            ) { viewModel.toggleVideo() }

            // Camera flip
            controlButton(icon: "arrow.triangle.2.circlepath.camera.fill", color: .white) {
                viewModel.switchCamera()
            }

            // Publish/Unpublish for guest-publishers
            if viewModel.localParticipant.role == .guest {
                controlButton(icon: "antenna.radiowaves.left.and.right", color: .green) {
                    Task { await viewModel.promoteToPublisher() }
                }
            } else if viewModel.localParticipant.role == .publisher {
                controlButton(icon: "antenna.radiowaves.left.and.right.slash", color: .orange) {
                    Task { await viewModel.unpublish() }
                }
            }

            // Leave button
            controlButton(icon: "phone.down.fill", color: .red, background: Color.red.opacity(0.2)) {
                showLeaveConfirm = true
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.8))
        .cornerRadius(20)
        .padding(.horizontal, 16)
    }

    private func controlButton(
        icon: String,
        color: Color,
        background: Color = Color.white.opacity(0.15),
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(color)
                .frame(width: 52, height: 52)
                .background(background)
                .clipShape(Circle())
        }
    }

    // MARK: - Broadcast Ended Overlay
    private var broadcastEndedOverlay: some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "tv.slash")
                    .font(.system(size: 60))
                    .foregroundColor(.white)
                Text("Broadcast Ended")
                    .font(.title2.bold())
                    .foregroundColor(.white)
                Text("The host has ended this broadcast.")
                    .foregroundColor(.gray)
            }
        }
    }
}

// MARK: - PK Battle View
struct PKBattleView: View {
    @StateObject var pkService: PKBattleService
    let hostTrack: RTCVideoTrack?

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                // Host side (left)
                ZStack {
                    if let track = hostTrack {
                        RTCVideoViewRepresentable(videoTrack: track)
                    } else {
                        Color(white: 0.1)
                        Text("You").foregroundColor(.white)
                    }
                    pkLabel(text: "YOU", alignment: .bottomLeading)
                }
                .frame(width: geo.size.width / 2)

                // Guest side (right)
                ZStack {
                    if let track = pkService.guestVideoTrack {
                        RTCVideoViewRepresentable(videoTrack: track)
                    } else {
                        Color(white: 0.1)
                        ProgressView().tint(.white)
                    }
                    pkLabel(text: "GUEST", alignment: .bottomTrailing)
                }
                .frame(width: geo.size.width / 2)
            }
            .clipped()
            .overlay(alignment: .top) {
                pkBattleBanner
            }
        }
    }

    private func pkLabel(text: String, alignment: Alignment) -> some View {
        ZStack(alignment: alignment) {
            Color.clear
            Text(text)
                .font(.caption.bold())
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.purple.opacity(0.8))
                .cornerRadius(4)
                .padding(8)
        }
    }

    private var pkBattleBanner: some View {
        HStack {
            Image(systemName: "bolt.fill")
                .foregroundColor(.yellow)
            Text("PK BATTLE")
                .font(.caption.bold())
                .foregroundColor(.yellow)
            Image(systemName: "bolt.fill")
                .foregroundColor(.yellow)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.7))
        .cornerRadius(8)
        .padding(.top, 8)
    }
}

// MARK: - Multi Room Grid View
struct MultiRoomGridView: View {
    @StateObject var service: MultiRoomService
    @State private var showJoinSheet = false
    @State private var roomIdInput = ""
    @State private var roomTitleInput = ""

    let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()

                if service.rooms.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(service.rooms) { entry in
                                roomCell(entry: entry)
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Live Rooms")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showJoinSheet = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(.purple)
                    }
                    .disabled(service.maxRoomsReached)
                }
            }
        }
        .sheet(isPresented: $showJoinSheet) {
            joinRoomSheet
        }
    }

    // MARK: - Room Cell
    private func roomCell(entry: MultiRoomEntry2) -> some View {
        ZStack {
            Color(white: 0.1)
                .cornerRadius(12)

            if let firstParticipant = entry.participants.first,
               let track = firstParticipant.videoTrack {
                RTCVideoViewRepresentable(videoTrack: track)
                    .cornerRadius(12)
            } else if entry.isConnected {
                VStack {
                    ProgressView().tint(.white)
                    Text("Connecting...")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            } else {
                VStack {
                    Image(systemName: "wifi.slash")
                        .foregroundColor(.red)
                    Text(entry.error ?? "Not connected")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }

            // Room info overlay
            VStack {
                Spacer()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.roomConfig.title)
                            .font(.caption.bold())
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Label("\(entry.participants.count)", systemImage: "eye.fill")
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }
                    Spacer()
                    Button {
                        Task { await service.leaveRoom(janusRoomId: entry.roomConfig.janusRoomId) }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.white)
                            .font(.system(size: 20))
                    }
                }
                .padding(8)
                .background(
                    LinearGradient(
                        gradient: Gradient(colors: [.clear, .black.opacity(0.8)]),
                        startPoint: .top, endPoint: .bottom
                    )
                )
            }

            // Live badge
            if entry.isConnected {
                VStack {
                    HStack {
                        Text("LIVE")
                            .font(.caption2.bold())
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.red)
                            .cornerRadius(4)
                        Spacer()
                    }
                    .padding(8)
                    Spacer()
                }
            }
        }
        .aspectRatio(9/16, contentMode: .fit)
        .cornerRadius(12)
        .clipped()
    }

    // MARK: - Empty State
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "tv.and.hifispeaker.fill")
                .font(.system(size: 60))
                .foregroundColor(.gray)
            Text("No Rooms")
                .font(.title3)
                .foregroundColor(.white)
            Text("Tap + to join a live room")
                .foregroundColor(.gray)
        }
    }

    // MARK: - Join Sheet
    private var joinRoomSheet: some View {
        NavigationView {
            Form {
                Section(header: Text("Room Details")) {
                    TextField("Room ID (numeric)", text: $roomIdInput)
                        .keyboardType(.numberPad)
                    TextField("Room Title", text: $roomTitleInput)
                }

                Section {
                    Button("Join Room") {
                        guard let id = Int(roomIdInput), !roomTitleInput.isEmpty else { return }
                        Task {
                            try? await service.joinRoom(janusRoomId: id, title: roomTitleInput)
                            showJoinSheet = false
                            roomIdInput = ""
                            roomTitleInput = ""
                        }
                    }
                    .disabled(roomIdInput.isEmpty || roomTitleInput.isEmpty)
                }

                if service.maxRoomsReached {
                    Section {
                        Text("Maximum rooms reached (\(service.rooms.count))")
                            .foregroundColor(.orange)
                    }
                }
            }
            .navigationTitle("Join Room")
            .navigationBarItems(trailing: Button("Cancel") {
                showJoinSheet = false
            })
        }
    }
}
