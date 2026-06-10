import SwiftUI
import WebRTC


/// A public, highly reusable SwiftUI View to render a WebRTC video track.
/// It dynamically scales to fill the parent container, making it ideal for grids, lists, or fullscreen use.
public struct VideoTrackView<Placeholder: View>: View {
    public let track: RTCVideoTrack?
    public let contentMode: UIView.ContentMode
    public let placeholder: Placeholder
    
    /// Initializes the video track view.
    /// - Parameters:
    ///   - track: The WebRTC video track to render.
    ///   - contentMode: How the video should fit/fill its bounds (default: `.scaleAspectFill`).
    ///   - placeholder: A view builder for the placeholder when the track is nil, disabled, or not live.
    public init(
        track: RTCVideoTrack?,
        contentMode: UIView.ContentMode = .scaleAspectFill,
        @ViewBuilder placeholder: () -> Placeholder
    ) {
        self.track = track
        self.contentMode = contentMode
        self.placeholder = placeholder()
    }

    public var body: some View {
        if let track = track {
            VideoFeedView(track: track, contentMode: contentMode)
        } else {
            placeholder
        }
    }
}

extension VideoTrackView where Placeholder == AnyView {
    /// Convenience initializer using a default progress overlay placeholder.
    public init(
        track: RTCVideoTrack?,
        contentMode: UIView.ContentMode = .scaleAspectFill
    ) {
        self.track = track
        self.contentMode = contentMode
        self.placeholder = AnyView(
            ZStack {
                Color.gray.opacity(0.3)
                ProgressView()
                    .tint(.white)
            }
        )
    }
}

/// Internal wrapper for RTCMTLVideoView that manages WebRTC renderer attachment/removal.
struct VideoFeedView: UIViewRepresentable {
    let track: RTCVideoTrack?
    let contentMode: UIView.ContentMode
 
    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView()
        view.videoContentMode = contentMode
        view.backgroundColor  = .black
        return view
    }
 
    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        let old = context.coordinator.currentTrack
        guard old !== track else { return } // no-op if same track instance
        old?.removeRenderer(uiView)
        track?.addRenderer(uiView)
        context.coordinator.currentTrack = track
    }
    
    static func dismantleUIView(_ uiView: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.currentTrack?.removeRenderer(uiView)
    }
 
    func makeCoordinator() -> Coordinator { Coordinator() }
 
    class Coordinator {
        var currentTrack: RTCVideoTrack?
    }
}

/// A public, LiveKit-compatible SwiftUI View to render a custom `VideoTrack`.
public struct VideoView<Placeholder: View>: View {
    public let track: VideoTrack?
    public let contentMode: UIView.ContentMode
    public let placeholder: Placeholder
    
    public init(
        _ track: VideoTrack?,
        contentMode: UIView.ContentMode = .scaleAspectFill,
        @ViewBuilder placeholder: () -> Placeholder
    ) {
        self.track = track
        self.contentMode = contentMode
        self.placeholder = placeholder()
    }
    
    public var body: some View {
        VideoTrackView(track: track?.rtcTrack, contentMode: contentMode) {
            placeholder
        }
    }
}

extension VideoView where Placeholder == AnyView {
    public init(
        _ track: VideoTrack?,
        contentMode: UIView.ContentMode = .scaleAspectFill
    ) {
        self.track = track
        self.contentMode = contentMode
        self.placeholder = AnyView(
            ZStack {
                Color.gray.opacity(0.3)
                ProgressView()
                    .tint(.white)
            }
        )
    }
}

