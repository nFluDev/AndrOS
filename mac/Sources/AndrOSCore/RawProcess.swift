import Foundation
import Darwin

/// Argumanlari HAM UTF-8 bayt dizisi olarak gecen surec calistirici.
///
/// Neden gerekli: Foundation'in `Process.arguments`'i Darwin'de dosya sistemi
/// gosterimine cevirim yapiyor ve Unicode normalizasyonunu degistiriyor.
/// Bu yuzden Turkce/Kiril karakterli dosya adlari `adb pull`'a yanlis
/// baytlarla ulasiyor ve cihaz "No such file or directory" diyordu —
/// ayni komut kabuktan sorunsuz calistigi halde.
///
/// Olculdu: "Aşk_Benimle(MP3_320K).mp3" Foundation ile HEM NFC HEM NFD
/// halinde basarisiz; ham baytlarla calisiyor.
public enum RawProcess {

    public struct Result {
        public let out: String
        public let err: String
        public let code: Int32
    }

    /// Calisan bir surecin tutamagi — durdurmak/iptal etmek icin.
    public final class Handle {
        public let pid: pid_t
        private var stopped = false
        init(pid: pid_t) { self.pid = pid }
        public func suspend() { kill(pid, SIGSTOP) }
        public func resume()  { kill(pid, SIGCONT) }
        public func cancel()  { stopped = true; kill(pid, SIGCONT); kill(pid, SIGKILL) }
        public var isCancelled: Bool { stopped }
    }

    /// Ilerleme bildiren surum. `adb pull/push` stdout'a `[ 45%] /yol`
    /// basiyor; satirlari akarken okuyup yuzdeyi disari veriyoruz.
    @discardableResult
    public static func runStreaming(_ path: String, _ args: [String],
                                    env: [String: String] = [:],
                                    onHandle: ((Handle) -> Void)? = nil,
                                    onProgress: ((Int) -> Void)? = nil,
                                    onLine: ((String) -> Void)? = nil,
                                    timeout: TimeInterval = 3600) -> Result {
        var outPipe: [Int32] = [0, 0]
        var errPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0, pipe(&errPipe) == 0 else {
            return Result(out: "", err: "pipe olusturulamadi", code: -1)
        }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, outPipe[0])
        posix_spawn_file_actions_addclose(&actions, errPipe[0])

        var argv: [UnsafeMutablePointer<CChar>?] = ([path] + args).map { s in
            let bytes = Array(s.utf8) + [0]
            let p = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
            for (i, b) in bytes.enumerated() { p[i] = CChar(bitPattern: b) }
            return p
        }
        argv.append(nil)
        defer {
            for p in argv where p != nil { p!.deallocate() }
            posix_spawn_file_actions_destroy(&actions)
        }

        var envp = env.isEmpty ? [UnsafeMutablePointer<CChar>?]() : makeEnv(env)
        defer { for p in envp where p != nil { p!.deallocate() } }

        var pid: pid_t = 0
        let rc = envp.isEmpty
            ? posix_spawn(&pid, path, &actions, nil, argv, environ)
            : posix_spawn(&pid, path, &actions, nil, argv, &envp)
        close(outPipe[1]); close(errPipe[1])
        guard rc == 0 else {
            close(outPipe[0]); close(errPipe[0])
            return Result(out: "", err: "spawn hatasi \(rc)", code: -1)
        }
        let handle = Handle(pid: pid)
        onHandle?(handle)

