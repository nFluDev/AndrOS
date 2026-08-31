import Foundation

/// Faz 1 tasiyicisi: scrcpy-server (Apache-2.0) cihaza itilip app_process ile
/// shell UID altinda calistirilir. Faz 2'de yerini kendi agent'imiz alacak.
public final class DeviceServer {

    public struct Config {
        public var codec: String = "h264"           // h264 | h265 (av1 YOK: RX 580 cozemiyor)
        public var bitRate: Int = 24_000_000
        public var maxSize: Int = 0                 // 0 = kisitlama yok
        public var maxFPS: Int = 0                  // 0 = cihaz varsayilani
        /// MediaCodec'e dogrudan gecen anahtarlar. Renk zorlamasinin yeri burasi.
        /// color-range: 1=FULL 2=LIMITED | color-standard: 1=BT709 | color-transfer: 3=SMPTE170M
        public var codecOptions: [String: String] = [:]
        public var control = false
        /// Cihazda dokunma noktalarini gosterir — girdi dogrulamasi icin.
        public var showTouches = false

        /// Sesi bilgisayara aktar.
        ///
        /// `audio_source=output` REMOTE_SUBMIX'e baglanir: ses cikisi
        /// YONLENDIRILIR, yani telefonun hoparlorunden ses GELMEZ.
        /// Android 11'de yakalamanin calismasi icin ekran KILITSIZ olmali.
        public var audio = false
        /// Ham PCM: cozucu gerekmez, en dusuk gecikme.
        public var audioCodec = "raw"
        public init() {}

