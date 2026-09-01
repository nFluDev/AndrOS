import Foundation

/// `CompanionLink`'in ES ZAMANLI (senkron) sarmalayicisi.
///
/// Paneller veri katmanini arka plan kuyruklarindan senkron cagiriyor
/// (`AndroidData.contacts()` gibi). Baglantiyi asenkron birakip her
/// paneli yeniden yazmak yerine burada bekletiyoruz — cagrilar zaten
/// ana is parcacigi disinda oldugu icin arayuz donmuyor.
public final class CompanionBridge {
    let link: CompanionLink
    public init(_ link: CompanionLink) { self.link = link }

    public var isReady: Bool { link.state == .ready }
    /// Telefonun adresi — akis URL'i icin.
    public var host: String? { link.remoteHost }

    /// Yaniti bekleyerek doner. Zaman asiminda `nil`.
    /// Son hatanin metni — kullaniciya gercek nedeni gosterebilmek icin.
    public private(set) var lastError: String?

    public func call(_ op: String, _ args: [String: Any] = [:],
                     timeout: TimeInterval = 20) -> [String: Any]? {
        let sem = DispatchSemaphore(value: 0)
        var result: [String: Any]?
        link.request(op, args) { [weak self] data, err in
            if err == nil { result = data }
            else {
                self?.lastError = err
                Log.write("companion \(op): \(err ?? "?")")
            }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + timeout)
        return result
    }

    /// Dizi donen uclar icin kisayol.
    public func array(_ op: String, _ key: String,
                      _ args: [String: Any] = [:]) -> [[String: Any]] {
        (call(op, args)?[key] as? [[String: Any]]) ?? []
    }
}

// MARK: - Veri katmani: eslesmisse UYGULAMA, degilse adb

public extension AndroidData {

    /// Kisiler.
    /// Son basarisizligin sebebi (izin yok, baglanti yok…). Paneller
    /// bos liste yerine NE OLDUGUNU gosterebilsin diye.
    static var lastFailure: String?

    func contactsPreferringApp() -> [Contact] {
        guard let b = companion, b.isReady else {
            Self.lastFailure = "notconnected"
            return contacts()
        }
        let rows = b.array("contacts.list", "contacts", ["limit": 2000])
        guard !rows.isEmpty else {
            // `permission` hatasi eksik iznin ADINI da tasiyor.
            Self.lastFailure = b.lastError ?? "empty"
            return contacts()
        }
        Self.lastFailure = nil
        var seen = Set<String>()
        return rows.compactMap { r in
            guard let name = r["name"] as? String, let num = r["number"] as? String
            else { return nil }
            guard seen.insert(name + num).inserted else { return nil }
            return Contact(name: name, number: num)
        }
    }

    /// SMS sohbetleri.
    func conversationsPreferringApp(contacts known: [Contact] = []) -> [Conversation] {
        guard let b = companion, b.isReady else { return conversations(contacts: known) }
        let convs = b.array("sms.conversations", "conversations", ["limit": 200])
        guard !convs.isEmpty else { return conversations(contacts: known) }
        let byNumber = Dictionary(known.map { ($0.number.filter(\.isNumber).suffix(9), $0.name) },
                                  uniquingKeysWith: { a, _ in a })
        return convs.compactMap { c in
            let thread = "\(c["threadId"] as? Int ?? 0)"
            let address = c["address"] as? String ?? ""
            let msgs = b.array("sms.thread", "messages",
                               ["threadId": c["threadId"] as? Int ?? 0, "limit": 500])
                .map { m in
                    Message(id: UUID().uuidString, threadID: thread,
                            address: m["address"] as? String ?? address,
                            body: m["body"] as? String ?? "",
                            date: Date(timeIntervalSince1970:
                                        (m["date"] as? Double ?? 0) / 1000),
                            incoming: m["incoming"] as? Bool ?? true)
                }
                .sorted { $0.date < $1.date }
            let key = address.filter(\.isNumber).suffix(9)
            return Conversation(threadID: thread, address: address,
                                displayName: byNumber[key], messages: msgs)
        }
    }

