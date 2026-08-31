import AppKit

/// Kalan sureyi %100'den %0'a inen bir cubukla gosterir.
///
/// Neden geri sayim yazisi degil: rakam okumak dikkat istiyor; kullanicinin
/// bilmesi gereken tek sey "daha vaktim var mi". Cubuk bunu bir bakista
/// veriyor ve azaldikca rengi uyariya donuyor.
final class CountdownBar: NSView {

    /// Bir tur bitince cagrilir (yeni kod uretilmeli).
    var onExpire: (() -> Void)?
    /// Tur suresi.
    var period: TimeInterval = 15

    private var startedAt = Date()
    private var timer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 4) }

    func restart() {
        startedAt = Date()
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.remaining <= 0 {
                self.startedAt = Date()
                self.onExpire?()
            }
            self.needsDisplay = true
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        needsDisplay = true
    }

    func stop() { timer?.invalidate(); timer = nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() }
    }

    private var remaining: TimeInterval {
        max(0, period - Date().timeIntervalSince(startedAt))
    }

    override func draw(_ dirtyRect: NSRect) {
        let frac = remaining / period
        let r = bounds.insetBy(dx: 0, dy: 0)
        let radius = r.height / 2

        NSColor.labelColor.withAlphaComponent(0.10).setFill()
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()

        guard frac > 0 else { return }
        // Son ucte bir turuncuya doner: "acele et" sinyali.
        let tint: NSColor = frac < 0.33 ? .systemOrange : .controlAccentColor
        tint.setFill()
        let w = max(r.height, r.width * frac)
        NSBezierPath(roundedRect: NSRect(x: r.minX, y: r.minY, width: w, height: r.height),
                     xRadius: radius, yRadius: radius).fill()
    }
}
