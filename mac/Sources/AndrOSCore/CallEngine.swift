import Foundation

/// Arama: davet, kabul, ret ve dogrudan baglantinin kurulmasi.
///
/// Sinyal sunucusu YALNIZCA tanistiriyor — davet ve cevap onun uzerinden
/// (sifreli zarfla) gidiyor, ama ses ve goruntu iki cihaz arasinda
/// DOGRUDAN akiyor. Bunun icin iki tarafin da dis adresini bilmesi ve
/// ayni anda birbirine paket gondermesi gerekiyor (NAT'ta delik acma).
///
/// Yalniz IKILI gorusme var: grup yok. Grup, anahtar dagitimini bambaska
/// bir probleme cevirir ve istenmedi.
public final class CallEngine {

    public static let shared = CallEngine()

    public enum State: Equatable {
        case idle
        /// Biz ariyoruz, karsi taraf henuz cevap vermedi.
        case calling(peer: String)
        /// Bizi ariyorlar.
        case ringing(peer: String, video: Bool)
        /// Kabul edildi, dogrudan baglanti kuruluyor.
        case connecting(peer: String)
        case active(peer: String, video: Bool)
        /// Bitti. `note` doluysa karsi taraf hizli mesaj birakti.
        case ended(reason: EndReason, note: String?)
    }

    public enum EndReason: Equatable {
        case hangup          // biri kapatti
        case declined        // karsi taraf reddetti
        case busy            // karsi taraf baska aramada
        case unreachable     // karsi taraf bagli degil
        case failed(String)  // baglanti kurulamadi
    }

    public private(set) var state: State = .idle {
        didSet {
            if state != oldValue {
                Log.write("arama durumu: \(state)")
                DispatchQueue.main.async { self.onState?(self.state) }
            }
        }
    }

    public var onState: ((State) -> Void)?
    /// Karsi tarafin adi (rehberden) — arayuz gostersin diye.
    public var displayName: ((String) -> String)?

    /// Su anki gorusmenin kimligi. Gec gelen iletileri elemek icin:
    /// kapanmis bir aramanin "kabul" iletisi yeni aramayi bozmasin.
    private var callID = ""
    private var peer = ""
    private var wantsVideo = false
    private var socket: Int32 = -1
    private var remote: (host: String, port: UInt16)?
    private var punchTimer: DispatchSourceTimer?
    private var ringTimeout: DispatchWorkItem?

    private init() {}

    // MARK: - Arama baslatma

    /// Aramayi baslatir. Karsi taraf bagli degilse hemen biter.
    public func call(peer id: String, video: Bool) {
        guard case .idle = state else { return }
        callID = UUID().uuidString
        peer = id
        wantsVideo = video
        state = .calling(peer: id)

        // Dis adresi ONCEDEN ogreniyoruz: davetle birlikte gondermek,
        // karsi taraf kabul ettigi anda delik acmaya baslamayi mumkun
        // kiliyor. Sonra sormak bir gidis-donus daha eklerdi.
        prepareSocket()
        let addr = reflexive()
        var payload: [String: Any] = ["t": "call.invite", "cid": callID,
                                      "video": video]
        if let a = addr { payload["addr"] = ["ip": a.host, "port": Int(a.port)] }
        SignalHub.shared.sendCall(to: id, payload)

        // 45 saniye calar, sonra biter. Sonsuza kadar calmak, karsi
        // taraf telefonu gormediginde aramayi acik birakirdi.
        armRingTimeout(45)
    }

    // MARK: - Gelen aramaya cevap

    public func accept() {
        guard case .ringing(let id, let video) = state else { return }
        cancelRingTimeout()
        wantsVideo = video
        prepareSocket()
        var payload: [String: Any] = ["t": "call.accept", "cid": callID]
        if let a = reflexive() { payload["addr"] = ["ip": a.host, "port": Int(a.port)] }
        SignalHub.shared.sendCall(to: id, payload)
        state = .connecting(peer: id)
        startPunching()
    }

    /// Reddet. `note` verilirse karsi tarafin ARAMA EKRANINDA gorunur —
    /// mesaj olarak gitmez; kullanici "dönecegim" yazip kapatinca
    /// karsi taraf bunu kapanma ekraninda okur.
    public func decline(note: String? = nil) {
        guard case .ringing(let id, _) = state else { return }
        cancelRingTimeout()
        var payload: [String: Any] = ["t": "call.reject", "cid": callID,
                                      "reason": "declined"]
        if let note, !note.isEmpty { payload["note"] = note }
        SignalHub.shared.sendCall(to: id, payload)
        finish(.declined, note: nil)
    }

