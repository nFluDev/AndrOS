import Foundation

/// Cihazdan veri okuma katmani (adb `content query` ve `ls` uzerinden).
///
/// Olculdu (realme RMX2040 / Android 11, shell UID):
///  - SMS      : okunabiliyor
///  - Kisiler  : okunabiliyor
///  - Medya    : MediaStore okunabiliyor
///  - Dosyalar : ls / pull / push calisiyor
///  - Arama gecmisi: ENGELLI (CallLogProvider SecurityException) -> companion app gerekli
public struct AndroidData {

    /// Eslestirilmis mobil uygulama baglantisi.
    ///
    /// Varsa moduller ONCE bunu deniyor: arama gecmisi ve SMS gonderme
    /// adb ile HIC mumkun degil, uygulama adlari ve simgeleri de yalniz
    /// buradan duzgun geliyor. Yoksa her sey eskisi gibi adb ile calisiyor.
    public var companion: CompanionBridge?


    public let adb: ADB
    public init(adb: ADB) { self.adb = adb }

    // MARK: - `content query` ciktisi cozumleme

    /// Cikti sekli: `Row: 0 key=deger, key2=deger2`
    ///
    /// Dikkat: degerlerin ICINDE ", " gecebiliyor (SMS govdesi gibi), bu yuzden
    /// duz split ile ayirmak bozuluyor. Anahtar konumlarini bulup aralarini
    /// deger olarak aliyoruz.
    static func parseRows(_ output: String, keys: [String]) -> [[String: String]] {
        var rows: [[String: String]] = []
        for line in output.split(separator: "\n") {
            guard line.hasPrefix("Row:") else { continue }
            let s = String(line)
            // Her anahtarin "key=" olarak gectigi yerleri bul
            var hits: [(key: String, range: Range<String.Index>)] = []
            for k in keys {
                var search = s.startIndex..<s.endIndex
                while let r = s.range(of: "\(k)=", range: search) {
                    // Anahtarin basi ya satir basi ya da ", " sonrasi olmali
                    let before = s.index(before: r.lowerBound)
                    let ok = r.lowerBound == s.startIndex || s[before] == " "
                    if ok { hits.append((k, r)) }
                    search = r.upperBound..<s.endIndex
                }
            }
            guard !hits.isEmpty else { continue }
            hits.sort { $0.range.lowerBound < $1.range.lowerBound }

            var row: [String: String] = [:]
            for (i, h) in hits.enumerated() {
                let valueStart = h.range.upperBound
                let valueEnd = i + 1 < hits.count
                    ? hits[i + 1].range.lowerBound : s.endIndex
                var v = String(s[valueStart..<valueEnd])
                if v.hasSuffix(", ") { v = String(v.dropLast(2)) }
                if v.hasSuffix(",") { v = String(v.dropLast()) }
                row[h.key] = v.trimmingCharacters(in: .whitespaces)
            }
            rows.append(row)
        }
        return rows
    }

    private func query(uri: String, projection: [String],
                       sort: String? = nil, limit: Int? = nil) -> [[String: String]] {
        var args = ["shell", "content", "query", "--uri", uri,
                    "--projection", projection.joined(separator: ":")]
        if let s = sort { args += ["--sort", "\"\(s)\""] }
        _ = limit
        guard let out = try? adb.checked(args, timeout: 30) else { return [] }
        if out.contains("SecurityException") || out.contains("Error while accessing") { return [] }
        return AndroidData.parseRows(out, keys: projection)
    }

    // MARK: - SMS

    public struct Message: Identifiable {
        public let id: String
        public let threadID: String
        public let address: String
        public let body: String
        public let date: Date
        /// 1 = gelen, 2 = giden
        public let incoming: Bool
    }

    public struct Conversation: Identifiable {
        public var id: String { threadID }
        public let threadID: String
        public var address: String
        public var displayName: String?
        public var messages: [Message]

        public init(threadID: String, address: String,
                    displayName: String? = nil, messages: [Message] = []) {
            self.threadID = threadID; self.address = address
            self.displayName = displayName; self.messages = messages
        }

        public var last: Message? { messages.last }
        public var title: String { displayName ?? address }
    }

