import Foundation
import CoreMediaIO
import CoreMedia
import CoreVideo
import AndrOSCore

/// Sanal kameraya kare YOLLAYAN uc.
///
/// Uzanti kum havuzunda calistigi icin paylasimli bellek ise yaramiyor
/// (bkz. Provider.swift). CMIO'nun kendi "sink" akisi bu duvarin dogru
/// gecidi: cihazin sink akisini acip kareleri kuyruga koyuyoruz,
/// uzanti oradan cekip kaynak akisa aktariyor.
///
/// Burasi C API kullaniyor cunku CMIO'nun Swift karsiligi yok.
final class VirtualCameraSink {

    static let shared = VirtualCameraSink()
    private init() {}

    private var deviceID: CMIOObjectID = 0
    private var streamID: CMIOObjectID = 0
    private var queue: CMSimpleQueue?
    private var started = false
    private var warned = false

    /// Uzantidaki cihazin sabit kimligi (Provider.swift ile ayni).
    private let uid = "6E1A7C40-93B4-4F2E-9F1B-2C7A5D0E8A31"

    // MARK: - Acilis

    @discardableResult
    func open() -> Bool {
        if started { return true }
        guard let dev = findDevice() else { return false }
        deviceID = dev
        guard let sink = findSinkStream(dev) else { return false }
        streamID = sink

        var q: Unmanaged<CMSimpleQueue>?
        let st = CMIOStreamCopyBufferQueue(streamID, { _, _, _ in }, nil, &q)
        guard st == noErr, let qq = q?.takeRetainedValue() else {
            Log.write("sanal kamera: kuyruk alınamadı (\(st))")
            return false
        }
        queue = qq
        let s2 = CMIODeviceStartStream(deviceID, streamID)
        guard s2 == noErr else {
            Log.write("sanal kamera: akış başlatılamadı (\(s2))")
            return false
        }
        started = true
        Log.write("sanal kamera: sink akışı açık")
        return true
    }

    func close() {
        guard started else { return }
        CMIODeviceStopStream(deviceID, streamID)
        queue = nil
        started = false
    }

    // MARK: - Kare yollama

    func send(_ pixels: CVPixelBuffer) {
        guard open(), let q = queue else {
            if !warned { warned = true; Log.write("sanal kamera: sink açılamadı") }
            return
        }
        // Kuyruk doluysa ATLA: birikmis kare gecikmeden baska bir sey
        // getirmiyor.
        guard CMSimpleQueueGetCount(q) < CMSimpleQueueGetCapacity(q) else { return }

        var fmt: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixels, formatDescriptionOut: &fmt)
        guard let fmt else { return }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        let st = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixels,
            formatDescription: fmt, sampleTiming: &timing, sampleBufferOut: &sb)
        guard st == noErr, let sb else { return }
        CMSimpleQueueEnqueue(q, element: Unmanaged.passRetained(sb).toOpaque())
    }

    // MARK: - Bulma

    private func findDevice() -> CMIOObjectID? {
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject),
                                            &addr, 0, nil, &size) == noErr, size > 0
        else { return nil }
        let count = Int(size) / MemoryLayout<CMIOObjectID>.size
        var ids = [CMIOObjectID](repeating: 0, count: count)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject),
                                        &addr, 0, nil, size, &used, &ids) == noErr
        else { return nil }
        for id in ids where deviceUID(id) == uid { return id }
        return nil
    }

    private func deviceUID(_ id: CMIOObjectID) -> String? {
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr else { return nil }
        var s: CFString? = nil
        var used: UInt32 = 0
        let st = withUnsafeMutablePointer(to: &s) {
            CMIOObjectGetPropertyData(id, &addr, 0, nil, size, &used, $0)
        }
        guard st == noErr, let s else { return nil }
        return s as String
    }

    /// Cihazin GIRIS yonlu akisi = bizim kare yollayacagimiz yer.
    private func findSinkStream(_ device: CMIOObjectID) -> CMIOObjectID? {
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyStreams),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr,
              size > 0 else { return nil }
        let count = Int(size) / MemoryLayout<CMIOObjectID>.size
        var ids = [CMIOObjectID](repeating: 0, count: count)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(device, &addr, 0, nil, size, &used, &ids) == noErr
        else { return nil }
        // YON DEGERLERI CIHAZIN BAKIS ACISINDAN. Olculdu:
        //   yon=1 -> "AndrOS Kamera"  (kaynak, uygulamalarin okudugu)
        //   yon=0 -> "AndrOS Giriş"   (sink, bizim yazdigimiz)
        // Tersini varsayip kaynak akisi acmistim; uzantinin sink
        // `startStream`i hic cagrilmiyordu.
        for id in ids where streamDirection(id) == 0 { return id }
        return ids.count > 1 ? ids[1] : nil
    }

    private func streamDirection(_ id: CMIOObjectID) -> UInt32? {
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOStreamPropertyDirection),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var v: UInt32 = 0
        var used: UInt32 = 0
        let st = CMIOObjectGetPropertyData(id, &addr, 0, nil,
                                           UInt32(MemoryLayout<UInt32>.size), &used, &v)
        return st == noErr ? v : nil
    }
}
