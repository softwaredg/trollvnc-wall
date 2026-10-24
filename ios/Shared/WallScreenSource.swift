import Foundation
import ReplayKit
import CoreMedia
import CoreVideo
import UIKit
import RootEncoder

/// 按编码器宽高做窗口快照推帧（TrollStore 上比 ReplayKit 稳；不依赖相机）。
final class WallScreenSource: VideoSource {
    private var metal: MetalInterface?
    private var ready = false
    private var running = false
    private var snapshotTimer: Timer?
    private var frameCount = 0
    private var encW = 720
    private var encH = 1280
    var onInfo: ((String) -> Void)?

    func created() -> Bool { ready }

    func create(width: Int, height: Int, fps: Int, rotation: Int) -> Bool {
        _ = (fps, rotation)
        encW = max(2, width)
        encH = max(2, height)
        ready = true
        return true
    }

    func start(metalInterface: MetalInterface) {
        metal = metalInterface
        guard ready, !running else { return }
        running = true
        frameCount = 0
        // ReplayKit 分辨率常与 prepareVideo 不一致，Metal/编码后易只出 1 帧就停；快照按编码尺寸出帧。
        startSnapshot()
    }

    func stop() {
        running = false
        snapshotTimer?.invalidate()
        snapshotTimer = nil
    }

    func isRunning() -> Bool { running }

    func release() {
        stop()
        metal = nil
        ready = false
    }

    private func startSnapshot() {
        guard running else { return }
        snapshotTimer?.invalidate()
        onInfo?("窗口快照 \(encW)x\(encH) @15fps（保持 App 前台）")
        let timer = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            self?.captureWindow()
        }
        RunLoop.main.add(timer, forMode: .common)
        snapshotTimer = timer
    }

    private func captureWindow() {
        guard running else { return }
        let width = encW
        let height = encH
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            attrs as CFDictionary, &pb
        ) == kCVReturnSuccess, let pb else { return }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: base, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: bytesPerRow, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }

        var window: UIWindow?
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            window = ws.windows.first(where: \.isKeyWindow) ?? ws.windows.first
            if window != nil { break }
        }
        guard let window else { return }
        UIGraphicsPushContext(ctx)
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: CGFloat(width) / window.bounds.width, y: -(CGFloat(height) / window.bounds.height))
        window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        UIGraphicsPopContext()

        guard let sample = Self.sampleBuffer(from: pb) else { return }
        metal?.sendBuffer(buffer: sample)
        frameCount += 1
        if frameCount == 1 || frameCount % 45 == 0 {
            onInfo?("已出帧 \(frameCount)")
        }
    }

    private static func sampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &format
        ) == noErr, let format else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 15),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sample
        ) == noErr else { return nil }
        return sample
    }
}
