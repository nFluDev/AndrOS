import Foundation
import Network
import CryptoKit

// MARK: - Bulunan cihaz

public struct CompanionDevice: Hashable, Identifiable {
    public var id: String { deviceId.isEmpty ? endpointName : deviceId }
    public let endpointName: String
    public var deviceId: String = ""
    public var name: String = ""
    /// Sertifika parmak izinin ilk 16 bayti (duyurudan).
    public var fingerprintHint: String = ""
    /// ANDROID_ID — adb ile gelen ayni cihazi eslestirmek icin ortak anahtar.
    public var androidId: String = ""
    /// Duyurunun geldigi baglanti turu: Wi-Fi mi USB (ag paylasimi) mi.
    public var overUSB = false
    /// Duyurunun geldigi arayuzler — olcum ve etiketleme icin.
    public var interfaces: [String] = []
    public var endpoint: NWEndpoint
    /// UDP yoklamasindan gelen DOGRUDAN adres (ip:port).
    ///
    /// Bonjour kaydi bayatlayabiliyor: cozumlenemeyen bir hizmet adina
    /// baglanmaya calisan `NWConnection` hicbir hata vermeden
    /// "hazirlaniyor" durumunda takili kaliyor — telefon tarafinda hic
    /// baglanti gorunmuyor (olculdu). Dogrudan adres varsa onu
    /// kullaniyoruz; duyurudaki bilgiler (arayuz turu vb.) yine Bonjour
    /// kaydindan geliyor.
    public var directEndpoint: NWEndpoint?

    /// Baglanti icin kullanilacak uc nokta.
    public var connectEndpoint: NWEndpoint { directEndpoint ?? endpoint }
}

/// Agdaki AndrOS telefonlarini bulur (Bonjour).
///
/// Neden Bonjour: kullanici IP yazmasin. Telefon `_andros._tcp` olarak
/// kendini duyuruyor; USB baglanti paylasimi acikken de ayni duyuru o
/// arayuz uzerinden geliyor, yani USB icin ayri bir yol gerekmiyor.
public final class CompanionBrowser {
    private var browser: NWBrowser?
    /// Bonjour ile bulunanlar.
    private var viaBonjour: [CompanionDevice] = []
    /// UDP yoklamasiyla bulunanlar (mDNS gecmedigi durumlar icin).
    private var viaUDP: [String: CompanionDevice] = [:]
    public private(set) var found: [CompanionDevice] = []
    public var onChange: (([CompanionDevice]) -> Void)?

    private let udp = UdpProbe()
    private var udpTimer: Timer?
    private let store = CompanionStore()

    /// TEK bulucu.
    ///
    /// Once hem uygulama hem Cihazlar paneli kendi `CompanionBrowser`'ini
    /// kuruyordu: iki NWBrowser, iki UDP taramasi ve ayni cihaz icin
    /// tekrar tekrar "bulundu" bildirimi. Eskiden ayni kalipla (paneli
    /// acinca bulucuyu yeniden baslatma) sonsuz eslestirme dongusu
    /// olusmustu. Artik tek ornek var, dinleyiciler adlariyla ekleniyor.
    public static let shared = CompanionBrowser()

    private var listeners: [String: ([CompanionDevice]) -> Void] = [:]

    /// Ek dinleyici ekler; `onChange` ile birlikte calisir.
    public func addListener(_ key: String, _ block: @escaping ([CompanionDevice]) -> Void) {
        listeners[key] = block
        if !found.isEmpty { block(found) }
    }

    public func removeListener(_ key: String) { listeners.removeValue(forKey: key) }

    /// Zaten calisiyorsa yeniden BASLATMAZ.
    private var started = false

    public init() {}

    /// Iki kaynagi birlestirir. Ayni cihaz iki yoldan da gelirse Bonjour
    /// kaydi kazanir (arayuz bilgisi onda var).
    private func publish() {
        var merged = viaBonjour
        // Bonjour kaydina UDP'den gelen dogrudan adresi ekle: veriler
        // duyurudan, baglanti adresi yoklamadan.
        for i in merged.indices {
            if let u = viaUDP[merged[i].id] { merged[i].directEndpoint = u.endpoint }
        }
        let known = Set(merged.map(\.id))
        for (_, d) in viaUDP where !known.contains(d.id) {
            var v = d
            v.directEndpoint = d.endpoint
            merged.append(v)
        }
        found = merged.sorted { $0.name < $1.name }
        DispatchQueue.main.async {
            self.onChange?(self.found)
            self.listeners.values.forEach { $0(self.found) }
        }
    }

