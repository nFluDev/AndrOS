import AppKit
import AndrOSCore
import CoreVideo

/// Tek bir aynalama oturumu: sunucu + cozucu + render + girdi.
final class MirrorSession {

    enum State { case idle, connecting, running, failed(String) }

    private(set) var state: State = .idle
    var onStateChange: ((State) -> Void)?
    var onSize: ((Int, Int) -> Void)?
    /// Cihaz tarafi uyarilari (orn. ses yakalama basarisiz).
    var onWarning: ((String, String) -> Void)?
    /// Kisa durum metni (menu cubugunda gosterilir).
    var onStatus: ((String) -> Void)?
    /// Kilit acildi ve ses icin oturumun yenilenmesi gerekiyor.
    var onNeedsRestartForAudio: (() -> Void)?

    private var adb: ADB?
    private var server: DeviceServer?
    private let decoder = VideoDecoder()
    private let renderer: MetalRenderer?
    private var readThread: Thread?
    private var stopping = false

    private(set) var streamWidth = 0
    private(set) var streamHeight = 0

    /// Istatistik
    private(set) var framesRendered = 0
    private var totalRendered = 0
    private var renderMisses = 0
    private let frameLock = NSLock()
    /// Kucuk kare kuyrugu. Bir yenileme aralatinda 2 kare gelirse birini
    /// atmak yerine siraya aliyoruz; boylece kaynak taraftaki ~%2 gecikmeli
    /// kare gorunur takilmaya donusmuyor. Derinlik 2 = en fazla ~17ms ek gecikme.
    private var frameQueue: [CVPixelBuffer] = []
    var smoothing = true
    /// Sag tik surukleme = kamera dondurme (ikinci parmak).
    var cameraDrag = true
    private var decodedSinceLastTick = 0
    private var decodedTotal = 0
    private var lastPresent = Date()
    private var presentGaps: [Double] = []
    private var lastArrival = Date()
    private var arrivalEMA: Double = 0

    /// Ekran yenilemesinde cagrilir. Yeni kare varsa cizer, yoksa hicbir sey
    /// yapmaz (ayni kareyi tekrar cizmek bosuna GPU harcar).
    private func drawTick() {
        frameLock.lock()
        let depth = frameQueue.count
        let target = arrivalEMA
        // HIZ DUZENLEYICI: kareyi geldigi anda degil, kaynagin kendi
        // ritminde sun. Aksi halde kareler 2-11 tick arasi degisen surelerle
        // ekranda kaliyor ve "drop" gibi gorunuyor.
        var take = !frameQueue.isEmpty
        if smoothing, take, target > 4 {
            let since = Date().timeIntervalSince(lastPresent) * 1000
            // Cok erkense bekle; ama kuyruk birikiyorsa yetis (gecikme birikmesin).
            if since < target * 0.8 && depth < 3 { take = false }
        }
        let pb = take ? frameQueue.removeFirst() : nil
        let newCount = decodedSinceLastTick
        if take { decodedSinceLastTick = 0 }
        frameLock.unlock()

        guard let pb, let r = renderer, let v = view else { return }
        if v.metalLayer.device == nil || v.metalLayer.drawableSize.width < 1 {
            renderMisses += 1
            if renderMisses % 120 == 1 {
                Log.write("CIZILEMEDI: device=\(v.metalLayer.device != nil) size=\(v.metalLayer.drawableSize)")
            }
            return
        }
        let tNow = Date()
        let gap = tNow.timeIntervalSince(lastPresent) * 1000
        lastPresent = tNow
        if gap < 500 { presentGaps.append(gap) }

        r.render(pb, to: v.metalLayer)
        lastFrame = pb
        framesRendered += 1
        decodedTotal += newCount
        totalRendered += 1
        if totalRendered == 1 { Log.write("ILK KARE CIZILDI") }

        let now = Date()
        let dt = now.timeIntervalSince(lastStatTime)
        if dt >= 2.0 {
            fps = Double(framesRendered) / dt
            let dropped = decodedTotal - framesRendered
            let g = presentGaps.sorted()
            let stat: String
            if g.count > 4 {
                let mean = g.reduce(0,+) / Double(g.count)
                let sd = (g.map { ($0-mean)*($0-mean) }.reduce(0,+) / Double(g.count)).squareRoot()
                stat = String(format: " | sunum ort %.1fms sd %.1f p95 %.1f max %.1f",
                              mean, sd, g[Int(Double(g.count)*0.95)], g.last!)
            } else { stat = "" }
            presentGaps.removeAll()
            Log.write(String(format: "cizilen FPS: %.1f  (cozulen %d, atlanan %d)%@",
                             fps, decodedTotal, max(0, dropped), stat))
            framesRendered = 0; decodedTotal = 0
            lastStatTime = now
        }
    }
    private var lastStatTime = Date()
    private(set) var fps: Double = 0

