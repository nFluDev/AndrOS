import AppKit

/// Iki dilli metin secici.
///
/// Ayri `.lproj` paketleri yerine cagri yerinde iki dizi tutuyoruz: uygulama
/// SwiftPM ile derlenip elle paketlendigi icin `.strings` dosyalarini
/// yonetmek fazladan bir adim olurdu ve derleme sirasinda dogrulanmazdi.
/// Bu bicimde eksik ceviri DERLENMEZ, yani gozden kacamaz.
@inline(__always)
func L(_ tr: String, _ en: String) -> String { L10n.turkish ? tr : en }

enum L10n {
    /// "auto" | "tr" | "en"
    static var override: String {
        get { UserDefaults.standard.string(forKey: "language") ?? "auto" }
        set {
            UserDefaults.standard.set(newValue, forKey: "language")
            cached = nil
        }
    }

    private static var cached: Bool?

    /// Turkce mi gosterelim? Kullanici elle secmediyse ISLETIM SISTEMININ
    /// diline bakilir — macOS Ingilizce iken menude "Pencere" yazmasi
    /// tutarsizdi.
    static var turkish: Bool {
        if let c = cached { return c }
        let v: Bool
        switch override {
        case "tr": v = true
        case "en": v = false
        default:
            let code = (Locale.preferredLanguages.first ?? "en")
                .prefix(2).lowercased()
            v = (code == "tr")
        }
        cached = v
        return v
    }
}

/// Icerigi USTTEN baslatan kaydirma govdesi.
///
/// AppKit'in varsayilan `NSClipView`'i ters koordinatta calisiyor; govde
/// gorunurden kisaysa icerik ALTA yapisiyor, uzunsa acilista en altta
/// duruyordu (pano gecmisi "en alttan basliyor" sorunu). Zaten ters olan
/// govdelerde (NSTableView, NSCollectionView) bu gecersiz kilma bir sey
/// degistirmiyor, cunku NSClipView oyle durumda da `true` donuyor.
final class TopClipView: NSClipView {
    override var isFlipped: Bool { true }
}

/// Yuvarlak kisi resmi — resim yoksa ismin bas harfi ORTALANMIS olarak.
///
/// Once sabit yukseklikli bir `NSTextField` kullaniliyordu; AppKit metni
/// hucrenin ustune yaslayip dikey ortalamadigi icin harf yukarida kaliyordu.
/// Dogrudan cizince hem yatay hem dikey ortalama kesin.
final class AvatarView: NSView {
    var initial: String = "" { didSet { needsDisplay = true } }
    var image: NSImage? { didSet { needsDisplay = true } }
    /// Ada gore sabit renk — ayni kisi her zaman ayni renkte gorunur.
    var seed: Int = 0 { didSet { needsDisplay = true } }

    private static let palette: [NSColor] = [
        .systemBlue, .systemPurple, .systemPink, .systemOrange,
        .systemGreen, .systemTeal, .systemIndigo, .systemBrown,
    ]

    override func draw(_ dirtyRect: NSRect) {
        let d = min(bounds.width, bounds.height)
        let box = NSRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2,
                         width: d, height: d)
        let path = NSBezierPath(ovalIn: box)
        let tint = Self.palette[abs(seed) % Self.palette.count]

        if let img = image {
            NSGraphicsContext.current?.saveGraphicsState()
            path.addClip()
            img.draw(in: box, from: .zero, operation: .copy, fraction: 1)
            NSGraphicsContext.current?.restoreGraphicsState()
            return
        }

        tint.withAlphaComponent(0.22).setFill()
        path.fill()

        guard !initial.isEmpty else { return }
        let f = NSFont.systemFont(ofSize: d * 0.42, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: tint]
        let s = (initial as NSString).size(withAttributes: attrs)
        // Dikeyde BUYUK HARF YUKSEKLIGINE gore ortaliyoruz.
        //
        // `size(withAttributes:)` satir kutusunu (cikinti + inis) veriyor;
        // onu ortalamak harfi asagida birakiyordu (olculdu: 1.5 px). Dogrusu
        // taban cizgisini `midY - capHeight/2`'ye oturtmak. `draw(at:)`
        // satir kutusunun ALTINI aldigi icin inis payini geri ekliyoruz —
        // descender negatif oldugundan toplama yeterli.
        (initial as NSString).draw(
            at: NSPoint(x: box.midX - s.width / 2,
                        y: box.midY - f.capHeight / 2 + f.descender),
            withAttributes: attrs)
    }
}
