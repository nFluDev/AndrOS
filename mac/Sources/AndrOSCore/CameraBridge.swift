import Foundation
import Network
import CoreVideo

/// Telefonun kamerasini Mac'e getirir.
///
/// Telefon donanim kodlayicisiyla H.264 uretiyor; burada yansitma icin
/// yazilmis `VideoDecoder` (VideoToolbox) ayni akisi cozuyor. Cikan
/// kareler `onFrame` ile veriliyor: hem uygulama ici onizleme hem menu
/// cubugu hem de sanal kamera ayni kaynagi kullaniyor.
///
/// AYRI SOKET (47825): goruntu buyuk ve surekli; denetim kanalinin
/// arkasinda beklerse hem kendi takilir hem otekini bekletir.
public final class CameraBridge {

    public static let shared = CameraBridge()
    private init() {}

    public enum Facing: Int { case back = 0, front = 1 }
    public enum State: Equatable { case off, connecting, on, failed(String) }

    public private(set) var state: State = .off {
        didSet { if state != oldValue { onState?(state) } }
    }
    public private(set) var facing: Facing = .back
    public private(set) var size: CGSize = .zero

    public var onState: ((State) -> Void)?
    /// Her cozulmus kare. Ana is parcaciginda DEGIL — kullanan taraf
    /// kendi kuyruguna gecirmeli.
    public var onFrame: ((CVPixelBuffer) -> Void)?

    private var conn: NWConnection?
    private let queue = DispatchQueue(label: "dev.naer.andros.camera", qos: .userInitiated)
    private let decoder = VideoDecoder()
    private var buffer = Data()

    public func start(host: String, token: String, facing: Facing = .back) {
        stop()
        state = .connecting
        self.facing = facing

        decoder.onFrame = { [weak self] px, _ in
            guard let self else { return }
            self.decoded += 1
            if self.decoded == 1 { Log.write("kamera: ilk kare çözüldü") }
            self.onFrame?(px)
        }

        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(
            tls.securityProtocolOptions, { _, _, complete in complete(true) }, queue)
        let params = NWParameters(tls: tls)
        if let tcp = params.defaultProtocolStack.transportProtocol
            as? NWProtocolTCP.Options { tcp.noDelay = true }

        let c = NWConnection(host: NWEndpoint.Host(host),
                             port: NWEndpoint.Port(rawValue: 47825)!, using: params)
        c.stateUpdateHandler = { [weak self] s in
            guard let self else { return }
            switch s {
            case .ready:
                self.send(kind: 0, payload: Data(token.utf8))          // yetki
                self.send(kind: 1, payload: Data([UInt8(facing.rawValue)]))  // baslat
                self.receive()
                self.state = .on
                Log.write("kamera köprüsü açık: \(host)")
            case .failed(let e): self.state = .failed("\(e)")
            case .cancelled:     self.state = .off
            default: break
            }
        }
        conn = c
        c.start(queue: queue)
    }

    public func stop() {
        if conn != nil { send(kind: 2, payload: Data()) }   // durdur
        conn?.cancel(); conn = nil
        buffer.removeAll()
        received = 0; decoded = 0; ready = false
        state = .off
    }

    /// On/arka kamera degistir.
    public func toggleFacing() {
        facing = facing == .back ? .front : .back
        send(kind: 3, payload: Data())
    }

    private func send(kind: UInt8, payload: Data) {
        var f = Data([kind])
        var n = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &n) { f.append(contentsOf: $0) }
        f.append(payload)
        conn?.send(content: f, completion: .contentProcessed { _ in })
    }

    /// Gelen H.264 birimini cozucuye verir.
    ///
    /// ONEMLI: `decode()` yalnizca oturum KURULMUSSA is goruyor; oturumu
    /// kuran sey SPS/PPS. `MediaCodec` bunlari ayri bir "codec config"
    /// tamponunda yolluyor. Bu ayrimi yapmadan her seyi `decode()`'a
    /// vermek sessiz basarisizlik demekti: paketler geliyor, hicbir kare
    /// cozulmuyordu (olculdu: 60 paket, 0 kare).
    private func feed(_ nalus: [UInt8]) {
        var hasSPS = false, hasPicture = false
        for nal in NALU.split(nalus) {
            guard let f = nal.first else { continue }
            switch f & 0x1F {
            case 7, 8: hasSPS = true                 // SPS / PPS
            case 1, 5: hasPicture = true             // kare
            default: break
            }
        }
        if hasSPS {
            if decoder.setParameterSets(fromAnnexB: nalus), !ready {
                ready = true
                Log.write("kamera: çözücü kuruldu")
            }
        }
        guard hasPicture else { return }
        pts &+= 33_333
        decoder.decode(annexB: nalus, pts: pts)
    }

    private var ready = false

    private func receive() {
        conn?.receive(minimumIncompleteLength: 1, maximumLength: 1 << 18) {
            [weak self] data, _, done, err in
            guard let self else { return }
            if let data, !data.isEmpty { self.ingest(data) }
            if done || err != nil { self.state = .off; return }
            self.receive()
        }
    }

    private var pts: UInt64 = 0
    private var received = 0
    private var decoded = 0

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
                if received == 1 { Log.write("kamera: ilk paket geldi (\(body.count) bayt)") }
                if received == 60 && decoded == 0 {
                    Log.write("kamera: 60 paket geldi ama HİÇ kare çözülemedi")
                }
                feed([UInt8](body))
            case 5:
                if let j = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                    if let e = j["error"] as? String {
                        Log.write("kamera hatası: \(e)")
                        state = .failed(e)
                        return
                    }
                    let w = j["width"] as? Int ?? 0, h = j["height"] as? Int ?? 0
                    size = CGSize(width: w, height: h)
                    if let f = j["facing"] as? Int, let ff = Facing(rawValue: f) { facing = ff }
                    Log.write("kamera: \(w)x\(h) (\(facing == .front ? "ön" : "arka"))")
                }
            default: break
            }
        }
    }
}