    public func messages(limit: Int = 600) -> [Message] {
        let rows = query(uri: "content://sms",
                         projection: ["_id", "thread_id", "address", "body", "date", "type"],
                         sort: "date DESC")
        return rows.prefix(limit).compactMap { r in
            guard let id = r["_id"], let body = r["body"] else { return nil }
            let ms = Double(r["date"] ?? "0") ?? 0
            return Message(id: id,
                           threadID: r["thread_id"] ?? "0",
                           address: r["address"] ?? "?",
                           body: body,
                           date: Date(timeIntervalSince1970: ms / 1000),
                           incoming: (r["type"] ?? "1") == "1")
        }
    }

    /// Mesajlari sohbetlere grupla, kisi adlariyla eslestir.
    public func conversations(contacts: [Contact] = []) -> [Conversation] {
        let msgs = messages()
        var byThread: [String: [Message]] = [:]
        for m in msgs { byThread[m.threadID, default: []].append(m) }

        // Numara -> isim haritasi (son 9 hane ile eslestir: format farklari olur)
        var nameByTail: [String: String] = [:]
        for c in contacts {
            let tail = AndroidData.tail(c.number)
            if !tail.isEmpty { nameByTail[tail] = c.name }
        }

        return byThread.map { tid, list in
            let sorted = list.sorted { $0.date < $1.date }
            let addr = sorted.last?.address ?? "?"
            return Conversation(threadID: tid, address: addr,
                                displayName: nameByTail[AndroidData.tail(addr)],
                                messages: sorted)
        }
        .sorted { ($0.last?.date ?? .distantPast) > ($1.last?.date ?? .distantPast) }
    }

    /// Numaralari karsilastirmak icin son 9 hane (ulke kodu/bosluk farklarini yutar).
    static func tail(_ number: String) -> String {
        let digits = number.filter(\.isNumber)
        return String(digits.suffix(9))
    }

    // MARK: - Kisiler

    public struct Contact: Identifiable, Hashable {
        public var id: String { name + number }
        public let name: String
        public let number: String
    }

