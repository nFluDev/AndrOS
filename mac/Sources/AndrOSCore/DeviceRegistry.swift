import Foundation

/// Bilinen cihazlarin kalici listesi.
///
/// `adb devices` yalniz O ANDA bagli olanlari verir. Kullanicinin cihazi
/// listede tutabilmesi, ona isim verebilmesi ve silebilmesi icin ayri bir
/// kayit gerekiyor: kablo cikinca cihaz listeden dusmesin, "cevrimdisi"
/// gorunsun.
public struct KnownDevice: Codable, Hashable, Identifiable {
    /// adb kimligi: USB'de seri numarasi, Wi-Fi'da "ip:port".
    public var id: String
    /// Kullanicinin verdigi ad. Bossa modelin adi kullanilir.
    public var alias: String
    public var model: String
    public var wifi: Bool
    public var lastSeen: Date

    public init(id: String, alias: String = "", model: String = "",
                wifi: Bool = false, lastSeen: Date = Date()) {
        self.id = id; self.alias = alias; self.model = model
        self.wifi = wifi; self.lastSeen = lastSeen
    }

    public var displayName: String {
        alias.isEmpty ? (model.isEmpty ? id : model) : alias
    }
}

public enum DeviceRegistry {
    private static let key = "knownDevices"

    public static func load() -> [KnownDevice] {
        guard let d = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([KnownDevice].self, from: d)
        else { return [] }
        return list
    }

    public static func save(_ list: [KnownDevice]) {
        guard let d = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(d, forKey: key)
    }

    /// Bagli cihazlari kayda isler; kaydi dondurur.
    @discardableResult
    public static func merge(connected: [ADBDevice]) -> [KnownDevice] {
        var list = load()
        for c in connected {
            let wifi = c.serial.contains(":")
            if let i = list.firstIndex(where: { $0.id == c.serial }) {
                list[i].lastSeen = Date()
                list[i].wifi = wifi
                if c.model != "?" { list[i].model = c.model }
            } else {
                list.append(KnownDevice(id: c.serial, model: c.model == "?" ? "" : c.model,
                                        wifi: wifi))
            }
        }
        save(list)
        return list
    }

    public static func rename(_ id: String, to alias: String) {
        var list = load()
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        list[i].alias = alias.trimmingCharacters(in: .whitespaces)
        save(list)
    }

    public static func forget(_ id: String) {
        save(load().filter { $0.id != id })
    }
}

// MARK: - Kablosuz baglanti

public extension ADB {
    /// Kabloyla bagli cihazi TCP moduna alip IP'sini dondurur.
    ///
    /// Android 11 oncesinde kablosuz hata ayiklama icin tek yol bu: cihaz
    /// bir kez USB ile baglanip `adb tcpip` calistirilmali. Sonrasinda kablo
    /// cikarilabilir.
    func enableWireless(port: Int = 5555) throws -> String {
        _ = try checked(["tcpip", "\(port)"], timeout: 15)
        Thread.sleep(forTimeInterval: 1.5)
        let ip = try wifiAddress()
        guard !ip.isEmpty else { throw ADBError.command("tcpip", 1, "Cihazın Wi-Fi adresi okunamadı") }
        return "\(ip):\(port)"
    }

    /// Cihazin Wi-Fi IPv4 adresi.
    func wifiAddress() throws -> String {
        // Once dogrudan ozellik, sonra `ip route` — bazi ROM'larda ilki bos.
        let prop = getProp("dhcp.wlan0.ipaddress")
        if !prop.isEmpty, prop.contains(".") { return prop }
        let out = (try? checked(["shell", "ip", "-f", "inet", "addr", "show", "wlan0"])) ?? ""
        for token in out.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
            if token.hasPrefix("inet") { continue }
            if token.contains("/"), token.contains(".") {
                return String(token.split(separator: "/")[0])
            }
        }
        return ""
    }

    /// "ip:port" adresine baglanir.
    func connect(_ address: String) throws -> String {
        let out = try checked(["connect", address], timeout: 20)
        if out.lowercased().contains("failed") || out.lowercased().contains("unable") {
            throw ADBError.command("connect", 1, out)
        }
        return out
    }

    func disconnect(_ address: String) {
        _ = try? run(["disconnect", address], timeout: 10)
    }

    /// Android 11+ "kablosuz hata ayiklama" eslestirmesi.
    func pair(_ address: String, code: String) throws -> String {
        let r = RawProcess.run(path, ["pair", address, code], timeout: 30)
        let text = (r.out + "\n" + r.err).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.lowercased().contains("successfully") else { throw ADBError.command("pair", 1, text) }
        return text
    }
}
