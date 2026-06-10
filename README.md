# sdkJanus Integration Guide & Examples

This guide provides concrete SwiftUI examples showing how to implement **Group Video Chat**, **Group Audio-Only Chat**, and **Multi-Room Chat** using the modern LiveKit-compatible `sdkJanus` API wrappers.

---

## 1. Group Video Chat Example

In a group video chat, the publisher connects to a room, starts local camera & microphone streams, and displays remote participant feeds in a responsive grid.

### Features
- Connects using `Room` instance.
- Dynamically publishes camera & microphone streams.
- Renders video streams in a grid using `VideoView`.
- Actions to toggle local audio, video, or disconnect.

```swift
import SwiftUI
import sdkJanus

struct GroupVideoChatView: View {
    @StateObject private var room = Room()
    @State private var isMuted = false
    @State private var isVideoOff = false

    let roomId: Int = 1234
    let janusURL = URL(string: "wss://binda.live/janus")!

    var body: some View {
        VStack {
            // Header Controls
            HStack {
                Text("Video Room \(roomId)")
                    .font(.headline)
                Spacer()
                Text(room.connectionState == .connected ? "Connected" : "Connecting...")
                    .font(.subheadline)
                    .foregroundColor(room.connectionState == .connected ? .green : .gray)
            }
            .padding()

            // Responsive Video Grid
            GeometryReader { geo in
                let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 2)
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 8) {
                        // 1. Local Participant Preview
                        if let local = room.localParticipant {
                            ForEach(Array(local.trackPublications.values)) { pub in
                                if pub.kind == .video, let videoTrack = pub.track as? VideoTrack {
                                    VStack {
                                        VideoView(videoTrack)
                                            .frame(height: geo.size.height / 2.2)
                                            .cornerRadius(12)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 12)
                                                    .stroke(Color.white.opacity(0.4), lineWidth: 1)
                                            )
                                        Text("Me (Local)")
                                            .font(.caption)
                                            .bold()
                                    }
                                }
                            }
                        }

                        // 2. Remote Participants
                        ForEach(Array(room.remoteParticipants.values)) { participant in
                            ForEach(Array(participant.trackPublications.values)) { pub in
                                if pub.kind == .video, let videoTrack = pub.track as? VideoTrack {
                                    VStack {
                                        VideoView(videoTrack)
                                            .frame(height: geo.size.height / 2.2)
                                            .cornerRadius(12)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 12)
                                                    .stroke(Color.white.opacity(0.4), lineWidth: 1)
                                            )
                                        Text(participant.displayName)
                                            .font(.caption)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal)

            // Bottom Actions Panel
            HStack(spacing: 40) {
                // Toggle Audio
                Button(action: {
                    Task {
                        isMuted.toggle()
                        try? await room.localParticipant?.setMicrophone(enabled: !isMuted)
                    }
                }) {
                    Image(systemName: isMuted ? "mic.slash.fill" : "mic.fill")
                        .font(.title)
                        .foregroundColor(isMuted ? .red : .blue)
                }

                // Toggle Video
                Button(action: {
                    Task {
                        isVideoOff.toggle()
                        try? await room.localParticipant?.setCamera(enabled: !isVideoOff)
                    }
                }) {
                    Image(systemName: isVideoOff ? "video.slash.fill" : "video.fill")
                        .font(.title)
                        .foregroundColor(isVideoOff ? .red : .blue)
                }

                // Leave Room
                Button(action: {
                    Task {
                        await room.disconnect()
                    }
                }) {
                    Image(systemName: "phone.down.fill")
                        .font(.title)
                        .foregroundColor(.red)
                }
            }
            .padding()
        }
        .onAppear {
            Task {
                try? await room.connect(
                    url: janusURL,
                    roomId: roomId,
                    displayName: "Alice",
                    role: .publisher
                )
                // Automatically publish camera and microphone
                try? await room.localParticipant?.setCamera(enabled: true)
                try? await room.localParticipant?.setMicrophone(enabled: true)
            }
        }
        .onDisappear {
            Task {
                await room.disconnect()
            }
        }
    }
}
```

