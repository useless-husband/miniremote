import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo

protocol FrameSource: AnyObject {
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)? { get set }
    var onStopped: ((Error) -> Void)? { get set }
    func start(width: Int, height: Int, fps: Int) async throws
    func update(width: Int, height: Int, fps: Int) async throws
    func stop() async
}

/// 用 ScreenCaptureKit 擷取整個顯示器
final class ScreenCapturer: NSObject, FrameSource, SCStreamOutput, SCStreamDelegate {
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    var onStopped: ((Error) -> Void)?

    private let display: SCDisplay
    private var stream: SCStream?
    private let configuration = SCStreamConfiguration()
    private let outputQueue = DispatchQueue(label: "miniremote.capture", qos: .userInteractive)

    init(display: SCDisplay) {
        self.display = display
        super.init()
    }

    func start(width: Int, height: Int, fps: Int) async throws {
        apply(width: width, height: height, fps: fps)
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let s = SCStream(filter: filter, configuration: configuration, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        try await s.startCapture()
        stream = s
    }

    func update(width: Int, height: Int, fps: Int) async throws {
        apply(width: width, height: height, fps: fps)
        guard let s = stream else { return }
        try await s.updateConfiguration(configuration)
    }

    func stop() async {
        guard let s = stream else { return }
        stream = nil
        try? await s.stopCapture()
    }

    private func apply(width: Int, height: Int, fps: Int) {
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = true
        configuration.queueDepth = 8   // 高幀率時多留一點緩衝,避免掉幀
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let statusRaw = info[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw), status == .complete,
              let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pb, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        onStopped?(error)
    }
}

/// 測試用:不需要螢幕錄製權限,產生會動的彩色圖樣,用來驗證整條傳輸鏈
final class TestPatternSource: FrameSource {
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    var onStopped: ((Error) -> Void)?

    private let queue = DispatchQueue(label: "miniremote.testpattern")
    private var timer: DispatchSourceTimer?
    private var pool: CVPixelBufferPool?
    private var width = 1280, height = 720, fps = 30
    private var frameIndex = 0

    func start(width: Int, height: Int, fps: Int) async throws {
        queue.sync { configure(width, height, fps); startTimer() }
    }

    func update(width: Int, height: Int, fps: Int) async throws {
        queue.sync { configure(width, height, fps); startTimer() }
    }

    func stop() async {
        queue.sync { timer?.cancel(); timer = nil }
    }

    private func configure(_ w: Int, _ h: Int, _ f: Int) {
        width = w; height = h; fps = f
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: w,
            kCVPixelBufferHeightKey: h,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var p: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &p)
        pool = p
    }

    private func startTimer() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0 / Double(max(1, fps)))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        guard let pool = pool else { return }
        var created: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created)
        guard let pb = created else { return }
        CVPixelBufferLockBaseAddress(pb, [])
        if let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt32.self) {
            let stride = CVPixelBufferGetBytesPerRow(pb) / 4
            let t = frameIndex
            for y in 0..<height {
                let row = base + y * stride
                let g = UInt32((y * 255) / max(1, height))
                let b = UInt32((t * 2) & 0xFF)
                let r = UInt32(((y + t * 6) * 255 / max(1, height)) & 0xFF)
                row.update(repeating: 0xFF00_0000 | (r << 16) | (g << 8) | b, count: width)
            }
            let size = min(120, width / 4, height / 4)
            let sx = (t * 7) % max(1, width - size), sy = (t * 3) % max(1, height - size)
            for y in sy..<(sy + size) {
                let row = base + y * stride
                for x in sx..<(sx + size) { row[x] = 0xFFFF_FFFF }
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        frameIndex += 1
        onFrame?(pb, CMClockGetTime(CMClockGetHostTimeClock()))
    }
}
