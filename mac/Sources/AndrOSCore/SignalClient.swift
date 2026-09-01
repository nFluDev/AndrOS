import Foundation
import CryptoKit

/// Sinyal sunucusuna baglanti (Mac tarafi).
///
/// Sunucu yalnizca TANISTIRIYOR: kimin bagli oldugunu biliyor ve
/// sifreli zarflari iletiyor, icerigi goremiyor.
///
/// `wss://` ZORUNLU. Duz `ws://` kabul edilmiyor: sunucu icerigi
/// goremese de kimin kime yazdigini aradaki herkes gorebilirdi.
public final class SignalClient: NSObject {

    public enum State: Equatable { case offline, connecting, ready }

    public private(set) var state: State = .offline {
        didSet { if state != oldValue { DispatchQueue.main.async { self.onState?(self.state) } } }
    }

    public var onState: ((State) -> Void)?
    /// Zarf geldi: (gonderen kimlik, ham zarf).
    public var onEnvelope: ((String, Data) -> Void)?
    /// Ulasilabilirlik yaniti: (numara ozeti -> kimlik), bulunamayanlar.
    public var onPresence: (([String: String], [String]) -> Void)?
    public var onUndeliverable: ((String) -> Void)?

    private let keys: SignalKeys
    private let url: URL
    /// Numara ozetinin tuzu. SUNUCUDAN geliyor: istemcinin hesapladigi
    /// ozetin sunucununkiyle tutmasi gerekiyor ve tuzu uygulamaya
    /// gommek hem paketten cikarilabilir olurdu hem de sunucu sahibini
    /// uygulamayi yeniden derlemeye zorlardi.
    private var salt: String
    private var task: URLSessionWebSocketTask?
    private var session: URLSession!
    private var closedByUs = false
    private var attempt = 0
    /// Bu Mac'in bulunabilecegi HAM numaralar (telefonun hatti).
    /// Ozetleri baglanti kurulunca hesaplaniyor — ham numara sunucuya
    /// hicbir zaman gitmiyor.
    public var myNumbers: [String] = [] {
        didSet { if state == .ready { publishNumbers() } }
    }

    private func publishNumbers() {
        let digests = myNumbers.map { digest($0) }.filter { !$0.isEmpty }
        guard !digests.isEmpty else { return }
        _ = say(["t": "numbers", "of": digests])
    }

    /// `wss://` zorunlu. TEK istisna geri dongu adresi: orada trafik
    /// makineden hic cikmiyor ve sinama sunucusuna sertifika kurmak
    /// gercek bir guvenlik kazanci saglamiyor.
    public static func isAllowed(_ url: String) -> Bool {
        if url.hasPrefix("wss://") { return true }
        return url.hasPrefix("ws://127.0.0.1") || url.hasPrefix("ws://localhost")
    }

    public init?(keys: SignalKeys, url: String, salt: String = "") {
        guard Self.isAllowed(url), let u = URL(string: url) else {
            Log.write("sinyal: wss:// dışında adres kabul edilmiyor")
            return nil
        }
        self.keys = keys
        self.url = u
        self.salt = salt
        super.init()
        session = URLSession(configuration: .default)
    }

    public func connect() {
        closedByUs = false
        state = .connecting
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        receive()
        ping()
    }

    public func disconnect() {
        closedByUs = true
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        state = .offline
    }

    // MARK: - Gonderme

    /// Sifreli zarfi kime gidecekse ona iletir.
    @discardableResult
    public func send(to: String, envelope: Data) -> Bool {
        guard state == .ready else { return false }
        return say(["t": "send", "to": to,
                    "env": envelope.base64EncodedString()])
    }

    /// Bu numaralardan hangileri su an ulasilabilir?
    public func lookup(_ digests: [String]) {
        _ = say(["t": "lookup", "of": digests])
    }