---

## 2. Group Audio-Only Chat Example

In an audio-only group chat, the device camera capturer is never initialized (preserving device power & privacy). The UI displays a grid of circular avatars with active speech/mute status indicators.

### Features
- Connects using custom `RoomConfig` with `mediaMode: .audioOnly`.
- Device camera indicator remains **off**.
- Lists only voice participants, updating mute/unmute status dynamically.

```swift
import SwiftUI
import sdkJanus

struct GroupAudioOnlyChatView: View {
    @StateObject private var room = Room()
    @State private var isMuted = false
    
    let roomId: Int = 5678
    let janusURL = URL(string: "wss://binda.live/janus")!

    var body: some View {
        VStack {
            // Room Info
            VStack(spacing: 8) {
                Text("Voice Clubhouse")
                    .font(.title2)
                    .bold()
                Text("Room ID: \(roomId)")
                    .font(.subheadline)
                    .foregroundColor(.gray)
                Text(room.connectionState == .connected ? "Joined" : "Connecting...")
                    .font(.caption)
                    .foregroundColor(.blue)
            }
            .padding(.top)

            Spacer()

            // Grid of Voice Avatars
            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 24), count: 3),
                    spacing: 24
                ) {
                    // Local Participant Avatar
                    if let local = room.localParticipant {
                        VStack {
                            ZStack {
                                Circle()
                                    .fill(Color.blue.opacity(0.2))
                                    .frame(width: 80, height: 80)
                                
                                Image(systemName: "person.crop.circle.fill")
                                    .resizable()
                                    .frame(width: 60, height: 60)
                                    .foregroundColor(.blue)

                                // Muted indicator overlay
                                if isMuted {
                                    Circle()
                                        .fill(Color.red)
                                        .frame(width: 24, height: 24)
                                        .overlay(
                                            Image(systemName: "mic.slash")
                                                .font(.caption2)
                                                .foregroundColor(.white)
                                        )
                                        .offset(x: 28, y: 28)
                                }
                            }

                            Text("Me (Bob)")
                                .font(.caption)
                                .bold()
                        }
                    }
                    
                    // Remote Participants Avatars
                    ForEach(Array(room.remoteParticipants.values)) { participant in
                        VStack {
                            ZStack {
                                Circle()
                                    .fill(Color.gray.opacity(0.2))
                                    .frame(width: 80, height: 80)
                                
                                Image(systemName: "person.crop.circle.fill")
                                    .resizable()
                                    .frame(width: 60, height: 60)
                                    .foregroundColor(.gray)

                                // Check if the remote audio track is muted
                                let isRemoteMuted = participant.trackPublications.values.first(where: { $0.kind == .audio })?.isMuted ?? false
                                if isRemoteMuted {
                                    Circle()
                                        .fill(Color.red)
                                        .frame(width: 24, height: 24)
                                        .overlay(
                                            Image(systemName: "mic.slash")
                                                .font(.caption2)
                                                .foregroundColor(.white)
                                        )
                                        .offset(x: 28, y: 28)
                                }
                            }

                            Text(participant.displayName)
                                .font(.caption)
                        }
                    }
                }
                .padding()
            }

            Spacer()

            // Bottom Audio Controls
            HStack {
                Button(action: {
                    Task {
                        isMuted.toggle()
                        try? await room.localParticipant?.setMicrophone(enabled: !isMuted)
                    }
                }) {
                    HStack {
                        Image(systemName: isMuted ? "mic.slash.fill" : "mic.fill")
                        Text(isMuted ? "Unmute Mic" : "Mute Mic")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(isMuted ? Color.red : Color.blue)
                    .cornerRadius(12)
                }
                .padding(.horizontal)

                Button(action: {
                    Task {
                        await room.disconnect()
                    }
                }) {
                    Text("Leave")
                        .font(.headline)
                        .foregroundColor(.red)
                        .padding()
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(12)
                }
                .padding(.trailing)
            }
            .padding(.bottom)
        }
        .onAppear {
            Task {
                // Connect to the room with .audioOnly override for the main roomId
                let roomConfig = RoomConfig(roomId: roomId, role: .publisher, mediaMode: .audioOnly)
                try? await room.connect(
                    url: janusURL,
                    roomId: roomId,
                    displayName: "Bob",
                    role: .publisher,
                    roomConfigs: [roomConfig]
                )
                // Automatically publish audio
                try? await room.localParticipant?.setMicrophone(enabled: true)
            }
        }
        .onDisappear {
            Task {
                await room.disconnect()
            }
        }
    }
}
```

