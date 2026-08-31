import Foundation
import Network

/// Bir cihaza hangi yoldan baglanilacagi.
///
/// Hangisinin hizli oldugu ORTAMA gore degisiyor: USB baglanti paylasimi
/// (RNDIS) cogu telefonda 100–480 Mbit/s ile sinirli, iyi bir Wi-Fi ise
/// 1 Gbit/s'e cikabiliyor — ama zayif sinyalde tersi olur. Bu yuzden
/// varsayilan "otomatik": iki yol da OLCULUP hizli olan seciliyor ve
/// sonuc cihaz basina hatirlaniyor.
public enum TransportChoice: String, CaseIterable, Codable {
    case auto, wifi, usb

    public var interfaceType: NWInterface.InterfaceType? {
        switch self {
        case .wifi: return .wifi
        case .usb:  return .wiredEthernet   // USB ag paylasimi kabloli gorunur
        case .auto: return nil
        }
    }
}

/// Cihaz basina yol tercihi ve olculen hizlar.
public final class TransportPrefs {
    private let key = "transportPrefs"
    public init() {}

    private func all() -> [String: [String: Double]] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: [String: Double]] ?? [:]
    }
    private func write(_ v: [String: [String: Double]]) {
        UserDefaults.standard.set(v, forKey: key)
    }

    public func choice(for id: String) -> TransportChoice {
        let raw = UserDefaults.standard.string(forKey: "transport.\(id)") ?? "auto"
        return TransportChoice(rawValue: raw) ?? .auto
    }
    public func setChoice(_ c: TransportChoice, for id: String) {
        UserDefaults.standard.set(c.rawValue, forKey: "transport.\(id)")
    }

    /// Olculen hiz (MB/s).
    public func speed(_ id: String, _ kind: TransportChoice) -> Double? {
        all()[id]?[kind.rawValue]
    }
    public func setSpeed(_ mbps: Double, _ id: String, _ kind: TransportChoice) {
        var v = all()
        var d = v[id] ?? [:]
        d[kind.rawValue] = mbps
        v[id] = d
        write(v)
    }

    /// Otomatik kipte hangi yol kullanilmali?
    public func effective(for id: String) -> TransportChoice {
        let c = choice(for: id)
        guard c == .auto else { return c }
        let w = speed(id, .wifi) ?? 0
        let u = speed(id, .usb) ?? 0
        if w == 0 && u == 0 { return .auto }        // henuz olculmedi
        return w >= u ? .wifi : .usb
    }
}
