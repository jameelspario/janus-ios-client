import Foundation
import WebRTC

#if targetEnvironment(simulator)
import CoreGraphics
import CoreVideo
import UIKit
#endif

public protocol SimulatorStreamPlugin {
    func start(feed: SimulatorFrameFeed)
    func stop()
}

public final class SimulatorFrameFeed {
    public let source: RTCVideoSource
    public let capturer: RTCVideoCapturer
    
    public init(source: RTCVideoSource, capturer: RTCVideoCapturer) {
        self.source = source
        self.capturer = capturer
    }
    
    public func send(pixelBuffer: CVPixelBuffer) {
        #if targetEnvironment(simulator)
        let rtcBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        let timeStampNs = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
        let frame = RTCVideoFrame(
            buffer: rtcBuffer,
            rotation: ._0,
            timeStampNs: timeStampNs
        )
        capturer.delegate?.capturer(capturer, didCapture: frame)
        #endif
    }
}

public final class SolidColorSimulatorPlugin: SimulatorStreamPlugin {
    #if targetEnvironment(simulator)
    private var timer: Timer?
    private var startTime: Date?
    private weak var feed: SimulatorFrameFeed?
    #endif
    
    public init() {}
    
    public func start(feed: SimulatorFrameFeed) {
        #if targetEnvironment(simulator)
        self.feed = feed
        self.startTime = Date()
        self.timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        #endif
    }
    
    public func stop() {
        #if targetEnvironment(simulator)
        timer?.invalidate()
        timer = nil
        feed = nil
        #endif
    }
    
    #if targetEnvironment(simulator)
    private func tick() {
        guard let feed = feed, let startTime = startTime else { return }
        let time = Date().timeIntervalSince(startTime)
        let width = 640
        let height = 480
        
        guard let pixelBuffer = createSimulatorPixelBuffer(width: width, height: height, time: time) else { return }
        feed.send(pixelBuffer: pixelBuffer)
    }
    
    private func createSimulatorPixelBuffer(width: Int, height: Int, time: Double) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer? = nil
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )
        
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            return nil
        }
        
        CVPixelBufferLockBaseAddress(buffer, [])
        
        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        )
        
        if let ctx = context {
            let hue1 = CGFloat(fmod(time * 0.1, 1.0))
            let hue2 = CGFloat(fmod(time * 0.1 + 0.3, 1.0))
            let color1 = UIColor(hue: hue1, saturation: 0.6, brightness: 0.6, alpha: 1.0).cgColor
            let color2 = UIColor(hue: hue2, saturation: 0.6, brightness: 0.6, alpha: 1.0).cgColor
            
            let colors = [color1, color2] as CFArray
            let space = CGColorSpaceCreateDeviceRGB()
            if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: nil) {
                ctx.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: 0, y: 0),
                    end: CGPoint(x: CGFloat(width), y: CGFloat(height)),
                    options: []
                )
            }
            
            let radius: CGFloat = 60
            let speedX = 2.5
            let speedY = 1.8
            let rangeX = CGFloat(width) - radius * 2
            let rangeY = CGFloat(height) - radius * 2
            let posX = radius + (CGFloat(sin(time * speedX)) + 1.0) / 2.0 * rangeX
            let posY = radius + (CGFloat(cos(time * speedY)) + 1.0) / 2.0 * rangeY
            
            ctx.setFillColor(UIColor.white.withAlphaComponent(0.4).cgColor)
            ctx.addEllipse(in: CGRect(x: posX - radius, y: posY - radius, width: radius * 2, height: radius * 2))
            ctx.fillPath()
        }
        
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }
    #endif
}
