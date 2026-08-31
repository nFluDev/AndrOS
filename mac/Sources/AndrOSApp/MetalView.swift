import AppKit
import Metal
import QuartzCore
import AndrOSCore

/// CAMetalLayer barindiran, en-boy oranini koruyan goruntu yuzeyi.
/// Girdi olaylarini akis koordinatlarina cevirip disari verir.
final class MetalView: NSView {

    var onTouch: ((ControlMessage.TouchAction, Int, Int) -> Void)?
    /// Ayni olay, oransal (0..1) konumla — makro kaydi icin.
    var onTouchNormalized: ((ControlMessage.TouchAction, Double, Double) -> Void)?
    var onScroll: ((Int, Int, Float, Float) -> Void)?
    /// Sag tik surukleme (kamera). Kapaliysa hic cagrilmaz.
    var onCamera: ((ControlMessage.TouchAction, Int, Int) -> Void)?
    var cameraDragEnabled = true
    var onKey: ((UInt32, Bool) -> Void)?
    /// Ham macOS tus kodu. true donerse olay tuketildi (tus haritalama).
    var onRawKey: ((UInt16, Bool) -> Bool)?

    /// Akisin piksel boyutu (orn. 1600x720)
    var videoSize = CGSize(width: 1, height: 1) {
        didSet { needsLayout = true }
    }

    let metalLayer = CAMetalLayer()

    /// Her ekran yenilemesinde cagrilir; cizilecek kare varsa cizer.
    var onDisplayTick: (() -> Void)?
    private var displayLink: CADisplayLink?

    /// CAMetalLayer device OLMADAN nextDrawable() daima nil doner ve
    /// ekran simsiyah kalir. Oturum baslarken mutlaka atanmali.
    func attach(device: MTLDevice) {
        metalLayer.device = device
        updateDrawableSize()
        startDisplayLink()
    }

    /// Cizimi decode aninda degil, EKRANIN yenileme sinyalinde yapiyoruz.
    /// Karelerin gelis araligi duzensiz oldugu icin geldigi an cizmek
    /// ekrana duzensiz dusmeye (judder) yol aciyordu — "dusuk FPS" hissi.
    private func startDisplayLink() {
        displayLink?.invalidate()
        let link = displayLink(target: self, selector: #selector(displayTick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func displayTick() { onDisplayTick?() }

    func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? 2.0
        metalLayer.contentsScale = scale
        let w = max(bounds.width, 1) * scale
        let h = max(bounds.height, 1) * scale
        if metalLayer.drawableSize != CGSize(width: w, height: h) {
            metalLayer.drawableSize = CGSize(width: w, height: h)
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    deinit { displayLink?.invalidate() }

    private func setup() {
        // SIRALAMA ONEMLI: once layer atanir, sonra wantsLayer.
        // Tersi olursa AppKit kendi layer'ini olusturur ve CAMetalLayer kaybolur.
        layer = metalLayer
        wantsLayer = true
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        // Dusuk gecikme: en fazla 2 drawable, islem sirasi beklemesi yok.
        // 3 drawable: nextDrawable() beklemesinden kaynaklanan takilmalari onler.
        metalLayer.maximumDrawableCount = 3
        metalLayer.presentsWithTransaction = false
        metalLayer.displaySyncEnabled = true
        metalLayer.backgroundColor = NSColor.black.cgColor
        // macOS pencere estetigi: yuvarlatilmis kose.
        metalLayer.cornerRadius = 12
        metalLayer.masksToBounds = true
        if #available(macOS 10.15, *) { metalLayer.cornerCurve = .continuous }
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        updateDrawableSize()
    }

    /// Goruntunun view icinde kapladigi dikdortgen (aspect-fit).
    var videoRect: CGRect {
        let vw = videoSize.width, vh = videoSize.height
        guard vw > 0, vh > 0 else { return bounds }
        let scale = min(bounds.width / vw, bounds.height / vh)
        let w = vw * scale, h = vh * scale
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    /// View noktasini akis pikseline cevirir. Goruntu disi ise nil.
    private func mapToVideo(_ p: NSPoint) -> (Int, Int)? {
        let r = videoRect
        guard r.width > 0, r.height > 0, r.contains(p) else { return nil }
        let nx = (p.x - r.minX) / r.width
        // AppKit'te y asagidan yukari; Android'de yukaridan asagi.
        let ny = 1.0 - (p.y - r.minY) / r.height
        return (Int(nx * videoSize.width), Int(ny * videoSize.height))
    }

    private func emit(_ action: ControlMessage.TouchAction, _ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let (x, y) = mapToVideo(p) else { return }
        onTouch?(action, x, y)
        let r = videoRect
        if r.width > 0 {
            onTouchNormalized?(action,
                               Double((p.x - r.minX) / r.width),
                               1 - Double((p.y - r.minY) / r.height))
        }
    }

    override func mouseDown(with event: NSEvent) {
        // Cmd basiliyken pencereyi tasi. Cmd'siz surukleme oyuna gitmeli,
        // yoksa oyun icinde kaydirma/swipe yapilamaz.
        if event.modifierFlags.contains(.command) {
            beginManualDrag(event)             // isMovable=false oldugu icin elle
            return
        }
        emit(.down, event)
    }
    /// ⌘ ile tasima. window.isMovable=false oldugundan performDrag calismaz;
    /// olaylari kendimiz takip edip pencereyi tasiyoruz.
    private func beginManualDrag(_ event: NSEvent) {
        guard let w = window else { return }
        let startMouse = NSEvent.mouseLocation
        let startOrigin = w.frame.origin
        while let e = w.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if e.type == .leftMouseUp { break }
            let now = NSEvent.mouseLocation
            w.setFrameOrigin(NSPoint(x: startOrigin.x + (now.x - startMouse.x),
                                     y: startOrigin.y + (now.y - startMouse.y)))
        }
    }

    override func mouseDragged(with event: NSEvent)  { emit(.move, event) }
    override func mouseUp(with event: NSEvent)       { emit(.up, event) }

    private func emitCamera(_ a: ControlMessage.TouchAction, _ event: NSEvent) {
        guard cameraDragEnabled else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard let (x, y) = mapToVideo(p) else { return }
        onCamera?(a, x, y)
    }
    override func rightMouseDown(with event: NSEvent)    { emitCamera(.down, event) }
    override func rightMouseDragged(with event: NSEvent) { emitCamera(.move, event) }
    override func rightMouseUp(with event: NSEvent)      { emitCamera(.up, event) }

    override func scrollWheel(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let (x, y) = mapToVideo(p) else { return }
        onScroll?(x, y, Float(event.scrollingDeltaX) / 10, Float(event.scrollingDeltaY) / 10)
    }

    override func keyDown(with event: NSEvent) {
        if onRawKey?(event.keyCode, true) == true { return }
        if let k = MetalView.androidKeycode(for: event.keyCode) { onKey?(k, true) }
    }
    override func keyUp(with event: NSEvent) {
        if onRawKey?(event.keyCode, false) == true { return }
        if let k = MetalView.androidKeycode(for: event.keyCode) { onKey?(k, false) }
    }

    /// macOS sanal tus kodu -> Android keycode (oyun icin gerekli minimum set).
    static func androidKeycode(for mac: UInt16) -> UInt32? {
        switch mac {
        case 53:  return AKeycode.back        // Esc -> Geri
        case 36:  return AKeycode.enter
        case 51:  return AKeycode.del
        case 126: return AKeycode.dpadUp
        case 125: return AKeycode.dpadDown
        case 123: return AKeycode.dpadLeft
        case 124: return AKeycode.dpadRight
        default:  return nil
        }
    }
}