    weak var view: MetalView?
    let clipboard = ClipboardBridge()
    let keyMapper = KeyMapper()
    let audioPlayer = AudioPlayer()
    /// Sesi Mac'e aktar. Acikken telefonun hoparlorunden ses GELMEZ
    /// (REMOTE_SUBMIX yonlendirmesi).
    var audioEnabled = true
    private var lastFrame: CVPixelBuffer?
    private(set) var audioFailed = false

    init() { renderer = MetalRenderer() }

    var params: MetalRenderer.Params {
        get { renderer?.params ?? .init() }
        set { renderer?.params = newValue }
    }

    /// ALT + tam ekranda kenarlik istemiyoruz: goruntu ekrani tamamen doldursun.
    var stretchToFill: Bool {
        get { renderer?.stretchToFill ?? false }
        set { renderer?.stretchToFill = newValue }
    }

    private func setState(_ s: State) {
        Log.write("durum -> \(s)")
        state = s
        DispatchQueue.main.async { [weak self] in self?.onStateChange?(s) }
    }

    /// Telefonun kendi ekranini sondurur (pil tasarrufu). Yayin devam eder.
    var turnScreenOff = true

    func setPhoneScreen(on: Bool) {
        _ = server?.send(ControlMessage.setDisplayPower(on))
        Log.write("telefon ekrani: \(on ? "acik" : "kapali")")
    }

