import Foundation
import CoreVideo
import AndrOSCore
import CryptoKit

/// Test icin minimal joystick surucusu.
final class KeyMapperProbe {
    let send: ([UInt8]) -> Bool
    let w: Int, h: Int
    init(send: @escaping ([UInt8]) -> Bool, w: Int, h: Int) { self.send = send; self.w = w; self.h = h }
    func press() {
        let cx = Int(0.16 * Double(w)), cy = Int(0.68 * Double(h))
        _ = send(ControlMessage.touch(.down, x: cx, y: cy, w: w, h: h,
                                      pointerID: ControlMessage.joystickID))
        _ = send(ControlMessage.touch(.move, x: cx + 60, y: cy, w: w, h: h,
                                      pointerID: ControlMessage.joystickID))
    }
    func release() {
        let cx = Int(0.16 * Double(w)), cy = Int(0.68 * Double(h))
        _ = send(ControlMessage.touch(.up, x: cx, y: cy, w: w, h: h,
                                      pointerID: ControlMessage.joystickID))
    }
}

// MARK: - Cikti yardimcilari
func hdr(_ s: String) { print("\n\u{001B}[1m== \(s)\u{001B}[0m") }
func ok(_ s: String)  { print("  \u{001B}[32m+\u{001B}[0m \(s)") }
func warn(_ s: String){ print("  \u{001B}[33m!\u{001B}[0m \(s)") }
func bad(_ s: String) { print("  \u{001B}[31mx\u{001B}[0m \(s)") }
func kv(_ k: String, _ v: String) { print("  \(k.padding(toLength: 22, withPad: " ", startingAt: 0)): \(v)") }

struct CaptureStats {
    var frames = 0, keyFrames = 0, bytes = 0
    var width = 0, height = 0
    var firstPTS: UInt64 = 0, lastPTS: UInt64 = 0
    var wallSeconds: Double = 0
    var configData: [UInt8] = []

    var fps: Double { wallSeconds > 0 ? Double(frames) / wallSeconds : 0 }
    var mbps: Double { wallSeconds > 0 ? Double(bytes) * 8 / wallSeconds / 1_000_000 : 0 }
    var avgFrameKB: Double { frames > 0 ? Double(bytes) / Double(frames) / 1024 : 0 }
}

/// Sunucuyu belirtilen ayarla calistirip N saniye ornek toplar.
func capture(adb: ADB, cfg: DeviceServer.Config, seconds: Double, port: UInt16) throws
    -> (stats: CaptureStats, color: ColorInfo?, codec: StreamDemuxer.Codec?, name: String)
{
    let server = DeviceServer(adb: adb, port: port)
    try server.start(cfg)
    defer { server.stop() }

    let demux = StreamDemuxer(socket: server.videoSocket)
    let codec = demux.readCodec()
    var st = CaptureStats()
    let t0 = Date()

    while Date().timeIntervalSince(t0) < seconds {
        guard let ev = demux.next() else { break }
        switch ev {
        case .session(let w, let h, _):
            st.width = w; st.height = h
        case .packet(let p):
            if p.isConfig { st.configData = p.data; continue }
            if st.frames == 0 { st.firstPTS = p.pts }
            st.lastPTS = p.pts
            st.frames += 1
            st.bytes += p.data.count
            if p.isKeyFrame { st.keyFrames += 1 }
        }
    }
    st.wallSeconds = Date().timeIntervalSince(t0)

    var color: ColorInfo? = nil
    if !st.configData.isEmpty {
        color = codec == .h265 ? SPSParser.parseHEVC(st.configData)
                               : SPSParser.parseH264(st.configData)
    }
    return (st, color, codec, server.deviceName)
}

func report(_ label: String, _ r: (stats: CaptureStats, color: ColorInfo?,
                                   codec: StreamDemuxer.Codec?, name: String)) {
    hdr(label)
    kv("codec", r.codec?.name ?? "?")
    kv("akis cozunurlugu", "\(r.stats.width)x\(r.stats.height)")
    kv("olculen FPS", String(format: "%.1f", r.stats.fps))
    kv("olculen bitrate", String(format: "%.1f Mbps", r.stats.mbps))
    kv("ort. kare boyutu", String(format: "%.1f KB", r.stats.avgFrameKB))
    kv("kare / anahtar kare", "\(r.stats.frames) / \(r.stats.keyFrames)")
    if let c = r.color {
        print("")
        for line in c.description.split(separator: "\n") { print("  \(line)") }
    } else {
        bad("SPS cozumlenemedi (config paketi alinamadi)")
    }
}

// MARK: - Komutlar