    public func start() {
        guard !started else { return }
        started = true

        // YEDEK BULMA YOLU. Bonjour multicast'e dayaniyor ve Wi-Fi
        // yongasi guc tasarrufunda multicast'i suzuyor; olculdu —
        // telefonun portu acikken hicbir duyuru gelmedi. UDP yayini
        // bu durumda da cevap aliyor ve cihazi Doze'dan cikariyor.
        udp.onFound = { [weak self] f in
            guard let self else { return }
            var d = CompanionDevice(
                endpointName: f.name,
                endpoint: .hostPort(host: .init(f.host),
                                    port: .init(rawValue: f.port) ?? 47821))
            d.deviceId = f.deviceId
            d.name = f.name
            d.fingerprintHint = f.fingerprintHint
            d.interfaces = ["UDP"]
            self.viaUDP[f.deviceId] = d
            self.publish()
        }
        udp.start()
        udp.probe()

        // GECEN SEFERKI adresle basla: Bonjour kaydinin cozumlenmesini
        // beklemeden ilk deneme dogru yere gitsin.
        for (id, _) in store.paired() {
            guard let h = UdpProbe.lastKnownHost(id) else { continue }
            var d = CompanionDevice(
                endpointName: store.name(for: id) ?? id,
                endpoint: .hostPort(host: .init(h), port: 47821))
            d.deviceId = id
            d.name = store.name(for: id) ?? id
            d.interfaces = ["UDP"]
            viaUDP[id] = d
        }
        if !viaUDP.isEmpty { publish() }
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            self?.udp.probe()
        }
        RunLoop.main.add(t, forMode: .common)
        udpTimer = t
        let params = NWParameters()
        params.includePeerToPeer = true
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_andros._tcp", domain: nil),
                          using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            var list: [CompanionDevice] = []
            for r in results {
                guard case let .service(name, _, _, _) = r.endpoint else { continue }
                var d = CompanionDevice(endpointName: name, endpoint: r.endpoint)
                if case let .bonjour(txt) = r.metadata {
                    d.deviceId = txt["id"] ?? ""
                    d.name = txt["name"] ?? name
                    d.fingerprintHint = txt["fp"] ?? ""
                    d.androidId = txt["aid"] ?? ""
                }
                // USB baglanti paylasimi Mac'e KABLOLU bir arayuz olarak
                // geliyor; Wi-Fi'dan bu sekilde ayirt ediyoruz. Ikisi de
                // hata ayiklama gerektirmiyor.
                d.overUSB = r.interfaces.contains { $0.type == .wiredEthernet }
                    && !r.interfaces.contains { $0.type == .wifi }
                d.interfaces = r.interfaces.map { i in
                    switch i.type {
                    case .wifi:          return "Wi-Fi (\(i.name))"
                    case .wiredEthernet: return "Ethernet/USB (\(i.name))"
                    case .cellular:      return "Hücresel"
                    case .loopback:      return "loopback"
                    default:             return i.name
                    }
                }
                if d.name.isEmpty { d.name = name }
                list.append(d)
            }
            self.viaBonjour = list
            self.publish()
        }
        b.start(queue: .global(qos: .utility))
        browser = b
    }

    /// Bulmayi hemen tazele (kopan baglantidan sonra).
    public func poke() { udp.probe() }

    public func stop() {
        started = false
        browser?.cancel()
        browser = nil
        udpTimer?.invalidate(); udpTimer = nil
        udp.stop()
        viaBonjour = []; viaUDP = [:]
    }
}

// MARK: - Baglanti

/// Telefona TLS baglantisi ve istek/yanit katmani.
///
/// Sertifika SABITLENIYOR: ilk eslestirmede telefonun kendinden imzali
/// sertifikasinin parmak izi kaydediliyor, sonraki baglantilarda birebir
/// ayni olmasi sart. Boylece ayni agdaki biri araya giremiyor.
public final class CompanionLink {

    public enum State: Equatable {
        case idle
        case connecting
        /// Telefon 6 haneli kodu ekranda gosteriyor; kod bekleniyor.
        case awaitingCode
        case ready
        case failed(String)