    @discardableResult
    private func say(_ obj: [String: Any]) -> Bool {
        guard let t = task,
              let d = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: d, encoding: .utf8) else { return false }
        t.send(.string(s)) { err in
            if let err { Log.write("sinyal gönderilemedi: \(err.localizedDescription)") }
        }
        return true
    }

    // MARK: - Alma

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let e):
                Log.write("sinyal bağlantısı düştü: \(e.localizedDescription)")
                self.state = .offline
                self.retry()
            case .success(let msg):
                switch msg {
                case .string(let s): self.handle(s)
                case .data(let d): self.handle(String(decoding: d, as: UTF8.self))
                @unknown default: break
                }
                self.receive()
            }
        }
    }

    private func handle(_ text: String) {
        guard let d = text.data(using: .utf8),
              let m = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        else { return }
        switch m["t"] as? String ?? "" {
        case "hello":
            // Kimligi ISPATLA: sunucunun verdigi rastgele meydan
            // okumayi imzaliyoruz. Hesap ve parola yok.
            guard let c = (m["challenge"] as? String).flatMap({ Data(base64Encoded: $0) })
            else { return }
            _ = say(["t": "auth",
                     "key": keys.edPublic.base64EncodedString(),
                     "sig": keys.sign(c).base64EncodedString()])
        case "ready":
            attempt = 0
            if let s = m["salt"] as? String, !s.isEmpty { salt = s }
            // Numaralar ANCAK SIMDI bildirilebilir: ozet tuzu
            // gerektiriyor ve tuz bu iletiyle geldi.
            publishNumbers()
            Log.write("sinyal hazır: \(m["id"] as? String ?? "?")")
            state = .ready
        case "recv":
            guard let from = m["from"] as? String,
                  let env = (m["env"] as? String).flatMap({ Data(base64Encoded: $0) })
            else { return }
            onEnvelope?(from, env)
        case "presence":
            let found = m["found"] as? [String: String] ?? [:]
            let missing = m["missing"] as? [String] ?? []
            DispatchQueue.main.async { self.onPresence?(found, missing) }
        case "undeliverable":
            let to = m["to"] as? String ?? ""
            DispatchQueue.main.async { self.onUndeliverable?(to) }
        case "error":
            Log.write("sinyal sunucu hatası: \(m["why"] as? String ?? "?")")
        default: break
        }
    }

    /// Baglantiyi acik tut. NAT eslemesi sessiz baglantiyi dakikalar
    /// icinde dusuruyor ve gelen arama hic ulasmiyordu.
    private func ping() {
        guard !closedByUs else { return }
        task?.sendPing { _ in }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, !self.closedByUs else { return }
            self.ping()
        }
    }

    /// Yeniden baglanma geri cekilmeli: sunucu kapaliyken saniyede bir
    /// denemek ne baglantiyi getirir ne de agi rahat birakir.
    private func retry() {
        guard !closedByUs else { return }
        attempt += 1
        let wait = min(30.0, 1.5 * pow(2.0, Double(min(attempt - 1, 4))))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, !self.closedByUs, self.state == .offline else { return }
            self.connect()
        }
    }

    // MARK: - Numara ozeti

    /// Numaranin sunucuya gidecek OZETI — numaranin kendisi hicbir
    /// zaman gonderilmiyor.
    public func digest(_ number: String) -> String {
        // Tuz yoksa ozet hesaplanamaz: bos donmek, yanlis ozet
        // uretip sessizce hic eslesmemekten iyi.
        guard !salt.isEmpty else { return "" }
        let e164 = Self.normalize(number)
        let key = SymmetricKey(data: Data(salt.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(e164.utf8), using: key)
        return Data(mac).prefix(16).base64EncodedString()
    }

    /// Numarayi E.164'e yaklastirir. Ayni kisi rehberde "0532 …",
    /// "+90 532 …", "90532…" diye yaziliyor; ozetleri farkli cikarsa
    /// iki taraf hic bulusamiyor.
    public static func normalize(_ raw: String, defaultCountry: String = "90") -> String {
        var d = raw.filter { $0.isNumber || $0 == "+" }
        if d.hasPrefix("+") { return d }
        d = d.filter(\.isNumber)
        if d.hasPrefix("00") { return "+" + d.dropFirst(2) }
        if d.hasPrefix("0") { return "+\(defaultCountry)" + d.dropFirst() }
        if d.hasPrefix(defaultCountry), d.count > 10 { return "+\(d)" }
        return "+\(defaultCountry)\(d)"
    }
}