    public func hangUp() {
        guard peer.isEmpty == false else { return }
        SignalHub.shared.sendCall(to: peer, ["t": "call.end", "cid": callID])
        finish(.hangup, note: nil)
    }

    // MARK: - Gelen iletiler

    /// `SignalHub.onCall` buraya baglaniyor.
    public func handle(from: String, _ m: [String: Any]) {
        let type = m["t"] as? String ?? ""
        let cid = m["cid"] as? String ?? ""

        switch type {
        case "call.invite":
            // MESGULSEK reddet. Ikinci bir aramayi sessizce yutmak,
            // arayan tarafta sonsuz calan bir ekran birakirdi.
            guard case .idle = state else {
                SignalHub.shared.sendCall(to: from, ["t": "call.reject", "cid": cid,
                                                     "reason": "busy"])
                return
            }
            callID = cid
            peer = from
            let video = m["video"] as? Bool ?? false
            remote = address(from: m)
            state = .ringing(peer: from, video: video)
            armRingTimeout(45)

        case "call.accept":
            guard cid == callID, case .calling = state else { return }
            cancelRingTimeout()
            remote = address(from: m)
            state = .connecting(peer: from)
            startPunching()

        case "call.reject":
            guard cid == callID else { return }
            let reason = m["reason"] as? String ?? "declined"
            finish(reason == "busy" ? .busy : .declined, note: m["note"] as? String)

        case "call.end":
            guard cid == callID else { return }
            finish(.hangup, note: nil)

        case "call.punch":
            // Delik acma paketinin sinyal uzerinden gelen esi: karsi
            // taraf adresini guncellemis olabilir.
            guard cid == callID else { return }
            if let a = address(from: m) { remote = a }

        default: break
        }
    }

    // MARK: - Dogrudan baglanti

    private func prepareSocket() {
        if socket >= 0 { close(socket) }
        socket = Stun.makeSocket()
    }

    private func reflexive() -> Stun.Mapped? {
        guard socket >= 0 else { return nil }
        return Stun.discover(socket: socket)
    }

    private func address(from m: [String: Any]) -> (String, UInt16)? {
        guard let a = m["addr"] as? [String: Any],
              let ip = a["ip"] as? String, let p = a["port"] as? Int
        else { return nil }
        return (ip, UInt16(p))
    }

