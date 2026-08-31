import AppKit

/// Sigmayan metni kaydirarak tam okutan etiket.
///
/// Davranis: metin sigiyorsa hicbir sey yapmaz. Sigmiyorsa 2 saniye bekler,
/// sonu gorunene kadar yumusakca kaydirir, 2 saniye bekler, basa doner.
/// Kenarlarda fade var; yazi kesilmis gibi degil, sonu devam ediyormus gibi durur.
final class MarqueeLabel: NSView {

    var text: String = "" {
        didSet {
            guard text != oldValue else { return }
            offset = 0
            restart()
            needsDisplay = true
        }
    }
    var font: NSFont = .systemFont(ofSize: 12) { didSet { needsDisplay = true } }
    var textColor: NSColor = .labelColor { didSet { needsDisplay = true } }
    /// Kaydirma hizi (saniyede piksel).
    var speed: CGFloat = 42
    /// Duraklama sureleri.
    var pauseAtStart: TimeInterval = 2.0
    var pauseAtEnd: TimeInterval = 2.0

    private var offset: CGFloat = 0
    private var timer: Timer?
    private var waiting = false
    private var waitUntil = Date()
    /// Tekrarlar arasindaki bosluk GORUNUR GENISLIK kadar.
    ///
    /// Neden: daha kucuk bir bosluk verilince ayni metin yan yana birkac kez
    /// gorunuyordu ("aslan aslan aslan"). Bosluk goruntu genisligine esit
    /// olunca ayni anda EN FAZLA BIR kopya gorunur; biri soldan cikarken
    /// digeri sagdan yeni giriyor.
    private var gap: CGFloat { max(bounds.width, 40) }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: ceil(font.boundingRectForFont.height))
    }

    private var textWidth: CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }
    private var overflows: Bool { textWidth > bounds.width + 1 }
    /// Bir tam tur: metin + bosluk. Bu kadar kayinca yazi TEKRAR basa
    /// gelmis olur ve gorsel olarak ayni kareye doneriz — teleport yok.
    private var cycle: CGFloat { textWidth + gap }

    override func layout() {
        super.layout()
        restart()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { timer?.invalidate(); timer = nil } else { restart() }
    }

    private func restart() {
        timer?.invalidate(); timer = nil
        offset = 0
        waiting = true
        waitUntil = Date().addingTimeInterval(pauseAtStart)
        guard overflows, window != nil else { needsDisplay = true; return }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard overflows else { timer?.invalidate(); timer = nil; offset = 0; return }
        if waiting {
            if Date() >= waitUntil { waiting = false }
            return
        }
        offset += speed / 60.0
        // TAM TUR tamamlandi: yazi tekrar basa geldi. Ayni goruntude
        // oldugumuz icin offset'i sifirlamak goze carpmiyor.
        if offset >= cycle {
            offset = 0
            waiting = true
            waitUntil = Date().addingTimeInterval(pauseAtEnd)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        let size = (text as NSString).size(withAttributes: attrs)
        let y = (bounds.height - size.height) / 2
        let ns = text as NSString

        guard overflows else {
            ns.draw(at: NSPoint(x: 0, y: y), withAttributes: attrs)
            return
        }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.clip(to: bounds)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)

        // BANT: metni iki kez cizip aralarina bosluk koyuyoruz. Birincinin
        // sonu gorunurken ikincisinin basi geliyor; boylece "sona gidip
        // basa isinlanma" yok, kesintisiz donen bir serit var.
        ns.draw(at: NSPoint(x: -offset, y: y), withAttributes: attrs)
        ns.draw(at: NSPoint(x: -offset + cycle, y: y), withAttributes: attrs)

        // Kenarlarda yumusak gecis
        let fadeW = min(CGFloat(16), bounds.width * 0.3)
        if let mask = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceGray(),
            colors: [NSColor.black.withAlphaComponent(0).cgColor,
                     NSColor.black.cgColor,
                     NSColor.black.cgColor,
                     NSColor.black.withAlphaComponent(0).cgColor] as CFArray,
            locations: [0, fadeW / bounds.width, 1 - fadeW / bounds.width, 1]) {
            ctx.setBlendMode(.destinationIn)
            ctx.drawLinearGradient(mask, start: NSPoint(x: 0, y: 0),
                                   end: NSPoint(x: bounds.width, y: 0), options: [])
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
}
