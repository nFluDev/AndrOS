import Foundation

/// Bir FIZIKSEL cihaz — hangi yollardan erisildigine bakilmaksizin.
///
/// Ayni telefon aynı anda uc yoldan gorunebiliyor:
///   • USB       — kabloyla adb
///   • Wi-Fi     — adb tcpip
///   • AndrOS    — mobil uygulama (hata ayiklama GEREKTIRMEZ)
///
/// Bunlari ayri satirlar olarak gostermek kullaniciyi yaniltiyordu ("uc
/// tane telefonum mu var?"). Ortak anahtar ANDROID_ID: hem uygulamadan
/// hem `adb shell settings get secure android_id` ile okunabiliyor.
public struct UnifiedDevice: Identifiable, Hashable {
    public var id: String { key }
    /// ANDROID_ID; okunamadiysa seri numarasi.
    public let key: String
    public var name: String
    public var alias: String = ""

    public var usbSerial: String?
    public var wifiSerial: String?
    public var companionId: String?
    public var companionPaired = false
    public var companionOverUSB = false
    public var lastSeen = Date()

    public init(key: String, name: String) { self.key = key; self.name = name }

    public var displayName: String { alias.isEmpty ? name : alias }
    public var isOnline: Bool { usbSerial != nil || wifiSerial != nil || companionId != nil }

    /// Panelde gosterilen adb seri numarasi (varsa USB, yoksa Wi-Fi).
    public var adbSerial: String? { usbSerial ?? wifiSerial }

    /// "USB + Wi-Fi + AndrOS" gibi.
    public func transportLabel(appName: String) -> String {
        var parts: [String] = []
        if usbSerial != nil { parts.append("USB") }
        if wifiSerial != nil { parts.append("Wi-Fi") }
        if companionId != nil {
            // Uygulama USB ag paylasimi uzerinden geliyorsa bunu ayrica
            // yazmiyoruz; kullanici icin onemli olan "uygulama bagli".
            parts.append(appName)
        }
        // " · " ayirici " + "den dar: satira "USB · Wi-Fi · AndrOS"
        // tam sigiyor, once son kelime kesiliyordu.
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }
}

/// adb ile gorunen cihazin AndrOS kimligini onbellekte tutar.
///
/// Kimlik uygulamanin yazdigi `/sdcard/Android/data/dev.naer.andros/
/// files/andros-id` dosyasindan okunuyor. ANDROID_ID kullanilamadi:
/// Android 8'den beri UYGULAMA BASINA farkli uretiliyor, yani uygulamanin
/// gordugu deger ile adb kabugununki ayni degil (olculdu).
///
/// Uygulama yuklu degilse seri numarasina duşuluyor; o zaman cihaz
/// yalniz adb yollariyla (USB/Wi-Fi) birlestirilir.
public final class AndroidIDCache {
    private var cache: [String: String] = [:]
    private let lock = NSLock()
    public init() {}

    public func id(for serial: String, adbPath: String) -> String {
        lock.lock()
        if let v = cache[serial] { lock.unlock(); return v }
        lock.unlock()
        let path = "/sdcard/Android/data/dev.naer.andros/files/andros-id"
        let r = RawProcess.run(adbPath, ["-s", serial, "shell", "cat", path], timeout: 10)
        let v = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        // Dosya yoksa kabuk "No such file" yaziyor; kimlik UUID bicimli.
        guard v.count == 36, v.contains("-") else {
            // BASARISIZ OKUMAYI ONBELLEGE ALMIYORUZ. Aksi halde uygulama
            // henuz baslamadan yapilan tek bir basarisiz okuma kaliciydi
            // ve ayni telefon hem seri numarasiyla hem kimlikle IKI SATIR
            // olarak gorunuyordu.
            return serial
        }
        lock.lock(); cache[serial] = v; lock.unlock()
        return v
    }

    /// Uygulama yeni kuruldugunda eski sonuc bayatlamasin.
    public func invalidate() { lock.lock(); cache.removeAll(); lock.unlock() }
}
