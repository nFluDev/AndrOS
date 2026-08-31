import Foundation
import CoreMediaIO
import CoreMedia
import CoreVideo
import os.log

/// AndrOS sanal kamerasi.
///
/// Sistem bu uzantiyi AYRI BIR SURECTE calistiriyor; FaceTime, Zoom,
/// Photo Booth gibi kamera kullanan HER uygulama buradan goruntu
/// aliyor. Kareleri uygulamadan paylasimli bellekle aliyoruz
/// (`AndrOSCameraShared`) — uzanti ag ya da telefon hakkinda hicbir sey
/// bilmiyor, yalnizca "son kareyi ver" diyor.
///
/// Uygulama kapaliyken kamera KAYBOLMUYOR: uygulamalar cihaz listesini
/// aclista bir kez okuyor, cihazin gelip gitmesi onlari sasirtiyor.
/// O durumda duz bir bilgi ekrani gosteriliyor.

let kFrameRate = 30
let logger = Logger(subsystem: "dev.naer.andros.camera", category: "extension")

// MARK: - Akis

final class StreamSource: NSObject, CMIOExtensionStreamSource {

    private(set) var stream: CMIOExtensionStream!
    private let device: CMIOExtensionDevice
    private let format: CMFormatDescription

    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "dev.naer.andros.camera.stream")
    private var sequence: UInt64 = 0
    private var lastSeen: UInt64 = 0
    /// Uygulamadan gelen SON kare (sink akisi uzerinden).
    ///
    /// Paylasimli bellek KULLANILAMADI: uzanti kum havuzunda calisiyor
    /// (CMIO boyle istiyor) ve kum havuzundaki POSIX paylasimli bellek
    /// ADI kendi kabina esleniyor; kum havuzunda olmayan uygulama ayni
    /// adi acsa bile BASKA bir bellege bakiyor (olculdu: uygulama kare
    /// yaziyor, uzanti hep yer tutucu goruyor). CMIO'nun kendi "sink"
    /// akisi bu duvarin dogru gecidi.
    private var latest: CMSampleBuffer?
    private let latestLock = NSLock()

    func submit(_ sb: CMSampleBuffer?) {
        latestLock.lock(); latest = sb; latestLock.unlock()
    }

    /// Paylasimli kare tamponu.
    private var shared: UnsafeMutablePointer<AndrOSCameraShared>?
    private var pool: CVPixelBufferPool?

    init(localizedName: String, device: CMIOExtensionDevice) {
        self.device = device
        var desc: CMFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            width: Int32(ANDROS_CAM_MAXW), height: Int32(ANDROS_CAM_MAXH),
            extensions: nil, formatDescriptionOut: &desc)
        self.format = desc!
        super.init()
        self.stream = CMIOExtensionStream(
            localizedName: localizedName,
            streamID: UUID(),
            direction: .source,
            clockType: .hostTime,
            source: self)

        let attrs: [String: Any] = [
            kCVPixelBufferWidthKey as String: ANDROS_CAM_MAXW,
            kCVPixelBufferHeightKey as String: ANDROS_CAM_MAXH,
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil,
                                attrs as CFDictionary, &pool)
    }

    /// BIRDEN COK BOYUT.
    ///
    /// Tek bir 720p bicim veren cihazi bazi istemciler (tarayicilar,
    /// Electron uygulamalari) eliyor: varsayilan olarak 640x480
    /// istiyorlar ve pazarlik basarisiz olunca kamerayi hic
    /// gostermiyorlar. Ayni tampondan uc boyut sunuyoruz.
    private static let sizes: [(Int32, Int32)] = [(1280, 720), (640, 480), (320, 240)]

    private lazy var allFormats: [CMIOExtensionStreamFormat] = {
        Self.sizes.compactMap { w, h in
            var d: CMFormatDescription?
            CMVideoFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                codecType: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                width: w, height: h, extensions: nil, formatDescriptionOut: &d)
            guard let d else { return nil }
            return CMIOExtensionStreamFormat(
                formatDescription: d,
                maxFrameDuration: CMTime(value: 1, timescale: Int32(kFrameRate)),
                minFrameDuration: CMTime(value: 1, timescale: Int32(kFrameRate)),
                validFrameDurations: nil)
        }
    }()

    var formats: [CMIOExtensionStreamFormat] { allFormats }

    var availableProperties: Set<CMIOExtensionProperty> { [.streamActiveFormatIndex] }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>)
        throws -> CMIOExtensionStreamProperties {
        let p = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { p.activeFormatIndex = activeFormat }
        return p
    }

    private var activeFormat = 0

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let i = streamProperties.activeFormatIndex, i < allFormats.count {
            activeFormat = i
        }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    func startStream() throws {
        if shared == nil { shared = androsCameraAttach(1) }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(),
                   repeating: .milliseconds(1000 / kFrameRate),
                   leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        logger.info("akis basladi")
    }

    func stopStream() throws {
        timer?.cancel(); timer = nil
        logger.info("akis durdu")
    }

    // MARK: - Kare uretimi

    private func tick() {
        // Uygulamadan kare geldiyse onu OLDUGU GIBI yolla: yeniden
        // kodlama ya da kopyalama yok.
        latestLock.lock()
        let fresh = latest
        latestLock.unlock()
        if let fresh {
            sequence &+= 1
            stream.send(fresh, discontinuity: [], hostTimeInNanoseconds:
                            UInt64(CMSampleBufferGetPresentationTimeStamp(fresh).seconds
                                   * 1_000_000_000))
            return
        }
        guard let pool else { return }
        var px: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &px) == kCVReturnSuccess,
              let px else { return }

        if !copyLatestFrame(into: px) { fillPlaceholder(px) }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Int32(kFrameRate)),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid)
        var fmt: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: px, formatDescriptionOut: &fmt)
        guard let fmt else { return }
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: px,
            formatDescription: fmt, sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return }
        sequence &+= 1
        stream.send(sample, discontinuity: [], hostTimeInNanoseconds:
                        UInt64(timing.presentationTimeStamp.seconds * 1_000_000_000))
    }

    /// Uygulamanin yazdigi son kareyi kopyalar. Yeni kare yoksa `false`.
    private func copyLatestFrame(into px: CVPixelBuffer) -> Bool {
        guard let sh = shared, sh.pointee.running != 0 else { return false }
        let seq = sh.pointee.sequence
        guard seq > 0 else { return false }
        // Ayni kareyi tekrar gondermek sorun degil (kamera 30 fps
        // isterken telefon 24 gonderebiliyor); yalnizca hic kare
        // gelmediyse yer tutucuya duseriz.
        lastSeen = seq
        guard let src = androsCameraSlot(sh, UInt32((seq &- 1) % UInt64(ANDROS_CAM_SLOTS)))
        else { return false }

        let w = Int(sh.pointee.width), h = Int(sh.pointee.height)
        guard w > 0, h > 0, w <= Int(ANDROS_CAM_MAXW), h <= Int(ANDROS_CAM_MAXH) else { return false }

        CVPixelBufferLockBaseAddress(px, [])
        defer { CVPixelBufferUnlockBaseAddress(px, []) }
        guard let yDst = CVPixelBufferGetBaseAddressOfPlane(px, 0),
              let cDst = CVPixelBufferGetBaseAddressOfPlane(px, 1) else { return false }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(px, 0)
        let cStride = CVPixelBufferGetBytesPerRowOfPlane(px, 1)
        let dstH = CVPixelBufferGetHeightOfPlane(px, 0)
        let dstW = CVPixelBufferGetWidthOfPlane(px, 0)

        let copyW = min(w, dstW), copyH = min(h, dstH)
        for row in 0..<copyH {
            memcpy(yDst.advanced(by: row * yStride), src.advanced(by: row * w), copyW)
        }
        let cSrc = src.advanced(by: w * h)
        for row in 0..<(copyH / 2) {
            memcpy(cDst.advanced(by: row * cStride), cSrc.advanced(by: row * w), copyW)
        }
        return true
    }

    /// Uygulama kare gondermiyorsa: ORTA GRI, ustunde ince cizgiler.
    ///
    /// Duz siyah "kamera bozuk" gibi duruyordu. Orta gri ve hafif bir
    /// desen "baglanti yok" oldugunu anlatiyor; goruntu akmaya
    /// baslayinca aninda gercek kareye geciyor.
    private func fillPlaceholder(_ px: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(px, [])
        defer { CVPixelBufferUnlockBaseAddress(px, []) }
        if let y = CVPixelBufferGetBaseAddressOfPlane(px, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(px, 0)
            let h = CVPixelBufferGetHeightOfPlane(px, 0)
            memset(y, 96, stride * h)
            // Yavas kayan capraz cizgiler: donmus goruntu ile
            // "baglanti yok" birbirine karismasin.
            let p = y.assumingMemoryBound(to: UInt8.self)
            let shift = Int(sequence / 2) % 64
            for row in 0..<h {
                var col = (row + shift) % 64
                while col < stride { p[row * stride + col] = 120; col += 64 }
            }
        }
        if let c = CVPixelBufferGetBaseAddressOfPlane(px, 1) {
            memset(c, 128, CVPixelBufferGetBytesPerRowOfPlane(px, 1)
                         * CVPixelBufferGetHeightOfPlane(px, 1))
        }
    }
}

