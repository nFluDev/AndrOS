import Foundation
import Network
import AndrOSAudioShim

/// Ses surucusuyle telefon arasindaki koprii.
///
/// Yol su:
///
///   Mac uygulamalari -> CoreAudio -> AndrOSAudio.driver
///        -> paylasimli halka (out) -> BURASI -> telefon (AudioTrack)
///
///   telefon (AudioRecord) -> BURASI -> paylasimli halka (in)
///        -> AndrOSAudio.driver -> CoreAudio -> Mac uygulamalari
///
/// Surucu gercek zamanli ses is parcaciginda calistigi icin ag isini
/// yapamaz; o yalnizca halkaya yaziyor, ag tarafi burada.
///
/// Bicim: 48 kHz / 16 bit. Cikis stereo, mikrofon MONO (telefonlarin
/// cogu MIC kaynagini stereo acmiyor) — burada ikiye kopyalaniyor.
public final class AudioBridge {

    public static let shared = AudioBridge()
    private init() {}

    public enum State: Equatable {
        case off, connecting, on, failed(String)
        public var isFailed: Bool { if case .failed = self { return true }; return false }
    }
    public private(set) var state: State = .off {
        didSet { if state != oldValue { onState?(state) } }
    }
    public var onState: ((State) -> Void)?
    /// Telefonun KENDI sesi (bildirim, muzik…) — Mac'in su anki
    /// cikisindan calinsin diye disari veriliyor. Sanal aygitla karistirma:
    /// bu ses kullanicinin Mac'e takili kulakligindan duyulmali.
    public var onPhoneAudio: ((Data) -> Void)?

    /// Telefonun mikrofonu Mac'e verilsin mi.
    public var microphoneEnabled = true {
        didSet { if state == .on { sendMicToggle(microphoneEnabled) } }
    }

    /// Telefonun KENDI sesi koprii uzerinden gelsin mi.
    ///
    /// Yansitma aciksa scrcpy zaten ayni sesi tasiyor; ikisi birden
    /// acikken ses cift duyuluyor. Karari `AudioRouting` veriyor.
    public var phoneCaptureAllowed = true {
        didSet {
            guard phoneCaptureAllowed != oldValue, state == .on else { return }
            sendFrame(kind: phoneCaptureAllowed ? 8 : 7, payload: Data())
        }
    }

    private var shm: UnsafeMutablePointer<AndrOSAudioShared>?
    private var outRing: UnsafeMutablePointer<Float>?
    private var inRing: UnsafeMutablePointer<Float>?
    private var conn: NWConnection?
    private let queue = DispatchQueue(label: "dev.naer.andros.audio", qos: .userInitiated)
    private var pump: DispatchSourceTimer?
    private var inBuffer = Data()

    // MARK: - Paylasimli bellek

    /// Surucunun actigi halkayi baglar. Surucu kurulu degilse `false`.
    @discardableResult
    private func attachShared() -> Bool {
        if shm != nil { return true }
        // Surucu `coreaudiod` icinde root olarak olusturuyor; biz yalniz
        // baglaniyoruz. Yoksa surucu kurulu degil demektir.
        guard let p = androsAudioAttach() else { return false }
        shm = p
        outRing = androsAudioOutRing(p)
        inRing = androsAudioInRing(p)
        return true
    }

    /// Ses surucusu kurulu mu (ses paneli cihazlari gorecek mi)?
    public static var driverInstalled: Bool {
        FileManager.default.fileExists(
            atPath: "/Library/Audio/Plug-Ins/HAL/AndrOSAudio.driver")
    }

    // MARK: - Baglanti

