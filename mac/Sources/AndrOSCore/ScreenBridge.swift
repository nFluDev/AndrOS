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
    public var onFrame: ((CVPixelBuffer) -> Void)?

    private var conn: NWConnection?
    private let queue = DispatchQueue(label: "dev.naer.andros.screen", qos: .userInitiated)
    private let decoder = VideoDecoder()
    private var buffer = Data()
    private var ready = false
    private var pts: UInt64 = 0
    private var received = 0
    private var decoded = 0

    public func start(host: String, token: String) {
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
                self.send(kind: 1, payload: Data())             // baslat
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
                    // "noinput" olumcul degil: goruntu akar, dokunma gitmez.
                    if e == "noinput" { inputReady = false; Log.write("yansıtma: erişilebilirlik kapalı") }
                    else { Log.write("yansıtma hatası: \(e)"); state = .failed(e) }
                    break
                }
                let w = j["width"] as? Int ?? 0, h = j["height"] as? Int ?? 0
                size = CGSize(width: w, height: h)
                inputReady = j["input"] as? Bool ?? false
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
