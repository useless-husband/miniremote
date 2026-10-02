import Foundation
import VideoToolbox
import CoreMedia

enum VideoCodec: String {
    case h264, hevc
    var messageType: UInt8 { self == .hevc ? 3 : 1 }
}

struct EncodedFrame {
    let codec: VideoCodec
    let data: Data          // 長度前綴(4 byte)的 NAL 串
    let isKey: Bool
    let description: Data?  // 關鍵幀附 avcC / hvcC,給 WebCodecs 用
    let pts: CMTime
    let width: Int
    let height: Int
}

/// VideoToolbox 硬體編碼(H.264 或 HEVC),低延遲模式
final class VideoEncoder {
    let codec: VideoCodec
    private var session: VTCompressionSession?
    private var width = 0
    private var height = 0
    private(set) var failed = false
    /// 已送進編碼器但還沒吐出來的幀數;超過 maxInFlight 就丟掉新幀,避免編碼器跟不上時無限堆積
    private var inFlight = 0
    private let inFlightLock = NSLock()
    private let maxInFlight = 3
    private(set) var droppedByEncoder = 0
    var bitrateKbps = 8000 { didSet { applyBitrate() } }
    var fps = 30 { didSet { applyFPS() } }
    var onEncoded: ((EncodedFrame) -> Void)?

    init(codec: VideoCodec) { self.codec = codec }

    /// 這台的硬體有沒有這種編碼器
    static func isSupported(_ codec: VideoCodec) -> Bool {
        var s: VTCompressionSession?
        let st = VTCompressionSessionCreate(
            allocator: nil, width: 1280, height: 720,
            codecType: codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            encoderSpecification: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
            compressionSessionOut: &s)
        if let s = s { VTCompressionSessionInvalidate(s) }
        return st == noErr
    }

