import AppKit
import CoreVideo
import AndrOSCore

/// Uygulama uzerinden (adb'siz) yansitma penceresi.
///
/// scrcpy penceresinden AYRI bir sinif: oradaki her sey adb kanalinin
/// olay bicimine (`ControlMessage`) bagli. Buradaki yol telefonun
/// erisilebilirlik hizmetine JEST gonderiyor, yani "bas/birak" degil
/// "sundan buraya sur" diyor. Ikisini tek sinifta toplamak her iki
/// tarafi da bozardi.
final class AppMirrorView: NSView {

    /// Telefon ekraninin piksel olcusu — orani buna gore koruyoruz.
    var videoSize = CGSize(width: 9, height: 16) { didSet { needsLayout = true } }

    var onTap: ((Double, Double) -> Void)?
    var onLongPress: ((Double, Double) -> Void)?
    var onSwipe: (([(Double, Double)], Int) -> Void)?
    var onBack: (() -> Void)?
    var onText: ((String) -> Void)?
    var onBackspace: (() -> Void)?

    private let image = CALayer()
    private var downAt = CGPoint.zero
    private var downTime = Date()
    private var path: [(Double, Double)] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        image.contentsGravity = .resizeAspect
        image.magnificationFilter = .linear
        layer?.addSublayer(image)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        image.frame = imageRect
        CATransaction.commit()
    }

    /// Goruntunun pencere icinde GERCEKTEN kapladigi dikdortgen.
    /// Dokunma esleme bunu kullanmali; tum goruntuye gore hesaplamak
    /// siyah kenarlarda yanlis yere dokunmak demekti.
    private var imageRect: CGRect {
        let b = bounds
        guard videoSize.width > 0, videoSize.height > 0 else { return b }
        let s = min(b.width / videoSize.width, b.height / videoSize.height)
        let w = videoSize.width * s, h = videoSize.height * s
        return CGRect(x: (b.width - w) / 2, y: (b.height - h) / 2, width: w, height: h)
    }

    /// Yeni kare. `IOSurface` dogrudan katmana veriliyor: VideoToolbox
    /// zaten IOSurface destekli tampon uretiyor, CGImage'e cevirmek her
    /// karede bosuna kopyalama olurdu.
    func show(_ px: CVPixelBuffer) {
        guard let surf = CVPixelBufferGetIOSurface(px) else { return }
        let w = CVPixelBufferGetWidth(px), h = CVPixelBufferGetHeight(px)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if Int(self.videoSize.width) != w || Int(self.videoSize.height) != h {
                self.videoSize = CGSize(width: w, height: h)
                self.layout()
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.image.contents = surf.takeUnretainedValue()
            CATransaction.commit()
        }
    }

    // MARK: - Fare -> jest

    /// Ekran konumunu 0..1 orana cevirir. Oran gonderiyoruz cunku pencere
    /// olceklenebiliyor; piksel gondermek yanlis yere dokunmak olurdu.
    private func norm(_ p: NSPoint) -> (Double, Double)? {
        let r = imageRect
        guard r.contains(p) else { return nil }
        return (Double((p.x - r.minX) / r.width),
                Double(1 - (p.y - r.minY) / r.height))   // Android'de y yukaridan
    }

    override func mouseDown(with e: NSEvent) {
        downAt = convert(e.locationInWindow, from: nil)
        downTime = Date()
        path = norm(downAt).map { [$0] } ?? []
    }

    override func mouseDragged(with e: NSEvent) {
        guard let n = norm(convert(e.locationInWindow, from: nil)) else { return }
        path.append(n)
    }

    override func mouseUp(with e: NSEvent) {
        let up = convert(e.locationInWindow, from: nil)
        guard let start = path.first, let end = norm(up) else { return }
        let moved = hypot(up.x - downAt.x, up.y - downAt.y)
        let held = Date().timeIntervalSince(downTime)
        defer { path.removeAll() }

        if moved < 6 {
            held > 0.45 ? onLongPress?(end.0, end.1) : onTap?(end.0, end.1)
            return
        }
        // Ara noktalari SEYRELT: yuzlerce nokta jesti yavaslatiyor.
        var pts = [start]
        let stride = max(1, path.count / 12)
        for i in Swift.stride(from: stride, to: path.count, by: stride) { pts.append(path[i]) }
        pts.append(end)
        onSwipe?(pts, Int(max(60, min(600, held * 1000))))
    }

    override func rightMouseUp(with e: NSEvent) { onBack?() }

    /// Tekerlek -> parmakla kaydirma. Android'de asagi kaydirmak icin
    /// parmak YUKARI gider; isaret bu yuzden ters.
    override func scrollWheel(with e: NSEvent) {
        guard let c = norm(convert(e.locationInWindow, from: nil)) else { return }
        let dy = Double(e.scrollingDeltaY) / Double(max(1, imageRect.height)) * 3
        guard abs(dy) > 0.01 else { return }
        let to = max(0.02, min(0.98, c.1 + dy))
        onSwipe?([(c.0, c.1), (c.0, (c.1 + to) / 2), (c.0, to)], 90)
    }

    override func keyDown(with e: NSEvent) {
        switch e.keyCode {
        case 51: onBackspace?()                     // ⌫
        case 53: onBack?()                          // esc -> geri
        case 36, 76: onText?("\n")                  // ↩
        default:
            if let s = e.characters, !s.isEmpty,
               s.rangeOfCharacter(from: .controlCharacters) == nil { onText?(s) }
        }
    }
}

