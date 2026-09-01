import Foundation
import CoreGraphics
import ApplicationServices

/// Telefon = Mac'in dokunmatik yuzeyi ve klavyesi.
///
/// Ters yon: burada GORUNTU yok, yalniz girdi. Telefon parmak
/// hareketlerini ORAN/FARK olarak yolluyor, Mac de bunlari gercek
/// olaylara ceviriyor. Fare imleci Mac'te kaliyor — telefonda imlec
/// gostermek gerekmiyor, kullanici zaten Mac'e bakiyor.
///
/// macOS sentetik olaylari ERISILEBILIRLIK izni olmadan yollatmiyor;
/// izin yoksa `postEvent` sessizce hicbir sey yapmaz, o yuzden durumu
/// `isTrusted` ile ONDEN soruyoruz ve kullaniciya soyluyoruz.
public final class RemoteControl {

    public static let shared = RemoteControl()
    private init() {}

    /// Bir hareket icinde sol dugme basili mi (surukleme).
    private var dragging = false
    private let src = CGEventSource(stateID: .combinedSessionState)

    /// Erisilebilirlik izni verilmis mi?
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Izin penceresini acar. Sistem kutusu yalnizca bir kez cikar;
    /// sonrasinda kullanici Sistem Ayarlari'ndan aciyor.
    public static func requestTrust() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // MARK: - Giris noktasi

    /// Telefondan gelen tek bir girdi olayi.
    public func handle(_ o: [String: Any]) {
        switch o["t"] as? String ?? "" {
        case "move":   move(dx: num(o["dx"]), dy: num(o["dy"]))
        case "click":  click(right: (o["b"] as? String) == "right",
                             count: o["n"] as? Int ?? 1)
        case "down":   buttonDown()
        case "up":     buttonUp()
        case "scroll": scroll(dx: num(o["dx"]), dy: num(o["dy"]))
        case "gesture": gesture(o["g"] as? String ?? "")
        case "text":   type(o["s"] as? String ?? "")
        case "key":    special(o["k"] as? String ?? "")
        default: break
        }
    }

    private func num(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? 0 }

    // MARK: - Fare

    private var cursor: CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    /// Imleci FARK kadar oynatir ve ekranlarin disina cikmasini engeller.
    private func move(dx: Double, dy: Double) {
        var p = cursor
        p.x += CGFloat(dx)
        p.y += CGFloat(dy)
        p = clamp(p)
        // Suruklerken `.mouseMoved` yollamak dugmeyi birakmis gibi
        // davraniyor: pencere tasima ve metin secme yarim kaliyordu.
        let type: CGEventType = dragging ? .leftMouseDragged : .mouseMoved
        post(CGEvent(mouseEventSource: src, mouseType: type,
                     mouseCursorPosition: p, mouseButton: .left))
    }

    /// Etkin ekranlarin BIRLESIMI. Tek ekranin sinirlarina kisitlamak
    /// ikinci ekrani erisilemez yapardi.
    private func clamp(_ p: CGPoint) -> CGPoint {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        var union = CGRect.null
        for id in ids { union = union.union(CGDisplayBounds(id)) }
        if union.isNull { union = CGDisplayBounds(CGMainDisplayID()) }
        return CGPoint(x: min(max(p.x, union.minX), union.maxX - 1),
                       y: min(max(p.y, union.minY), union.maxY - 1))
    }

    private func click(right: Bool, count: Int) {
        let p = cursor
        let down: CGEventType = right ? .rightMouseDown : .leftMouseDown
        let up:   CGEventType = right ? .rightMouseUp   : .leftMouseUp
        let btn: CGMouseButton = right ? .right : .left
        for i in 1...max(1, count) {
            let d = CGEvent(mouseEventSource: src, mouseType: down,
                            mouseCursorPosition: p, mouseButton: btn)
            let u = CGEvent(mouseEventSource: src, mouseType: up,
                            mouseCursorPosition: p, mouseButton: btn)
            // Cift tik TEK bir olay degil: ayni yerde iki tik ve
            // `clickState` 2. Bu alan olmadan macOS iki ayri tik sayiyor
            // ve dosya acilmiyordu.
            d?.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            u?.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            post(d); post(u)
        }
    }

    private func buttonDown() {
        guard !dragging else { return }
        dragging = true
        post(CGEvent(mouseEventSource: src, mouseType: .leftMouseDown,
                     mouseCursorPosition: cursor, mouseButton: .left))
    }

    private func buttonUp() {
        guard dragging else { return }
        dragging = false
        post(CGEvent(mouseEventSource: src, mouseType: .leftMouseUp,
                     mouseCursorPosition: cursor, mouseButton: .left))
    }

    private func scroll(dx: Double, dy: Double) {
        let e = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2,
                        wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0)
        // Dogal kaydirma zaten telefondaki parmak yonunde: burada TERS
        // cevirmiyoruz, yoksa iki kez ters donerdi.
        post(e)
    }

    // MARK: - Uc parmak jestleri

    /// macOS'ta sanal masaustu gecisi ve Mission Control'un kendi
    /// kisayollari var; jesti taklit etmek yerine O kisayollari
    /// yolluyoruz — sentetik cok parmakli jest API'si yok.
    private func gesture(_ g: String) {
        switch g {
        case "desktopLeft":  key(123, [.maskControl])     // ⌃←
        case "desktopRight": key(124, [.maskControl])     // ⌃→
        case "missionControl": key(126, [.maskControl])   // ⌃↑
        case "back":         key(125, [.maskControl])     // ⌃↓ (geri döner)
        default: break
        }
    }

    // MARK: - Klavye

    /// Rastgele metin. Sanal tus kodu ARAMIYORUZ: kod->karakter esleme
    /// klavye duzenine bagli ve Turkce duzende yanlis harf uretiyordu.
    /// `keyboardSetUnicodeString` duzenden bagimsiz calisiyor.
    private func type(_ s: String) {
        guard !s.isEmpty else { return }
        for ch in s {
            let u = Array(String(ch).utf16)
            guard let d = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
            else { continue }
            d.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u)
            up.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u)
            post(d); post(up)
        }
    }

    private func special(_ k: String) {
        switch k {
        case "backspace": key(51, [])
        case "enter":     key(36, [])
        case "tab":       key(48, [])
        case "escape":    key(53, [])
        case "left":      key(123, [])
        case "right":     key(124, [])
        case "up":        key(126, [])
        case "down":      key(125, [])
        default: break
        }
    }

    private func key(_ code: CGKeyCode, _ flags: CGEventFlags) {
        let d = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
        let u = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
        d?.flags = flags
        u?.flags = flags
        post(d); post(u)
    }

    private func post(_ e: CGEvent?) { e?.post(tap: .cghidEventTap) }
}