    /// NAT'TA DELIK ACMA.
    ///
    /// Iki taraf da otekine paket yolluyor. Ilk paketler dusuyor —
    /// NAT'lar disaridan gelen ilk paketi tanimadigi icin atiyor — ama
    /// giden paket donus icin bir delik aciyor ve birkac denemede
    /// karsilikli olarak gecmeye basliyor. Tek taraflı denemek
    /// calismaz; ikisi de ayni anda gondermeli.
    private func startPunching() {
        guard let r = remote, socket >= 0 else {
            finish(.failed("noaddr"), note: nil); return
        }
        var attempts = 0
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        t.schedule(deadline: .now(), repeating: .milliseconds(200))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            attempts += 1
            self.sendPunch(to: r)
            if attempts == 1 {
                Log.write("delik açılıyor: \(r.host):\(r.port)")
            }
            // 8 saniye sonunda hala sessizse basarisiz. Simetrik NAT ve
            // operator CGNAT'inda bu olabiliyor; role sunucumuz yok.
            // Baglandiktan sonra da bir sure gonderiyoruz: karsi
            // tarafin onayi yolda olabilir.
            if attempts > 40 {
                self.punchTimer?.cancel()
                self.punchTimer = nil
                if case .connecting = self.state { self.finish(.failed("nopath"), note: nil) }
            }
        }
        t.resume()
        punchTimer = t
        listenForPunch()
    }

    private func sendPunch(to r: (host: String, port: UInt16), ack: Bool = false) {
        var sin = sockaddr_in()
        sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sin.sin_family = sa_family_t(AF_INET)
        sin.sin_port = r.port.bigEndian
        inet_pton(AF_INET, r.host, &sin.sin_addr)
        let msg = Array((ack ? "ANDROS-PUNCH-ACK" : "ANDROS-PUNCH").utf8)
        _ = withUnsafePointer(to: &sin) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                sendto(socket, msg, msg.count, 0, sa,
                       socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    /**
     * Gelen delik paketlerini dinler.
     *
     * ILK OLCUMDE HATA BURADAYDI: paket gelir gelmez gondermeyi
     * kesiyorduk. Ama karsi taraf BIZIM paketimizi henuz almamis
     * olabiliyor — olculdu: aranan taraf 100 ms icinde baglandi ve
     * susstu, arayan ise hicbir sey alamadan sekiz saniye bekleyip
     * "yol yok" dedi. Delik acmada iki tarafin da paket ALMASI
     * gerekiyor, birinin almasi yetmiyor.
     *
     * Cozum: gelen her delik paketine ONAY yolluyoruz ve onay
     * gelmeden gondermeyi kesmiyoruz. Ayrica kaynagi `recvfrom` ile
     * ogreniyoruz — karsi tarafin gercek adresi, STUN'un soyledigi
     * adresten farkli olabiliyor.
     */
    private func listenForPunch() {
        let fd = socket
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var buf = [UInt8](repeating: 0, count: 256)
            var tv = timeval(tv_sec: 12, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv,
                       socklen_t(MemoryLayout<timeval>.size))
            while true {
                var from = sockaddr_in()
                var len = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &from) { p -> Int in
                    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        recvfrom(fd, &buf, buf.count, 0, sa, &len)
                    }
                }
                guard n > 0 else { return }
                guard let self else { return }
                let s = String(decoding: buf[0..<n], as: UTF8.self)

                var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var a = from.sin_addr
                inet_ntop(AF_INET, &a, &ipBuf, socklen_t(INET_ADDRSTRLEN))
                let src = (String(cString: ipBuf), UInt16(bigEndian: from.sin_port))

                if s.hasPrefix("ANDROS-PUNCH-ACK") {
                    // Karsi taraf BIZI aldi: artik gondermeyi kesebiliriz.
                    self.remote = src
                    self.punchTimer?.cancel(); self.punchTimer = nil
                    self.markConnected()
                    return
                }
                if s.hasPrefix("ANDROS-PUNCH") {
                    // Biz aldik ama o bizi almamis olabilir: ONAY yolla
                    // ve gondermeye DEVAM et.
                    self.remote = src
                    self.sendPunch(to: src, ack: true)
                    self.markConnected()
                    continue
                }
            }
        }
    }

    private var announced = false

    private func markConnected() {
        guard !announced else { return }
        announced = true
        Log.write("doğrudan bağlantı kuruldu")
        DispatchQueue.main.async {
            if case .connecting(let p) = self.state {
                self.state = .active(peer: p, video: self.wantsVideo)
            }
        }
    }

    // MARK: - Bitis

    private func armRingTimeout(_ seconds: TimeInterval) {
        cancelRingTimeout()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            switch self.state {
            case .ringing, .calling:
                if !self.peer.isEmpty {
                    SignalHub.shared.sendCall(to: self.peer,
                                              ["t": "call.end", "cid": self.callID])
                }
                self.finish(.hangup, note: nil)
            default: break
            }
        }
        ringTimeout = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    private func cancelRingTimeout() { ringTimeout?.cancel(); ringTimeout = nil }

    private func finish(_ reason: EndReason, note: String?) {
        announced = false
        cancelRingTimeout()
        punchTimer?.cancel(); punchTimer = nil
        if socket >= 0 { close(socket); socket = -1 }
        remote = nil
        peer = ""
        callID = ""
        state = .ended(reason: reason, note: note)
        // Kapanma ekrani birkac saniye durup kendiliginden kapanir;
        // hizli mesaj orada okunuyor.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, case .ended = self.state else { return }
            self.state = .idle
        }
    }
}

/// Hizli cevaplar. Kullanici kendi metnini de ekleyebiliyor.
public enum QuickReplies {
    private static let key = "quickReplies"

    public static var defaults: [String] {
        [L2("Şimdi konuşamam", "Can't talk now"),
         L2("Döneceğim", "I'll call you back"),
         L2("Toplantıdayım", "In a meeting"),
         L2("Yoldayım", "On my way")]
    }

    public static var all: [String] {
        get { UserDefaults.standard.stringArray(forKey: key) ?? defaults }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// Cekirdek katman iki dilli metin tutmuyor; burada kucuk bir
    /// yardimci yeterli.
    private static func L2(_ tr: String, _ en: String) -> String {
        Locale.preferredLanguages.first?.hasPrefix("tr") == true ? tr : en
    }
}
