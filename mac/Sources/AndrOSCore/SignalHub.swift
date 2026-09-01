import Foundation
import CryptoKit

/// AndrOS agi: kimlik, baglanti, taniska ve mesajlar tek yerde.
///
/// Panellerin `SignalClient`, `Envelope` ve anahtarlarla tek tek
/// ugrasmasi gerekmiyor — burada "kime yaz" ve "mesaj geldi" var.
public final class SignalHub {

    public static let shared = SignalHub()

    public let keys = SignalKeys()
    public private(set) var client: SignalClient?
    public var id: String { keys.id }

    /// Kurulu sunucu. Kullaniciya adres YAZDIRMIYORUZ: bu bir uygulama
    /// ayari degil, altyapi. Elle degistirmek yalnizca kendi sunucusunu
    /// kuranlar icin, ayarlarda geri planda duruyor.
    public static let defaultURL = "wss://endpoint.gamehost.dev/andros.signal/ws"

    /// Kullanilacak adres: kullanici baskasini yazmadiysa kurulu olan.
    public static var serverURL: String {
        get {
            let custom = UserDefaults.standard.string(forKey: "signalURL") ?? ""
            return custom.isEmpty ? defaultURL : custom
        }
        set {
            // Varsayilanla ayni ise HIC saklamiyoruz: sunucu adresi
            // ileride degisirse eski deger takili kalmasin.
            UserDefaults.standard.set(newValue == defaultURL ? "" : newValue,
                                      forKey: "signalURL")
        }
    }