func cmdDevices() throws {
    let adb = try ADB()
    let devs = try adb.devices()
    if devs.isEmpty { bad("Bagli cihaz yok."); return }
    for d in devs { ok("\(d.serial)  model=\(d.model)  (\(d.transport))") }
}

func cmdProbe(codec: String) throws {
    hdr("Cihaz")
    let adb0 = try ADB()
    let dev = try adb0.singleDevice()
    let adb = try ADB(serial: dev.serial)

    kv("seri", dev.serial)
    kv("baglanti", dev.transport == "usb" ? "USB" : "TCP/IP (kablosuz)")
    kv("model", "\(adb.getProp("ro.product.manufacturer")) \(adb.getProp("ro.product.model"))")
    kv("Android", "\(adb.getProp("ro.build.version.release")) (API \(adb.getProp("ro.build.version.sdk")))")
    let size = (try? adb.checked(["shell", "wm", "size"])) ?? ""
    let density = (try? adb.checked(["shell", "wm", "density"])) ?? ""
    kv("ekran", size.replacingOccurrences(of: "Physical size: ", with: ""))
    kv("yogunluk", density.replacingOccurrences(of: "Physical density: ", with: ""))
    if dev.transport != "usb" {
        warn("Kablosuz baglantidasin. Gecikme olcumu USB'ye gore yaniltici olur.")
    }

    // 1) Temel cizgi: hicbir sey zorlamadan
    let baseCfg = { var c = DeviceServer.Config(); c.codec = codec; return c }()
    let base = try capture(adb: adb, cfg: baseCfg, seconds: 4, port: 27183)
    report("Temel cizgi (scrcpy varsayilani, \(codec))", base)

    if let c = base.color, !c.warnings.isEmpty {
        hdr("Teshis")
        for w in c.warnings { warn(w) }
    }

    // 2) Renk kaynakta zorlanirsa ne oluyor?
    var forceCfg = DeviceServer.Config()
    forceCfg.codec = codec
    forceCfg.codecOptions = ["color-range": "1",      // MediaFormat.COLOR_RANGE_FULL
                             "color-standard": "1",   // COLOR_STANDARD_BT709
                             "color-transfer": "3"]   // COLOR_TRANSFER_SDR_VIDEO
    let forced = try capture(adb: adb, cfg: forceCfg, seconds: 4, port: 27184)
    report("Zorlanmis renk (color-range=FULL, BT.709)", forced)

    hdr("Sonuc")
    let b = base.color, f = forced.color
    if b?.fullRange == nil && f?.fullRange != nil {
        ok("Encoder renk sinyalini KABUL ETTI. Varsayilanda hic sinyal yokken zorlayinca geldi.")
        ok("-> Solukluk kaynakta cozulebilir. Bu ayar kalici olarak kullanilacak.")
    } else if b?.fullRange == f?.fullRange && b?.matrix == f?.matrix {
        warn("Encoder codec-options'i YOK SAYDI (iki calistirma ayni).")
        warn("-> Duzeltme client tarafinda shader ile yapilacak. Faz 1 plani zaten bu.")
    } else {
        ok("Iki yapilandirma farkli sonuc verdi, detaylar yukarida.")
    }
    if base.stats.fps > 0 {
        let target = Double(adb.getProp("ro.surface_flinger.max_frame_buffer_acquired_buffers"))
        _ = target
        kv("not", String(format: "Olculen %.0f FPS. Ekranin 120Hz; --max-fps ile eslestirmeyi deneyecegiz.", base.stats.fps))
    }
}

// MARK: - Giris