    func encode(_ pb: CVPixelBuffer, pts: CMTime, forceKey: Bool) {
        guard !failed else { return }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        if session == nil || w != width || h != height { recreate(width: w, height: h) }
        guard let session = session else { return }
        inFlightLock.lock()
        if inFlight >= maxInFlight && !forceKey {
            inFlightLock.unlock()
            droppedByEncoder += 1
            return
        }
        inFlight += 1
        inFlightLock.unlock()
        var props: [CFString: Any] = [:]
        if forceKey { props[kVTEncodeFrameOptionKey_ForceKeyFrame] = true }
        let duration = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pb, presentationTimeStamp: pts, duration: duration,
            frameProperties: props.isEmpty ? nil : props as CFDictionary, infoFlagsOut: nil
        ) { [weak self] status, flags, sampleBuffer in
            guard let self = self else { return }
            self.inFlightLock.lock(); self.inFlight -= 1; self.inFlightLock.unlock()
            guard status == noErr, let sb = sampleBuffer, !flags.contains(.frameDropped) else { return }
            self.handleOutput(sb, width: w, height: h)
        }
        if status != noErr {
            inFlightLock.lock(); inFlight -= 1; inFlightLock.unlock()
            log("\(codec.rawValue) 編碼失敗 \(status)")
        }
    }

    func invalidate() {
        if let s = session { VTCompressionSessionInvalidate(s) }
        session = nil
        inFlightLock.lock(); inFlight = 0; inFlightLock.unlock()
    }

    private func recreate(width w: Int, height h: Int) {
        invalidate()
        let codecType: CMVideoCodecType = codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        var created: VTCompressionSession?
        var status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(w), height: Int32(h), codecType: codecType,
            encoderSpecification: [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
            compressionSessionOut: &created)
        if status != noErr || created == nil {
            status = VTCompressionSessionCreate(
                allocator: nil, width: Int32(w), height: Int32(h), codecType: codecType,
                encoderSpecification: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary,
                imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                compressionSessionOut: &created)
        }
        guard status == noErr, let s = created else {
            log("\(codec.rawValue) 硬體編碼器無法建立(\(status)),這台不支援")
            failed = true
            return
        }
        session = s
        width = w
        height = h
        set(kVTCompressionPropertyKey_RealTime, true)
        set(kVTCompressionPropertyKey_ProfileLevel, codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel)
        set(kVTCompressionPropertyKey_AllowFrameReordering, false)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, fps * 30)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 30)
        set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, true, quiet: true)
        if codec == .h264 { set(kVTCompressionPropertyKey_H264EntropyMode, kVTH264EntropyMode_CABAC, quiet: true) }
        set(kVTCompressionPropertyKey_ColorPrimaries, kCMFormatDescriptionColorPrimaries_ITU_R_709_2, quiet: true)
        set(kVTCompressionPropertyKey_TransferFunction, kCMFormatDescriptionTransferFunction_ITU_R_709_2, quiet: true)
        set(kVTCompressionPropertyKey_YCbCrMatrix, kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2, quiet: true)
        applyBitrate()
        applyFPS()
        VTCompressionSessionPrepareToEncodeFrames(s)
        log("\(codec.rawValue.uppercased()) 編碼器就緒 \(w)×\(h) @ \(fps)fps \(bitrateKbps)kbps")
    }

    private func applyBitrate() { set(kVTCompressionPropertyKey_AverageBitRate, bitrateKbps * 1000, quiet: true) }
    private func applyFPS() { set(kVTCompressionPropertyKey_ExpectedFrameRate, fps, quiet: true) }

    private func set(_ key: CFString, _ value: Any, quiet: Bool = false) {
        guard let s = session else { return }
        let st = VTSessionSetProperty(s, key: key, value: value as CFTypeRef)
        if st != noErr && !quiet { log("編碼器屬性 \(key) 設定失敗 \(st)") }
    }

    private func handleOutput(_ sb: CMSampleBuffer, width: Int, height: Int) {
        guard CMSampleBufferDataIsReady(sb), let bb = CMSampleBufferGetDataBuffer(sb) else { return }
        var isKey = true
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [NSDictionary],
           let a = arr.first, let notSync = a[kCMSampleAttachmentKey_NotSync] as? Bool {
            isKey = !notSync
        }
        var desc: Data?
        if isKey, let fd = CMSampleBufferGetFormatDescription(sb) {
            desc = codec == .hevc ? Self.makeHvcC(fd) : Self.makeAvcC(fd)
        }
        let length = CMBlockBufferGetDataLength(bb)
        guard length > 0 else { return }
        var data = Data(count: length)
        let st = data.withUnsafeMutableBytes { ptr -> OSStatus in
            CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: length, destination: ptr.baseAddress!)
        }
        guard st == kCMBlockBufferNoErr else { return }
        onEncoded?(EncodedFrame(codec: codec, data: data, isKey: isKey, description: desc,
                                pts: CMSampleBufferGetPresentationTimeStamp(sb), width: width, height: height))
    }

    // MARK: avcC(ISO 14496-15)

    static func makeAvcC(_ fd: CMFormatDescription) -> Data? {
        var count = 0
        var nalLen: Int32 = 4
        var spsPtr: UnsafePointer<UInt8>?
        var spsSize = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            fd, parameterSetIndex: 0, parameterSetPointerOut: &spsPtr, parameterSetSizeOut: &spsSize,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalLen) == noErr,
            let sps = spsPtr, count >= 2, spsSize >= 4 else { return nil }
        var ppsPtr: UnsafePointer<UInt8>?
        var ppsSize = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            fd, parameterSetIndex: 1, parameterSetPointerOut: &ppsPtr, parameterSetSizeOut: &ppsSize,
            parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let pps = ppsPtr else { return nil }
        var d = Data()
        d.append(1)
        d.append(sps[1]); d.append(sps[2]); d.append(sps[3])
        d.append(0xFC | UInt8(max(1, min(4, Int(nalLen))) - 1))
        d.append(0xE1)
        d.append(UInt8(spsSize >> 8)); d.append(UInt8(spsSize & 0xFF))
        d.append(sps, count: spsSize)
        d.append(1)
        d.append(UInt8(ppsSize >> 8)); d.append(UInt8(ppsSize & 0xFF))
        d.append(pps, count: ppsSize)
        return d
    }

    // MARK: hvcC(ISO 14496-15 §8.3.3)

    static func makeHvcC(_ fd: CMFormatDescription) -> Data? {
        var sets: [Data] = []
        for i in 0..<3 {
            var p: UnsafePointer<UInt8>?
            var size = 0
            var count = 0
            var nalLen: Int32 = 4
            guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                fd, parameterSetIndex: i, parameterSetPointerOut: &p, parameterSetSizeOut: &size,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalLen) == noErr, let ptr = p else { return nil }
            sets.append(Data(bytes: ptr, count: size))
        }
        // 依 NAL 類型排好:VPS=32、SPS=33、PPS=34
        var byType: [Int: Data] = [:]
        for s in sets where s.count >= 2 { byType[Int((s[0] >> 1) & 0x3F)] = s }
        guard let vps = byType[32], let spsRaw = byType[33], let pps = byType[34] else { return nil }
        let sps = removeEmulationPrevention(spsRaw)
        guard sps.count >= 15 else { return nil }
        var d = Data()
        d.append(1)                      // configurationVersion
        d.append(sps[3])                 // general_profile_space(2) tier(1) profile_idc(5)
        d.append(sps[4...7])             // general_profile_compatibility_flags
        d.append(sps[8...13])            // general_constraint_indicator_flags(48 bit)
        d.append(sps[14])                // general_level_idc
        d.append(contentsOf: [0xF0, 0x00])   // min_spatial_segmentation_idc
        d.append(0xFC)                   // parallelismType
        d.append(0xFD)                   // chromaFormat 4:2:0
        d.append(0xF8)                   // bitDepthLumaMinus8
        d.append(0xF8)                   // bitDepthChromaMinus8
        d.append(contentsOf: [0x00, 0x00])   // avgFrameRate
        d.append(0x0F)                   // constantFrameRate(2)=0 numTemporalLayers(3)=1 temporalIdNested(1)=1 lengthSizeMinusOne(2)=3
        d.append(3)                      // numOfArrays
        for (type, nal) in [(32, vps), (33, spsRaw), (34, pps)] {
            d.append(UInt8(0x80 | type))
            d.append(0); d.append(1)
            d.append(UInt8(nal.count >> 8)); d.append(UInt8(nal.count & 0xFF))
            d.append(nal)
        }
        return d
    }

    private static func removeEmulationPrevention(_ nal: Data) -> Data {
        var out = Data(capacity: nal.count)
        var zeros = 0
        for b in nal {
            if zeros >= 2 && b == 3 { zeros = 0; continue }
            out.append(b)
            zeros = b == 0 ? zeros + 1 : 0
        }
        return out
    }
}