        let lock = NSLock()
        var outAll = "", errAll = ""
        let group = DispatchGroup()
        for (fd, isOut) in [(outPipe[0], true), (errPipe[0], false)] {
            group.enter()
            DispatchQueue.global().async {
                var buf = [UInt8](repeating: 0, count: 16384)
                var acc = Data()
                var carry = ""
                while true {
                    let n = read(fd, &buf, buf.count)
                    if n <= 0 { break }
                    acc.append(contentsOf: buf[0..<n])
                    if onProgress != nil || onLine != nil {
                        carry += String(decoding: buf[0..<n], as: UTF8.self)
                        // adb/sdkmanager ilerlemeyi \r ile ayni satira basiyor
                        for piece in carry.split(whereSeparator: { $0 == "\r" || $0 == "\n" }) {
                            let line = String(piece)
                            if let pct = parsePercent(line) { onProgress?(pct) }
                            onLine?(line)
                        }
                        if carry.count > 4096 { carry = "" }
                    }
                }
                close(fd)
                lock.lock()
                if isOut { outAll = String(decoding: acc, as: UTF8.self) }
                else { errAll = String(decoding: acc, as: UTF8.self) }
                lock.unlock()
                group.leave()
            }
        }

        var status: Int32 = 0
        let deadline = Date().addingTimeInterval(timeout)
        var finished = false
        while Date() < deadline {
            let r = waitpid(pid, &status, WNOHANG)
            if r == pid { finished = true; break }
            if r < 0 { break }
            usleep(20_000)
        }
        if !finished { kill(pid, SIGKILL); _ = waitpid(pid, &status, 0) }
        _ = group.wait(timeout: .now() + 5)

