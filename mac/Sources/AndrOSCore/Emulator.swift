import Foundation

// MARK: - Sistem imaji

/// Indirilebilir bir Android sistem imaji.
public struct SystemImage: Hashable, Identifiable {
    public var id: String { path }
    /// "system-images;android-34;google_apis_playstore;x86_64"
    public let path: String
    public let api: Int
    /// "google_apis_playstore" | "google_apis" | "default"
    public let tag: String
    public let abi: String
    public var installed = false

    public init(path: String, api: Int, tag: String, abi: String, installed: Bool = false) {
        self.path = path; self.api = api; self.tag = tag
        self.abi = abi; self.installed = installed
    }

    /// API seviyesinden Android surumu.
    public static func androidName(_ api: Int) -> String {
        switch api {
        case 30: return "11"
        case 31: return "12"
        case 32: return "12L"
        case 33: return "13"
        case 34: return "14"
        case 35: return "15"
        case 36: return "16"
        default: return "API \(api)"
        }
    }
    public var androidVersion: String { Self.androidName(api) }
    public var hasPlayStore: Bool { tag.contains("playstore") }
    public var hasGoogleServices: Bool { tag.contains("google_apis") }
    /// Varyant turu — aciklama metnini panel bundan uretiyor.
    public enum Kind { case aosp, googleAPIs, playStore }
    public var kind: Kind {
        if hasPlayStore { return .playStore }
        if hasGoogleServices { return .googleAPIs }
        return .aosp
    }
    public var title: String {
        "Android \(androidVersion)"
            + (hasPlayStore ? " · Play Store" : (tag == "default" ? "" : " · Google APIs"))
    }
}

// MARK: - AVD ayarlari

/// Bir sanal cihazin TUM ayarlari. `config.ini` anahtarlariyla birebir
/// eslesiyor, boylece emulatorun kendi bicimiyle uyumlu kaliyor.
public struct AVDSettings: Codable, Hashable {
    public var ramMB = 4096
    public var cores = 4
    public var heapMB = 512
    /// Veri bolumu — "8G" gibi. Emulator bunu SEYREK (sparse) ayirir:
    /// dosya ancak kullanildikca buyur, bastan yer kaplamaz.
    public var dataPartitionGB = 16
    public var sdCardMB = 0
    public var width = 1080
    public var height = 2400
    public var density = 440
    /// host | auto | swiftshader_indirect | angle_indirect | off
    ///
    /// Varsayilan "host": olculdu — `angle_indirect` bu makinede
    /// emulatorun kendi penceresini SIYAH birakiyordu; `host` ve
    /// `swiftshader_indirect` sorunsuz aciliyor, `host` daha hizli.
    public var gpuMode = "host"
    public var accelerated = true
    public var coldBoot = false
    public var keyboard = true
    public var cameraBack = "emulated"
    public var cameraFront = "emulated"

    public init() {}

    /// "Yuksek basarim" (0.0) ile "yuksek kalite" (1.0) arasinda bir
    /// on ayar uretir. Degerler MAKINEYE gore olceklenir.
    ///
    /// Cekirdek: basarimda yarisi, kalitede %75'i (olcut: 8 cekirdekte 6).
    /// RAM: 16 GB'ta basarimda 6144 MB (%37.5), kalitede 8192 MB (%50).
    /// VM yigini RAM'in sekizde biri — Android'in kendi cihaz profilleri
    /// de bu orani kullaniyor.
    public static func preset(_ quality: Double,
                              totalRAMMB: Int, totalCores: Int) -> AVDSettings {
        let q = Swift.min(Swift.max(quality, 0), 1)
        var s = AVDSettings()

        let coreLo = Swift.max(1, totalCores / 2)
        let coreHi = Swift.max(coreLo, Int((Double(totalCores) * 0.75).rounded(.down)))
        s.cores = coreLo + Int((Double(coreHi - coreLo) * q).rounded())

        let ramLo = Int(Double(totalRAMMB) * 0.375)
        let ramHi = Int(Double(totalRAMMB) * 0.50)
        // 512 MB'lik adimlara yuvarla: emulator ara degerleri sevmiyor.
        let ram = ramLo + Int((Double(ramHi - ramLo) * q).rounded())
        s.ramMB = Swift.max(2048, (ram / 512) * 512)

        s.heapMB = Swift.min(1024, Swift.max(256, (s.ramMB / 8 / 128) * 128))

        // Kaliteye gidildikce cozunurluk artiyor.
        if q < 0.34 { s.width = 720;  s.height = 1280; s.density = 320 }
        else if q < 0.67 { s.width = 1080; s.height = 1920; s.density = 420 }
        else { s.width = 1080; s.height = 2400; s.density = 440 }

        s.gpuMode = "host"
        s.accelerated = true
        return s
    }

