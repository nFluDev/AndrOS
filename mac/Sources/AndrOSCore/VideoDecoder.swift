import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

/// Annex-B H.264 akisini VideoToolbox ile donanimda cozer (RX 580 UVD).
public final class VideoDecoder {

    public var onFrame: ((CVPixelBuffer, UInt64) -> Void)?
    public private(set) var formatDesc: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var sps: [UInt8] = []
    private var pps: [UInt8] = []

    public init() {}
    deinit { invalidate() }

    public func invalidate() {
        if let s = session {
            VTDecompressionSessionWaitForAsynchronousFrames(s)
            VTDecompressionSessionInvalidate(s)
        }
        session = nil
        formatDesc = nil
    }

    /// Config paketi (SPS+PPS) islenir, oturum kurulur.
    @discardableResult
    public func setParameterSets(fromAnnexB data: [UInt8]) -> Bool {
        for nal in NALU.split(data) {
            guard let f = nal.first else { continue }
            switch f & 0x1F {
            case 7: sps = Array(nal)
            case 8: pps = Array(nal)
            default: break
            }
        }
        guard !sps.isEmpty, !pps.isEmpty else { return false }

        var desc: CMVideoFormatDescription?
        let status = sps.withUnsafeBufferPointer { sp in
            pps.withUnsafeBufferPointer { pp -> OSStatus in
                let ptrs: [UnsafePointer<UInt8>] = [sp.baseAddress!, pp.baseAddress!]
                let sizes: [Int] = [sps.count, pps.count]
                return ptrs.withUnsafeBufferPointer { ptrBuf in
                    sizes.withUnsafeBufferPointer { sizeBuf in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: ptrBuf.baseAddress!,
                            parameterSetSizes: sizeBuf.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &desc)
                    }
                }
            }
        }
        guard status == noErr, let d = desc else { return false }
        formatDesc = d
        return createSession(d)
    }

    private func createSession(_ desc: CMVideoFormatDescription) -> Bool {
        if let s = session { VTDecompressionSessionInvalidate(s) }
        session = nil
        // Piksel formatini ZORLAMIYORUZ: VideoToolbox akisin kendi renk
        // araligini (full/video range) korusun, donusumu shader'da yapalim.
        let attrs: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any]() as CFDictionary,
        ]
        let spec: [CFString: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true,
        ]
        var cb = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { refCon, _, status, _, imageBuffer, pts, _ in
                guard status == noErr, let img = imageBuffer, let refCon else { return }
                let me = Unmanaged<VideoDecoder>.fromOpaque(refCon).takeUnretainedValue()
                let us = CMTimeGetSeconds(pts) * 1_000_000
                me.onFrame?(img, us.isFinite && us > 0 ? UInt64(us) : 0)
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())

        var s: VTDecompressionSession?
        let st = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: desc,
            decoderSpecification: spec as CFDictionary,
            imageBufferAttributes: attrs as CFDictionary,
            outputCallback: &cb, decompressionSessionOut: &s)
        guard st == noErr, let sess = s else { return false }

        VTSessionSetProperty(sess, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = sess
        return true
    }

    /// Bir kareyi cozer. Annex-B start code'lari AVCC uzunluk onekine cevrilir.
    public func decode(annexB: [UInt8], pts: UInt64) {
        guard let sess = session, let desc = formatDesc else { return }

        var avcc: [UInt8] = []
        avcc.reserveCapacity(annexB.count + 16)
        for nal in NALU.split(annexB) {
            let n = UInt32(nal.count)
            avcc.append(UInt8(truncatingIfNeeded: n >> 24)); avcc.append(UInt8(truncatingIfNeeded: n >> 16))
            avcc.append(UInt8(truncatingIfNeeded: n >> 8));  avcc.append(UInt8(truncatingIfNeeded: n))
            avcc.append(contentsOf: nal)
        }
        guard !avcc.isEmpty else { return }

        var block: CMBlockBuffer?
        let mem = UnsafeMutableRawPointer.allocate(byteCount: avcc.count, alignment: 1)
        avcc.withUnsafeBytes { _ = memcpy(mem, $0.baseAddress!, avcc.count) }
        var st = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: mem, blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: avcc.count, flags: 0, blockBufferOut: &block)
        guard st == noErr, let blk = block else { mem.deallocate(); return }

        var sample: CMSampleBuffer?
        var sizes = [avcc.count]
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(pts), timescale: 1_000_000),
            decodeTimeStamp: .invalid)
        st = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: blk, formatDescription: desc,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sizes, sampleBufferOut: &sample)
        guard st == noErr, let smp = sample else { return }

        var flagsOut = VTDecodeInfoFlags()
        VTDecompressionSessionDecodeFrame(
            sess, sampleBuffer: smp, flags: [], frameRefcon: nil, infoFlagsOut: &flagsOut)
    }
}