/// Uygulama yoluyla yansitma penceresi (goruntu + gezinme dugmeleri).
final class AppMirrorWindowController: NSWindowController {

    let mirror = AppMirrorView(frame: NSRect(x: 0, y: 0, width: 400, height: 800))
    private let hint = NSTextField(labelWithString: "")
    var onClose: (() -> Void)?

    convenience init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 860),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = L("Telefon ekranı", "Phone screen")
        w.isReleasedWhenClosed = false
        w.center()
        self.init(window: w)

        // Gezinme: erisilebilirlik jestleriyle donanim tuslarina
        // basilamiyor, o yuzden GERI/ANA EKRAN/SON UYGULAMALAR burada.
        let bar = NSStackView(views: [
            navButton("chevron.left", L("Geri", "Back"), #selector(back)),
            navButton("house", L("Ana ekran", "Home"), #selector(home)),
            navButton("square.on.square", L("Son uygulamalar", "Recents"), #selector(recents)),
        ])
        bar.orientation = .horizontal
        bar.distribution = .fillEqually
        bar.spacing = 8

        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .systemOrange
        hint.alignment = .center
        hint.isHidden = true

        let root = NSStackView(views: [mirror, hint, bar])
        root.orientation = .vertical
        root.spacing = 6
        root.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 10, right: 10)
        mirror.translatesAutoresizingMaskIntoConstraints = false
        w.contentView = root
        w.delegate = self
        w.makeFirstResponder(mirror)
    }

    /// Erisilebilirlik kapaliyken goruntu akar ama DOKUNMA gitmez —
    /// bunu sessizce gecmek "bozuk" izlenimi veriyordu.
    func setInputReady(_ ok: Bool) {
        hint.isHidden = ok
        hint.stringValue = L("Dokunma çalışmıyor: telefonda Ayarlar › Erişilebilirlik › AndrOS'u aç.",
                             "Touch is off: on the phone open Settings › Accessibility › AndrOS.")
    }

    private func navButton(_ symbol: String, _ tip: String, _ sel: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol,
                                        accessibilityDescription: tip) ?? NSImage(),
                         target: self, action: sel)
        b.bezelStyle = .rounded
        b.toolTip = tip
        return b
    }

    var onBack: (() -> Void)?
    var onHome: (() -> Void)?
    var onRecents: (() -> Void)?

    @objc private func back() { onBack?() }
    @objc private func home() { onHome?() }
    @objc private func recents() { onRecents?() }
}

extension AppMirrorWindowController: NSWindowDelegate {
    func windowWillClose(_ n: Notification) { onClose?() }
}