    public func start(host: String, token: String) {
        stop()
        guard attachShared() else {
            state = .failed("nodriver")
            return
        }
        state = .connecting

        // Sertifika telefonun kendisi; denetim kanalinda zaten
        // sabitlenmis parmak iziyle eslesiyor.
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(
            tls.securityProtocolOptions,
            { _, _, complete in complete(true) }, queue)
        let params = NWParameters(tls: tls)
        if let tcp = params.defaultProtocolStack.transportProtocol
            as? NWProtocolTCP.Options { tcp.noDelay = true }

        let c = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: 47824)!, using: params)
        c.stateUpdateHandler = { [weak self] s in
            guard let self else { return }
            switch s {
            case .ready:
                self.sendFrame(kind: 0, payload: Data(token.utf8))   // yetki
                self.sendMicToggle(self.microphoneEnabled)
                self.sendFrame(kind: self.phoneCaptureAllowed ? 8 : 7, payload: Data())
                self.startPump()
                self.receive()
                self.state = .on
                Log.write("ses köprüsü açık: \(host)")
            case .failed(let e):
                self.state = .failed("\(e)")
            case .cancelled:
                self.state = .off
            default: break
            }
        }
        conn = c
        c.start(queue: queue)
    }

    public func stop() {
        pump?.cancel(); pump = nil
        conn?.cancel(); conn = nil
        inBuffer.removeAll()
        state = .off
    }

    // MARK: - Cerceve

    private func sendFrame(kind: UInt8, payload: Data) {
        var f = Data([kind])
        var n = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &n) { f.append(contentsOf: $0) }
        f.append(payload)
        conn?.send(content: f, completion: .contentProcessed { _ in })
    }

    private func sendMicToggle(_ on: Bool) {
        sendFrame(kind: on ? 3 : 4, payload: Data())
    }

    // MARK: - Mac -> telefon

    /// Halkayi duzenli araliklarla bosaltip telefona yolluyoruz.
    ///
    /// Neden zamanlayici: surucu gercek zamanli is parcacigindan bize
    /// haber veremez (orada sinyal/kilit yasak). 10 ms'de bir bakmak
    /// hem gecikmeyi dusuk tutuyor hem islemciyi yormuyor.
    private func startPump() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.drainOutput() }
        t.resume()
        pump = t
    }

    private func drainOutput() {
        guard let sh = shm else { return }
        sh.pointee.bridgeHeartbeat = UInt64(Date().timeIntervalSince1970)
        guard sh.pointee.outRunning != 0 else { return }

        let write = sh.pointee.outWrite
        var read = sh.pointee.outRead
        var avail = write &- read
        guard avail > 0 else { return }
        // Cok birikmisse (uygulama duraklamis olabilir) ESKISINI AT:
        // gecikmeyi buyutmektense kisa bir bosluk daha iyi.
        let maxLag = UInt64(ANDROS_RATE / 4)          // 250 ms
        if avail > maxLag { read = write &- maxLag; avail = maxLag }

        let frames = Int(min(avail, UInt64(4800)))     // en cok 100 ms
        var pcm = Data(count: frames * 2 * 2)          // stereo, 16 bit
        guard let ringBase = outRing else { return }
        pcm.withUnsafeMutableBytes { raw in
            let dst = raw.bindMemory(to: Int16.self).baseAddress!
            for i in 0..<frames {
                let idx = Int((read &+ UInt64(i)) % UInt64(ANDROS_RING_FRAMES)) * 2
                dst[i * 2 + 0] = AudioBridge.toInt16(ringBase[idx + 0])
                dst[i * 2 + 1] = AudioBridge.toInt16(ringBase[idx + 1])
            }
        }
        sh.pointee.outRead = read &+ UInt64(frames)
        sendFrame(kind: 1, payload: pcm)
    }

    private static func toInt16(_ f: Float) -> Int16 {
        let v = max(-1.0, min(1.0, f)) * 32767.0
        return Int16(v)
    }

    // MARK: - Telefon -> Mac

    private func receive() {
        conn?.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) {
            [weak self] data, _, done, err in
            guard let self else { return }
            if let data, !data.isEmpty { self.ingest(data) }
            if done || err != nil { self.state = .off; return }
            self.receive()
        }
    }

    private func ingest(_ chunk: Data) {
        inBuffer.append(chunk)
        while inBuffer.count >= 5 {
            let kind = inBuffer[inBuffer.startIndex]
            let len = inBuffer[(inBuffer.startIndex + 1)..<(inBuffer.startIndex + 5)]
                .reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard len <= 1 << 20 else { inBuffer.removeAll(); return }
            let total = 5 + Int(len)
            guard inBuffer.count >= total else { return }
            let body = inBuffer.subdata(in: (inBuffer.startIndex + 5)..<(inBuffer.startIndex + total))
            inBuffer.removeFirst(total)
            if kind == 2 { pushMic(body) }
            else if kind == 6 { onPhoneAudio?(body) }
        }
    }

    /// Gelen MONO mikrofon sesini halkaya stereo olarak yaziyoruz.
    private func pushMic(_ pcm: Data) {
        guard let sh = shm, sh.pointee.inRunning != 0 else { return }
        let frames = pcm.count / 2
        guard frames > 0 else { return }
        let write = sh.pointee.inWrite
        let read = sh.pointee.inRead
        let space = UInt64(ANDROS_RING_FRAMES) - (write &- read)
        if space < UInt64(frames) {
            // Yer yoksa okuyucuyu ileri al: birikmis eski ses atilir.
            sh.pointee.inRead = write &+ UInt64(frames) &- UInt64(ANDROS_RING_FRAMES)
        }
        guard let ringBase = inRing else { return }
        pcm.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            for i in 0..<frames {
                let v = Float(src[i]) / 32768.0
                let idx = Int((write &+ UInt64(i)) % UInt64(ANDROS_RING_FRAMES)) * 2
                ringBase[idx + 0] = v
                ringBase[idx + 1] = v          // mono -> stereo
            }
        }
        sh.pointee.inWrite = write &+ UInt64(frames)
    }
}