    public func contacts() -> [Contact] {
        let rows = query(uri: "content://com.android.contacts/data/phones",
                         projection: ["display_name", "data1"])
        var seen = Set<String>()
        var out: [Contact] = []
        for r in rows {
            guard let n = r["display_name"], let num = r["data1"] else { continue }
            let key = n + AndroidData.tail(num)
            if seen.contains(key) { continue }
            seen.insert(key)
            out.append(Contact(name: n, number: num))
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Medya

    public struct MediaItem: Identifiable, Hashable {
        public var id: String { path }
        /// MediaStore kimligi — video kucuk resmi bununla aliniyor.
        public let mediaID: String
        public let name: String
        public let path: String
        public let size: Int
        public let isVideo: Bool
        public let date: Date
    }

    public func media(videos: Bool = false, limit: Int = 400) -> [MediaItem] {
        let uri = videos ? "content://media/external/video/media"
                         : "content://media/external/images/media"
        // Video tablosunda `duration` da istiyoruz: Android MIME turunu yalniz
        // UZANTIYA bakarak atadigi icin ".ts" gibi dosyalar "video/mp2ts"
        // sayilip listeye giriyor — oysa bunlar TypeScript kaynak dosyalari
        // (olculdu: enum.effect.ts 57 KB, gli.keys.ts 503 B, core.ts 10 KB;
        // ucunde de duration/width/height NULL). Gercek videolarin suresi
        // her zaman dolu, o yuzden suresiz satirlari eliyoruz.
        var cols = ["_id", "_display_name", "_data", "_size", "date_modified"]
        if videos { cols.append("duration") }
        let rows = query(uri: uri, projection: cols, sort: "date_modified DESC")
        return rows.prefix(limit).compactMap { r in
            guard let n = r["_display_name"], let p = r["_data"] else { return nil }
            if videos, (Int(r["duration"] ?? "") ?? 0) <= 0 { return nil }
            return MediaItem(mediaID: r["_id"] ?? "", name: n, path: p,
                             size: Int(r["_size"] ?? "0") ?? 0,
                             isVideo: videos,
                             date: Date(timeIntervalSince1970: Double(r["date_modified"] ?? "0") ?? 0))
        }
    }

    // MARK: - Muzik

    public struct Track: Identifiable, Hashable {
        public var id: String { path }
        public let title: String
        public let artist: String
        public let album: String
        public let albumID: String
        public let path: String
        public let name: String
        /// Milisaniye
        public let duration: Int
        public let size: Int

        public var durationText: String {
            let s = duration / 1000
            return String(format: "%d:%02d", s / 60, s % 60)
        }
    }

    public func tracks(limit: Int = 500) -> [Track] {
        let rows = query(uri: "content://media/external/audio/media",
                         projection: ["_display_name", "_data", "title", "artist",
                                      "album", "album_id", "duration", "_size"],
                         sort: "title ASC")
        return rows.prefix(limit).compactMap { r in
            guard let p = r["_data"], let n = r["_display_name"] else { return nil }
            // Cok kisa kayitlar zil sesi/bildirim olabiliyor
            let dur = Int(r["duration"] ?? "0") ?? 0
            guard dur > 20_000 else { return nil }
            return Track(title: r["title"] ?? n,
                         artist: r["artist"] ?? "Bilinmeyen",
                         album: r["album"] ?? "",
                         albumID: r["album_id"] ?? "",
                         path: p, name: n, duration: dur,
                         size: Int(r["_size"] ?? "0") ?? 0)
        }
    }

    /// Video kucuk resmini cihazdan alir — VIDEOYU INDIRMEDEN.
    ///
    /// `content read .../video/media/<id>/thumbnail` MediaStore'un urettigi
    /// kucuk resmi veriyor (~24 KB). Videoyu cekip kare cikarmak gereksiz.
    public func videoThumb(mediaID: String, cacheDir: URL) -> URL? {
        guard !mediaID.isEmpty else { return nil }
        let local = cacheDir.appendingPathComponent("vid_\(mediaID).jpg")
        if FileManager.default.fileExists(atPath: local.path) { return local }
        let miss = cacheDir.appendingPathComponent("vid_\(mediaID).miss")
        if FileManager.default.fileExists(atPath: miss.path) { return nil }
        var args = adb.serial.map { ["-s", $0] } ?? []
        args += ["exec-out", "content", "read",
                 "--uri", "content://media/external/video/media/\(mediaID)/thumbnail"]
        guard RawProcess.runToFile(adb.path, args, output: local.path),
              Self.isImage(local) else {
            try? FileManager.default.removeItem(at: local)
            FileManager.default.createFile(atPath: miss.path, contents: nil)
            return nil
        }
        return local
    }

    /// Album kapagini cihazdan alir — SARKIYI INDIRMEDEN.
    ///
    /// `content read` MediaStore'un kapak akisini veriyor (~40 KB), boylece
    /// liste kucuk resimleri icin 8 MB'lik mp3 indirmeye gerek kalmiyor.
    /// Dosyanin GERCEKTEN resim olup olmadigini imzasindan anlar.
    ///
    /// Neden gerekli: kucuk resmi olmayan bir video icin `content read`
    /// cikis kodu 0 veriyor ama stdout'a "Error while accessing provider:..."
    /// metnini basiyor. 644 bayt oldugu icin boyut kontrolunu geciyor ve
    /// bozuk bir "jpg" onbellege giriyordu. Imzaya bakmak sart.
    static func isImage(_ url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url),
              let head = try? fh.read(upToCount: 8) else { return false }
        try? fh.close()
        let b = [UInt8](head)
        guard b.count >= 4 else { return false }
        if b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return true }            // JPEG
        if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return true } // PNG
        if b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 { return true }            // GIF
        if b.count >= 8, b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46 { return true } // WEBP
        return false
    }

    public func albumArt(albumID: String, cacheDir: URL) -> URL? {
        guard !albumID.isEmpty, albumID != "0" else { return nil }
        let local = cacheDir.appendingPathComponent("alb_\(albumID).jpg")
        if FileManager.default.fileExists(atPath: local.path) { return local }
        // Daha once denenip cikmadiysa tekrar ugrasmayalim.
        let miss = cacheDir.appendingPathComponent("alb_\(albumID).miss")
        if FileManager.default.fileExists(atPath: miss.path) { return nil }
        var args = adb.serial.map { ["-s", $0] } ?? []
        args += ["exec-out", "content", "read",
                 "--uri", "content://media/external/audio/albumart/\(albumID)"]
        guard RawProcess.runToFile(adb.path, args, output: local.path),
              Self.isImage(local) else {
            try? FileManager.default.removeItem(at: local)
            FileManager.default.createFile(atPath: miss.path, contents: nil)
            return nil
        }
        return local
    }

    // MARK: - Uygulama ikonu

    /// Uygulamanin baslatici ikonunu cikarir.
    ///
    /// Neden cihazda cikariyoruz: APK'lar 100 MB olabiliyor ama ikon 20-70 KB.
    /// Cihazdaki `unzip` ile YALNIZ ikonu ayikliyoruz, sonra o kucuk dosyayi
    /// cekiyoruz. APK'yi butun halinde indirmek sacma olurdu.
    public func appIcon(_ package: String, cacheDir: URL) -> URL? {
        let safe = package.replacingOccurrences(of: ".", with: "_")
        // Onbellek
        for ext in ["png", "webp"] {
            let c = cacheDir.appendingPathComponent("\(safe).\(ext)")
            if FileManager.default.fileExists(atPath: c.path) { return c }
        }
        guard let pathOut = try? adb.checked(["shell", "pm", "path", package]),
              let apkLine = pathOut.split(separator: "\n").first else { return nil }
        let apk = String(apkLine).replacingOccurrences(of: "package:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apk.isEmpty else { return nil }

        guard let listing = try? adb.checked(
            ["shell", "unzip", "-l", "'\(apk)'"], timeout: 30) else { return nil }

        // Adaylari topla: bazi uygulamalarda ic_launcher bir XML (adaptive
        // icon) oluyor ve resim dosyasi baska adla duruyor. Bu yuzden sadece
        // ic_launcher aramak yetmiyordu; bazi ikonlar hic bulunamiyordu.
        var candidates: [String] = []
        for line in listing.split(separator: "\n") {
            let l = String(line)
            guard let r = l.range(of: "res/") else { continue }
            let p = String(l[r.lowerBound...]).trimmingCharacters(in: .whitespaces)
            guard p.hasSuffix(".png") || p.hasSuffix(".webp") else { continue }
            let low = p.lowercased()
            guard low.contains("mipmap") || low.contains("drawable") else { continue }
            guard low.contains("launcher") || low.contains("ic_icon")
               || low.contains("app_icon") || low.contains("/icon") else { continue }
            guard !low.contains("_background"), !low.contains("notification"),
                  !low.contains("_bg") else { continue }
            candidates.append(p)
        }
        guard !candidates.isEmpty else { return nil }

        /// Once en yuksek yogunluk, sonra "round" olmayan, sonra foreground.
        func score(_ p: String) -> Int {
            let l = p.lowercased()
            var s = 0
            for (i, d) in ["xxxhdpi", "xxhdpi", "xhdpi", "hdpi", "mdpi"].enumerated()
            where l.contains(d) { s += (5 - i) * 10; break }
            if l.contains("ic_launcher") { s += 8 }
            if l.contains("round") { s -= 4 }
            if l.contains("_foreground") { s -= 2 }   // son care: adaptive on katman
            return s
        }
        let iconPath = candidates.max { score($0) < score($1) }!

        let tmpDir = "/data/local/tmp/andros_ico"
        _ = try? adb.run(["shell", "rm", "-rf", tmpDir])
        _ = try? adb.run(["shell", "unzip", "-o", "-d", tmpDir, "'\(apk)'", "'\(iconPath)'"],
                         timeout: 30)
        let ext = (iconPath as NSString).pathExtension
        let local = cacheDir.appendingPathComponent("\(safe).\(ext)")
        guard pull("\(tmpDir)/\(iconPath)", to: local.path) else { return nil }
        _ = try? adb.run(["shell", "rm", "-rf", tmpDir])
        return FileManager.default.fileExists(atPath: local.path) ? local : nil
    }

    // MARK: - Dosyalar

    public struct FileEntry: Identifiable, Hashable {
        public var id: String { path }
        public let name: String
        public let path: String
        public let isDirectory: Bool
        public let size: Int

        public init(name: String, path: String, isDirectory: Bool, size: Int) {
            self.name = name; self.path = path
            self.isDirectory = isDirectory; self.size = size
        }
    }

    public func list(_ path: String) -> [FileEntry] {
        // -p: dizinlerin sonuna / ekler, -L: sembolik baglantiyi izler,
        // -A: NOKTALI (gizli) dosyalar da gelsin — "." ve ".." haric.
        // Gizlileri gosterip gostermemeye panel karar veriyor (Finder gibi);
        // veri katmani hepsini dondurur.
        guard let out = try? adb.checked(["shell", "ls", "-lLpA", "\"\(path)\""],
                                         timeout: 30) else { return [] }
        var entries: [FileEntry] = []
        for line in out.split(separator: "\n") {
            let s = String(line)
            if s.hasPrefix("total ") || s.contains("Permission denied") { continue }
            // drwxr-xr-x 2 root root 4096 2026-01-01 12:00 isim/
            let parts = s.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 8 else { continue }
            let name = parts[7...].joined(separator: " ")
            guard !name.isEmpty, name != ".", name != ".." else { continue }
            let isDir = name.hasSuffix("/") || s.hasPrefix("d")
            let clean = isDir && name.hasSuffix("/") ? String(name.dropLast()) : name
            let full = path.hasSuffix("/") ? path + clean : path + "/" + clean
            entries.append(FileEntry(name: clean, path: full,
                                     isDirectory: isDir,
                                     size: Int(parts[4]) ?? 0))
        }
        return entries.sorted {
            $0.isDirectory != $1.isDirectory ? $0.isDirectory
                : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// adb ile indirme — YALNIZ geri dusus.
    ///
    /// Asil yol `pull(_:to:)`, o da eslesmis uygulamayi tercih ediyor
    /// (bkz. CompanionBridge). Bu ayrim onemli: kullanici hata
    /// ayiklamayi kapatip kabloyu cikardiginda adb yok ve DOGRUDAN
    /// adb cagiran her yer sessizce basarisiz oluyordu — surukle
    /// birak, resim acma, kopyalama, APK cikarma… hepsi.
    ///
    /// HAM surec kullaniliyor: Foundation'in Process'i Unicode
    /// normalizasyonunu bozdugu icin Turkce/Kiril adli dosyalar
    /// "No such file or directory" veriyordu. Bkz. RawProcess.
    @discardableResult
    public func pullViaADB(_ remote: String, to local: String) -> Bool {
        guard adb.hasDevice else { return false }
        var args = adb.serial.map { ["-s", $0] } ?? []
        args += ["pull", remote, local]
        return RawProcess.run(adb.path, args).code == 0
    }

    @discardableResult
    public func pushViaADB(_ local: String, to remote: String) -> Bool {
        guard adb.hasDevice else { return false }
        var args = adb.serial.map { ["-s", $0] } ?? []
        args += ["push", local, remote]
        return RawProcess.run(adb.path, args).code == 0
    }

    // MARK: - Yetenek tespiti

    public struct Capabilities {
        public var sms = false
        public var contacts = false
        public var media = false
        public var files = false
        public var callLog = false
        public init() {}
    }

    /// Hangi modullerin gercekten calisacagini olcer (tahmin etmez).
    public func probe() -> Capabilities {
        var c = Capabilities()
        c.sms = !query(uri: "content://sms/inbox", projection: ["_id"]).isEmpty
        c.contacts = !query(uri: "content://com.android.contacts/data/phones",
                            projection: ["display_name"]).isEmpty
        c.media = !query(uri: "content://media/external/images/media",
                         projection: ["_display_name"]).isEmpty
        c.files = !list("/sdcard").isEmpty
        c.callLog = !query(uri: "content://call_log/calls", projection: ["_id"]).isEmpty
        return c
    }
}
