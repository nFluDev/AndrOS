import Foundation
import Network
import CoreVideo

/// Ekran yansitma — ADB OLMADAN.
///
/// scrcpy iyi calisiyor ama bedeli USB hata ayiklama: sunucusunu adb ile
/// itiyor, girdiyi de yalniz shell yetkisiyle erisilebilen
/// `InputManager` ile enjekte ediyor. Bu projenin butun amaci telefonu
/// hata ayiklama ACMADAN kullanmak, o yuzden kendi motorumuzu yazdik:
///
///   • GORUNTU — telefonda `MediaProjection` + sanal ekran +
///     `MediaCodec` (H.264). Burada `VideoDecoder` (VideoToolbox) cozuyor.
///   • GIRDI  — telefonda erisilebilirlik hizmeti (`InputService`).
///
/// Kameradan AYRI soket (47826): ikisi ayni anda calisabilsin ve biri
/// otekini bekletmesin.
public final class ScreenBridge {

    public static let shared = ScreenBridge()
    private init() {}

    public enum State: Equatable { case off, connecting, on, failed(String) }

    public private(set) var state: State = .off {
        didSet { if state != oldValue { DispatchQueue.main.async { self.onState?(self.state) } } }
    }
    /// Telefon ekraninin PIKSEL olcusu.
    public private(set) var size: CGSize = .zero
    /// Erisilebilirlik acik mi — kapaliysa goruntu gelir, dokunma gitmez.
    public private(set) var inputReady = false

    public var onState: ((State) -> Void)?
    /// Dokunmanin calisip calismadigi DEGISTIGINDE. Durum degismeden
    /// de degisebiliyor (kullanici erisilebilirligi sonradan aciyor),
    /// o yuzden `onState` yetmiyor.
    public var onInputReady: ((Bool) -> Void)?
    /// Olumcul OLMAYAN uyari KODU: yayin surer, tek bir dugme calismaz.
    /// Kullaniciya gosterilecek metni arayuz seciyor.
    public var onNotice: ((String) -> Void)?
    public var onFrame: ((CVPixelBuffer) -> Void)?

    private var conn: NWConnection?
    private let queue = DispatchQueue(label: "dev.naer.andros.screen", qos: .userInitiated)
    private let decoder = VideoDecoder()
    private var buffer = Data()
    private var ready = false
    private var pts: UInt64 = 0
    private var received = 0
    private var decoded = 0

    /// Kalite ayarlari. Gecikmeyi en cok COZUNURLUK ve KARE HIZI
    /// belirliyor; bit hizi gorunuse etki ediyor.
    public struct Quality {
        public var maxSize: Int
        public var fps: Int
        public var mbps: Int
        public init(maxSize: Int = 1920, fps: Int = 60, mbps: Int = 8) {
            self.maxSize = maxSize; self.fps = fps; self.mbps = mbps
        }
    }

    public func start(host: String, token: String, quality: Quality = Quality()) {
        stop()
        state = .connecting

        decoder.onFrame = { [weak self] px, _ in
            guard let self else { return }
            self.decoded += 1
            if self.decoded == 1 { Log.write("yansıtma: ilk kare çözüldü") }
            self.onFrame?(px)
        }

        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(
            tls.securityProtocolOptions, { _, _, complete in complete(true) }, queue)
        let params = NWParameters(tls: tls)
        if let tcp = params.defaultProtocolStack.transportProtocol
            as? NWProtocolTCP.Options { tcp.noDelay = true }

        let c = NWConnection(host: NWEndpoint.Host(host),
                             port: NWEndpoint.Port(rawValue: 47826)!, using: params)
        c.stateUpdateHandler = { [weak self] s in
            guard let self else { return }
            switch s {
            case .ready:
                self.send(kind: 0, payload: Data(token.utf8))   // yetki
                let q: [String: Any] = ["maxSize": quality.maxSize,
                                        "fps": quality.fps,
                                        "bitrate": quality.mbps]
                self.send(kind: 1, payload: (try? JSONSerialization.data(
                    withJSONObject: q)) ?? Data())              // baslat
                self.receive()
                self.state = .on
                Log.write("yansıtma köprüsü açık: \(host)")
            case .failed(let e): self.state = .failed("\(e)")
            case .cancelled:     self.state = .off
            default: break
            }
        }
        conn = c
        c.start(queue: queue)
    }

    public func stop() {
        if conn != nil { send(kind: 2, payload: Data()) }
        conn?.cancel(); conn = nil
        buffer.removeAll()
        received = 0; decoded = 0; ready = false
        size = .zero
        state = .off
    }

    // MARK: - Girdi

    /// Dokunma. Koordinatlar 0..1 ORANLI: Mac penceresi olceklenebiliyor,
    /// piksel gondermek yanlis yere dokunmak demek.
    public func tap(_ x: Double, _ y: Double) { input(["t": "tap", "x": x, "y": y]) }
    public func longPress(_ x: Double, _ y: Double) { input(["t": "long", "x": x, "y": y]) }

    public func swipe(_ points: [(Double, Double)], ms: Int = 120) {
        guard points.count >= 2 else { return }
        input(["t": "swipe", "ms": ms,
               "p": points.map { ["x": $0.0, "y": $0.1] }])
    }