/// Uygulamanin kare YOLLADIGI akis.
///
/// CMIO'da uzanti, istemciden kareleri `consumeSampleBuffer` ile CEKER.
/// Gelen her kare dogrudan kaynak akisa aktariliyor.
final class SinkStreamSource: NSObject, CMIOExtensionStreamSource {

    private(set) var stream: CMIOExtensionStream!
    private let format: CMFormatDescription
    private weak var target: StreamSource?
    private var client: CMIOExtensionClient?
    private var consuming = false

    init(localizedName: String, target: StreamSource) {
        self.target = target
        var desc: CMFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            width: Int32(ANDROS_CAM_MAXW), height: Int32(ANDROS_CAM_MAXH),
            extensions: nil, formatDescriptionOut: &desc)
        self.format = desc!
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: UUID(),
                                     direction: .sink, clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] {
        [CMIOExtensionStreamFormat(
            formatDescription: format,
            maxFrameDuration: CMTime(value: 1, timescale: Int32(kFrameRate)),
            minFrameDuration: CMTime(value: 1, timescale: Int32(kFrameRate)),
            validFrameDurations: nil)]
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamSinkBufferQueueSize,
         .streamSinkBuffersRequiredForStartup]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>)
        throws -> CMIOExtensionStreamProperties {
        let p = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { p.activeFormatIndex = 0 }
        if properties.contains(.streamSinkBufferQueueSize) { p.sinkBufferQueueSize = 3 }
        if properties.contains(.streamSinkBuffersRequiredForStartup) {
            p.sinkBuffersRequiredForStartup = 1
        }
        return p
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        self.client = client
        return true
    }

    func startStream() throws {
        consuming = true
        consumeLoop()
        logger.info("sink akisi basladi")
    }

    /// Kac kare alindi (tanilama).
    private var got = 0

    func stopStream() throws {
        consuming = false
        target?.submit(nil)
        logger.info("sink akisi durdu")
    }

    /// Istemciden kare CEK ve kaynak akisa aktar.
    private func consumeLoop() {
        guard consuming, let client else { return }
        stream.consumeSampleBuffer(from: client) { [weak self] sb, seq, disc, hasMore, err in
            guard let self else { return }
            // Gelen kare KAYNAK akisa aktariliyor. Sink akisi kendisi
            // bir sey YAYINLAMAZ — yalnizca alir.
            if let sb {
                self.got += 1
                if self.got == 1 { logger.info("sink: ilk kare alindi") }
                self.target?.submit(sb)
            }
            _ = seq; _ = disc; _ = hasMore; _ = err
            if self.consuming { self.consumeLoop() }
        }
    }
}

