import Foundation

public enum ADBError: Error, CustomStringConvertible {
    case notFound
    case noDevice
    case multipleDevices([String])
    case command(String, Int32, String)

    public var description: String {
        switch self {
        case .notFound: return "adb bulunamadi (brew install android-platform-tools)"
        case .noDevice: return "Bagli cihaz yok. USB hata ayiklamayi acip kabloyu tak."
        case .multipleDevices(let s): return "Birden fazla cihaz: \(s.joined(separator: ", "))"
        case .command(let c, let code, let err): return "adb \(c) basarisiz (\(code)): \(err)"
        }
    }
}

public struct ADBDevice {
    public let serial: String
    public let model: String
    public let transport: String   // "usb" | "tcp"
}

public struct ADB {
    public let path: String
    public let serial: String?

    public init(path: String? = nil, serial: String? = nil) throws {
        if let p = path { self.path = p }
        else if let p = ADB.locate() { self.path = p }
        else { throw ADBError.notFound }
        self.serial = serial
    }

    static func locate() -> String? {
        for c in ["/usr/local/bin/adb", "/opt/homebrew/bin/adb",
                  "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb"]
        where FileManager.default.isExecutableFile(atPath: c) { return c }
        return nil
    }

    /// adb'yi calistirir, (stdout, stderr, exitCode) doner.
    @discardableResult
    public func run(_ args: [String], timeout: TimeInterval = 30) throws
        -> (out: String, err: String, code: Int32)
    {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = (serial.map { ["-s", $0] } ?? []) + args
        let o = Pipe(), e = Pipe()
        p.standardOutput = o; p.standardError = e
        try p.run()

        // Deadlock olmamasi icin pipe'lari arka planda bosalt.
        var oData = Data(), eData = Data()
        let lock = NSLock()
        let g = DispatchGroup()
        for (pipe, isOut) in [(o, true), (e, false)] {
            g.enter()
            DispatchQueue.global().async {
                let d = pipe.fileHandleForReading.readDataToEndOfFile()
                lock.lock(); if isOut { oData = d } else { eData = d }; lock.unlock()
                g.leave()
            }
        }
        if p.isRunning {
            let deadline = Date().addingTimeInterval(timeout)
            while p.isRunning && Date() < deadline { usleep(20_000) }
            if p.isRunning { p.terminate() }
        }
        p.waitUntilExit()
        _ = g.wait(timeout: .now() + 5)
        return (String(decoding: oData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                String(decoding: eData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                p.terminationStatus)
    }

    public func checked(_ args: [String], timeout: TimeInterval = 30) throws -> String {
        let r = try run(args, timeout: timeout)
        guard r.code == 0 else { throw ADBError.command(args.joined(separator: " "), r.code, r.err) }
        return r.out
    }

    public func devices() throws -> [ADBDevice] {
        let out = try checked(["devices", "-l"])
        return out.split(separator: "\n").dropFirst().compactMap { line -> ADBDevice? in
            let f = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard f.count >= 2, f[1] == "device" else { return nil }
            let kv = Dictionary(uniqueKeysWithValues: f.dropFirst(2)
                .compactMap { s -> (String, String)? in
                    let p = s.split(separator: ":", maxSplits: 1)
                    return p.count == 2 ? (String(p[0]), String(p[1])) : nil
                })
            return ADBDevice(serial: f[0],
                             model: kv["model"] ?? "?",
                             transport: f[0].contains(":") ? "tcp" : "usb")
        }
    }

    public func singleDevice() throws -> ADBDevice {
        let d = try devices()
        if d.isEmpty { throw ADBError.noDevice }
        if d.count > 1, serial == nil { throw ADBError.multipleDevices(d.map(\.serial)) }
        return d[0]
    }

    /// Cihaz ozelligi — ONBELLEKLI.
    ///
    /// `ro.*` ozellikleri cihaz acikken degismiyor; buna ragmen cihaz
    /// listesi her 3 saniyede tazelendigi icin her turda birkac
    /// `adb shell getprop` calisiyordu. adb tek kanal: bu cagrilar
    /// galeri kucuk resimleri ve muzik listesiyle ayni siraya girip
    /// panellerin isteklerini zaman asimina ugratiyordu ("muzigi actim,
    /// aramalar kayboldu"). Bir kez okuyup sakliyoruz.
    /// adb'nin ELINDE bir cihaz var mi?
    ///
    /// Yoksa `pull`/`push` cagirmak bosuna: her seferinde birkac
    /// saniyelik zaman asimi ve sessiz basarisizlik demek.
    public var hasDevice: Bool {
        guard let out = try? checked(["devices"], timeout: 5) else { return false }
        return out.split(separator: "\n").dropFirst().contains { $0.contains("\tdevice") }
    }

    public func getProp(_ key: String) -> String {
        let ck = (serial ?? "-") + "|" + key
        ADB.propLock.lock()
        let hit = ADB.propCache[ck]
        ADB.propLock.unlock()
        if let hit { return hit }
        let v = (try? checked(["shell", "getprop", key])) ?? ""
        // Bos sonucu SAKLAMA: cihaz henuz hazir olmayabilir.
        guard !v.isEmpty else { return v }
        ADB.propLock.lock()
        ADB.propCache[ck] = v
        ADB.propLock.unlock()
        return v
    }

    private static var propCache: [String: String] = [:]
    private static let propLock = NSLock()

    /// Cihaz gidince onbellegi bosalt (yeniden baglanan cihaz taze okunsun).
    public static func forgetProps(serial: String?) {
        let prefix = (serial ?? "-") + "|"
        propLock.lock()
        propCache = propCache.filter { !$0.key.hasPrefix(prefix) }
        propLock.unlock()
    }
}