    public func back()    { input(["t": "back"]) }
    public func home()    { input(["t": "home"]) }
    public func recents() { input(["t": "recents"]) }
    public func shade()   { input(["t": "shade"]) }
    public func quickSettings() { input(["t": "quick"]) }
    public func powerDialog()   { input(["t": "power"]) }
    public func lockScreen()    { input(["t": "lock"]) }
    public func screenshot()    { input(["t": "shot"]) }
    public func volume(up: Bool) { input(["t": "vol", "d": up ? 1 : -1]) }
    public func toggleAutoRotate() { input(["t": "rotate"]) }
    /// Telefon ekranini karart / geri ac.
    ///
    /// Ekrani GERCEKTEN kapatmak adb istiyor (scrcpy bunu `--turn-screen-off`
    /// ile yapiyor ve orada shell yetkisi var). Adb'siz yapabildigimiz
    /// parlakligi sifirlamak: yansitma surer, telefon kararir.
    public func dimScreen(_ on: Bool) { input(["t": "dim", "on": on]) }
    public func type(_ s: String) { input(["t": "text", "s": s]) }
    public func backspace() { input(["t": "backspace"]) }

    private func input(_ obj: [String: Any]) {
        guard state == .on,
              let d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        send(kind: 3, payload: d)
    }

    // MARK: - Cerceveler

    private func send(kind: UInt8, payload: Data) {
        var f = Data([kind])
        var n = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &n) { f.append(contentsOf: $0) }
        f.append(payload)
        conn?.send(content: f, completion: .contentProcessed { _ in })
    }

    private func receive() {
        conn?.receive(minimumIncompleteLength: 1, maximumLength: 1 << 18) {
            [weak self] data, _, done, err in
            guard let self else { return }
            if let data, !data.isEmpty { self.ingest(data) }
            if done || err != nil { self.state = .off; return }
            self.receive()
        }
    }

    private func ingest(_ chunk: Data) {
        buffer.append(chunk)
        while buffer.count >= 5 {
            let kind = buffer[buffer.startIndex]
            let len = buffer[(buffer.startIndex + 1)..<(buffer.startIndex + 5)]
                .reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard len <= 8 << 20 else { buffer.removeAll(); return }
            let total = 5 + Int(len)
            guard buffer.count >= total else { return }
            let body = buffer.subdata(in: (buffer.startIndex + 5)..<(buffer.startIndex + total))
            buffer.removeFirst(total)
            switch kind {
            case 4:
                received += 1
                if received == 1 { Log.write("yansıtma: ilk paket (\(body.count) bayt)") }
                feed([UInt8](body))
            case 5:
                guard let j = try? JSONSerialization.jsonObject(with: body)
                        as? [String: Any] else { break }
                if let e = j["error"] as? String {
                    // Her hata yayini bitirmez. "noinput" ve
                    // "nowritesettings" tek bir dugmeyle ilgili;
                    // bunlari olumcul saymak calisan yansitmayi
                    // kapatirdi.
                    switch e {
                    case "noinput":
                        if inputReady { Log.write("yansıtma: erişilebilirlik kapalı") }
                        inputReady = false
                        DispatchQueue.main.async { self.onInputReady?(false) }
                    case "nowritesettings":
                        Log.write("yansıtma: sistem ayarlarını yazma izni yok")
                        // Metni ARAYUZ yaziyor: cekirdek iki dilli
                        // dizeleri tutmuyor, yalnizca kodu geciyor.
                        DispatchQueue.main.async { self.onNotice?(e) }
                    default:
                        Log.write("yansıtma hatası: \(e)")
                        state = .failed(e)
                    }
                    break
                }
                let w = j["width"] as? Int ?? 0, h = j["height"] as? Int ?? 0
                size = CGSize(width: w, height: h)
                inputReady = j["input"] as? Bool ?? false
                DispatchQueue.main.async { self.onInputReady?(self.inputReady) }
                Log.write("yansıtma: \(w)x\(h) · girdi: \(inputReady ? "açık" : "kapalı")")
            default: break
            }
        }
    }

    /// ONEMLI: `decode()` yalniz oturum kurulmussa is goruyor ve oturumu
    /// kuran sey SPS/PPS. `MediaCodec` bunlari AYRI bir "codec config"
    /// tamponunda yolluyor; ayrimi yapmadan her seyi `decode()`'a vermek
    /// sessiz basarisizlik demekti (kamerada olculdu: 60 paket, 0 kare).
    private func feed(_ nalus: [UInt8]) {
        var hasSPS = false, hasPicture = false
        for nal in NALU.split(nalus) {
            guard let f = nal.first else { continue }
            switch f & 0x1F {
            case 7, 8: hasSPS = true
            case 1, 5: hasPicture = true
            default: break
            }
        }
        if hasSPS, decoder.setParameterSets(fromAnnexB: nalus), !ready {
            ready = true
            Log.write("yansıtma: çözücü kuruldu")
        }
        guard hasPicture else { return }
        pts &+= 16_666                      // 60 fps
        decoder.decode(annexB: nalus, pts: pts)
    }
}