        let code: Int32 = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : -1
        return Result(out: outAll.trimmingCharacters(in: .whitespacesAndNewlines),
                      err: errAll.trimmingCharacters(in: .whitespacesAndNewlines),
                      code: handle.isCancelled ? -2 : code)
    }

    /// "[ 45%] /sdcard/x" -> 45,  "[====   ] 24% Downloading" -> 24
    private static func parsePercent(_ line: String) -> Int? {
        guard let pct = line.firstIndex(of: "%") else { return nil }
        var digits = ""
        var i = pct
        while i > line.startIndex {
            i = line.index(before: i)
            if line[i].isNumber { digits.insert(line[i], at: digits.startIndex) }
            else if line[i] == " " || line[i] == "]" { if !digits.isEmpty { break } }
            else { break }
        }
        return digits.isEmpty ? nil : Int(digits)
    }

    /// stdout'u dogrudan bir DOSYAYA yazar.
    ///
    /// `adb exec-out` ikili veri donuyor; String'e cevirmek onu bozuyordu.
    /// Album kapaklari ve benzeri ikili ciktilar icin bu kullanilir.
    @discardableResult
    public static func runToFile(_ path: String, _ args: [String],
                                 output: String,
                                 timeout: TimeInterval = 120) -> Bool {
        FileManager.default.createFile(atPath: output, contents: nil)
        guard let fh = FileHandle(forWritingAtPath: output) else { return false }
        defer { try? fh.close() }

        var errPipe: [Int32] = [0, 0]
        guard pipe(&errPipe) == 0 else { return false }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, fh.fileDescriptor, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, errPipe[0])

        var argv: [UnsafeMutablePointer<CChar>?] = ([path] + args).map { s in
            let bytes = Array(s.utf8) + [0]
            let p = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
            for (i, b) in bytes.enumerated() { p[i] = CChar(bitPattern: b) }
            return p
        }
        argv.append(nil)
        defer {
            for p in argv where p != nil { p!.deallocate() }
            posix_spawn_file_actions_destroy(&actions)
        }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, &actions, nil, argv, environ)
        close(errPipe[1])
        guard rc == 0 else { close(errPipe[0]); return false }
        DispatchQueue.global().async {
            var b = [UInt8](repeating: 0, count: 4096)
            while read(errPipe[0], &b, b.count) > 0 {}
            close(errPipe[0])
        }
        var status: Int32 = 0
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if waitpid(pid, &status, WNOHANG) == pid { break }
            usleep(20_000)
        }
        let size = (try? FileManager.default
            .attributesOfItem(atPath: output)[.size] as? Int) ?? 0
        return (size ?? 0) > 512
    }

    /// Ek ortam degiskenleriyle birlikte envp kurar.
    ///
    /// Android arac zinciri ANDROID_SDK_ROOT / ANDROID_AVD_HOME / JAVA_HOME
    /// okuyor; bunlari surece gecirebilmek icin gerekiyor.
    private static func makeEnv(_ extra: [String: String]) -> [UnsafeMutablePointer<CChar>?] {
        var merged: [String: String] = [:]
        var p = environ
        while let entry = p.pointee {
            let s = String(cString: entry)
            if let i = s.firstIndex(of: "=") {
                merged[String(s[s.startIndex..<i])] = String(s[s.index(after: i)...])
            }
            p += 1
        }
        for (k, v) in extra { merged[k] = v }
        var out: [UnsafeMutablePointer<CChar>?] = merged.map { k, v in
            let bytes = Array("\(k)=\(v)".utf8) + [0]
            let buf = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
            for (i, b) in bytes.enumerated() { buf[i] = CChar(bitPattern: b) }
            return buf
        }
        out.append(nil)
        return out
    }

    /// `path` calistirilabilir, `args` ham gecirilecek argumanlar.
    public static func run(_ path: String, _ args: [String],
                           env: [String: String] = [:],
                           timeout: TimeInterval = 300) -> Result {
        var outPipe: [Int32] = [0, 0]
        var errPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0, pipe(&errPipe) == 0 else {
            return Result(out: "", err: "pipe olusturulamadi", code: -1)
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, outPipe[0])
        posix_spawn_file_actions_addclose(&actions, errPipe[0])

        // argv: her arguman UTF-8 baytlariyla, dokunulmadan.
        var argv: [UnsafeMutablePointer<CChar>?] = ([path] + args).map { s in
            let bytes = Array(s.utf8) + [0]
            let p = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
            for (i, b) in bytes.enumerated() { p[i] = CChar(bitPattern: b) }
            return p
        }
        argv.append(nil)
        defer {
            for p in argv where p != nil { p!.deallocate() }
            posix_spawn_file_actions_destroy(&actions)
        }

        var envp = env.isEmpty ? [UnsafeMutablePointer<CChar>?]() : makeEnv(env)
        defer { for p in envp where p != nil { p!.deallocate() } }

        var pid: pid_t = 0
        let rc = envp.isEmpty
            ? posix_spawn(&pid, path, &actions, nil, argv, environ)
            : posix_spawn(&pid, path, &actions, nil, argv, &envp)
        close(outPipe[1]); close(errPipe[1])
        guard rc == 0 else {
            close(outPipe[0]); close(errPipe[0])
            return Result(out: "", err: "spawn hatasi \(rc)", code: -1)
        }

        // Cikti borularini paralel bosalt: dolarsa surec bloke olur.
        let lock = NSLock()
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        for (fd, isOut) in [(outPipe[0], true), (errPipe[0], false)] {
            group.enter()
            DispatchQueue.global().async {
                var buf = [UInt8](repeating: 0, count: 65536)
                var acc = Data()
                while true {
                    let n = read(fd, &buf, buf.count)
                    if n <= 0 { break }
                    acc.append(contentsOf: buf[0..<n])
                }
                close(fd)
                lock.lock()
                if isOut { outData = acc } else { errData = acc }
                lock.unlock()
                group.leave()
            }
        }

        var status: Int32 = 0
        let deadline = Date().addingTimeInterval(timeout)
        var finished = false
        while Date() < deadline {
            let r = waitpid(pid, &status, WNOHANG)
            if r == pid { finished = true; break }
            if r < 0 { break }
            usleep(15_000)
        }
        if !finished {
            kill(pid, SIGTERM)
            _ = waitpid(pid, &status, 0)
        }
        _ = group.wait(timeout: .now() + 5)

        let code: Int32 = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : -1
        return Result(out: String(decoding: outData, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      err: String(decoding: errData, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      code: code)
    }
}
