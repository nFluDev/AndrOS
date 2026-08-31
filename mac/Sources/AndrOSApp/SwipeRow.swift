import AppKit

/// Yatay surukleyince eylem tetikleyen satir.
///
/// Samsung'un telefon yoneticisindeki gibi: satiri saga cekip birakmak
/// arar, sola cekmek mesaj yazar. Surukleme sirasinda satir parmagi
/// takip ediyor ve arkada eylemin ikonu beliriyor — birakmadan once ne
/// olacagi gorunuyor.
final class SwipeRow: NSStackView {

    var onSwipeRight: (() -> Void)?
    var onSwipeLeft: (() -> Void)?
    /// Eylemin tetiklenmesi icin gereken en az mesafe.
    var threshold: CGFloat = 60

    private var dragging = false
    private var startX: CGFloat = 0
    private var offset: CGFloat = 0
    private let hint = NSTextField(labelWithString: "")

    /// Satirin HER YERINDEN surukleme.
    ///
    /// Olculen sorun: isim/ikon gibi alt gorunumler fare olayini kendi
    /// aliyordu; surukleme yalniz satirin BOS kismindan isliyordu.
    /// Burada dugme olmayan her alt gorunumun yerine satirin kendisi
    /// donuyor — dugmeler (varsa) calismaya devam ediyor.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let v = super.hitTest(point) else { return nil }
        if v === self { return self }
        var n: NSView? = v
        while let cur = n, cur !== self {
            if cur is NSControl, !(cur is NSTextField) { return v }
            n = cur.superview
        }
        return self
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard hint.superview == nil, let sv = superview else { return }
        hint.font = .systemFont(ofSize: 12, weight: .semibold)
        hint.alignment = .center
        hint.isHidden = true
        sv.addSubview(hint, positioned: .below, relativeTo: self)
    }

    override func mouseDown(with e: NSEvent) {
        startX = e.locationInWindow.x
        dragging = false
        offset = 0
        // Hareket boyunca tazelemeler ertelensin: yarida liste yenilenince
        // satir yeniden ciziliyor ve hareket bozuluyordu.
        UserBusy.begin()
    }

    override func mouseDragged(with e: NSEvent) {
        let dx = e.locationInWindow.x - startX
        // Kucuk titremeleri suruklemeye cevirmiyoruz.
        if !dragging && abs(dx) < 6 { return }
        dragging = true
        offset = dx
        setFrameOrigin(NSPoint(x: dx, y: frame.origin.y))

        let ready = abs(dx) >= threshold
        hint.isHidden = false
        hint.frame = NSRect(x: dx > 0 ? 12 : (superview?.bounds.width ?? 0) - 120,
                            y: frame.midY - 9, width: 108, height: 18)
        hint.stringValue = dx > 0 ? L("Ara", "Call") : L("Mesaj yaz", "Message")
        hint.alignment = dx > 0 ? .left : .right
        hint.textColor = ready ? (dx > 0 ? .systemGreen : .controlAccentColor)
                               : .tertiaryLabelColor
    }

    override func mouseUp(with e: NSEvent) {
        let fire = dragging && abs(offset) >= threshold
        let right = offset > 0
        UserBusy.end()
        dragging = false
        hint.isHidden = true
        // Yerine YUMUSAKCA don.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrameOrigin(NSPoint(x: 0, y: frame.origin.y))
        }
        guard fire else {
            // Surukleme degilse SATIR SECIMI kaybolmasin.
            //
            // Satirin tamami artik fareyi kendi aldigi icin tablonun
            // secim dongusu hic calismiyor; secimi elle yapiyoruz.
            // (Olay zincirine geri vermek tablonun kendi izleme
            // dongusunu baslatip suruklemeyi yiyordu.)
            selectOwnRow(extend: e.modifierFlags.contains(.shift),
                         toggle: e.modifierFlags.contains(.command))
            return
        }
        if right { onSwipeRight?() } else { onSwipeLeft?() }
    }

    /// Bu satirin tablodaki sirasini bulup secer (⇧ ve ⌘ dahil).
    private func selectOwnRow(extend: Bool, toggle: Bool) {
        var v: NSView? = self
        while let cur = v, !(cur is NSTableView) { v = cur.superview }
        guard let table = v as? NSTableView else { return }
        let row = table.row(for: self)
        guard row >= 0 else { return }
        if toggle {
            var set = table.selectedRowIndexes
            if set.contains(row) { set.remove(row) } else { set.insert(row) }
            table.selectRowIndexes(set, byExtendingSelection: false)
        } else if extend, let anchor = table.selectedRowIndexes.first {
            let lo = min(anchor, row), hi = max(anchor, row)
            table.selectRowIndexes(IndexSet(lo...hi), byExtendingSelection: false)
        } else {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
    }
}