    /// Bu makinenin olculeri.
    public static var hostRAMMB: Int {
        Int(ProcessInfo.processInfo.physicalMemory / 1024 / 1024)
    }
    public static var hostCores: Int { ProcessInfo.processInfo.processorCount }
}

/// Kayitli bir sanal cihaz.
public struct AVD: Hashable, Identifiable {
    public var id: String { name }
    public let name: String
    public var displayName: String
    public var imagePath: String
    public var api: Int
    public var settings: AVDSettings
    public var running = false

    public var androidVersion: String { SystemImage.androidName(api) }
}

// MARK: - Yonetici

/// Android emulatorunu indiren, kuran ve calistiran katman.
///
/// Kendi emulatorumuzu YAZMIYORUZ: Google'in QEMU tabanli `emulator`'unu
/// kullaniyoruz. Sebebi hem gercekcilik hem de su kazanc — emulator kendini
/// adb'ye normal bir cihaz gibi veriyor, yani AndrOS'un yansitma, dosya,
/// galeri, uygulama, pano modullerinin HEPSI uzerinde oldugu gibi calisiyor.
///
/// SDK kullanicinin acik istegiyle Google'in deposundan iniyor; paket
/// icinde dagitilmiyor.
public final class EmulatorManager {
    public static let shared = EmulatorManager()