    /// SMS GONDERME — adb ile hic mumkun degildi.
    /// @return hata metni; `nil` ise gonderildi.
    func sendSMS(to address: String, body: String) -> String? {
        guard let b = companion, b.isReady else { return "notpaired" }
        guard b.call("sms.send", ["address": address, "body": body]) != nil else {
            return b.lastError ?? "sendfailed"
        }
        return nil
    }

    public struct CallEntry: Identifiable, Hashable {
        public var id: String { number + "\(date.timeIntervalSince1970)" }
        public let number: String
        public let name: String
        /// incoming | outgoing | missed | rejected | blocked | other
        public let kind: String
        public let date: Date
        public let duration: Int
    }

    /// Arama gecmisi — YALNIZ uygulama ile mumkun. Android, arama kaydi
    /// saglayicisini adb kabuguna kapatiyor (SecurityException).
    func callLog() -> [CallEntry] {
        guard let b = companion, b.isReady else { return [] }
        return b.array("calls.list", "calls", ["limit": 500]).map { c in
            CallEntry(number: c["number"] as? String ?? "",
                      name: c["name"] as? String ?? "",
                      kind: c["type"] as? String ?? "other",
                      date: Date(timeIntervalSince1970: (c["date"] as? Double ?? 0) / 1000),
                      duration: c["duration"] as? Int ?? 0)
        }
    }

    /// Yuklu uygulamalar — GERCEK adlariyla.
    /// adb yalniz paket adini veriyordu ("com.ark.mzxqteq.gp").
    func appsPreferringApp(includeSystem: Bool) -> [(package: String, label: String)]? {
        guard let b = companion, b.isReady else { return nil }
        let rows = b.array("apps.list", "apps", ["system": includeSystem])
        guard !rows.isEmpty else { return nil }
        return rows.compactMap { r in
            guard let p = r["package"] as? String else { return nil }
            return (p, r["label"] as? String ?? p)
        }
    }

    /// Uygulama simgesi — APK indirmeden, dogrudan PNG.
    func appIconPreferringApp(_ package: String, cacheDir: URL) -> URL? {
        guard let b = companion, b.isReady else { return appIcon(package, cacheDir: cacheDir) }
        let local = cacheDir.appendingPathComponent("app_\(package).png")
        if FileManager.default.fileExists(atPath: local.path) { return local }
        guard let d = b.call("apps.icon", ["package": package]),
              let b64 = d["png"] as? String,
              let bytes = Data(base64Encoded: b64), bytes.count > 64 else {
            return appIcon(package, cacheDir: cacheDir)
        }
        try? bytes.write(to: local)
        return local
    }