        public var isFailed: Bool { if case .failed = self { return true }; return false }
    }

    public private(set) var state: State = .idle {
        didSet {
            guard state != oldValue else { return }
            stateChangedAt = Date()
            Log.write("baglanti \(device.name): \(oldValue) -> \(state)")
            onState?(state)
        }
    }
    /// Baglandigimiz telefonun adresi — akis URL'i kurmak icin.
    public private(set) var remoteHost: String?
    /// Durumun en son ne zaman degistigi — takili kalmayi anlamak icin.
    public private(set) var stateChangedAt = Date()
    public var onState: ((State) -> Void)?
    public var onEvent: ((String, [String: Any]) -> Void)?

    private let device: CompanionDevice
    private let store: CompanionStore
    private var conn: NWConnection?
    private let queue = DispatchQueue(label: "dev.naer.andros.companion")
    private var nextID: Int32 = 1
    private var pending: [Int: ([String: Any]?, String?) -> Void] = [:]
    /// `pending` icin ayri kilit.
    ///
    /// `queue.sync` KULLANILAMAZ: `handshake()` zaten `queue` uzerinde
    /// calisan durum geri cagrisindan `request()` cagiriyor; ayni kuyruga
    /// senkron girmek kilitlenme/cokme demek (olculdu: uygulama aninda
    /// dusuyordu). Kayit yine de ES ZAMANLI olmali, yoksa yanit geri
    /// cagri yerini almadan gelip sessizce dusuyor.
    private let pendingLock = NSLock()
    private var buffer = Data()
    /// El sikismada gorulen parmak izi — eslestirme onaylanirsa saklanir.
    private var seenFingerprint = ""

    /// Belirli bir yolu zorlar (Wi-Fi ya da USB ag paylasimi). `nil` ise
    /// sistem hangisini uygun goruyorsa onu kullanir.
    public var requiredInterface: NWInterface.InterfaceType?

    public init(device: CompanionDevice, store: CompanionStore,
                requiring iface: NWInterface.InterfaceType? = nil) {
        self.device = device
        self.store = store
        self.requiredInterface = iface
    }

    public func connect() {
        state = .connecting
        let tls = NWProtocolTLS.Options()
        let pinned = store.fingerprint(for: device.id)

        sec_protocol_options_set_verify_block(tls.securityProtocolOptions,
            { [weak self] _, trustRef, complete in
                let trust = sec_trust_copy_ref(trustRef).takeRetainedValue()
                guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                      let leaf = chain.first else { complete(false); return }
                let der = SecCertificateCopyData(leaf) as Data
                let fp = SHA256.hash(data: der).map { String(format: "%02X", $0) }
                    .joined(separator: ":")
                self?.seenFingerprint = fp
                // Eslestirilmisse BIREBIR ayni sertifika olmali. Henuz
                // eslestirilmemisse kabul ediyoruz ama guveni kod
                // dogrulamasi kuruyor; parmak izi ancak ondan sonra
                // kaydediliyor.
                if let pinned, !pinned.isEmpty {
                    complete(pinned == fp)
                } else {
                    complete(true)
                }
            }, queue)

        let params = NWParameters(tls: tls)
        params.includePeerToPeer = true
        // ONCELIK: bu baglanti istek/yanit tasiyor — kisa paketler,
        // gecikmeye duyarli. Dosya aktarimi ve video akisi ayri
        // soketlerde ilerledigi icin onlarla ayni kuyruga girmesin.
        // NOT: `serviceClass` DENEND VE GERI ALINDI — asagiya bak.
        // Nagle KAPALI: kucuk JSON cerceveleri birlestirilmek icin
        // bekletiliyordu; her istege 40 ms'e varan gereksiz gecikme
        // biniyordu.
        if let tcp = params.defaultProtocolStack.transportProtocol
            as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }
        // Olcum ve tercih icin yolu sabitleyebiliyoruz.
        if let want = requiredInterface { params.requiredInterfaceType = want }
        let c = NWConnection(to: device.connectEndpoint, using: params)
        c.stateUpdateHandler = { [weak self] s in
            guard let self else { return }
            switch s {
            case .ready:
                // Akis sunucusuna ayni adresten baglanacagiz.
                if let ep = c.currentPath?.remoteEndpoint,
                   case let .hostPort(host, _) = ep {
                    var h = "\(host)"
                    // IPv6 kapsam eki ("fe80::1%en0") URL'de calismiyor.
                    if let i = h.firstIndex(of: "%") { h = String(h[h.startIndex..<i]) }
                    self.remoteHost = h.contains(":") ? "[\(h)]" : h
                }
                self.receive(); self.handshake()
            case .failed(let e): self.state = .failed("\(e)")
            case .cancelled: self.state = .idle
            default: break
            }
        }
        conn = c
        c.start(queue: queue)