    /// Ag kapali mi? Kullanici bilerek kapatabiliyor.
    public static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "signalEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "signalEnabled") }
    }

    public var onState: ((SignalClient.State) -> Void)?
    /// Metin mesaji geldi: (gonderen kimlik, metin, zaman).
    public var onMessage: ((String, String, Date) -> Void)?
    /// Cagri iletisi geldi (davet, cevap, aday adres…).
    public var onCall: ((String, [String: Any]) -> Void)?
    /// Ulasilabilirlik yaniti tazelendi.
    public var onPresence: (() -> Void)?

    private init() {}

    // MARK: - Taninan cihazlar

    public struct Peer: Codable {
        public let id: String
        public let edPublic: Data
        public let xPublic: Data
    }

    private var peers: [String: Peer] = [:]
    private var sharedKeys: [String: SymmetricKey] = [:]
    /// Karsi tarafin anahtari daha gelmedigi icin bekleyen iletiler.
    private var pending: [String: [[String: Any]]] = [:]
    /// Numara ozeti -> kimlik (ulasilabilir olanlar).
    public private(set) var reachable: [String: String] = [:]

    private static var peerFile: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("AndrOS", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let custom = ProcessInfo.processInfo.environment["ANDROS_PEERS"] {
            return URL(fileURLWithPath: custom)
        }
        return dir.appendingPathComponent("peers.json")
    }

    private func loadPeers() {
        guard let d = try? Data(contentsOf: Self.peerFile),
              let list = try? JSONDecoder().decode([Peer].self, from: d) else { return }
        for p in list { peers[p.id] = p }
    }

    private func savePeers() {
        guard let d = try? JSONEncoder().encode(Array(peers.values)) else { return }
        try? d.write(to: Self.peerFile)
    }

    // MARK: - Baglanti

    public func start() {
        guard Self.enabled else { Log.write("sinyal: ağ kapalı"); return }
        let url = Self.serverURL
        guard !url.isEmpty else { return }
        loadPeers()
        client?.disconnect()
        guard let c = SignalClient(keys: keys, url: url) else { return }
        c.onState = { [weak self] st in self?.onState?(st) }
        c.onEnvelope = { [weak self] from, env in self?.receive(from: from, env) }
        c.onPresence = { [weak self] found, _ in
            guard let self else { return }
            self.reachable = found
            // Hangi ozet hangi numaraydi? Gelen mesaji dogru sohbete
            // koyabilmek icin kimlik<->numara eslemesi sakli tutuluyor;
            // ag kimlik konusuyor, arayuz numara.
            for (digest, peer) in found {
                if let number = self.pendingLookups[digest] {
                    NetworkMessages.shared.remember(peer: peer, number: number)
                }
            }
            self.onPresence?()
        }
        c.onUndeliverable = { to in Log.write("sinyal: \(to) bağlı değil") }
        client = c
        c.connect()
    }

    public func stop() {
        client?.disconnect()
        client = nil
    }

    /// Bu Mac hangi numaralardan bulunabilir (telefonun hatti).
    public func announce(numbers: [String]) {
        client?.myNumbers = numbers
    }

    /// Bu numaralar su an ulasilabilir mi?
    /// Ozet -> sorulan numara. Yanit yalniz ozeti tasiyor.
    private var pendingLookups: [String: String] = [:]

    public func checkReachable(_ numbers: [String]) {
        guard let c = client else { return }
        var digests: [String] = []
        for n in numbers {
            let d = c.digest(n)
            guard !d.isEmpty else { continue }
            pendingLookups[d] = n
            digests.append(d)
        }
        guard !digests.isEmpty else { return }
        c.lookup(digests)
    }

    /// Numaranin AndrOS kimligi — ulasilabilirse.
    public func peerID(forNumber number: String) -> String? {
        guard let c = client else { return nil }
        return reachable[c.digest(number)]
    }

    // MARK: - Gonderme

    /// Metin mesaji. Karsi taraf taninmiyorsa once tanisma yollanir ve
    /// mesaj anahtarlar gelince gider.
    @discardableResult
    public func sendMessage(to peer: String, text: String) -> NetworkMessages.Message {
        let m = NetworkMessages.Message(outgoing: true, text: text)
        NetworkMessages.shared.add(peer: peer, m)
        send(to: peer, ["t": "msg", "text": text,
                        "ts": m.at.timeIntervalSince1970])
        return m
    }

    /// Cagri iletisi (davet, kabul, ret, aday adres…).
    public func sendCall(to peer: String, _ payload: [String: Any]) {
        var p = payload
        p["t"] = payload["t"] ?? "call"
        send(to: peer, p)
    }

    private func send(to peer: String, _ payload: [String: Any]) {
        guard let c = client else { return }
        guard let key = key(for: peer) else {
            // Anahtari yok: once TANISMA. Ileti kuyruga giriyor ve
            // karsi tarafin tanismasi gelince yollaniyor.
            pending[peer, default: []].append(payload)
            c.send(to: peer, envelope: Envelope.intro(keys))
            return
        }
        guard let env = Envelope.seal(key, payload) else { return }
        c.send(to: peer, envelope: env)
    }

    private func key(for peer: String) -> SymmetricKey? {
        if let k = sharedKeys[peer] { return k }
        guard let p = peers[peer],
              let k = keys.sharedKey(with: p.xPublic, myID: id, theirID: peer)
        else { return nil }
        sharedKeys[peer] = k
        return k
    }

    // MARK: - Alma

    private func receive(from: String, _ env: Data) {
        switch Envelope.type(of: env) {
        case Envelope.typeIntro:
            guard let p = Envelope.openIntro(env, from: from) else {
                Log.write("sinyal: geçersiz tanışma paketi (\(from))")
                return
            }
            let known = peers[from] != nil
            peers[from] = Peer(id: p.id, edPublic: p.edPublic, xPublic: p.xPublic)
            sharedKeys[from] = nil
            savePeers()
            // Karsilikli tanisma: bizi taniyan taraf bizim anahtarimizi
            // da bilmeli, yoksa cevap yazamaz.
            if !known { client?.send(to: from, envelope: Envelope.intro(keys)) }
            // Bekleyen iletiler artik yollanabilir.
            if let queued = pending.removeValue(forKey: from) {
                for p in queued { send(to: from, p) }
            }

        case Envelope.typeSealed:
            guard let k = key(for: from), let m = Envelope.open(k, env) else {
                // Anahtarimiz yok ya da eskimis: yeniden taniselim.
                Log.write("sinyal: çözülemeyen zarf (\(from)) — yeniden tanışılıyor")
                client?.send(to: from, envelope: Envelope.intro(keys))
                return
            }
            let type = m["t"] as? String ?? ""
            if type == "msg" {
                let ts = Date(timeIntervalSince1970: m["ts"] as? Double
                              ?? Date().timeIntervalSince1970)
                let text = m["text"] as? String ?? ""
                // SUNUCU SAKLAMIYOR: kayit bizde degilse hicbir yerde
                // yok. Once yaz, sonra haber ver.
                NetworkMessages.shared.add(peer: from,
                    .init(outgoing: false, text: text, at: ts))
                DispatchQueue.main.async { self.onMessage?(from, text, ts) }
            } else {
                DispatchQueue.main.async { self.onCall?(from, m) }
            }

        default:
            Log.write("sinyal: bilinmeyen zarf türü")
        }
    }
}
