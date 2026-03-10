//
//  LobbyView.swift
//  janus-test
//
//  Created by jameel on 04/03/26.
//

import SwiftUI

struct LobbyView: View {
    @State private var serverURL = Config.signalingServerURL
    @State private var roomIDText = "\(Config.defaultRoomID)"
    @State private var displayName = Config.defaultDisplayName
    @State private var isShowingRoom = false
    @State private var roomID: UInt64 = Config.defaultRoomID

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [Color(.systemIndigo), Color(.systemBlue).opacity(0.7)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                VStack(spacing: 0) {
                    VStack(spacing: 8) {
                        Image(systemName: "video.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(.white)
                        Text("Janus VideoRoom")
                            .font(.largeTitle.bold())
                            .foregroundStyle(.white)
                        Text("WebRTC Video Conference")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .padding(.top, 60)
                    .padding(.bottom, 48)

                    VStack(spacing: 20) {
                        LobbyField(title: "Server URL", placeholder: "wss://...", text: $serverURL, icon: "server.rack")
                        LobbyField(title: "Room Number", placeholder: "1234", text: $roomIDText, icon: "number", keyboardType: .numberPad)
                        LobbyField(title: "Display Name", placeholder: "Your name", text: $displayName, icon: "person.fill")
                    }
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
                    .padding(.horizontal, 24)

                    Spacer()

                    Button(action: joinRoom) {
                        HStack {
                            Image(systemName: "video.badge.plus")
                            Text("Join Room").fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(.white)
                        .foregroundStyle(Color(.systemIndigo))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 48)
                }
            }
            .navigationDestination(isPresented: $isShowingRoom) {
//                RoomView(roomID: roomID, displayName: displayName, serverURL: serverURL)
                GroupCallView(config: .init(
                                janusURL: URL(string: "wss://your-janus-server.com/")!,
                                roomId: roomID,
                                displayName: displayName,
                                role: .guest
                            ))
            }
        }
    }

    private func joinRoom() {
        guard let id = UInt64(roomIDText), !displayName.isEmpty else { return }
        roomID = id
        isShowingRoom = true
    }
}

private struct LobbyField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var icon: String
    var keyboardType: UIKeyboardType = .default

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .keyboardType(keyboardType)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(12)
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}
#Preview{
    LobbyView()
}