        // ZAMAN ASIMI. `NWConnection` cozumlenemeyen bir uc noktada
        // hicbir hata uretmeden beklemeye devam ediyor; kendimiz
        // kesmezsek baglanti sonsuza kadar "connecting" kaliyor.
        queue.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, self.conn === c, self.state == .connecting else { return }
            Log.write("baglanti \(self.device.name): 12 sn'de kurulamadi, birakiliyor")
            c.cancel()
            self.state = .failed("zaman aşımı")
        }
    }

    public func disconnect() {
        conn?.cancel()
        conn = nil
        state = .idle
    }

    // ---- El sikisma

    private func handshake() {
        let name = Host.current().localizedName ?? "Mac"
        request("hello", ["client": name]) { [weak self] data, err in
            guard let self else { return }
            if let err { self.state = .failed(err); return }
            _ = data
            if let token = self.store.token(for: self.device.id) {
                self.request("auth", ["token": token]) { _, err in
                    if err == nil { self.state = .ready }
                    else { self.beginPairing() }
                }
            } else {
                self.beginPairing()
            }
        }
    }

    private func beginPairing() {
        request("pair.begin", [:]) { [weak self] _, err in
            guard let self else { return }
            if let err { self.state = .failed(err) } else { self.state = .awaitingCode }
        }
    }

    /// Kullanicinin telefondan okudugu kodu gonderir.
    public func confirmPairing(code: String, done: @escaping (String?) -> Void) {
        request("pair.confirm", ["code": code]) { [weak self] data, err in
            guard let self else { return }
            if let err { done(err); return }
            guard let token = data?["token"] as? String else {
                done("Belirteç alınamadı"); return
            }
            self.store.save(deviceId: self.device.id, name: self.device.name,
                            token: token, fingerprint: self.seenFingerprint)
            self.state = .ready
            done(nil)
        }
    }

    // ---- Istek/yanit

    @discardableResult
    public func request(_ op: String, _ args: [String: Any],
                        done: @escaping ([String: Any]?, String?) -> Void) -> Int {
        let id = Int(OSAtomicIncrement32(&nextID))
        var obj: [String: Any] = ["id": id, "op": op]
        if !args.isEmpty { obj["args"] = args }
        guard let body = try? JSONSerialization.data(withJSONObject: obj) else {
            done(nil, "istek kodlanamadı"); return id
        }
        // KAYIT ES ZAMANLI olmali. `async` ile kaydedince yanit, geri
        // cagri sozlukte yerini almadan gelebiliyor; `pending` bos
        // oldugu icin yanit sessizce dusuyor ve cagri zaman asimina
        // ugruyordu (olculdu: baglanti "ready" ama her istek bos donuyor).
        pendingLock.lock(); pending[id] = done; pendingLock.unlock()

        var frame = Data()
        var len = UInt32(body.count + 1).bigEndian
        withUnsafeBytes(of: &len) { frame.append(contentsOf: $0) }
        frame.append(0)                       // tur: JSON
        frame.append(body)
        conn?.send(content: frame, completion: .contentProcessed { _ in })
        return id
    }

    /// Bir dosyayi telefondan indirir — adb OLMADAN.
    ///
    /// `files.read` once JSON basligi (boyut, ad) sonra 256 KB'lik
    /// ikili bloklar yolluyor; bos blok "bitti" demek. Blok alicisi
    /// TEK oldugu icin bu cagri es zamanli calisamaz; ust katman
    /// (`AndroidData.pullPreferringApp`) sirayi kendisi tutuyor.
    ///
    /// Neden gerekli: hedef adb'siz calismak. USB cikinca ve hata
    /// ayiklama kapaninca `adb pull` calismiyor, muzik/dosya indirme
    /// tamamen duruyordu (olculdu: kuyruga giriyor, hicbiri inmiyor).
    public func downloadFile(path: String, to local: String,
                             progress: ((Int, Int) -> Void)? = nil,
                             done: @escaping (Bool) -> Void) {
        guard state == .ready else { done(false); return }
        FileManager.default.createFile(atPath: local, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: local) else { done(false); return }

        var expected = 0
        var received = 0
        var finished = false
        func finish(_ ok: Bool) {
            guard !finished else { return }
            finished = true
            blobSink = nil
            try? handle.close()
            if !ok { try? FileManager.default.removeItem(atPath: local) }
            DispatchQueue.main.async { done(ok) }
        }

        blobSink = { chunk in
            if chunk.isEmpty {
                let ok = received > 0 && (expected == 0 || received >= expected)
                if !ok {
                    Log.write("indirme eksik: \(received)/\(expected) bayt — \(path)")
                }
                finish(ok)
                return
            }
            handle.write(chunk)
            received += chunk.count
            if let progress { DispatchQueue.main.async { progress(received, expected) } }
        }

        request("files.read", ["path": path]) { data, err in
            if let err {
                Log.write("indirme reddedildi (\(path)): \(err)")
                finish(false); return
            }
            expected = data?["size"] as? Int ?? 0
            if expected == 0 { Log.write("indirme: boyut 0 — \(path)") }
        }

        // Guvenlik agi: telefon susarsa sonsuza kadar bekleme.
        queue.asyncAfter(deadline: .now() + 300) {
            if !finished { finish(false) }
        }
    }

    /// Mac'ten telefona dosya yollar — adb OLMADAN.
    ///
    /// `files.read`in tersi: once istegi yolluyoruz, sonra 256 KB'lik
    /// bloklar, en sonda bos blok. Telefon bloklari ayni soketten
    /// okuyor; bu yuzden gonderim SIRALI olmali (`uploadGate`).
    public func uploadFileSync(local: String, to remote: String) -> Bool {
        guard state == .ready,
              let data = FileManager.default.contents(atPath: local) else { return false }
        return Self.uploadGate.sync {
            let sem = DispatchSemaphore(value: 0)
            var ok = false
            let id = request("files.write", ["path": remote, "size": data.count]) { d, err in
                ok = (err == nil) && (d != nil)
                sem.signal()
            }
            // Bloklari HEMEN ardindan yolluyoruz: telefon istegi
            // gorur gormez okumaya basliyor.
            let chunk = 256 * 1024
            var offset = 0
            while offset < data.count {
                let end = min(offset + chunk, data.count)
                sendBlob(id: id, payload: data.subdata(in: offset..<end))
                offset = end
            }
            sendBlob(id: id, payload: Data())        // bitti
            _ = sem.wait(timeout: .now() + 600)
            return ok
        }
    }

    private static let uploadGate = DispatchQueue(label: "dev.naer.andros.upload")

    /// Ikili cerceve: [4 bayt uzunluk][1 bayt tur=1][4 bayt istek][govde]
    private func sendBlob(id: Int, payload: Data) {
        var frame = Data()
        var len = UInt32(payload.count + 5).bigEndian
        withUnsafeBytes(of: &len) { frame.append(contentsOf: $0) }
        frame.append(1)
        var rid = UInt32(id).bigEndian
        withUnsafeBytes(of: &rid) { frame.append(contentsOf: $0) }
        frame.append(payload)
        conn?.send(content: frame, completion: .contentProcessed { _ in })
    }

    /// Cihazdan `bytes` kadar veri cekip MB/s olcer.
    ///
    /// Gercek yuk uzerinden olcum: kuramsal hiz yerine bu baglantida
    /// GERCEKTEN ne aktarilabildigini goruyoruz.
    public func measureThroughput(bytes: Int = 8 * 1024 * 1024,
                                  done: @escaping (Double?) -> Void) {
        let started = Date()
        var received = 0
        var finished = false
        blobSink = { [weak self] chunk in
            guard !finished else { return }
            if chunk.isEmpty {
                finished = true
                self?.blobSink = nil
                let secs = Date().timeIntervalSince(started)
                let mbps = secs > 0 ? Double(received) / secs / 1_000_000 : 0
                DispatchQueue.main.async { done(mbps) }
                return
            }
            received += chunk.count
        }
        request("bench", ["bytes": bytes]) { _, err in
            if let err {
                self.blobSink = nil
                Log.write("companion: olcum basarisiz \(err)")
                DispatchQueue.main.async { done(nil) }
            }
        }
    }

    /// Ikili cercevelerin gittigi yer (olcum ve dosya indirme).
    private var blobSink: ((Data) -> Void)?

    private func receive() {
        conn?.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) {
            [weak self] data, _, closed, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.queue.async { self.ingest(data) } }
            if closed || error != nil {
                self.state = .idle
                return
            }
            self.receive()
        }
    }

    private func ingest(_ chunk: Data) {
        buffer.append(chunk)
        while buffer.count >= 5 {
            let len = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard len >= 1, len <= 16 * 1024 * 1024 else { buffer.removeAll(); return }
            let total = 4 + Int(len)
            guard buffer.count >= total else { return }
            let type = buffer[buffer.startIndex + 4]
            let body = buffer.subdata(in: (buffer.startIndex + 5)..<(buffer.startIndex + total))
            buffer.removeFirst(total)
            if type == 0 { handleJSON(body) }
            // Ikili cerceve: ilk 4 bayt istek kimligi, kalani govde.
            else if type == 1, body.count >= 4 {
                let payload = body.subdata(in: 4..<body.count)
                blobSink?(payload)
            }
        }
    }

    private func handleJSON(_ body: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return }
        if let event = obj["event"] as? String {
            let data = obj["data"] as? [String: Any] ?? [:]
            DispatchQueue.main.async { self.onEvent?(event, data) }
            return
        }
        guard let id = obj["id"] as? Int else { return }
        pendingLock.lock()
        let done = pending.removeValue(forKey: id)
        pendingLock.unlock()
        guard let done else { return }
        if obj["ok"] as? Bool == true {
            let data = obj["data"] as? [String: Any] ?? [:]
            DispatchQueue.main.async { done(data, nil) }
        } else {
            let e = obj["error"] as? [String: Any]
            let msg = (e?["message"] as? String) ?? "bilinmeyen hata"
            DispatchQueue.main.async { done(nil, msg) }
        }
    }
}