    /// Muzik listesi.
    func tracksPreferringApp(limit: Int = 2000) -> [Track] {
        guard let b = companion, b.isReady else { return tracks() }
        let rows = b.array("music.tracks", "tracks", ["limit": limit])
        guard !rows.isEmpty else { return tracks() }
        // Yol MUTLAK mi? Degilse indirme telefonda reddediliyor.
        if let first = rows.first?["path"] as? String {
            Log.write("muzik yolu örneği: \(first)")
        } else {
            Log.write("muzik: telefon YOL göndermiyor (eski sürüm?)")
        }
        return rows.compactMap { r in
            guard let title = r["title"] as? String else { return nil }
            return Track(title: title,
                         artist: r["artist"] as? String ?? "",
                         album: r["album"] as? String ?? "",
                         albumID: "\(r["albumId"] as? Int ?? 0)",
                         // MUTLAK yol; telefon vermiyorsa (eski surum)
                         // ada duseriz ama indirme calismaz.
                         path: (r["path"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                               ?? (r["name"] as? String ?? title),
                         name: r["name"] as? String ?? title,
                         duration: r["duration"] as? Int ?? 0,
                         size: r["size"] as? Int ?? 0)
        }
    }

    /// Album kapagi — ONCE UYGULAMA, sonra adb.
    /// Album kapagi.
    ///
    /// Parcanin YOLU da gonderiliyor: bircok parcada MediaStore'da album
    /// kapagi yok ama dosyanin icinde gomulu kapak var. Album kimligi
    /// bos ya da 0 olan parcalar (ColorOS'ta sik) yalniz bu yolla kapak
    /// alabiliyor.
    func albumArtPreferringApp(albumID: String, trackPath: String = "",
                               cacheDir: URL) -> URL? {
        // Onbellek anahtari: album varsa album, yoksa parcanin kendisi.
        let key = (Int(albumID) ?? 0) > 0
            ? "album-\(albumID)"
            : "track-\(abs(trackPath.hashValue))"
        let local = cacheDir.appendingPathComponent("\(key).jpg")
        if FileManager.default.fileExists(atPath: local.path) { return local }
        if let b = companion, b.isReady {
            var args: [String: Any] = ["px": 256, "path": trackPath]
            args["albumId"] = Int(albumID) ?? 0
            if let d = b.call("music.artwork", args),
               let b64 = d["jpeg"] as? String,
               let data = Data(base64Encoded: b64), data.count > 512 {
                try? FileManager.default.createDirectory(at: cacheDir,
                                                         withIntermediateDirectories: true)
                try? data.write(to: local)
                return local
            }
        }
        return albumArt(albumID: albumID, cacheDir: cacheDir)
    }

    /// Dosya listesi.
    func listPreferringApp(_ path: String) -> [FileEntry] {
        guard let b = companion, b.isReady else { return list(path) }
        guard let d = b.call("files.list", ["path": path]),
              let rows = d["entries"] as? [[String: Any]] else { return list(path) }
        return rows.compactMap { r in
            guard let name = r["name"] as? String, let p = r["path"] as? String
            else { return nil }
            return FileEntry(name: name, path: p,
                             isDirectory: r["dir"] as? Bool ?? false,
                             size: r["size"] as? Int ?? 0)
        }
    }

    /// Klasor olustur. Uygulama varsa ONDAN — adb'siz de calissin.
    func mkdirPreferringApp(_ path: String) -> Bool {
        if let b = companion, b.isReady, b.call("files.mkdir", ["path": path]) != nil {
            return true
        }
        return (try? adb.run(["shell", "mkdir", "-p", "\"\(path)\""]))?.code == 0
    }

    /// Dosya/klasor sil.
    func deletePreferringApp(_ path: String) -> Bool {
        if let b = companion, b.isReady, b.call("files.delete", ["path": path]) != nil {
            return true
        }
        return (try? adb.run(["shell", "rm", "-rf", "\"\(path)\""]))?.code == 0
    }

    /// Tasi / yeniden adlandir.
    func movePreferringApp(_ from: String, _ to: String) -> Bool {
        if let b = companion, b.isReady,
           b.call("files.move", ["from": from, "to": to]) != nil { return true }
        return (try? adb.run(["shell", "mv", "\"\(from)\"", "\"\(to)\""]))?.code == 0
    }

    /// Dosyayi indir — eslesmisse UYGULAMA ile, yoksa adb ile.
    ///
    /// Uygulama yolu SIRALI: blok alicisi tek, es zamanli indirme
    /// verileri karistirir. Sirayi burada tutuyoruz.
    private static let pullGate = DispatchQueue(label: "dev.naer.andros.pull")

    func pullPreferringApp(_ remote: String, to local: String,
                           progress: ((Int, Int) -> Void)? = nil) -> Bool {
        pull(remote, to: local, progress: progress)
    }

    /// Dosyayi indir. ONCE UYGULAMA, sonra adb.
    ///
    /// Butun cagri yerleri (surukle birak, resim acma, kopyalama, APK
    /// cikarma, muzik) bunu kullaniyor. Eskiden hepsi dogrudan adb
    /// cagiriyordu ve hata ayiklama kapaliyken sessizce basarisiz
    /// oluyordu.
    @discardableResult
    func pull(_ remote: String, to local: String,
              progress: ((Int, Int) -> Void)? = nil) -> Bool {
        if let b = companion, b.isReady {
            let ok = Self.pullGate.sync { () -> Bool in
                let sem = DispatchSemaphore(value: 0)
                var done = false
                b.link.downloadFile(path: remote, to: local, progress: progress) { r in
                    done = r; sem.signal()
                }
                _ = sem.wait(timeout: .now() + 600)
                return done
            }
            if ok { return true }
        }
        // Uygulama yolu yoksa ya da basarisizsa adb'yi dene.
        return pullViaADB(remote, to: local)
    }

    /// Dosya yukle. ONCE UYGULAMA, sonra adb.
    @discardableResult
    func push(_ local: String, to remoteDir: String) -> Bool {
        if let b = companion, b.isReady {
            let name = (local as NSString).lastPathComponent
            let target = remoteDir.hasSuffix("/") ? remoteDir + name
                                                  : remoteDir + "/" + name
            if b.link.uploadFileSync(local: local, to: target) { return true }
        }
        return pushViaADB(local, to: remoteDir)
    }

    /// Galeri ogeleri.
    func mediaPreferringApp(videos: Bool, limit: Int = 500) -> [MediaItem] {
        guard let b = companion, b.isReady else { return media(videos: videos, limit: limit) }
        let rows = b.array(videos ? "media.videos" : "media.images", "items",
                           ["limit": limit])
        guard !rows.isEmpty else { return media(videos: videos, limit: limit) }
        return rows.compactMap { r in
            guard let name = r["name"] as? String else { return nil }
            let id = "\(r["id"] as? Int ?? 0)"
            return MediaItem(mediaID: id,
                             name: name,
                             path: r["path"] as? String ?? name,
                             size: r["size"] as? Int ?? 0,
                             isVideo: videos,
                             date: Date(timeIntervalSince1970: r["date"] as? Double ?? 0))
        }
    }

    /// Kucuk resim — dosyayi indirmeden.
    func thumbnailPreferringApp(mediaID: String, video: Bool, cacheDir: URL) -> URL? {
        guard let b = companion, b.isReady, let n = Int(mediaID) else { return nil }
        let local = cacheDir.appendingPathComponent("t_\(video ? "v" : "i")\(mediaID).jpg")
        if FileManager.default.fileExists(atPath: local.path) { return local }
        guard let d = b.call("media.thumbnail",
                             ["mediaId": n, "video": video, "px": 256]),
              let b64 = d["jpeg"] as? String,
              let bytes = Data(base64Encoded: b64), bytes.count > 256 else { return nil }
        try? bytes.write(to: local)
        return local
    }

    /// Dosyayi INDIRMEDEN oynatmak icin gecici HTTP adresi.
    ///
    /// `AVPlayer` byte-range destekli bir HTTP kaynagindan akitarak
    /// oynatiyor: ilk saniyeler gelir gelmez basliyor. Onceden dosya
    /// bastan sona indiriliyordu ve buyuk videoda bu dakikalar
    /// suruyordu.
    func streamURL(for path: String) -> URL? {
        guard let b = companion, b.isReady,
              let host = b.host,
              let d = b.call("media.stream", ["path": path]),
              let p = d["path"] as? String, let port = d["port"] as? Int
        else { return nil }
        return URL(string: "http://\(host):\(port)\(p)")
    }

    /// Aramayi TELEFONDA baslatir.
    ///
    /// Ses Mac'e TASINMIYOR: Android 10'dan beri `VOICE_CALL` ses
    /// kaynagi normal uygulamalara kapali ve telefonun giden ses
    /// akisina disaridan ses vermenin API'si yok. Yani konusma
    /// telefondan yapiliyor; Mac yalnizca aramayi baslatiyor.
    /// @return hata anahtari; `nil` ise baslatildi.
    func dial(_ number: String, immediate: Bool = false) -> String? {
        guard let b = companion, b.isReady else { return "notpaired" }
        guard b.call("calls.dial", ["number": number, "immediate": immediate]) != nil
        else { return b.lastError ?? "dialfailed" }
        return nil
    }

    /// Arama kaydindan bir girdiyi siler.
    func deleteCall(number: String, date: Date) -> String? {
        guard let b = companion, b.isReady else { return "notpaired" }
        let ms = Int(date.timeIntervalSince1970 * 1000)
        guard b.call("calls.delete", ["number": number, "date": ms]) != nil
        else { return b.lastError ?? "deletefailed" }
        return nil
    }

    /// Telefonun kendi numarasi ve operatoru.
    func ownNumber() -> (number: String?, carrier: String?) {
        guard let b = companion, b.isReady, let d = b.call("phone.number")
        else { return (nil, nil) }
        return (d["number"] as? String, d["carrier"] as? String)
    }

    public struct PhoneNotification: Identifiable, Hashable {
        public struct Action: Hashable {
            public let index: Int
            public let title: String
            /// Metin girdisi kabul ediyor mu (yanit verilebilir mi)?
            public let reply: Bool
        }
        public var id: String { key }
        public let key: String
        public let package: String
        public let app: String
        public let title: String
        public let text: String
        public let date: Date
        public let ongoing: Bool
        public let clearable: Bool
        public let actions: [Action]
    }

    private static func parse(_ r: [String: Any]) -> PhoneNotification? {
        guard let key = r["key"] as? String else { return nil }
        let acts = (r["actions"] as? [[String: Any]] ?? []).compactMap { a -> PhoneNotification.Action? in
            guard let i = a["index"] as? Int, let t = a["title"] as? String else { return nil }
            return PhoneNotification.Action(index: i, title: t,
                                            reply: a["reply"] as? Bool ?? false)
        }
        return PhoneNotification(
            key: key,
            package: r["package"] as? String ?? "",
            app: r["app"] as? String ?? "",
            title: r["title"] as? String ?? "",
            text: r["text"] as? String ?? "",
            date: Date(timeIntervalSince1970: (r["time"] as? Double ?? 0) / 1000),
            ongoing: r["ongoing"] as? Bool ?? false,
            clearable: r["clearable"] as? Bool ?? true,
            actions: acts)
    }

    /// Olay olarak gelen tek bildirimi cozer.
    public static func notification(from data: [String: Any]) -> PhoneNotification? {
        parse(data)
    }

    /// Ekranda duranlar ve gecmis.
    func notifications() -> (live: [PhoneNotification], history: [PhoneNotification]) {
        guard let b = companion, b.isReady, let d = b.call("notifications.list")
        else { return ([], []) }
        let live = (d["notifications"] as? [[String: Any]] ?? []).compactMap(Self.parse)
        let hist = (d["history"] as? [[String: Any]] ?? []).compactMap(Self.parse)
        return (live, hist)
    }

    @discardableResult
    func dismissNotification(_ key: String) -> Bool {
        guard let b = companion, b.isReady else { return false }
        return b.call("notifications.dismiss", ["key": key]) != nil
    }

    @discardableResult
    func dismissAllNotifications() -> Bool {
        guard let b = companion, b.isReady else { return false }
        return b.call("notifications.dismissAll") != nil
    }

    /// Bildirimin bir eylemini calistirir; `text` verilirse YANIT olarak.
    @discardableResult
    func runNotificationAction(_ key: String, index: Int, text: String? = nil) -> Bool {
        guard let b = companion, b.isReady else { return false }
        var args: [String: Any] = ["key": key, "index": index]
        if let text { args["text"] = text }
        return b.call("notifications.act", args) != nil
    }

    /// Telefonun panosu — yansitma ACIK OLMADAN.
    func clipboardText() -> String? {
        guard let b = companion, b.isReady else { return nil }
        return b.call("clipboard.get")?["text"] as? String
    }

    @discardableResult
    func setClipboard(_ text: String) -> Bool {
        guard let b = companion, b.isReady else { return false }
        return b.call("clipboard.set", ["text": text]) != nil
    }
}
