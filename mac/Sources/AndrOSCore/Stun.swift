import Foundation

/// Kendi dis adresini ogrenmek (RFC 5389 Binding).
///
/// NAT arkasindaki iki cihaz birbirine dogrudan paket yollayacaksa once
/// KENDI disaridan gorunen adreslerini bilmeleri gerekiyor. Bunu ancak
/// disaridaki biri soyleyebilir; sunucudaki kucuk STUN ucu bunun icin.
///
/// AYNI SOKET SART. NAT esleme soket basina aciliyor: yoklamayi bir
/// soketle yapip ses/goruntuyu baskasindan yollamak, ogrenilen adresi
/// gecersiz kilar. Bu yuzden burasi soketi disaridan aliyor ve geri
/// veriyor — cagri boyunca ayni soket kullanilacak.
public enum Stun {

    public struct Mapped {
        public let host: String
        public let port: UInt16
    }

    /// Sunucunun adresi. Alan adi Cloudflare gibi bir VEKILDEN
    /// gecmemeli: vekiller yalniz HTTP tasiyor, UDP tasimiyor ve paket
    /// hic sunucuya varmiyor.
    public static let defaultHost = "stun.gamehost.dev"
    public static let defaultPort: UInt16 = 3478

    /// Verilen soketle dis adresi sorar. Yanit gelmezse `nil`.
    ///
    /// UDP paketi kaybolabiliyor ve tek denemede vazgecmek, calisan bir
    /// sunucuda "arama kurulamadi" demek olurdu. Uc kez deniyoruz.
    public static func discover(socket fd: Int32,
                                host: String = defaultHost,
                                port: UInt16 = defaultPort,
                                timeout: TimeInterval = 2,
                                attempts: Int = 3) -> Mapped? {
        for i in 0..<max(1, attempts) {
            if let m = probe(socket: fd, host: host, port: port, timeout: timeout) {
                if i > 0 { Log.write("STUN: \(i + 1). denemede yanıt geldi") }
                return m
            }
        }
        return nil
    }

    private static func probe(socket fd: Int32, host: String, port: UInt16,
                              timeout: TimeInterval) -> Mapped? {
        guard let addr = resolve(host, port) else { return nil }

        var request = [UInt8](repeating: 0, count: 20)
        request[0] = 0x00; request[1] = 0x01                 // Binding istegi
        request[2] = 0x00; request[3] = 0x00                 // govde yok
        let magic: UInt32 = 0x2112_A442
        request[4] = UInt8((magic >> 24) & 0xFF); request[5] = UInt8((magic >> 16) & 0xFF)
        request[6] = UInt8((magic >> 8) & 0xFF);  request[7] = UInt8(magic & 0xFF)
        var txn = [UInt8](repeating: 0, count: 12)
        for i in 0..<12 { txn[i] = UInt8.random(in: 0...255) }
        for i in 0..<12 { request[8 + i] = txn[i] }

        var sin = addr
        let sent = withUnsafePointer(to: &sin) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                sendto(fd, request, request.count, 0, sa,
                       socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard sent > 0 else { Log.write("STUN: gönderilemedi (\(errno))"); return nil }

        // Kisa bir bekleme: yanit gelmezse cagri kurulmayacak ve bunu
        // dakikalarca beklemenin anlami yok.
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var buf = [UInt8](repeating: 0, count: 512)
        let n = recv(fd, &buf, buf.count, 0)
        guard n >= 20 else { Log.write("STUN: yanıt yok (n=\(n), errno=\(errno))"); return nil }
        guard buf[0] == 0x01, buf[1] == 0x01 else {
            Log.write("STUN: beklenmeyen tür \(buf[0]),\(buf[1])"); return nil
        }
        for i in 0..<12 where buf[8 + i] != txn[i] { return nil }  // baska bir yanit

        // Nitelikleri gez: XOR-MAPPED-ADDRESS (0x0020) ariyoruz.
        var i = 20
        while i + 4 <= n {
            let type = (UInt16(buf[i]) << 8) | UInt16(buf[i + 1])
            let len = Int((UInt16(buf[i + 2]) << 8) | UInt16(buf[i + 3]))
            let value = i + 4
            guard value + len <= n else { break }
            if type == 0x0020, len >= 8, buf[value + 1] == 0x01 {
                let port = ((UInt16(buf[value + 2]) << 8) | UInt16(buf[value + 3]))
                         ^ UInt16(magic >> 16)
                var ip: [UInt8] = []
                for k in 0..<4 {
                    ip.append(buf[value + 4 + k] ^ UInt8((magic >> (24 - 8 * UInt32(k))) & 0xFF))
                }
                return Mapped(host: ip.map(String.init).joined(separator: "."), port: port)
            }
            i = value + len + ((4 - len % 4) % 4)              // 4 bayta hizali
        }
        return nil
    }

    /// Cagri icin kullanilacak UDP soketi. Ayni soket hem yoklamada hem
    /// medyada kullanilmali.
    public static func makeSocket() -> Int32 {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return -1 }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var sin = sockaddr_in()
        sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sin.sin_family = sa_family_t(AF_INET)
        sin.sin_port = 0                                       // sistem sectsin
        sin.sin_addr.s_addr = INADDR_ANY
        _ = withUnsafePointer(to: &sin) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return fd
    }

    private static func resolve(_ host: String, _ port: UInt16) -> sockaddr_in? {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_DGRAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil,
                             ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &result)
        guard rc == 0, let r = result else {
            Log.write("STUN: ad çözülemedi \(host) (\(rc))"); return nil
        }
        defer { freeaddrinfo(result) }
        guard let sa = r.pointee.ai_addr else { return nil }
        return sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
    }
}