// MARK: - Cihaz

final class DeviceSource: NSObject, CMIOExtensionDeviceSource {

    private(set) var device: CMIOExtensionDevice!
    private var streamSource: StreamSource!
    private var sinkSource: SinkStreamSource!

    init(localizedName: String) {
        super.init()
        // Sabit UUID: cihaz her acilista AYNI kalsin, uygulamalarin
        // hatirladigi secim bozulmasin.
        let id = UUID(uuidString: "6E1A7C40-93B4-4F2E-9F1B-2C7A5D0E8A31")!
        device = CMIOExtensionDevice(localizedName: localizedName, deviceID: id,
                                     legacyDeviceID: nil, source: self)
        streamSource = StreamSource(localizedName: "AndrOS Kamera", device: device)
        try? device.addStream(streamSource.stream)
        sinkSource = SinkStreamSource(localizedName: "AndrOS Giriş", target: streamSource)
        try? device.addStream(sinkSource.stream)
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>)
        throws -> CMIOExtensionDeviceProperties {
        let p = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            // 'virt' — sanal aygit. Sabit IOKit adi CoreMediaIO'ya
            // aktarilmadigi icin dogrudan dort harfli kodu veriyoruz.
            p.transportType = 0x76697274
        }
        if properties.contains(.deviceModel) { p.model = "AndrOS" }
        return p
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}
}

// MARK: - Saglayici

final class ProviderSource: NSObject, CMIOExtensionProviderSource {

    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: DeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = DeviceSource(localizedName: "AndrOS · Telefon Kamerası")
        try? provider.addDevice(deviceSource.device)
    }

    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> {
        [.providerManufacturer]
    }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>)
        throws -> CMIOExtensionProviderProperties {
        let p = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { p.manufacturer = "AndrOS" }
        return p
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}
