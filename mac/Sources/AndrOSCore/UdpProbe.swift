import Foundation
import Network

/// mDNS'in gormedigi telefonlari YAYIN paketiyle bulur.
///
/// Neden gerekli: Bonjour multicast'e dayaniyor. Wi-Fi yongasi guc
/// tasarrufunda multicast'i suzuyor, bazi yonlendiriciler de IGMP
/// snooping / istemci yalitimi yuzunden hic gecirmiyor. Olculdu:
/// telefonun TLS portu (47821) acikken `dns-sd -B _andros._tcp` hicbir
/// sey dondurmedi — telefon calisiyordu, duyuru kayipti.
///
/// Burada Mac yerel yayin adresine kucuk bir "ANDROS?" yolluyor;
/// telefondaki dinleyici kendini tanitan JSON ile cevap veriyor. Paket
/// ayni zamanda cihazi Doze'dan kisa sureligine cikariyor.
public final class UdpProbe {

    public struct Found {
        public let host: String
        public let port: UInt16
        public let deviceId: String
        public let name: String
        public let manufacturer: String
        public let fingerprintHint: String
    }

    private var socketFD: Int32 = -1
    private let queue = DispatchQueue(label: "dev.naer.andros.udpprobe")
    private var source: DispatchSourceRead?
    /// Bulunanlar: cihaz kimligi -> kayit.
    private var seen: [String: Found] = [:]
    private let lock = NSLock()

    public var onFound: ((Found) -> Void)?

    /// Son bilinen adresler kalici olarak saklaniyor.
    ///
    /// Neden: Bonjour kaydi bu agda cozumlenmiyor ve ona yapilan ilk
    /// baglanti denemesi 12 saniye bosa gidiyordu (olculdu). Onceki
    /// oturumdan bilinen adres elde oldugunda ilk deneme dogrudan
    /// dogru yere gidiyor.
    private static let storeKey = "udpKnownHosts"

    private static func remember(_ deviceId: String, _ host: String) {
        var m = UserDefaults.standard.dictionary(forKey: storeKey) as? [String: String] ?? [:]
        guard m[deviceId] != host else { return }
        m[deviceId] = host
        UserDefaults.standard.set(m, forKey: storeKey)
    }

