import AppKit
import UserNotifications
import AndrOSCore

/// macOS yerel bildirimleri — EYLEMLERIYLE BIRLIKTE.
///
/// Telefonda olan bir sey Mac'te de gorunsun diye. Ama yalniz gorunmesi
/// yetmiyor: banner'in uzerinden YANITLANABILIYOR, susturulabiliyor ve
/// okundu isaretlenebiliyor. Kullanici telefona uzanmadan isini
/// bitiriyor.
///
/// EN FAZLA IKI EYLEM. macOS ucuncu dugmeden itibaren hepsini bir
/// "Secenekler" menusune katliyor ve kullanicinin once genisletme okuna
/// basmasi gerekiyor (olculdu: uc eylemle "Yanitla" gorunmuyordu).
/// Bu yuzden banner'da yalniz en gerekli ikisi var; gerisi kategoride.
///
/// KATEGORILER UYGULAMA BASINA uretiliyor: dugme yazisinda gercek
/// uygulama adi geciyor ("WhatsApp'ı sustur"). Sabit bir "Bu uygulamayı
/// sustur" yazisi, macOS'un kendi ucnokta menusundeki "AndrOS'u sustur"
/// ile karisiyordu — kullanici hangisinin neyi susturdugunu anlamiyordu.
final class Notify: NSObject, UNUserNotificationCenterDelegate {

    static let shared = Notify()
    private override init() { super.init() }

    private var ready = false
    private var allowed = false

    /// Telefondaki bildirimin KENDI eylemi.
    struct PhoneAction {
        let index: Int
        let title: String
        /// Metin girdisi kabul ediyor mu?
        let reply: Bool
    }

    /// Bildirim eylemleri disari baglaniyor: bu katman veri katmanini
    /// tanimiyor, yalniz "su anahtara su eylemi uygula" diyor.
    var onReply: ((_ key: String, _ index: Int, _ text: String) -> Void)?
    /// Telefonun kendi dugmesi (metinsiz): "Bağlantıyı kes", "Duraklat"…
    var onAction: ((_ key: String, _ index: Int) -> Void)?
    var onMarkRead: ((_ key: String) -> Void)?
    var onOpen: ((_ key: String) -> Void)?

    // MARK: - Susturma (sureli)

    private static let muteKey = "mutedNotificationApps2"

    /// paket -> susturmanin bittigi an. `distantFuture` = suresiz.
    private static var muteTable: [String: Date] {
        get {
            let raw = UserDefaults.standard.dictionary(forKey: muteKey) as? [String: Double] ?? [:]
            return raw.mapValues { Date(timeIntervalSince1970: $0) }
        }
        set {
            UserDefaults.standard.set(
                newValue.mapValues { $0.timeIntervalSince1970 }, forKey: muteKey)
        }
    }

    /// Susturma YALNIZ Mac tarafini etkiler; telefonda bildirim gelmeye
    /// devam eder ve kategoride gorunur — kullanici hicbir sey
    /// kaybetmez, yalniz banner cikmaz.
    static func isMuted(_ package: String) -> Bool {
        guard let until = muteTable[package] else { return false }
        if until > Date() { return true }
        // Suresi dolmus kaydi temizle.
        var t = muteTable; t.removeValue(forKey: package); muteTable = t
        return false
    }

    /// Ne zamana kadar susturulmus (gosterim icin).
    static func mutedUntil(_ package: String) -> Date? {
        guard let u = muteTable[package], u > Date() else { return nil }
        return u
    }

    /// `until` nil ise susturma kaldirilir.
    static func mute(_ package: String, until: Date?) {
        var t = muteTable
        if let until { t[package] = until } else { t.removeValue(forKey: package) }
        muteTable = t
        NotificationCenter.default.post(name: .androsNotificationsChanged, object: nil)
    }

    static func muteForever(_ package: String) { mute(package, until: .distantFuture) }
    static func mute(_ package: String, hours: Double) {
        mute(package, until: Date().addingTimeInterval(hours * 3600))
    }

    // MARK: - Yanit sonrasi sessizlik

    /// Bizim eyledigimiz bildirimler kisa sure YENIDEN GOSTERILMEZ.
    ///
    /// Olculen davranis: yanit gonderilince mesajlasma uygulamasi kendi
    /// bildirimini guncelliyor, bu da yeni bir bildirim olayi olarak
    /// geliyordu — kullanici cevap yazar yazmaz ayni bildirim geri
    /// geliyordu. Kisa bir sessizlik penceresi bunu kesiyor.
    private var actedAt: [String: Date] = [:]
    private let actedLock = NSLock()
    /// anahtar -> en son gosterilen icerik (tekrar uyarmamak icin).
    private var lastPosted: [String: String] = [:]
    private let postLock = NSLock()

