//
//  Janusvideocallapp.swift
//  janus-test
//
//  Created by jameel on 03/03/26.
//

// JanusVideoCallApp.swift
// App entry point and dependency wiring

import SwiftUI

// MARK: - App Configuration
struct AppConfiguration {
    // Replace with your Janus WebSocket endpoint
    static let janusServerURL = URL(string: "wss://bindaslive.com/janus")!
    static let defaultUserId = UUID().uuidString
    static let defaultDisplayName = "User_\(String(AppConfiguration.defaultUserId.prefix(5)))"
}

// MARK: - Root App
//@main
//struct JanusVideoCallApp: App {
//    var body: some Scene {
//        WindowGroup {
//            RootNavigationView()
//        }
//    }
//}

// MARK: - Root Navigation
struct RootNavigationView: View {
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            // --- Demo: Start a Group Call as Host ---
            HostDemoView()
                .tabItem {
                    Label("Live", systemImage: "video.fill")
                }
                .tag(0)

            // --- Multi Room Viewer ---
            MultiRoomGridView(
                service: MultiRoomService(
                    serverURL: AppConfiguration.janusServerURL,
                    localUserId: AppConfiguration.defaultUserId,
                    localDisplayName: AppConfiguration.defaultDisplayName
                )
            )
            .tabItem {
                Label("Rooms", systemImage: "square.grid.2x2.fill")
            }
            .tag(1)
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Host Demo View
struct HostDemoView: View {
    @State private var showCall = false
    @State private var showPK = false
    @State private var roomIdInput = "1234"
    @State private var nameInput = AppConfiguration.defaultDisplayName
    @State private var pkRoomInput = ""
    @State private var isHost = true

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Join Configuration")) {
                    TextField("Room ID", text: $roomIdInput)
                        .keyboardType(.numberPad)
                    TextField("Display Name", text: $nameInput)
                    Toggle("Join as Host", isOn: $isHost)
                }

                Section {
                    Button("Join Room") {
                        showCall = true
                    }
                    .disabled(roomIdInput.isEmpty || nameInput.isEmpty)
                }

                if isHost {
                    Section(header: Text("PK Battle")) {
                        TextField("Guest Room ID (for PK)", text: $pkRoomInput)
                            .keyboardType(.numberPad)
                        Button("Start PK Battle") {
                            showPK = true
                        }
                        .disabled(pkRoomInput.isEmpty)
                    }
                }
            }
            .navigationTitle("Janus Video Call")
        }
        .fullScreenCover(isPresented: $showCall) {
            let room = Room(
                id: UUID().uuidString,
                title: "Room \(roomIdInput)",
                janusRoomId: Int(roomIdInput) ?? 1234
            )
            let participant = Participant(
                id: AppConfiguration.defaultUserId,
                displayName: nameInput,
                role: isHost ? .host : .guest,
                isLocal: true
            )
            let vm = RoomViewModel(
                serverURL: AppConfiguration.janusServerURL,
                room: room,
                localUser: participant
            )
            GroupCallView(viewModel: vm)
        }
        .fullScreenCover(isPresented: $showPK) {
            let room = Room(
                id: UUID().uuidString,
                title: "Host Room \(roomIdInput)",
                janusRoomId: Int(roomIdInput) ?? 1234
            )
            let participant = Participant(
                id: AppConfiguration.defaultUserId,
                displayName: nameInput,
                role: .host,
                isLocal: true
            )
            let hostVM = RoomViewModel(
                serverURL: AppConfiguration.janusServerURL,
                room: room,
                localUser: participant
            )
            let pkService = PKBattleService(
                serverURL: AppConfiguration.janusServerURL,
                hostViewModel: hostVM
            )
            PKBattleDemoView(
                hostVM: hostVM,
                pkService: pkService,
                guestRoomId: Int(pkRoomInput) ?? 0
            )
        }
    }
}

// MARK: - PK Battle Demo View
struct PKBattleDemoView: View {
    @StateObject var hostVM: RoomViewModel
    @StateObject var pkService: PKBattleService
    let guestRoomId: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                // PK split view
                PKBattleView(
                    pkService: pkService,
                    hostTrack: hostVM.webRTC.localVideoTrackRef
                )
                .frame(maxHeight: .infinity)

                // Controls
                HStack(spacing: 24) {
                    Button("End PK") {
                        Task {
                            await pkService.endPKBattle()
                            dismiss()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)

                    Button(hostVM.localParticipant.isAudioEnabled ? "Mute" : "Unmute") {
                        hostVM.toggleAudio()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.gray)
                }
                .padding()
                .background(Color.black.opacity(0.8))
            }
        }
        .task {
            // Connect host room + start PK
            await hostVM.connect()
            try? await pkService.startPKBattle(
                guestRoomId: guestRoomId,
                guestRoomTitle: "Guest Room",
                localHostRoomId: hostVM.room.id
            )
        }
    }
}