        var serverArgs: [String] {
            var a = ["log_level=info", "tunnel_forward=true",
                     "video_codec=\(codec)", "video_bit_rate=\(bitRate)"]
            if audio {
                a.append("audio_codec=\(audioCodec)")
                a.append("audio_source=output")
            } else {
                a.append("audio=false")
            }
            if !control { a.append("control=false") }
            if showTouches { a.append("show_touches=true") }
            if maxSize > 0 { a.append("max_size=\(maxSize)") }
            if maxFPS > 0 { a.append("max_fps=\(maxFPS)") }
            if !codecOptions.isEmpty {
                let opts = codecOptions.sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }.joined(separator: ",")
                a.append("video_codec_options=\(opts)")
            }
            return a
        }
    }

    /// Sunucu surumu jar'in YANINDAKI VERSION dosyasindan okunur; boylece
    /// jar ile surum stringi asla ayrisamaz (ayrisirsa sunucu kendini kapatir).
    public static var serverVersion: String = {
        if let jar = locateServerJar() {
            let v = URL(fileURLWithPath: jar).deletingLastPathComponent()
                .appendingPathComponent("VERSION")
            if let s = try? String(contentsOf: v, encoding: .utf8) {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return t }
            }
        }
        return "4.1"
    }()
    public static let devicePath = "/data/local/tmp/scrcpy-server-andros.jar"

    private let adb: ADB
    private let scid: String
    private let port: UInt16
    private var proc: Process?
    public private(set) var deviceName = ""
    public let videoSocket = TCPSocket()
    public let audioSocket = TCPSocket()
    public let controlSocket = TCPSocket()

    /// Cihaz tarafi hatalarini disari bildirir (orn. ses yakalama basarisiz).
    /// Sessizce yutulursa kullanici "ses neden yok" diye anlayamiyor.
    public var onServerError: ((String) -> Void)?

    public init(adb: ADB, port: UInt16 = 27183) {
        self.adb = adb
        self.port = port
        self.scid = String(format: "%08x", UInt32.random(in: 0..<0x7FFF_FFFF))
    }

    /// Sunucu jar'ini bulur. Once uygulama paketinin icine bakar (kendi
    /// kopyamiz), sonra depo icindeki vendor/, en son sistemdeki scrcpy.
    public static func locateServerJar() -> String? {
        var candidates: [String] = []
        if let res = Bundle.main.resourcePath {
            candidates.append("\(res)/scrcpy-server")
        }
        // Gelistirme sirasinda depodan calistirirken
        var dir = URL(fileURLWithPath: CommandLine.arguments.first ?? ".")
            .deletingLastPathComponent()
        for _ in 0..<6 {
            candidates.append(dir.appendingPathComponent("vendor/scrcpy-server").path)
            dir = dir.deletingLastPathComponent()
        }
        candidates += ["/usr/local/share/scrcpy/scrcpy-server",
                       "/opt/homebrew/share/scrcpy/scrcpy-server"]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    public func start(_ cfg: Config) throws {
        Log.write("server.start codec=\(cfg.codec) opts=\(cfg.codecOptions)")
        guard let jar = DeviceServer.locateServerJar() else {
            throw ADBError.command("scrcpy-server bulunamadi", 1,
                                   "brew install scrcpy ile kurun")
        }
        Log.write("jar: \(jar)")
        _ = try adb.checked(["push", jar, DeviceServer.devicePath], timeout: 60)
        _ = try? adb.run(["forward", "--remove", "tcp:\(port)"])
        _ = try adb.checked(["forward", "tcp:\(port)", "localabstract:scrcpy_\(scid)"])

        // Sunucuyu arka planda baslat (cikti akisini terk etmiyoruz, log icin).
        let p = Process()
        p.executableURL = URL(fileURLWithPath: adb.path)
        p.arguments = (adb.serial.map { ["-s", $0] } ?? []) + [
            "shell", "CLASSPATH=\(DeviceServer.devicePath)",
            "app_process", "/", "com.genymobile.scrcpy.Server",
            DeviceServer.serverVersion, "scid=\(scid)",
        ] + cfg.serverArgs
        let errPipe = Pipe()
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        Log.write("app_process baslatiliyor: \((p.arguments ?? []).joined(separator: " "))")
        try p.run()
        proc = p

        // KRITIK: bu borulari surekli bosaltmazsak 64 KB dolunca cihazdaki
        // sunucu log yazarken BLOKE olur ve goruntu akisi sessizce durur.
        // Ayrica sunucu taraflı hatalari gormemizi saglar.
        for (pipe, tag) in [(outPipe, "sunucu"), (errPipe, "sunucu!")] {
            let h = pipe.fileHandleForReading
            h.readabilityHandler = { [weak self] fh in
                let d = fh.availableData
                if d.isEmpty { fh.readabilityHandler = nil; return }
                let text = String(decoding: d, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    for line in text.split(separator: "\n") {
                        Log.write("[\(tag)] \(line)")
                        if line.contains("Failed to start audio capture") {
                            self?.onServerError?("audio")
                        }
                    }
                }
            }
        }

        // Sunucu dinlemeye baslayana kadar dene (scrcpy: 100 deneme x 100ms).
        var connected = false
        for _ in 0..<100 {
            if videoSocket.connect(port: port),
               let dummy = videoSocket.readExactly(1, timeoutSeconds: 1.0) {
                _ = dummy                       // forward tunelde 1 baytlik dummy
                connected = true
                break
            }
            videoSocket.close()
            usleep(100_000)
        }
        guard connected else {
            Log.write("BAGLANTI YOK (sunucu ciktisi yukaridaki [sunucu] satirlarinda)")
            let log = ""
            throw ADBError.command("sunucuya baglanilamadi", 1,
                                   log.isEmpty ? "cihaz yanit vermedi" : log)
        }

        // SIRALAMA KRITIK: sunucu soketleri VIDEO -> SES -> KONTROL sirasiyla
        // kabul ediyor ve cihaz adini ancak hepsi baglandiktan SONRA yaziyor.
        // Sirayi bozmak ya da eksik baglamak 64 baytlik okumayi kilitler.
        func connectExtra(_ sock: TCPSocket, _ name: String) throws {
            var ok = false
            for _ in 0..<100 where !ok {
                if sock.connect(port: port) { ok = true; break }
                usleep(50_000)
            }
            guard ok else {
                Log.write("\(name) soketi acilamadi")
                throw ADBError.command("\(name) soketi acilamadi", 1, "")
            }
            Log.write("\(name) soketi baglandi")
        }
        if cfg.audio   { try connectExtra(audioSocket, "ses") }
        if cfg.control { try connectExtra(controlSocket, "kontrol") }

        guard let nameBytes = videoSocket.readExactly(64, timeoutSeconds: 10) else {
            Log.write("cihaz adi okunamadi (64 bayt gelmedi)")
            throw ADBError.command("cihaz adi okunamadi", 1, "")
        }
        deviceName = String(decoding: nameBytes.prefix { $0 != 0 }, as: UTF8.self)
        Log.write("baglandi, cihaz adi: \(deviceName)")
    }

    /// Kontrol mesaji gonderir (girdi enjeksiyonu).
    @discardableResult
    public func send(_ msg: [UInt8]) -> Bool { controlSocket.write(msg) }

    public func stop() {
        Log.write("server.stop cagrildi")
        proc?.standardOutput.map { ($0 as? Pipe)?.fileHandleForReading.readabilityHandler = nil }
        proc?.standardError.map { ($0 as? Pipe)?.fileHandleForReading.readabilityHandler = nil }
        controlSocket.close()
        audioSocket.close()
        videoSocket.close()
        proc?.terminate()
        _ = try? adb.run(["forward", "--remove", "tcp:\(port)"])
    }
}

extension Process {
    static func brewPrefix() throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["brew", "--prefix"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