---

## 3. Multi-Room Chat Example

This example demonstrates how to connect to multiple room locations simultaneously, displaying sidebar tabs for each room and dynamically subscribing/publishing to them in parallel using independent `Room` client controllers.

### Features
- Instantiates two independent `Room` objects.
- Connects Room 101 as a broadcasting publisher and Room 102 as a viewing guest.
- Preserves both connection feeds in parallel, dynamically rendering them when the user navigates tabs.

```swift
import SwiftUI
import sdkJanus

struct MultiRoomChatView: View {
    @StateObject private var room1 = Room()
    @StateObject private var room2 = Room()
    @State private var selectedRoomId: Int = 101

    let janusURL = URL(string: "wss://binda.live/janus")!

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedRoomId) {
                Section(header: Text("Active Rooms")) {
                    NavigationLink(value: 101) {
                        HStack {
                            Image(systemName: "bubble.left.and.bubble.right.fill")
                            Text("Room #101")
                            Spacer()
                            let remoteCount = room1.remoteParticipants.count
                            Text("\(remoteCount) peers")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }
                    
                    NavigationLink(value: 102) {
                        HStack {
                            Image(systemName: "bubble.left.and.bubble.right.fill")
                            Text("Room #102")
                            Spacer()
                            let remoteCount = room2.remoteParticipants.count
                            Text("\(remoteCount) peers")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }
                }
            }
            .navigationTitle("Lobby")
        } detail: {
            VStack {
                if selectedRoomId == 101 {
                    RoomView(room: room1, title: "Room 101")
                } else {
                    RoomView(room: room2, title: "Room 102")
                }
            }
        }
        .onAppear {
            Task {
                // Connect to Room 101 as publisher
                try? await room1.connect(
                    url: janusURL,
                    roomId: 101,
                    displayName: "Charlie",
                    role: .publisher
                )
                try? await room1.localParticipant?.setCamera(enabled: true)
                try? await room1.localParticipant?.setMicrophone(enabled: true)
                
                // Connect to Room 102 as guest (subscribing only)
                try? await room2.connect(
                    url: janusURL,
                    roomId: 102,
                    displayName: "Charlie",
                    role: .guest
                )
            }
        }
        .onDisappear {
            Task {
                await room1.disconnect()
                await room2.disconnect()
            }
        }
    }
}

struct RoomView: View {
    @ObservedObject var room: Room
    let title: String
    
    var body: some View {
        VStack {
            Text(title)
                .font(.title2)
                .bold()
                .padding()
            
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    // Local preview
                    if let local = room.localParticipant {
                        ForEach(Array(local.trackPublications.values)) { pub in
                            if pub.kind == .video, let videoTrack = pub.track as? VideoTrack {
                                VStack {
                                    VideoView(videoTrack)
                                        .frame(height: 120)
                                        .cornerRadius(8)
                                    Text("Me (Local)")
                                        .font(.caption)
                                }
                            }
                        }
                    }
                    
                    // Remote feeds
                      ForEach(Array(room.remoteParticipants.values)) { participant in
                        ForEach(Array(participant.trackPublications.values)) { pub in
                            if pub.kind == .video, let videoTrack = pub.track as? VideoTrack {
                                VStack {
                                    VideoView(videoTrack)
                                        .frame(height: 120)
                                        .cornerRadius(8)
                                    Text(participant.displayName)
                                        .font(.caption)
                                }
                            }
                        }
                    }
                }
                .padding()
            }
        }
    }
}
```