    public static func lastKnownHost(_ deviceId: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: storeKey) as? [String: String])?[deviceId]
    }

    public init() {}

    public func start() {
        stop()
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        // Kaynak portu sistem sectigi icin bind'a gerek yok; yanitlar
        // ayni sokete geliyor.
        socketFD = fd

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.readOne() }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    public func stop() {
        source?.cancel()
        source = nil
        socketFD = -1
        lock.lock(); seen.removeAll(); lock.unlock()
    }

    /// Yerel aga yoklama yollar. Birkac kez cagrilabilir.
    ///
    /// Once yayin adresleri denenir; ama YAYIN GUVENILIR DEGIL —
    /// olculdu: bu agda telefon 192.168.1.143'e giden TEKIL pakete
    /// cevap verdi, 192.168.1.255 ve 255.255.255.255'e hic cevap
    /// vermedi (yonlendirici yayini gecirmiyor). Bu yuzden hicbir cihaz
    /// bilinmiyorken alt agin tamami TEKIL paketlerle taraniyor: 254
    /// kucuk paket, bir saniyeden kisa surer ve cihazi uykudan da
    /// cikarir. Cihaz bulunduktan sonra yalniz BILINEN adresler
    /// yoklanir — ag bosuna mesgul edilmesin.
    public func probe() {
        guard socketFD >= 0 else { return }
        for addr in Self.broadcastAddresses() { send(to: addr) }

        lock.lock()
        let known = seen.values.map(\.host)
        lock.unlock()
        if known.isEmpty {
            // Once GECEN SEFERKI adresler: cogu zaman degismiyor.
            let remembered = (UserDefaults.standard.dictionary(forKey: Self.storeKey)
                              as? [String: String])?.values ?? [:].values
            for h in remembered {
                var a = in_addr()
                if inet_pton(AF_INET, h, &a) == 1 { send(to: a.s_addr) }
            }
            for a in Self.subnetHosts() { send(to: a) }
        } else {
            for h in known {
                var a = in_addr()
                if inet_pton(AF_INET, h, &a) == 1 { send(to: a.s_addr) }
            }
        }
    }

    private func send(to addr: in_addr_t) {
        var sin = sockaddr_in()
        sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sin.sin_family = sa_family_t(AF_INET)
        sin.sin_port = UInt16(47823).bigEndian
        sin.sin_addr.s_addr = addr
        let msg = Array("ANDROS?".utf8)
        withUnsafePointer(to: &sin) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                _ = sendto(socketFD, msg, msg.count, 0, sa,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    /// Acik IPv4 arayuzlerin alt agindaki tum konak adresleri.
    /// Yalniz makul buyuruklukteki aglar (/22 ve dar) taraniyor.
    private static func subnetHosts() -> [in_addr_t] {
        var out: [in_addr_t] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return out }
        defer { freeifaddrs(ifap) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            defer { p = cur.pointee.ifa_next }
            guard let sa = cur.pointee.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_INET),
                  (cur.pointee.ifa_flags & UInt32(IFF_LOOPBACK)) == 0,
                  (cur.pointee.ifa_flags & UInt32(IFF_UP)) != 0,
                  let nm = cur.pointee.ifa_netmask else { continue }
            let ip = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            let mask = nm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            let hostBits = (~mask) & 0xFFFF_FFFF
            guard hostBits > 0, hostBits <= 1023 else { continue }   // /22 ve dar
            let network = ip & mask
            for h in 1...hostBits where h != hostBits {              // yayin adresi haric
                let a = network | h
                if a == ip { continue }                              // kendimiz
                out.append(a.bigEndian)
            }
        }
        return out
    }

    private func readOne() {
        var buf = [UInt8](repeating: 0, count: 2048)
        var from = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = withUnsafeMutablePointer(to: &from) { p -> Int in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                recvfrom(socketFD, &buf, buf.count, 0, sa, &len)
            }
        }
        guard n > 0,
              let obj = try? JSONSerialization.jsonObject(
                  with: Data(buf[0..<n])) as? [String: Any],
              obj["andros"] != nil else { return }

        var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var a = from.sin_addr
        inet_ntop(AF_INET, &a, &ipBuf, socklen_t(INET_ADDRSTRLEN))
        let host = String(cString: ipBuf)

        let f = Found(host: host,
                      port: UInt16(obj["port"] as? Int ?? 47821),
                      deviceId: obj["deviceId"] as? String ?? "",
                      name: obj["name"] as? String ?? host,
                      manufacturer: obj["manufacturer"] as? String ?? "",
                      fingerprintHint: obj["fp"] as? String ?? "")
        guard !f.deviceId.isEmpty else { return }
        lock.lock()
        let isNew = seen[f.deviceId]?.host != f.host
        seen[f.deviceId] = f
        lock.unlock()
        UdpProbe.remember(f.deviceId, f.host)
        guard isNew else { return }
        Log.write("UDP bulucu: \(f.name) @ \(f.host):\(f.port)")
        DispatchQueue.main.async { self.onFound?(f) }
    }

    /// Acik IPv4 arayuzlerin yayin adresleri.
    private static func broadcastAddresses() -> [in_addr_t] {
        var out: [in_addr_t] = [INADDR_BROADCAST.bigEndian]
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return out }
        defer { freeifaddrs(ifap) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            defer { p = cur.pointee.ifa_next }
            guard let sa = cur.pointee.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_INET),
                  (cur.pointee.ifa_flags & UInt32(IFF_LOOPBACK)) == 0,
                  (cur.pointee.ifa_flags & UInt32(IFF_UP)) != 0,
                  let dst = cur.pointee.ifa_dstaddr else { continue }
            let b = dst.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                $0.pointee.sin_addr.s_addr
            }
            if b != 0, !out.contains(b) { out.append(b) }
        }
        return out
    }
}