    func markActed(_ key: String) {
        actedLock.lock(); actedAt[key] = Date(); actedLock.unlock()
        postLock.lock(); lastPosted.removeValue(forKey: key); postLock.unlock()
    }

    private func recentlyActed(_ key: String) -> Bool {
        actedLock.lock(); let t = actedAt[key]; actedLock.unlock()
        guard let t else { return false }
        return Date().timeIntervalSince(t) < 12
    }

    // MARK: - Kurulum

    func setup() {
        guard !ready else { return }
        ready = true
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        applyCategories()
        c.requestAuthorization(options: [.alert, .sound]) { [weak self] ok, err in
            self?.allowed = ok
            Log.write("bildirim izni: \(ok ? "verildi" : "REDDEDILDI")"
                      + (err.map { " (\($0.localizedDescription))" } ?? ""))
        }
    }

    /// Uretilmis kategoriler: kimlik -> kategori.
    ///
    /// Kategori BILDIRIM BASINA degil, EYLEM KUMESI basina uretiliyor.
    /// Ayni uygulamanin ayni dugmelere sahip bildirimleri tek kategoriyi
    /// paylasiyor; boylece kayit listesi sinirsiz buyumuyor.
    private var categories: [String: UNNotificationCategory] = [:]

    private func applyCategories() {
        UNUserNotificationCenter.current()
            .setNotificationCategories(Set(categories.values))
    }

    /// Telefonun eylemlerinden bir kategori uretir (gerekirse kaydeder)
    /// ve kimligini doner.
    ///
    /// DUGMELER KIRPILMIYOR: bildirim kac dugme tasiyorsa hepsi geliyor.
    /// macOS ikiden fazlasini "Seçenekler" altina katliyor — orasi bir
    /// tik uzakta ama hicbir sey KAYBOLMUYOR. Az dugme tasiyan
    /// bildirimlerde (cogu) hepsi dogrudan gorunuyor.
    private func categoryID(package: String, app: String,
                            actions: [PhoneAction]) -> String {
        let sig = actions.map { "\($0.index):\($0.reply ? "r" : "b"):\($0.title)" }
            .joined(separator: "|")
        let id = "andros.d." + String(format: "%08x", abs((package + sig).hashValue))
        if categories[id] == nil {
            var list: [UNNotificationAction] = actions.map { a in
                if a.reply {
                    return UNTextInputNotificationAction(
                        identifier: ActionID.phonePrefix + "\(a.index)",
                        title: a.title.isEmpty ? L("Yanıtla", "Reply") : a.title,
                        options: [],
                        textInputButtonTitle: L("Gönder", "Send"),
                        textInputPlaceholder: L("Yanıt yaz…", "Write a reply…"))
                }
                return UNNotificationAction(
                    identifier: ActionID.phonePrefix + "\(a.index)",
                    title: a.title, options: [])
            }
            // Bizim ikimiz her zaman en sonda: telefonun kendi dugmeleri
            // once gelsin.
            list.append(markRead)
            list.append(muteAction(app: app.isEmpty ? nil : app))
            categories[id] = UNNotificationCategory(
                identifier: id, actions: list, intentIdentifiers: [], options: [])
            applyCategories()
        }
        return id
    }

    private var markRead: UNNotificationAction {
        UNNotificationAction(identifier: ActionID.markRead,
                             title: L("Okundu işaretle", "Mark as read"), options: [])
    }

    /// Sure ONEMLI: "sustur" deyip kalici susturmak kullaniciyi
    /// sasirtiyor. Banner'daki dugme 1 SAAT susturuyor; suresiz susturma
    /// kategorideki menude.
    private func muteAction(app: String?) -> UNNotificationAction {
        let who = app.map { "\($0)" } ?? L("bu uygulamayı", "this app")
        return UNNotificationAction(
            identifier: ActionID.muteHour,
            title: L("\(who) 1 saat sustur", "Mute \(who) for 1 hour"), options: [])
    }

    enum ActionID {
        /// Telefonun kendi eylemi: sonuna eylem sirasi ekleniyor.
        static let phonePrefix = "andros.act."
        static let markRead = "andros.action.markread"
        static let muteHour = "andros.action.mutehour"
    }

    // MARK: - Gonderme

    /// Basit bildirim (telefon bildirimi degil).
    static func post(title: String, body: String, id: String = UUID().uuidString) {
        shared.show(title: title, body: body, id: id,
                    key: id, package: "", app: "", actions: [])
    }

