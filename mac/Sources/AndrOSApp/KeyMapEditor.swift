import AppKit
import AndrOSCore

/// Goruntunun uzerine binen tus haritalama duzenleyicisi.
/// Isaretciler surukle-birak ile tasinir; ekrana DOKUNMA gonderilmez,
/// yani duzenleme sirasinda oyuna kazara input gitmez.
final class KeyMapEditorView: NSView {

    var mapper: KeyMapper?
    /// Goruntunun view icindeki dikdortgeni (aspect-fit) — MetalView ile ayni.
    var videoRect: NSRect = .zero
    var onClose: (() -> Void)?
    var onChange: (() -> Void)?

    private enum Handle: Equatable {
        case stick
        case stickRadius
        case binding(Int)
    }

    private var dragging: Handle?
    private var capturingKeyFor: Int?      // tus atama bekleyen baglama indeksi
    private var capturingStick = false

    private let markerR: CGFloat = 21

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Konum donusumleri

    private func point(nx: Double, ny: Double) -> NSPoint {
        NSPoint(x: videoRect.minX + CGFloat(nx) * videoRect.width,
                y: videoRect.minY + CGFloat(1 - ny) * videoRect.height)   // y ters
    }
    private func norm(_ p: NSPoint) -> (Double, Double) {
        let nx = Double((p.x - videoRect.minX) / max(videoRect.width, 1))
        let ny = 1 - Double((p.y - videoRect.minY) / max(videoRect.height, 1))
        return (min(max(nx, 0), 1), min(max(ny, 0), 1))
    }

    // MARK: - Cizim