// MARK: - Eslestirme kaydi

/// Eslestirilmis telefonlarin belirteci ve sabitlenmis parmak izi.
/// Baglantilarin CANLI durumu.
///
/// `CompanionStore` yalnizca "belirtec var mi" biliyor; cihaz satiri
/// bunu "eslesmis" diye gosterip baglanti kopukken bile ayni kaliyordu.
/// Arayuz gercek durumu gosterebilsin diye ayri bir kayit tutuyoruz.
public enum CompanionStatus {
    private static var states: [String: CompanionLink.State] = [:]
    private static let lock = NSLock()

    public static func set(_ id: String, _ s: CompanionLink.State) {
        lock.lock(); states[id] = s; lock.unlock()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .androsCompanionStateChanged, object: nil)
        }
    }

    public static func state(_ id: String) -> CompanionLink.State {
        lock.lock(); defer { lock.unlock() }
        return states[id] ?? .idle
    }

    public static func isConnected(_ id: String) -> Bool { state(id) == .ready }
}

public extension Notification.Name {
    static let androsCompanionStateChanged =
        Notification.Name("androsCompanionStateChanged")
    /// Kullanici elle "yeniden baglan" dedi.
    static let androsReconnectRequested =
        Notification.Name("androsReconnectRequested")
}

public final class CompanionStore {
    private let key = "companionDevices"
    public init() {}

    private func all() -> [String: [String: String]] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: [String: String]] ?? [:]
    }
    private func write(_ v: [String: [String: String]]) {
        UserDefaults.standard.set(v, forKey: key)
    }

    public func token(for id: String) -> String? { all()[id]?["token"] }
    public func fingerprint(for id: String) -> String? { all()[id]?["fingerprint"] }
    public func name(for id: String) -> String? { all()[id]?["name"] }
    public func isPaired(_ id: String) -> Bool { all()[id]?["token"] != nil }

    public func save(deviceId: String, name: String, token: String, fingerprint: String) {
        var v = all()
        v[deviceId] = ["name": name, "token": token, "fingerprint": fingerprint]
        write(v)
    }

    public func forget(_ id: String) {
        var v = all(); v.removeValue(forKey: id); write(v)
    }

    public func paired() -> [(id: String, name: String)] {
        all().map { ($0.key, $0.value["name"] ?? "?") }
    }
}