    /// Telefon bildirimi — KENDI dugmeleriyle birlikte.
    func show(title: String, body: String, id: String,
              key: String, package: String, app: String,
              actions: [PhoneAction]) {
        setup()
        guard allowed else { Log.write("bildirim atlandi: izin yok — \(title)"); return }
        guard package.isEmpty || !Notify.isMuted(package) else { return }
        // Az once biz cevapladiysak ayni bildirimi geri getirme.
        guard !recentlyActed(key) else {
            Log.write("bildirim atlandi: az once yanitlandi — \(package)")
            return
        }

        // AYNI ICERIK TEKRAR GELMESIN.
        //
        // Mesajlasma uygulamalari tek bir mesaj icin bildirimi birkac
        // kez guncelliyor (olculdu: Discord ayni sohbet icin saniyeler
        // icinde uc kez). Kimlik ayni oldugu icin macOS satiri
        // degistiriyor ama HER SEFERINDE yeniden ses cikarip uyariyor.
        let stamp = title + "\u{1}" + body
        postLock.lock()
        let same = lastPosted[key] == stamp
        lastPosted[key] = stamp
        postLock.unlock()
        if same { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = categoryID(package: package, app: app,
                                                actions: actions)
        content.userInfo = ["key": key, "package": package]
        // Uyari bicimi: banner gibi kendiliginden kaybolmasin, kullanici
        // kapatana kadar dursun. Telefon bildirimi kacirilmamali.
        if #available(macOS 12.0, *) { content.interruptionLevel = .timeSensitive }
        // Ayni sohbetin guncellemeleri tek satirda toplansin.
        if !package.isEmpty { content.threadIdentifier = package }
        // KIMLIK = bildirim anahtari: ayni sohbet guncellenince Mac'te
        // yeni bir satir birikmesin, var olan tazelensin.
        let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { err in
            if let err { Log.write("bildirim gonderilemedi: \(err.localizedDescription)") }
        }
    }

    /// Bildirim bicimi "Uyari" mi?
    ///
    /// macOS'ta dugmeler yalnizca UYARI (alert) biciminde dogrudan
    /// gorunur; SERIT (banner) biciminde kullanicinin uzerine gelip
    /// genisletme okuna basmasi gerekiyor. Bu bir kullanici ayari,
    /// uygulama degistiremiyor — ama kullaniciyi dogru yere
    /// goturebiliriz.
    static func isAlertStyle(_ done: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            DispatchQueue.main.async { done(s.alertStyle == .alert) }
        }
    }

    /// Sistem Ayarlari > Bildirimler'i acar.
    static func openSystemSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.notifications",
        ]
        for u in urls where NSWorkspace.shared.open(URL(string: u)!) { return }
    }

    /// Telefonda kapatilan bildirim Mac'te de kalksin.
    static func withdraw(_ id: String) {
        let c = UNUserNotificationCenter.current()
        c.removeDeliveredNotifications(withIdentifiers: [id])
        c.removePendingNotificationRequests(withIdentifiers: [id])
    }

    // MARK: - Yanitlar

    /// Uygulama ondeyken de banner cikssin: kullanici baska kategoriye
    /// bakiyor olabilir, bildirim yine de gorunmeli.
    func userNotificationCenter(_ c: UNUserNotificationCenter,
                                willPresent n: UNNotification,
                                withCompletionHandler done:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        if #available(macOS 11.0, *) { done([.banner, .sound]) } else { done([.alert, .sound]) }
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let key = info["key"] as? String ?? ""
        let package = info["package"] as? String ?? ""
        let action = response.actionIdentifier

        // Telefonun KENDI dugmesi mi? ("Bağlantıyı kes", "Duraklat"…)
        if action.hasPrefix(Notify.ActionID.phonePrefix),
           let idx = Int(action.dropFirst(Notify.ActionID.phonePrefix.count)) {
            markActed(key)
            Notify.withdraw(response.notification.request.identifier)
            if let r = response as? UNTextInputNotificationResponse {
                guard !r.userText.isEmpty else { done(); return }
                onReply?(key, idx, r.userText)
            } else {
                onAction?(key, idx)
            }
            done()
            return
        }

        switch action {
        case Notify.ActionID.markRead:
            markActed(key)
            onMarkRead?(key)
        case Notify.ActionID.muteHour:
            guard !package.isEmpty else { break }
            Notify.mute(package, hours: 1)
        case UNNotificationDefaultActionIdentifier:
            // Banner'a tiklandi: uygulamayi one getir ve Bildirimler'i ac.
            NSApp.activate(ignoringOtherApps: true)
            onOpen?(key)
        default: break
        }
        done()
    }
}