    public let root: URL
    public let avdHome: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("AndrOS", isDirectory: true)
        root = base.appendingPathComponent("android-sdk", isDirectory: true)
        avdHome = base.appendingPathComponent("avd", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: avdHome, withIntermediateDirectories: true)
    }

    // ---- Yollar

    public var sdkmanager: String {
        root.appendingPathComponent("cmdline-tools/latest/bin/sdkmanager").path
    }
    public var avdmanager: String {
        root.appendingPathComponent("cmdline-tools/latest/bin/avdmanager").path
    }
    public var emulatorBin: String {
        root.appendingPathComponent("emulator/emulator").path
    }
    public var adbBin: String {
        root.appendingPathComponent("platform-tools/adb").path
    }

    public var isBootstrapped: Bool {
        let f = FileManager.default
        return f.isExecutableFile(atPath: sdkmanager) && f.isExecutableFile(atPath: emulatorBin)
    }

    /// Bu makinede donanim hizlandirma var mi? (Hypervisor.framework)
    public static var hardwareAccelerated: Bool {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.hv_support", &v, &size, nil, 0) == 0 else { return false }
        return v == 1
    }

    private var env: [String: String] {
        var e = ["ANDROID_SDK_ROOT": root.path,
                 "ANDROID_HOME": root.path,
                 "ANDROID_AVD_HOME": avdHome.path]
        if let home = javaHome() { e["JAVA_HOME"] = home }
        return e
    }

    /// sdkmanager bir Java aracı; JAVA_HOME bulunmazsa calismiyor.
    private func javaHome() -> String? {
        if let h = ProcessInfo.processInfo.environment["JAVA_HOME"] { return h }
        // `java` hangi kurulumdan geliyorsa onun kokunu bul.
        let r = RawProcess.run("/usr/bin/which", ["java"], timeout: 10)
        guard r.code == 0, !r.out.isEmpty else { return nil }
        var p = URL(fileURLWithPath: r.out).resolvingSymlinksInPath()
        // .../Home/bin/java -> .../Home
        p.deleteLastPathComponent()          // bin
        p.deleteLastPathComponent()          // Home
        return FileManager.default.fileExists(atPath: p.appendingPathComponent("bin/java").path)
            ? p.path : nil
    }

    // MARK: - Kurulum

    /// Komut satiri araclarini indirip yerlestirir, sonra emulator ve
    /// platform-tools paketlerini kurar.
    public func bootstrap(onProgress: @escaping (String, Int) -> Void,
                          done: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
                if !FileManager.default.isExecutableFile(atPath: sdkmanager) {
                    onProgress("tools.download", 0)
                    let url = try discoverCmdlineToolsURL()
                    let zip = root.appendingPathComponent("cmdline-tools.zip")
                    try download(url, to: zip) { onProgress("tools.download", $0) }

                    onProgress("tools.unzip", 0)
                    let tmp = root.appendingPathComponent("_unzip", isDirectory: true)
                    try? FileManager.default.removeItem(at: tmp)
                    let r = RawProcess.run("/usr/bin/unzip", ["-q", "-o", zip.path, "-d", tmp.path],
                                           timeout: 300)
                    guard r.code == 0 else { throw Err.msg("unzip.failed: \(r.err)") }

                    // Arsivde "cmdline-tools/" var; sdkmanager onu
                    // "cmdline-tools/latest/" altinda bekliyor.
                    let dest = root.appendingPathComponent("cmdline-tools/latest", isDirectory: true)
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.createDirectory(
                        at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.moveItem(
                        at: tmp.appendingPathComponent("cmdline-tools"), to: dest)
                    try? FileManager.default.removeItem(at: tmp)
                    try? FileManager.default.removeItem(at: zip)
                }

                onProgress("licenses", 0)
                acceptLicenses()

                for pkg in ["platform-tools", "emulator"] {
                    onProgress("pkg:\(pkg)", 0)
                    let r = install(pkg) { onProgress("pkg:\(pkg)", $0) }
                    if !r { throw Err.msg("pkg.failed:\(pkg)") }
                }
                DispatchQueue.main.async { done(nil) }
            } catch {
                DispatchQueue.main.async { done("\(error)") }
            }
        }
    }

    enum Err: Error, CustomStringConvertible {
        case msg(String)
        var description: String { if case .msg(let m) = self { return m }; return "hata" }
    }

    /// Depodan bu mimariye uygun cmdline-tools arsivini bulur.
    ///
    /// URL'i sabit yazmiyoruz: surum numarasi degistikce baglanti kiriliyor.
    private func discoverCmdlineToolsURL() throws -> URL {
        let base = "https://dl.google.com/android/repository/"
        guard let xmlURL = URL(string: base + "repository2-3.xml"),
              let data = try? Data(contentsOf: xmlURL),
              let xml = String(data: data, encoding: .utf8) else {
            throw Err.msg("repo.unreachable")
        }
        #if arch(arm64)
        let want = "commandlinetools-mac_arm64-"
        #else
        let want = "commandlinetools-mac_x86_64-"
        #endif
        // Once mimariye ozel, yoksa evrensel mac arsivi.
        for prefix in [want, "commandlinetools-mac-"] {
            let pattern = "<url>(\(NSRegularExpression.escapedPattern(for: prefix))[^<]+)</url>"
            if let re = try? NSRegularExpression(pattern: pattern),
               let m = re.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
               let r = Range(m.range(at: 1), in: xml) {
                return URL(string: base + String(xml[r]))!
            }
        }
        throw Err.msg("tools.notfound")
    }

    private func download(_ url: URL, to dest: URL,
                          onProgress: @escaping (Int) -> Void) throws {
        // curl ilerlemeyi stderr'e basiyor; yuzdeyi oradan okuyoruz.
        let r = RawProcess.runStreaming(
            "/usr/bin/curl",
            ["-L", "--fail", "--progress-bar", "-o", dest.path, url.absoluteString],
            onLine: { line in
                let parts = line.split(separator: " ").compactMap { Double($0.replacingOccurrences(of: "%", with: "")) }
                if let p = parts.first, p >= 0, p <= 100 { onProgress(Int(p)) }
            },
            timeout: 3600)
        guard r.code == 0 else { throw Err.msg("download.failed: \(r.err)") }
    }

    private func acceptLicenses() {
        // sdkmanager --licenses her lisans icin "y" bekliyor. Kabul
        // dosyalarini dogrudan yazmak daha guvenilir: etkilesimli boru
        // bazen yarim kaliyor.
        let dir = root.appendingPathComponent("licenses", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let known: [String: String] = [
            "android-sdk-license":
                "\n24333f8a63b6825ea9c5514f83c2829b004d1fee\n8933bad161af4178b1185d1a37fbf41ea5269c55",
            "android-sdk-preview-license":
                "\n84831b9409646a918e30573bab4c9c91346d8abd",
            "android-sdk-arm-dbt-license":
                "\n859f317696f67ef3d7f30a50a5560e7834b43903",
        ]
        for (name, body) in known {
            try? body.write(to: dir.appendingPathComponent(name),
                            atomically: true, encoding: .utf8)
        }
    }

    @discardableResult
    private func install(_ pkg: String, onProgress: @escaping (Int) -> Void) -> Bool {
        let r = RawProcess.runStreaming(
            sdkmanager, ["--sdk_root=\(root.path)", pkg],
            env: env, onProgress: onProgress, timeout: 7200)
        return r.code == 0
    }

    /// Sistem imajini kurar (buyuk indirme).
    public func installImage(_ image: SystemImage,
                             onProgress: @escaping (Int) -> Void,
                             done: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let ok = install(image.path, onProgress: { p in
                DispatchQueue.main.async { onProgress(p) }
            })
            DispatchQueue.main.async { done(ok ? nil : "image.failed") }
        }
    }

    // MARK: - Sistem imajlari

    /// Depodan indirilebilir imajlari listeler (ag gerektirir).
    public func availableImages(done: @escaping ([SystemImage]) -> Void) {
        DispatchQueue.global().async { [self] in
            var out: [SystemImage] = []
            #if arch(arm64)
            let abi = "arm64-v8a"
            #else
            let abi = "x86_64"
            #endif
            let repos = ["google_apis_playstore", "google_apis", "android"]
            for repo in repos {
                let u = "https://dl.google.com/android/repository/sys-img/\(repo)/sys-img2-3.xml"
                guard let url = URL(string: u), let d = try? Data(contentsOf: url),
                      let xml = String(data: d, encoding: .utf8) else { continue }
                let pattern = "<remotePackage path=\"(system-images;android-(\\d+);([^;\"]+);\(abi))\""
                guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
                for m in re.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)) {
                    guard let pr = Range(m.range(at: 1), in: xml),
                          let ar = Range(m.range(at: 2), in: xml),
                          let tr = Range(m.range(at: 3), in: xml),
                          let api = Int(xml[ar]), api >= 30 else { continue }
                    let tag = String(xml[tr])
                    // "_ps16k" 16 KB sayfa boyutlu ozel varyant; normal
                    // kullanimda gereksiz, listeyi sisirmesin.
                    if tag.hasSuffix("ps16k") { continue }
                    out.append(SystemImage(path: String(xml[pr]), api: api, tag: tag, abi: abi))
                }
            }
            let have = Set(self.installedImagePaths())
            out = out.map { var i = $0; i.installed = have.contains(i.path); return i }
                .sorted { $0.api == $1.api ? $0.tag < $1.tag : $0.api > $1.api }
            DispatchQueue.main.async { done(out) }
        }
    }

    /// Diskte kurulu olan imajlarin paket yollari.
    public func installedImagePaths() -> [String] {
        let base = root.appendingPathComponent("system-images", isDirectory: true)
        let f = FileManager.default
        guard let apis = try? f.contentsOfDirectory(atPath: base.path) else { return [] }
        var out: [String] = []
        for api in apis {
            let apiDir = base.appendingPathComponent(api)
            guard let tags = try? f.contentsOfDirectory(atPath: apiDir.path) else { continue }
            for tag in tags {
                guard let abis = try? f.contentsOfDirectory(
                    atPath: apiDir.appendingPathComponent(tag).path) else { continue }
                for abi in abis where !abi.hasPrefix(".") {
                    out.append("system-images;\(api);\(tag);\(abi)")
                }
            }
        }
        return out
    }

    // MARK: - Sanal cihazlar

    public func listAVDs() -> [AVD] {
        let f = FileManager.default
        guard let items = try? f.contentsOfDirectory(atPath: avdHome.path) else { return [] }
        let live = runningAVDNames()
        return items.filter { $0.hasSuffix(".avd") }.compactMap { dir in
            let name = String(dir.dropLast(4))
            let cfg = avdHome.appendingPathComponent("\(dir)/config.ini")
            guard let text = try? String(contentsOf: cfg, encoding: .utf8) else { return nil }
            let kv = Self.parseINI(text)
            let sys = kv["image.sysdir.1"] ?? ""
            let api = Int(sys.split(separator: "/").first(where: { $0.hasPrefix("android-") })?
                .dropFirst("android-".count) ?? "") ?? 0
            var s = AVDSettings()
            s.ramMB = Int(kv["hw.ramSize"] ?? "") ?? s.ramMB
            s.cores = Int(kv["hw.cpu.ncore"] ?? "") ?? s.cores
            s.heapMB = Int(kv["vm.heapSize"] ?? "") ?? s.heapMB
            s.width = Int(kv["hw.lcd.width"] ?? "") ?? s.width
            s.height = Int(kv["hw.lcd.height"] ?? "") ?? s.height
            s.density = Int(kv["hw.lcd.density"] ?? "") ?? s.density
            s.gpuMode = kv["hw.gpu.mode"] ?? s.gpuMode
            s.coldBoot = (kv["fastboot.forceColdBoot"] ?? "no") == "yes"
            s.keyboard = (kv["hw.keyboard"] ?? "yes") == "yes"
            s.cameraBack = kv["hw.camera.back"] ?? s.cameraBack
            s.cameraFront = kv["hw.camera.front"] ?? s.cameraFront
            if let d = kv["disk.dataPartition.size"], d.hasSuffix("G") {
                s.dataPartitionGB = Int(d.dropLast()) ?? s.dataPartitionGB
            }
            if let sd = kv["sdcard.size"], sd.hasSuffix("M") {
                s.sdCardMB = Int(sd.dropLast()) ?? 0
            }
            return AVD(name: name,
                       displayName: kv["avd.ini.displayname"] ?? name,
                       imagePath: sys.replacingOccurrences(of: "/", with: ";")
                           .replacingOccurrences(of: "system-images;", with: "system-images;"),
                       api: api, settings: s, running: live.contains(name))
        }.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    static func parseINI(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let i = line.firstIndex(of: "=") else { continue }
            out[String(line[line.startIndex..<i]).trimmingCharacters(in: .whitespaces)] =
                String(line[line.index(after: i)...]).trimmingCharacters(in: .whitespaces)
        }
        return out
    }

    public func createAVD(name: String, image: SystemImage, settings: AVDSettings) -> String? {
        let safe = Self.safeName(name)
        let r = RawProcess.run(avdmanager,
                               ["create", "avd", "-n", safe, "-k", image.path, "-f",
                                "--abi", image.abi, "--device", "pixel_6"],
                               env: env, timeout: 300)
        guard r.code == 0 else { return "avdmanager: \(r.err.isEmpty ? r.out : r.err)" }
        applySettings(name: safe, displayName: name, settings: settings)
        return nil
    }

    /// Ayarlari `config.ini`'ye yazar.
    public func applySettings(name: String, displayName: String?, settings s: AVDSettings) {
        let cfg = avdHome.appendingPathComponent("\(name).avd/config.ini")
        guard var kv = (try? String(contentsOf: cfg, encoding: .utf8)).map(Self.parseINI)
        else { return }
        kv["hw.ramSize"] = "\(s.ramMB)"
        kv["hw.cpu.ncore"] = "\(s.cores)"
        kv["vm.heapSize"] = "\(s.heapMB)"
        kv["disk.dataPartition.size"] = "\(s.dataPartitionGB)G"
        kv["sdcard.size"] = s.sdCardMB > 0 ? "\(s.sdCardMB)M" : ""
        kv["hw.lcd.width"] = "\(s.width)"
        kv["hw.lcd.height"] = "\(s.height)"
        kv["hw.lcd.density"] = "\(s.density)"
        kv["hw.gpu.enabled"] = s.gpuMode == "off" ? "no" : "yes"
        kv["hw.gpu.mode"] = s.gpuMode
        kv["fastboot.forceColdBoot"] = s.coldBoot ? "yes" : "no"
        kv["hw.keyboard"] = s.keyboard ? "yes" : "no"
        kv["hw.camera.back"] = s.cameraBack
        kv["hw.camera.front"] = s.cameraFront
        if let d = displayName { kv["avd.ini.displayname"] = d }
        let text = kv.keys.sorted().map { "\($0)=\(kv[$0] ?? "")" }.joined(separator: "\n") + "\n"
        try? text.write(to: cfg, atomically: true, encoding: .utf8)
    }

    public func rename(_ avd: AVD, to newDisplayName: String) {
        applySettings(name: avd.name, displayName: newDisplayName, settings: avd.settings)
    }

    public func clone(_ avd: AVD, as newName: String) -> String? {
        let safe = Self.safeName(newName)
        let f = FileManager.default
        let src = avdHome.appendingPathComponent("\(avd.name).avd")
        let dst = avdHome.appendingPathComponent("\(safe).avd")
        guard !f.fileExists(atPath: dst.path) else { return "clone.exists" }
        do {
            try f.copyItem(at: src, to: dst)
            // .ini dosyasi ve config icindeki yollar yeni ada gore guncellenmeli.
            let srcIni = avdHome.appendingPathComponent("\(avd.name).ini")
            if var t = try? String(contentsOf: srcIni, encoding: .utf8) {
                t = t.replacingOccurrences(of: "\(avd.name).avd", with: "\(safe).avd")
                try t.write(to: avdHome.appendingPathComponent("\(safe).ini"),
                            atomically: true, encoding: .utf8)
            }
            let cfg = dst.appendingPathComponent("config.ini")
            if var t = try? String(contentsOf: cfg, encoding: .utf8) {
                t = t.replacingOccurrences(of: "AvdId=\(avd.name)", with: "AvdId=\(safe)")
                     .replacingOccurrences(of: "avd.ini.displayname=\(avd.displayName)",
                                           with: "avd.ini.displayname=\(newName)")
                try t.write(to: cfg, atomically: true, encoding: .utf8)
            }
        } catch { return "\(error)" }
        return nil
    }

    public func delete(_ avd: AVD) {
        _ = RawProcess.run(avdmanager, ["delete", "avd", "-n", avd.name], env: env, timeout: 120)
        try? FileManager.default.removeItem(at: avdHome.appendingPathComponent("\(avd.name).avd"))
        try? FileManager.default.removeItem(at: avdHome.appendingPathComponent("\(avd.name).ini"))
    }

    /// Emulatoru EN YUKSEK PERFORMANS ayarlariyla baslatir.
    @discardableResult
    public func start(_ avd: AVD) -> RawProcess.Handle? {
        var args = ["-avd", avd.name,
                    "-gpu", avd.settings.gpuMode,
                    "-memory", "\(avd.settings.ramMB)",
                    "-cores", "\(avd.settings.cores)",
                    // Onyukleme animasyonu ve ag gecikmesi bosuna zaman;
                    // kapatinca acilis gozle gorulur hizlaniyor.
                    "-no-boot-anim", "-netdelay", "none", "-netspeed", "full"]
        if avd.settings.accelerated && Self.hardwareAccelerated {
            args += ["-accel", "on"]
        } else {
            args += ["-accel", "off"]
        }
        if avd.settings.coldBoot { args += ["-no-snapshot-load"] }

        var handle: RawProcess.Handle?
        DispatchQueue.global().async { [self] in
            _ = RawProcess.runStreaming(emulatorBin, args, env: env,
                                        onHandle: { handle = $0 }, timeout: 86400)
        }
        return handle
    }

    /// Calisan emulator ornekleri (`emulator-5554` gibi).
    public func runningAVDNames() -> [String] {
        let r = RawProcess.run("/bin/ps", ["-Ao", "command"], timeout: 15)
        var out: [String] = []
        for line in r.out.split(separator: "\n") where line.contains("qemu-system")
                                                    || line.contains("/emulator/emulator") {
            if let i = line.range(of: "-avd ") {
                let rest = line[i.upperBound...]
                out.append(String(rest.split(separator: " ").first ?? ""))
            }
        }
        return out
    }

    public func stop(_ avd: AVD) {
        _ = RawProcess.run("/usr/bin/pkill", ["-f", "-avd \(avd.name)"], timeout: 15)
    }

    public static func safeName(_ s: String) -> String {
        let ok = s.map { ch -> Character in
            ch.isLetter || ch.isNumber || ch == "_" || ch == "." || ch == "-" ? ch : "_"
        }
        let v = String(ok).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return v.isEmpty ? "avd" : v
    }
}
