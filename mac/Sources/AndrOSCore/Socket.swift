import Foundation
import Darwin

/// Minimal bloklamali TCP istemcisi (adb forward uzerinden localhost'a baglanir).
public final class TCPSocket {
    private var fd: Int32 = -1
    public private(set) var isOpen = false
    /// Kapatma istegi. EAGAIN dongusunden cikmak icin.
    private var cancelled = false

    public init() {}
    deinit { close() }

    public func connect(host: String = "127.0.0.1", port: UInt16, timeout: TimeInterval = 2) -> Bool {
        close()
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }

        var one: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr(host)

        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        if !ok { Darwin.close(fd); fd = -1; return false }
        cancelled = false
        isOpen = true
        return true
    }

    /// Tam olarak `count` bayt okur. Akis GERCEKTEN kapandiysa nil doner.
    ///
    /// Onemli: SO_RCVTIMEO dolunca recv -1/EAGAIN doner. Bu "baglanti koptu"
    /// DEGILDIR — hareketsiz ekranda cihaz kare uretmez ve bu tamamen normaldir.
    /// Zaman asimini kopma sanmak akisi 2 saniyede oldururdu.
    public func readExactly(_ count: Int, timeoutSeconds: Double? = nil) -> [UInt8]? {
        guard isOpen, count > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: count)
        var got = 0
        let deadline = timeoutSeconds.map { Date().addingTimeInterval($0) }

        while got < count {
            if cancelled { return nil }
            let n = buf.withUnsafeMutableBytes { p -> Int in
                Darwin.recv(fd, p.baseAddress!.advanced(by: got), count - got, 0)
            }
            if n > 0 { got += n; continue }
            if n == 0 { return nil }                     // karsi taraf kapatti

            switch errno {
            case EAGAIN, EWOULDBLOCK, EINTR:
                // Veri yok, beklemeye devam. Sinir verildiyse ona uy.
                if let d = deadline, Date() >= d { return nil }
                continue
            default:
                return nil                                // gercek soket hatasi
            }
        }
        return buf
    }

    @discardableResult
    public func write(_ bytes: [UInt8]) -> Bool {
        guard isOpen else { return false }
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBytes { p -> Int in
                Darwin.send(fd, p.baseAddress!.advanced(by: sent), bytes.count - sent, 0)
            }
            if n <= 0 { return false }
            sent += n
        }
        return true
    }

    public func close() {
        cancelled = true
        if fd >= 0 { Darwin.close(fd); fd = -1 }
        isOpen = false
    }
}