    override func draw(_ dirtyRect: NSRect) {
        guard let m = mapper else { return }
        NSColor(calibratedWhite: 0, alpha: 0.35).setFill()
        dirtyRect.fill()

        // Sanal cubuk
        let c = point(nx: m.stickCenter.x, ny: m.stickCenter.y)
        let rPx = CGFloat(m.stickRadius) * min(videoRect.width, videoRect.height)
        let ring = NSBezierPath(ovalIn: NSRect(x: c.x - rPx, y: c.y - rPx,
                                               width: rPx * 2, height: rPx * 2))
        NSColor.systemGreen.withAlphaComponent(0.18).setFill(); ring.fill()
        NSColor.systemGreen.setStroke(); ring.lineWidth = 2; ring.stroke()
        drawMarker(at: c, label: "WASD", color: .systemGreen,
                   highlighted: capturingStick)

        // Yaricap tutamagi (cemberin sagi)
        let h = NSPoint(x: c.x + rPx, y: c.y)
        let hr: CGFloat = 7
        NSColor.systemGreen.setFill()
        NSBezierPath(ovalIn: NSRect(x: h.x - hr, y: h.y - hr, width: hr*2, height: hr*2)).fill()

        // Yetenek tuslari
        for (i, b) in m.bindings.enumerated() {
            let p = point(nx: b.nx, ny: b.ny)
            drawMarker(at: p, label: b.label, color: .systemBlue,
                       highlighted: capturingKeyFor == i)
            if b.mode != .hold {
                // Mod rozeti: T = tek dokunus, R = otomatik tekrar
                let tag = b.mode == .tap ? "T" : "R"
                let a: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 9, weight: .heavy),
                    .foregroundColor: NSColor.black,
                ]
                let bp = NSPoint(x: p.x + markerR - 7, y: p.y + markerR - 7)
                NSColor.systemYellow.setFill()
                NSBezierPath(ovalIn: NSRect(x: bp.x - 7, y: bp.y - 7,
                                            width: 14, height: 14)).fill()
                let sz = tag.size(withAttributes: a)
                tag.draw(at: NSPoint(x: bp.x - sz.width/2, y: bp.y - sz.height/2),
                         withAttributes: a)
            }
        }

        // Yardim metni
        let help = L("Sürükle: taşı  •  Tıkla: tuş ata  •  Sağ tık: davranış menüsü  •  Boş alan: yeni tuş  •  Esc: kapat", "Drag: move  •  Click: assign key  •  Right click: behaviour menu  •  Empty space: new key  •  Esc: close")
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let sz = help.size(withAttributes: attrs)
        let bg = NSRect(x: (bounds.width - sz.width)/2 - 10, y: 12,
                        width: sz.width + 20, height: sz.height + 10)
        NSColor(calibratedWhite: 0, alpha: 0.65).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 8, yRadius: 8).fill()
        help.draw(at: NSPoint(x: bg.minX + 10, y: bg.minY + 5), withAttributes: attrs)
    }

    private func drawMarker(at p: NSPoint, label: String, color: NSColor,
                            highlighted: Bool) {
        let r = markerR
        let rect = NSRect(x: p.x - r, y: p.y - r, width: r*2, height: r*2)
        let path = NSBezierPath(ovalIn: rect)
        (highlighted ? NSColor.systemOrange : color).withAlphaComponent(0.85).setFill()
        path.fill()
        NSColor.white.setStroke(); path.lineWidth = 2; path.stroke()

        let text = highlighted ? "?" : label
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: label.count > 2 ? 9 : 13, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let sz = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: p.x - sz.width/2, y: p.y - sz.height/2), withAttributes: attrs)
    }

    // MARK: - Etkilesim

    private func hitTest(_ p: NSPoint) -> Handle? {
        guard let m = mapper else { return nil }
        let c = point(nx: m.stickCenter.x, ny: m.stickCenter.y)
        let rPx = CGFloat(m.stickRadius) * min(videoRect.width, videoRect.height)
        if hypot(p.x - (c.x + rPx), p.y - c.y) <= 10 { return .stickRadius }
        if hypot(p.x - c.x, p.y - c.y) <= markerR { return .stick }
        for (i, b) in m.bindings.enumerated() {
            let q = point(nx: b.nx, ny: b.ny)
            if hypot(p.x - q.x, p.y - q.y) <= markerR { return .binding(i) }
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        dragging = hitTest(p)
        if dragging == nil, let m = mapper {
            // Bos alana tiklayinca yeni bir tus ekle
            let (nx, ny) = norm(p)
            m.bindings.append(.init(key: 0, label: "?", nx: nx, ny: ny))
            capturingKeyFor = m.bindings.count - 1
            onChange?()
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let m = mapper, let d = dragging else { return }
        let p = convert(event.locationInWindow, from: nil)
        switch d {
        case .stick:
            let (nx, ny) = norm(p); m.stickCenter = (nx, ny)
        case .stickRadius:
            let c = point(nx: m.stickCenter.x, ny: m.stickCenter.y)
            let px = hypot(p.x - c.x, p.y - c.y)
            m.stickRadius = min(max(Double(px / min(videoRect.width, videoRect.height)), 0.04), 0.30)
        case .binding(let i):
            guard i < m.bindings.count else { return }
            let (nx, ny) = norm(p); m.bindings[i].nx = nx; m.bindings[i].ny = ny
        }
        capturingKeyFor = nil; capturingStick = false
        onChange?()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        // Suruklemeden birakildiysa: tus atama moduna gec
        if let d = dragging, event.clickCount == 1 {
            let p = convert(event.locationInWindow, from: nil)
            if hitTest(p) == d {
                switch d {
                case .binding(let i): capturingKeyFor = i; capturingStick = false
                case .stick: capturingStick = true; capturingKeyFor = nil
                case .stickRadius: break
                }
            }
        }
        dragging = nil
        needsDisplay = true
    }

    /// Sag tik: o tusun DAVRANIS menusu (mod secimi + sil).
    override func rightMouseDown(with event: NSEvent) {
        guard let m = mapper else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard case .binding(let i)? = hitTest(p), i < m.bindings.count else { return }

        let menu = NSMenu()
        let header = NSMenuItem(title: L("“\(m.bindings[i].label)” davranışı", "“\(m.bindings[i].label)” behaviour"),
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        for mode in KeyMapper.Mode.allCases {
            let it = NSMenuItem(title: mode.title, action: #selector(setMode(_:)),
                                keyEquivalent: "")
            it.target = self
            it.state = m.bindings[i].mode == mode ? .on : .off
            it.representedObject = [i, mode.rawValue] as [Any]
            menu.addItem(it)
        }
        menu.addItem(.separator())
        let del = NSMenuItem(title: L("Sil", "Delete"), action: #selector(deleteBinding(_:)),
                             keyEquivalent: "")
        del.target = self
        del.representedObject = i
        menu.addItem(del)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func setMode(_ sender: NSMenuItem) {
        guard let arr = sender.representedObject as? [Any],
              let i = arr.first as? Int,
              let raw = arr.last as? String,
              let mode = KeyMapper.Mode(rawValue: raw),
              let m = mapper, i < m.bindings.count else { return }
        m.bindings[i].mode = mode
        onChange?()
        needsDisplay = true
    }

    @objc private func deleteBinding(_ sender: NSMenuItem) {
        guard let i = sender.representedObject as? Int,
              let m = mapper, i < m.bindings.count else { return }
        m.bindings.remove(at: i)
        capturingKeyFor = nil
        onChange?()
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 || event.keyCode == 51 {   // Esc / Backspace
            onClose?(); return
        }
        guard let m = mapper else { return }
        if let i = capturingKeyFor, i < m.bindings.count {
            m.bindings[i].key = event.keyCode
            m.bindings[i].label = KeyMapEditorView.label(for: event)
            capturingKeyFor = nil
            onChange?()
            needsDisplay = true
        }
    }

    /// Tus kodu -> okunabilir etiket.
    static func label(for e: NSEvent) -> String {
        if let c = e.charactersIgnoringModifiers, !c.isEmpty,
           let f = c.unicodeScalars.first, f.value >= 33, f.value < 127 {
            return c.uppercased()
        }
        switch e.keyCode {
        case 49: return "SPC"
        case 36: return "RET"
        case 48: return "TAB"
        case 56, 60: return "SHF"
        case 59, 62: return "CTL"
        case 123: return "←"; case 124: return "→"
        case 125: return "↓";  case 126: return "↑"
        default: return "\(e.keyCode)"
        }
    }
}
