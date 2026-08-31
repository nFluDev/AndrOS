import AppKit

/// Oynarken tus konumlarini saydam olarak gosteren kilavuz.
/// Tiklamalari GECIRIR (hitTest nil) — yani oyuna mudahale etmez.
final class GuideOverlay: NSView {
    var mapper: KeyMapper?
    var videoRect: NSRect = .zero

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let m = mapper, videoRect.width > 1 else { return }

        func pt(_ nx: Double, _ ny: Double) -> NSPoint {
            NSPoint(x: videoRect.minX + CGFloat(nx) * videoRect.width,
                    y: videoRect.minY + CGFloat(1 - ny) * videoRect.height)
        }

        let c = pt(m.stickCenter.x, m.stickCenter.y)
        let r = CGFloat(m.stickRadius) * min(videoRect.width, videoRect.height)
        let ring = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r*2, height: r*2))
        NSColor.systemGreen.withAlphaComponent(0.30).setStroke()
        ring.lineWidth = 2
        ring.stroke()
        label("WASD", at: c, color: .systemGreen)

        for b in m.bindings {
            label(b.label, at: pt(b.nx, b.ny), color: .systemBlue)
        }
    }

    private func label(_ text: String, at p: NSPoint, color: NSColor) {
        let r: CGFloat = 16
        let rect = NSRect(x: p.x - r, y: p.y - r, width: r*2, height: r*2)
        let path = NSBezierPath(ovalIn: rect)
        color.withAlphaComponent(0.28).setFill(); path.fill()
        color.withAlphaComponent(0.55).setStroke(); path.lineWidth = 1.5; path.stroke()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: text.count > 2 ? 8 : 11, weight: .bold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85),
        ]
        let sz = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: p.x - sz.width/2, y: p.y - sz.height/2), withAttributes: attrs)
    }
}