let args = Array(CommandLine.arguments.dropFirst())
do {
    switch args.first {
    case "devices": try cmdDevices()
    case "pulltest":
        let a0 = try ADB(); let dv = try a0.singleDevice(); let a = try ADB(serial: dv.serial)
        let d = AndroidData(adb: a)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pulltest")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var fail = 0, n = 0
        for t in d.tracks().prefix(14) {
            n += 1
            let local = dir.appendingPathComponent(
                String(UInt(bitPattern: t.path.hashValue), radix: 16) + "-" + t.name)
            if !d.pull(t.path, to: local.path) {
                fail += 1
                bad(String(t.name.prefix(48)))
            }
        }
        if fail == 0 { ok("\(n)/\(n) indirildi") } else { bad("\(fail)/\(n) basarisiz") }
        exit(fail == 0 ? 0 : 1)
    case "data":
        let a0 = try ADB(); let dv = try a0.singleDevice(); let a = try ADB(serial: dv.serial)
        let d = AndroidData(adb: a)
        hdr("Yetenekler")
        let c = d.probe()
        for (n, v) in [("SMS", c.sms), ("Kisiler", c.contacts), ("Medya", c.media),
                       ("Dosyalar", c.files), ("Arama gecmisi", c.callLog)] {
            if v { ok(n) } else { bad(n + " — erisilemiyor") }
        }
        hdr("Kisiler (ilk 3)")
        for x in d.contacts().prefix(3) { kv(x.name, x.number) }
        hdr("Sohbetler (ilk 3)")
        let cons = d.conversations(contacts: d.contacts())
        kv("toplam sohbet", "\(cons.count)")
        for cv in cons.prefix(3) {
            let body = (cv.last?.body ?? "").replacingOccurrences(of: "\n", with: " ")
            kv(cv.title, "\(cv.messages.count) mesaj | son: \(body.prefix(52))")
        }
        hdr("Virgullu govde testi (ayristirici saglamligi)")
        let withComma = d.messages().filter { $0.body.contains(", ") }
        kv("virgullu mesaj", "\(withComma.count)")
        if let m = withComma.first {
            kv("adres", m.address)
            kv("govde", String(m.body.prefix(70)))
            ok(m.address.contains("=") ? "SUPHELI: adres icinde = var" : "adres temiz — ayristirici saglam")
        }
        hdr("Uygulama ikonu testi")
        let icoDir = FileManager.default.temporaryDirectory.appendingPathComponent("androsico")
        try? FileManager.default.createDirectory(at: icoDir, withIntermediateDirectories: true)
        let t0 = Date()
        if let u = d.appIcon("com.ark.mzxqteq.gp", cacheDir: icoDir) {
            let sz = (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0
            ok("ikon cikarildi: \(u.lastPathComponent) \((sz ?? 0)/1024) KB, \(String(format: "%.1f", Date().timeIntervalSince(t0))) sn")
        } else { bad("ikon cikarilamadi") }

        hdr("Muzik")
        let tr = d.tracks()
        kv("parca", "\(tr.count)")
        for t in tr.prefix(3) { kv(t.title, "\(t.artist) · \(t.durationText)") }

        hdr("Medya")
        let img = d.media()
        kv("resim", "\(img.count)")
        if let f = img.first { kv("ilk", "\(f.name)  \(f.size/1024) KB") }
        kv("video", "\(d.media(videos: true).count)")
        hdr("Dosyalar /sdcard")
        for f in d.list("/sdcard").prefix(5) {
            kv(f.isDirectory ? "[dizin] " + f.name : f.name, f.isDirectory ? "" : "\(f.size) B")
        }
        exit(0)
    case "uitest":
        // Yan panel eylemlerinin protokol tarafini dogrular: home/recents/back,
        // dondurme, bildirim paneli ve joystick coklu dokunma.
        let a0 = try ADB(); let dv = try a0.singleDevice(); let a = try ADB(serial: dv.serial)
        var cfg = DeviceServer.Config()
        cfg.codec = "h264"; cfg.control = true; cfg.maxSize = 640
        let srv = DeviceServer(adb: a, port: 27197)
        try srv.start(cfg); defer { srv.stop() }
        let dm = StreamDemuxer(socket: srv.videoSocket); _ = dm.readCodec()
        var sw = 0, sh = 0
        // Oturum paketini bekle
        for _ in 0..<40 {
            if case .session(let w, let h, _)? = dm.next() { sw = w; sh = h; break }
        }
        ok("akis \(sw)x\(sh)")

        // Gercek bir DOKUNUS: down ve up arasinda bekleme YOK.
        // (Onceki surumde arada beklenince uzun basma oluyor ve Asistan aciliyordu.)
        func tap(_ name: String, _ code: UInt32) {
            _ = srv.send(ControlMessage.keycode(0, code))
            _ = srv.send(ControlMessage.keycode(1, code))
            usleep(1_800_000)
            let fg = (try? a.checked(["shell", "dumpsys activity activities | grep -m1 mResumedActivity"])) ?? ""
            let app = fg.split(separator: " ").first(where: { $0.contains("/") })
                        .map(String.init) ?? "?"
            kv(name, app)
        }
        tap("ANA EKRAN", AKeycode.home)
        tap("GOREV GORUNUMU", AKeycode.appSwitch)
        tap("GERI", AKeycode.back)

        // Joystick: iki parmak ayni anda
        let km = KeyMapperProbe(send: { srv.send($0) }, w: sw, h: sh)
        km.press()
        usleep(500_000)
        km.release()
        ok("joystick down/move/up gonderildi (pointer id 1)")
        exit(0)
    case "cliptest":
        // Tam tur: Mac -> cihaz panosu -> Mac. Cihazin gercek
        // ClipboardManager'indan geri gelirse iki yon de calisiyor demektir.
        let a0 = try ADB(); let dv = try a0.singleDevice(); let a = try ADB(serial: dv.serial)
        var cfg = DeviceServer.Config()
        cfg.codec = "h264"; cfg.control = true; cfg.maxSize = 480
        let srv = DeviceServer(adb: a, port: 27196)
        try srv.start(cfg); defer { srv.stop() }
        let probe = "AndrOS-roundtrip-\(Int(Date().timeIntervalSince1970))"

        var got: String?
        let sem = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            while got == nil {
                guard let m = DeviceMessage.read(from: srv.controlSocket) else { break }
                if case .clipboard(let t) = m, !t.isEmpty { got = t; sem.signal(); break }
            }
        }
        usleep(600_000)
        _ = srv.send(ControlMessage.setClipboard(probe, sequence: 7))
        ok("gonderildi: \(probe)")
        usleep(800_000)
        _ = srv.send(ControlMessage.getClipboard())
        ok("geri istendi")
        _ = sem.wait(timeout: .now() + 6)
        if let g = got {
            kv("cihazdan donen", g)
            if g == probe { ok("TAM TUR BASARILI - pano iki yonde calisiyor") }
            else { warn("farkli metin dondu (cihazda baska icerik olabilir)") }
        } else { bad("cihazdan pano yaniti gelmedi") }
        exit(got == probe ? 0 : 1)
    case "jitter":
        // Karelerin gelis araliklarini olcer. Ortalama duzgun ama sapma
        // buyukse "dusuk FPS" hissi bundandir (judder).
        let a0 = try ADB(); let dv = try a0.singleDevice(); let a = try ADB(serial: dv.serial)
        var cfg = DeviceServer.Config()
        cfg.codec = "h264"; cfg.maxFPS = 60
        cfg.bitRate = 24_000_000
        if let i = args.firstIndex(of: "--bitrate"), i+1 < args.count {
            cfg.bitRate = (Int(args[i+1]) ?? 24) * 1_000_000
        }
        if let i = args.firstIndex(of: "--size"), i+1 < args.count {
            cfg.maxSize = Int(args[i+1]) ?? 0
        }
        let srv = DeviceServer(adb: a, port: 27195)
        try srv.start(cfg); defer { srv.stop() }
        let dm = StreamDemuxer(socket: srv.videoSocket); _ = dm.readCodec()
        var gaps: [Double] = []
        var last = Date()
        var first = true
        let t0 = Date()
        while Date().timeIntervalSince(t0) < 8 {
            guard let ev = dm.next() else { break }
            if case .packet(let pk) = ev, !pk.isConfig {
                let now = Date()
                if !first { gaps.append(now.timeIntervalSince(last) * 1000) }
                first = false; last = now
            }
        }
        guard gaps.count > 10 else { bad("yeterli kare gelmedi (\(gaps.count))"); exit(1) }
        let mean = gaps.reduce(0,+) / Double(gaps.count)
        let sd = (gaps.map { ($0 - mean) * ($0 - mean) }.reduce(0,+) / Double(gaps.count)).squareRoot()
        let sorted = gaps.sorted()
        hdr("Kare gelis araliklari (\(gaps.count) kare, 8 sn)")
        kv("ortalama", String(format: "%.1f ms  (= %.1f FPS)", mean, 1000/mean))
        kv("standart sapma", String(format: "%.1f ms", sd))
        kv("en dusuk / ortanca", String(format: "%.1f / %.1f ms", sorted.first!, sorted[sorted.count/2]))
        kv("%95 / en yuksek", String(format: "%.1f / %.1f ms", sorted[Int(Double(sorted.count)*0.95)], sorted.last!))
        let over33 = gaps.filter { $0 > 33 }.count
        kv("33ms ustu bosluk", "\(over33) kez (%\(over33 * 100 / gaps.count))")
        if sd > mean * 0.5 { warn("Yuksek sapma: judder'in kaynagi kare uretimi/iletimi.") }
        else { ok("Gelis araliklari duzenli; judder cizim tarafinda degil.") }
        exit(0)
    case "screen":
        // Telefon ekranini ac/kapa. Uygulama anormal kapanip ekran sonuk
        // kalirsa kurtarma yolu budur.
        let on = args.count < 2 || args[1] != "off"
        let a0 = try ADB(); let dv = try a0.singleDevice(); let a = try ADB(serial: dv.serial)
        var cfg = DeviceServer.Config()
        cfg.codec = "h264"; cfg.control = true; cfg.maxSize = 320
        let srv = DeviceServer(adb: a, port: 27194)
        try srv.start(cfg)
        usleep(400_000)
        _ = srv.send(ControlMessage.setDisplayPower(on))
        usleep(600_000)
        srv.stop()
        ok("telefon ekrani: \(on ? "ACIK" : "KAPALI")")
        exit(0)
    case "colorcheck":
        // VT'nin bildirdigi piksel formati ile akisin GERCEK luma araligini
        // karsilastirir. Uyusmazlik dogrudan "soluk renk" demektir.
        for force in [true, false] {
            let a0 = try ADB(); let dv = try a0.singleDevice(); let a = try ADB(serial: dv.serial)
            var cfg = DeviceServer.Config()
            cfg.codec = "h264"; cfg.bitRate = 24_000_000
            if force { cfg.codecOptions = ["color-range": "1", "color-standard": "1", "color-transfer": "3"] }
            let srv = DeviceServer(adb: a, port: force ? 27192 : 27193)
            try srv.start(cfg)
            let dm = StreamDemuxer(socket: srv.videoSocket); _ = dm.readCodec()
            let dec = VideoDecoder()
            var done = false
            dec.onFrame = { pb, _ in
                guard !done else { return }; done = true
                let f = CVPixelBufferGetPixelFormatType(pb)
                let tag = String(bytes: [UInt8(f >> 24 & 0xFF), UInt8(f >> 16 & 0xFF),
                                         UInt8(f >> 8 & 0xFF), UInt8(f & 0xFF)], encoding: .ascii) ?? "?"
                // Y duzlemini dogrudan oku
                CVPixelBufferLockBaseAddress(pb, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
                let w = CVPixelBufferGetWidthOfPlane(pb, 0)
                let h = CVPixelBufferGetHeightOfPlane(pb, 0)
                let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
                guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return }
                let ptr = base.assumingMemoryBound(to: UInt8.self)
                var hist = [Int](repeating: 0, count: 256)
                var n = 0
                for y in stride(from: 0, to: h, by: 3) {
                    for x in stride(from: 0, to: w, by: 3) {
                        hist[Int(ptr[y * rowBytes + x])] += 1; n += 1
                    }
                }
                var lo = 0, hi = 255
                var acc = 0
                for i in 0..<256 { acc += hist[i]; if acc >= n / 500 { lo = i; break } }
                acc = 0
                for i in stride(from: 255, through: 0, by: -1) { acc += hist[i]; if acc >= n / 500 { hi = i; break } }
                let below16 = hist[0..<16].reduce(0,+) * 100 / max(n,1)
                let above235 = hist[236...].reduce(0,+) * 100 / max(n,1)

                hdr(force ? "color-range=1 ZORLANMIS" : "VARSAYILAN (zorlama yok)")
                kv("VT piksel formati", tag + (tag == "420f" ? "  (FULL range)" : tag == "420v" ? "  (VIDEO/limited range)" : ""))
                kv("gercek luma %0.2-%99.8", "\(lo) .. \(hi)")
                kv("16 altinda piksel", "%\(below16)")
                kv("235 ustunde piksel", "%\(above235)")
                let looksFull = (lo < 16 || hi > 235 || below16 > 0 || above235 > 0)
                kv("veri gercekte", looksFull ? "FULL range gibi" : "LIMITED range gibi")
                if tag == "420v" && looksFull {
                    bad("UYUSMAZLIK: VT limited diyor ama veri full -> shader yanlis genisletiyor, renkler bozulur")
                } else if tag == "420f" && !looksFull {
                    bad("UYUSMAZLIK: VT full diyor ama veri limited -> shader genisletmiyor, GORUNTU SOLUK KALIR")
                } else {
                    ok("tutarli")
                }
            }
            var k = 0
            while !done && k < 400 {
                guard let ev = dm.next() else { break }
                if case .packet(let pk) = ev {
                    if pk.isConfig { _ = dec.setParameterSets(fromAnnexB: pk.data) }
                    else { dec.decode(annexB: pk.data, pts: pk.pts); k += 1 }
                }
            }
            usleep(400_000)
            srv.stop()
            usleep(500_000)
        }
        exit(0)
    case "inputtest":
        // Dokunma gostergesini acar, bir dokunus enjekte eder ve o anin
        // karesini kaydeder. Gosterge karede gorunuyorsa girdi CALISIYOR.
        let a0 = try ADB(); let dv = try a0.singleDevice(); let a = try ADB(serial: dv.serial)
        var cfg = DeviceServer.Config()
        cfg.codec = "h264"; cfg.control = true
        cfg.codecOptions = ["color-range": "1", "color-standard": "1", "color-transfer": "3"]
        let srv = DeviceServer(adb: a, port: 27191)
        try srv.start(cfg)
        defer { srv.stop() }
        let dm = StreamDemuxer(socket: srv.videoSocket)
        _ = dm.readCodec()
        let dec = VideoDecoder()
        guard let rnd = MetalRenderer() else { bad("renderer yok"); exit(1) }

        var sw = 0, sh = 0
        var tapped = false, saved = false
        var tapX = 0, tapY = 0
        var settleUntil = Int.max
        let outPath = args.count >= 2 ? args[1] : "inputtest.png"
        dec.onFrame = { pb, _ in
            guard tapped, !saved else { return }
            saved = true
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
            if let t = rnd.renderToTexture(pb, width: w, height: h),
               MetalRenderer.savePNG(t, to: URL(fileURLWithPath: outPath)) {
                ok("dokunus ani kaydedildi: \(outPath)")
            }
        }
        var n = 0
        while !saved && n < 600 {
            guard let ev = dm.next() else { break }
            switch ev {
            case .session(let w, let h, _):
                sw = w; sh = h
                ok("akis \(w)x\(h)")
            case .packet(let pk):
                if pk.isConfig { _ = dec.setParameterSets(fromAnnexB: pk.data) }
                else {
                    dec.decode(annexB: pk.data, pts: pk.pts); n += 1
                    if n >= settleUntil { tapped = true }
                    // Birkac kare aktiktan sonra ekranin ortasina bas ve BASILI TUT
                    if n == 20 && sw > 0 {
                        var x = sw / 2, y = sh / 2
                        if let i = args.firstIndex(of: "--x"), i+1 < args.count { x = Int(args[i+1]) ?? x }
                        if let i = args.firstIndex(of: "--y"), i+1 < args.count { y = Int(args[i+1]) ?? y }
                        _ = srv.send(ControlMessage.touch(.down, x: x, y: y, w: sw, h: sh))
                        usleep(60_000)
                        _ = srv.send(ControlMessage.touch(.up, x: x, y: y, w: sw, h: sh))
                        ok("dokunma gonderildi: (\(x),\(y)) / \(sw)x\(sh)")
                        tapX = x; tapY = y
                        // Arayuzun tepki vermesi icin bir sure daha kare tuket
                        settleUntil = n + 90
                    }
                }
            }
        }
        _ = tapX; _ = tapY
        exit(saved ? 0 : 1)
    case "grab":
        // Canli akistan bir kare alip TAM render hattindan gecirerek PNG yazar.
        let outPath = args.count >= 2 ? args[1] : "androsgrab.png"
        let a0 = try ADB(); let dv = try a0.singleDevice(); let a = try ADB(serial: dv.serial)
        var cfg = DeviceServer.Config()
        cfg.codec = "h264"; cfg.bitRate = 24_000_000; cfg.maxFPS = 60
        if !args.contains("--no-force") {
            cfg.codecOptions = ["color-range": "1", "color-standard": "1", "color-transfer": "3"]
        }
        let srv = DeviceServer(adb: a, port: 27190)
        try srv.start(cfg)
        defer { srv.stop() }
        let dm = StreamDemuxer(socket: srv.videoSocket)
        _ = dm.readCodec()
        let dec = VideoDecoder()
        guard let rnd = MetalRenderer() else { bad("renderer yok"); exit(1) }
        if let i = args.firstIndex(of: "--sat"), i+1 < args.count {
            rnd.params.saturation = Float(args[i+1]) ?? 1.0
        }
        if let i = args.firstIndex(of: "--sharpen"), i+1 < args.count {
            rnd.params.sharpen = Float(args[i+1]) ?? 0.35
        }
        var saved = false
        let sem = DispatchSemaphore(value: 0)
        var outW = 0, outH = 0
        dec.onFrame = { pb, _ in
            guard !saved else { return }
            saved = true
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
            outW = w; outH = h
            if let t = rnd.renderToTexture(pb, width: w, height: h),
               MetalRenderer.savePNG(t, to: URL(fileURLWithPath: outPath)) {
                ok("kaydedildi: \(outPath)  (\(w)x\(h))")
            } else { bad("PNG yazilamadi") }
            sem.signal()
        }
        var frames = 0
        while !saved && frames < 400 {
            guard let ev = dm.next() else { break }
            if case .packet(let pk) = ev {
                if pk.isConfig { _ = dec.setParameterSets(fromAnnexB: pk.data) }
                else { dec.decode(annexB: pk.data, pts: pk.pts); frames += 1 }
            }
        }
        _ = sem.wait(timeout: .now() + 5)
        _ = outW; _ = outH
        exit(saved ? 0 : 1)
    case "selftest":
        hdr("Metal shader runtime derlemesi")
        if let r = MetalRenderer() {
            ok("Shader derlendi, pipeline kuruldu")
            kv("GPU", r.mtlDevice.name)
        } else { bad("MetalRenderer kurulamadi"); exit(1) }
        hdr("VideoToolbox decoder")
        let dec = VideoDecoder()
        let vec = "/private/tmp/claude-501/-Users-naer-code-AndrOS/9cbf6e17-015f-45a8-84cc-235a5e19799f/scratchpad/vec/a_h264_limited_709.h264"
        if let d = try? Data(contentsOf: URL(fileURLWithPath: vec)) {
            var got = 0
            dec.onFrame = { pb, _ in
                if got == 0 {
                    let f = CVPixelBufferGetPixelFormatType(pb)
                    let tag = String(bytes: [UInt8(f >> 24 & 0xFF), UInt8(f >> 16 & 0xFF),
                                             UInt8(f >> 8 & 0xFF), UInt8(f & 0xFF)], encoding: .ascii) ?? "?"
                    kv("cozulen kare", "\(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb)) fmt=\(tag)")
                }
                got += 1
            }
            let bytes = [UInt8](d)
            if dec.setParameterSets(fromAnnexB: bytes) {
                ok("SPS/PPS kabul edildi, VT oturumu acildi")
                // Tum akisi tek parca vermek yerine NAL bazli besle
                var frame: [UInt8] = []
                var count = 0
                for nal in NALU.split(bytes) {
                    let t = (nal.first ?? 0) & 0x1F
                    if t == 7 || t == 8 { continue }
                    frame = [0,0,0,1] + Array(nal)
                    dec.decode(annexB: frame, pts: UInt64(count) * 16666)
                    count += 1
                    if count >= 30 { break }
                }
                usleep(300_000)
                if got > 0 { ok("Donanim decode calisiyor: \(got) kare cozuldu") }
                else { bad("Hic kare cozulemedi") }
            } else { bad("SPS/PPS reddedildi") }
        } else { warn("test vektoru bulunamadi, decoder testi atlandi") }
        exit(0)
    // Kimlik ve zarf turetmesinin ANDROID ve SUNUCU ile ayni oldugunu
    // olcer. Uc dilde ayni sonucu uretmezse arama agi hic kurulmaz ve
    // hata "bir sey olmuyor" diye gorunur — o yuzden sinanabilir olmali.
    case "signal":
        let k = SignalKeys()
        print("kimlik:      \(k.id)")
        print("ed açık:     \(k.edPublic.base64EncodedString())")
        print("x açık:      \(k.xPublic.base64EncodedString())")

        // Bilinen vektor: sifirlarla dolu bir acik anahtarin kimligi.
        // Ayni deger Android ve sunucuda da cikmali.
        let zero = Data(repeating: 0, count: 32)
        print("sıfır anahtarın kimliği: \(SignalKeys.id(for: zero))")

        // Iki taraf birbirini tanisip muhurlu mesaj degistirsin.
        let a = SignalKeys()
        let bPriv = Curve25519.KeyAgreement.PrivateKey()
        let bEd = Curve25519.Signing.PrivateKey()
        let bID = SignalKeys.id(for: bEd.publicKey.rawRepresentation)
        guard let key = a.sharedKey(with: bPriv.publicKey.rawRepresentation,
                                    myID: a.id, theirID: bID),
              let sealed = Envelope.seal(key, ["t": "msg", "text": "merhaba"]),
              let opened = Envelope.open(key, sealed) else {
            print("MÜHÜRLEME BAŞARISIZ"); exit(1)
        }
        print("mühürlü boyut: \(sealed.count) bayt · açıldı: \(opened)")

        // ANDROID ile uyum icin sabit anahtarli vektor. BouncyCastle
        // ile CryptoKit ayni bicimi uretmezse mesajlar sessizce
        // acilmiyor; bu satirlar iki tarafi karsilastirmayi mumkun
        // kiliyor.
        let fixed = SymmetricKey(data: Data(repeating: 7, count: 32))
        if let v = Envelope.seal(fixed, ["t": "msg", "text": "sınama"]) {
            print("vektör anahtar: \(Data(repeating: 7, count: 32).base64EncodedString())")
            print("vektör zarf:    \(v.base64EncodedString())")
        }

        // Tanisma paketi kendi kimligiyle dogrulanmali, baskasiyla degil.
        let intro = Envelope.intro(a)
        let ok = Envelope.openIntro(intro, from: a.id) != nil
        let bad = Envelope.openIntro(intro, from: bID) == nil
        print("tanışma doğrulama: \(ok ? "geçti" : "KALDI") · "
            + "yanlış kimlik reddi: \(bad ? "geçti" : "KALDI")")
        if !ok || !bad { exit(1) }

    // Canli sinyal sunucusuna baglanip ucu uca sinar.
    //   androsctl signal-live ws://127.0.0.1:8899/ws <tuz>
    case "signal-live":
        let addr = args.count > 1 ? args[1] : "ws://127.0.0.1:8899/ws"
        let salt = args.count > 2 ? args[2] : "test"
        let k = SignalKeys()
        guard let c = SignalClient(keys: k, url: addr, salt: salt) else {
            print("adres kabul edilmedi"); exit(1)
        }
        c.myNumbers = ["0532 111 22 33"]
        var done = false
        c.onState = { st in
            print("durum: \(st)")
            if st == .ready {
                // Ozet ancak tuz gelince hesaplanabiliyor.
                let digest = c.digest("0532 111 22 33")
                print("kimlik: \(k.id) · numara özeti: \(digest)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    c.lookup([digest, c.digest("+905000000000")])
                }
            }
        }
        c.onPresence = { found, missing in
            print("bulunan: \(found) · bulunamayan: \(missing.count) adet")
            // Kendi kimligimize zarf yollayip geri almak, iletme yolunun
            // tamamini sinar: muhurleme, sunucu, cozme.
            let key = k.sharedKey(with: k.xPublic, myID: k.id, theirID: k.id)!
            if let env = Envelope.seal(key, ["t": "msg", "text": "döngü sınaması"]) {
                c.send(to: k.id, envelope: env)
            }
        }
        c.onEnvelope = { from, env in
            let key = k.sharedKey(with: k.xPublic, myID: k.id, theirID: from)!
            print("zarf geldi (\(env.count) bayt): \(Envelope.open(key, env) ?? [:])")
            done = true
        }
        c.connect()
        let deadline = Date().addingTimeInterval(10)
        while !done, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        c.disconnect()
        print(done ? "SINAMA GEÇTI" : "SINAMA KALDI")
        exit(done ? 0 : 1)

    // Iki uc arasinda GERCEK mesajlasma sinamasi.
    //   androsctl chat <ws-adres> listen
    //   androsctl chat <ws-adres> send <kimlik> <metin>
    case "chat":
        let addr = args.count > 1 ? args[1] : "ws://127.0.0.1:8899/ws"
        let mode = args.count > 2 ? args[2] : "listen"
        SignalHub.serverURL = addr
        let hub = SignalHub.shared
        print("kimlik: \(hub.id)")
        var got = false
        hub.onMessage = { from, text, _ in
            print("mesaj [\(from)]: \(text)")
            got = true
        }
        hub.onState = { print("durum: \($0)") }
        hub.start()
        if mode == "send", args.count > 4 {
            // Baglanti kurulunca yolla: hazir olmadan gonderilen ileti
            // sessizce dusuyordu.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                hub.sendMessage(to: args[3], text: args[4])
                print("yollandı -> \(args[3])")
            }
        }
        let until = Date().addingTimeInterval(mode == "send" ? 6 : 20)
        while Date() < until, !(mode == "listen" && got) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        hub.stop()
        if mode == "listen" { print(got ? "MESAJ ALINDI" : "MESAJ GELMEDI"); exit(got ? 0 : 1) }

    // Dis adresi ogrenme sinamasi.
    //   androsctl stun [sunucu] [port]
    case "stun":
        let host = args.count > 1 ? args[1] : Stun.defaultHost
        let port = args.count > 2 ? (UInt16(args[2]) ?? 3478) : Stun.defaultPort
        let fd = Stun.makeSocket()
        guard fd >= 0 else { print("soket açılamadı"); exit(1) }
        defer { close(fd) }
        if let m = Stun.discover(socket: fd, host: host, port: port) {
            print("dış adresim: \(m.host):\(m.port)  (\(host):\(port) söyledi)")
        } else {
            print("STUN yanıt vermedi — \(host):\(port) ulaşılabilir mi?")
            exit(1)
        }

    case "parse":
        guard args.count >= 2 else { bad("kullanim: androsctl parse <dosya.h264|.h265>"); exit(1) }
        let path = args[1]
        let data = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
        let isHEVC = path.hasSuffix(".h265") || path.hasSuffix(".hevc") || args.contains("--hevc")
        guard let c = (isHEVC ? SPSParser.parseHEVC(data) : SPSParser.parseH264(data)) else {
            bad("SPS bulunamadi/cozumlenemedi"); exit(1)
        }
        print(c.description)
    case "probe", nil:
        var codec = "h264"
        if let i = args.firstIndex(of: "--codec"), i + 1 < args.count { codec = args[i+1] }
        try cmdProbe(codec: codec)
    default:
        print("""
        androsctl <komut>
          devices              Bagli cihazlari listeler
          probe [--codec h264|h265]
                               Renk/gecikme teshisi calistirir
        """)
    }
} catch {
    bad("\(error)")
    exit(1)
}