    func start(bitRate: Int, maxFPS: Int, forceFullRange: Bool) {
        guard case .idle = state else { return }
        setState(.connecting)
        stopping = false

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let a = try ADB()
                let dev = try a.singleDevice()
                let adb = try ADB(serial: dev.serial)
                self.adb = adb

                // KILIT: beklemiyoruz. Video ve kontrol kilitliyken de
                // calistigi icin kilit ekranini AYNALIYORUZ — kullanici PIN'ini
                // Mac'ten girebiliyor. Ses (Android 11 kisiti) kilitliyken
                // kurulamadigindan, kilit acilinca oturumu bir kez yenileyip
                // sesi o zaman ekliyoruz.
                let lockedAtStart = self.isLocked(adb)
                let wantAudio = self.audioEnabled && !lockedAtStart
                if lockedAtStart {
                    Log.write("telefon kilitli — kilit ekrani aynalanacak, PIN Mac'ten girilebilir")
                    // Ekrani ac: kullanici isterse telefondan da girebilsin.
                    _ = try? adb.run(["shell", "input", "keyevent", "KEYCODE_WAKEUP"])
                }
                if self.stopping { return }

                var cfg = DeviceServer.Config()
                cfg.codec = "h264"           // olculdu: bu donanimda HEVC'nin avantaji yok
                cfg.bitRate = bitRate
                cfg.maxFPS = maxFPS
                cfg.control = true
                cfg.audio = wantAudio
                if forceFullRange {
                    // Olculdu: bu cihazin encoder'i bunu KABUL ediyor.
                    cfg.codecOptions = ["color-range": "1", "color-standard": "1",
                                        "color-transfer": "3"]
                }
                let srv = DeviceServer(adb: adb, port: 27183)
                srv.onServerError = { [weak self] kind in
                    guard kind == "audio" else { return }
                    self?.audioFailed = true
                    self?.onWarning?(L("Ses aktarılamadı", "Audio could not be routed"),
                        L("Android 11'de ses yakalama ancak ekran AÇIK ve KİLİTSİZKEN "
                          + "başlatılabiliyor.\n\nTelefonun kilidini aç, sonra menü "
                          + "çubuğundan \"Bağlantıyı kes\" → \"Bağlan\" yap.\n\n",
                            "On Android 11 audio capture only starts while the screen is ON "
                          + "and UNLOCKED.\n\nUnlock the phone, then use the menu bar: "
                          + "\"Disconnect\" → \"Connect\".\n\n")
                      + L("Görüntü ve kontrol etkilenmedi.", "Video and control are unaffected."))
                }
                try srv.start(cfg)
                self.server = srv

                let demux = StreamDemuxer(socket: srv.videoSocket)
                let c = demux.readCodec()
                Log.write("codec: \(c?.name ?? "YOK")")
                guard c == .h264 else {
                    throw ADBError.command("beklenmeyen codec", 1, "")
                }
                // CAMetalLayer'a GPU cihazini bagla — bu olmadan ekran siyah kalir.
                if let dev = self.renderer?.mtlDevice {
                    DispatchQueue.main.sync { self.view?.attach(device: dev) }
                }
                // Kontrol soketinden gelen cihaz mesajlarini dinle (pano vb.)
                self.clipboard.send = { [weak self] bytes in _ = self?.server?.send(bytes) }
                self.keyMapper.send = { [weak self] bytes in _ = self?.server?.send(bytes) }
                DispatchQueue.main.async { self.clipboard.start() }
                Thread.detachNewThread { [weak self] in self?.deviceMessageLoop() }

                // SES: ekrani sondurmeden ONCE baslat. Android 11'de yakalama
                // ekran acik ve kilitsizken kuruluyor; once sondururken
                // baslatirsak "Could not read audio" ile basarisiz oluyor.
                if wantAudio { self.startAudio() }

                // Kilitliyken izlemeye basla: acilinca sesi eklemek icin
                // oturumu yenileyecegiz.
                if lockedAtStart && self.audioEnabled { self.watchForUnlock() }

                self.setState(.running)
                // Kilitliyken ekrani SONDURMUYORUZ: kullanici PIN'i telefondan
                // girmek isteyebilir. Kilit acilinca yenilenen oturumda sonecek.
                if self.turnScreenOff && !lockedAtStart {
                    // Ses hatti kuruldu; artik sondurulebilir.
                    // Anahtar KAPALIYSA hic dokunmuyoruz: telefon ekrani acik kalir.
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) { [weak self] in
                        guard let self, case .running = self.state else { return }
                        self.setPhoneScreen(on: false)
                    }
                }
                self.readLoop(demux)
            } catch {
                Log.write("HATA: \(error)")
                self.setState(.failed("\(error)"))
                self.cleanup()
            }
        }
    }

    private func readLoop(_ demux: StreamDemuxer) {
        // Decode edilen kareyi SAKLA; cizimi ekran yenilemesi tetikler.
        decoder.onFrame = { [weak self] pb, _ in
            guard let self else { return }
            self.frameLock.lock()
            if self.smoothing {
                self.frameQueue.append(pb)
                // Kuyruk buyurse gecikme birikir: en eskiyi at.
                if self.frameQueue.count > 4 { self.frameQueue.removeFirst() }
                // Kaynak kare araligini yumusatarak takip et (EMA).
                let now = Date()
                let dt = now.timeIntervalSince(self.lastArrival) * 1000
                self.lastArrival = now
                if dt > 4 && dt < 200 {
                    self.arrivalEMA = self.arrivalEMA == 0 ? dt : self.arrivalEMA * 0.9 + dt * 0.1
                }
            } else {
                self.frameQueue = [pb]
            }
            self.decodedSinceLastTick += 1
            self.frameLock.unlock()
        }

        DispatchQueue.main.async { [weak self] in
            self?.view?.onDisplayTick = { [weak self] in self?.drawTick() }
        }

        while !stopping {
            guard let ev = demux.next() else { break }
            switch ev {
            case .session(let w, let h, _):
                streamWidth = w; streamHeight = h
                keyMapper.streamSize = (w, h)
                Log.write("oturum: \(w)x\(h)")
                DispatchQueue.main.async { [weak self] in
                    self?.view?.videoSize = CGSize(width: w, height: h)
                    self?.onSize?(w, h)
                }
            case .packet(let p):
                if p.isConfig {
                    let okSet = decoder.setParameterSets(fromAnnexB: p.data)
                    Log.write("config paketi \(p.data.count)B, VT oturumu: \(okSet)")
                } else {
                    decoder.decode(annexB: p.data, pts: p.pts)
                }
            }
        }
        if !stopping {
            Log.write("okuma dongusu bitti (demuxer nil dondu)")
            setState(.failed("akis kesildi"))
        }
        cleanup()
    }

    /// Telefon kilitliyse ekrani uyandirir ve kullanici acana kadar bekler.
    ///
    /// Neden gerekli: Android 11'de ses yakalama on planda kurulmak zorunda;
    /// kilitliyken "Failed to start audio capture" aliyoruz. Ayrica kullanici
    /// zaten kilidi acmadan telefonu kullanamaz.
    func isLocked(_ adb: ADB) -> Bool {
        let out = (try? adb.checked(["shell",
            "dumpsys window | grep -m1 isKeyguardShowing"])) ?? ""
        return out.contains("isKeyguardShowing=true")
    }

    /// Kilit acilmasini ARKA PLANDA izler. Acilinca sesi kurmak icin
    /// oturumu bir kez yeniler (ses soketi ancak sunucu baslarken kurulabiliyor).
    private func watchForUnlock() {
        guard let adb else { return }
        Thread.detachNewThread { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(300)
            while !self.stopping, Date() < deadline {
                Thread.sleep(forTimeInterval: 1.0)
                if self.stopping { return }
                if !self.isLocked(adb) {
                    Log.write("kilit acildi — ses icin oturum yenileniyor")
                    DispatchQueue.main.async { [weak self] in
                        self?.onStatus?(L("Kilit açıldı, ses ekleniyor…", "Unlocked, adding audio…"))
                        self?.onNeedsRestartForAudio?()
                    }
                    return
                }
            }
        }
    }

    /// Ses akisi: video ile ayni 12 baytlik paket protokolu, ama icerik
    /// ham PCM. Ayri bir is parcaciginda okunup dogrudan calinir.
    private func startAudio() {
        // Koprii ayni sesi TASIMASIN: iki yoldan gelirse cift duyulur.
        AudioRouting.mirroringAudioActive = true
        guard let srv = server else { return }
        DispatchQueue.main.sync {
            // Yansitma sesi de sanal aygittan CALMAMALI — ayni dongu.
            self.audioPlayer.preferredDevice = AudioRouting.deviceForPhoneAudio()
            self.audioPlayer.start()
        }

        Thread.detachNewThread { [weak self] in
            guard let self else { return }
            let dm = StreamDemuxer(socket: srv.audioSocket)
            let codec = dm.readCodec()
            Log.write("ses codec: \(codec?.name ?? "raw/bilinmeyen")")

            var bytes = 0
            var lastLog = Date()
            while !self.stopping, srv.audioSocket.isOpen {
                guard let ev = dm.next() else { break }
                guard case .packet(let p) = ev, !p.isConfig else { continue }
                self.audioPlayer.enqueue(p.data)
                bytes += p.data.count
                if Date().timeIntervalSince(lastLog) > 5 {
                    let kbps = Double(bytes) * 8 / 1000 / Date().timeIntervalSince(lastLog)
                    Log.write(String(format: "ses akisi: %.0f kbps", kbps))
                    bytes = 0; lastLog = Date()
                }
            }
            Log.write("ses akisi bitti")
            DispatchQueue.main.async {
                self.audioPlayer.stop()
            AudioRouting.mirroringAudioActive = false
                AudioRouting.mirroringAudioActive = false
            }
        }
    }

    /// Kontrol soketi cift yonlu: cihaz da bize mesaj gonderiyor.
    private func deviceMessageLoop() {
        guard let srv = server else { return }
        while !stopping, srv.controlSocket.isOpen {
            guard let msg = DeviceMessage.read(from: srv.controlSocket) else { break }
            switch msg {
            case .clipboard(let text): clipboard.receivedFromDevice(text)
            case .ackClipboard: break
            case .unknown(let t): Log.write("bilinmeyen cihaz mesaji: \(t)")
            }
        }
    }

    func stop() {
        DispatchQueue.main.async {
            self.clipboard.stop()
            self.audioPlayer.stop()
        }
        if turnScreenOff { setPhoneScreen(on: true) }
        stopping = true
        cleanup()
        setState(.idle)
    }

    private func cleanup() {
        DispatchQueue.main.async { [weak self] in self?.view?.stopDisplayLink() }
        frameLock.lock(); frameQueue.removeAll(); frameLock.unlock()
        decoder.invalidate()
        server?.stop()
        server = nil
    }

    // MARK: - Girdi

    func sendTouch(_ action: ControlMessage.TouchAction, x: Int, y: Int) {
        guard streamWidth > 0, streamHeight > 0 else { return }
        _ = server?.send(ControlMessage.touch(action, x: x, y: y,
                                              w: streamWidth, h: streamHeight))
    }
    func sendScroll(x: Int, y: Int, h: Float, v: Float) {
        guard streamWidth > 0 else { return }
        _ = server?.send(ControlMessage.scroll(x: x, y: y, w: streamWidth,
                                               h: streamHeight, hscroll: h, vscroll: v))
    }
    /// Son cizilen kareyi PNG'ye cevirir (pano + dosya icin).
    func screenshotPNG() -> Data? {
        guard let pb = lastFrame, let r = renderer else { return nil }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        guard let tex = r.renderToTexture(pb, width: w, height: h) else { return nil }
        return MetalRenderer.pngData(tex)
    }

    func sendRaw(_ bytes: [UInt8]) { _ = server?.send(bytes) }

    /// Tek dokunusluk tus (bas-birak).
    func tapKey(_ code: UInt32) {
        _ = server?.send(ControlMessage.keycode(0, code))
        _ = server?.send(ControlMessage.keycode(1, code))
    }

    /// Makro parmagi — elle yapilan dokunmayla cakismasin diye ayri pointer.
    func sendMacroTouch(_ action: ControlMessage.TouchAction, x: Int, y: Int) {
        guard streamWidth > 0 else { return }
        _ = server?.send(ControlMessage.touch(action, x: x, y: y,
                                              w: streamWidth, h: streamHeight,
                                              pointerID: 4))
    }

    /// Kamera parmagi — fare ve joystickten bagimsiz ucuncu pointer.
    func sendCamera(_ action: ControlMessage.TouchAction, x: Int, y: Int) {
        guard streamWidth > 0 else { return }
        _ = server?.send(ControlMessage.touch(action, x: x, y: y,
                                              w: streamWidth, h: streamHeight,
                                              pointerID: 3))
    }

    func sendKey(_ code: UInt32, down: Bool) {
        _ = server?.send(ControlMessage.keycode(down ? 0 : 1, code))
    }
}
