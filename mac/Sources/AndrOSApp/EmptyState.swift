import AppKit

/// Hassas degerleri gizleyen ortak maskeleme.
///
/// Seri numarasi ve IP gibi seyler ekran paylasirken ya da yanindaki biri
/// varken goze carpmamali. Deger TAMAMEN silinmiyor: sekli hakkinda fikir
/// versin diye bas/son iki karakter duruyor.
enum Privacy {
    static func mask(_ s: String) -> String {
        guard s.count > 4 else { return String(repeating: "•", count: max(s.count, 3)) }
        let c = Array(s)
        return String(c.prefix(2)) + String(repeating: "•", count: min(c.count - 4, 14))
             + String(c.suffix(2))
    }
}

/// Panel bosken icerik alaninin TAM ORTASINDA duran durum mesaji.
///
/// Once bu mesaj listenin kaydirma yiginina ekleniyordu; yigin ustten
/// hizalandigi icin mesaj tepede duruyor, panel boyutu degisince
/// kayiyordu. Burada yerlesim ELLE yapiliyor — Auto Layout'un bu projede
/// sessizce yanlis sonuc urettigi yerlerdeki cozumun aynisi — boylece
/// mesaj her boyutta tam merkezde kaliyor.
final class EmptyStateView: NSView {
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.contentTintColor = .tertiaryLabelColor
        icon.imageScaling = .scaleProportionallyUpOrDown

        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.alignment = .center

        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .tertiaryLabelColor
        detailLabel.alignment = .center
        detailLabel.maximumNumberOfLines = 6
        detailLabel.lineBreakMode = .byWordWrapping

        for v in [icon, titleLabel, detailLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = true
            addSubview(v)
        }
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ title: String, _ detail: String, symbol: String) {
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 34, weight: .regular))
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        // Katman panel daha olculmeden once olusmus olabilir; gosterirken
        // cerceveyi ust view'a esitliyoruz. Sonraki boyut degisimlerini
        // autoresizing maskesi tasiyor.
        if let sv = superview { frame = sv.bounds }
        isHidden = false
        needsLayout = true
    }

    /// Katman TIKLAMALARI GECIRIR: panelin ustune serildigi icin aksi
    /// halde arac cubugu ve arama kutusu tiklanamaz olurdu.
    override func hitTest(_ p: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        guard !isHidden else { return }
        let maxW = min(bounds.width - 48, 420)
        guard maxW > 0 else { return }

        let iconH: CGFloat = icon.image == nil ? 0 : 40
        titleLabel.preferredMaxLayoutWidth = maxW
        detailLabel.preferredMaxLayoutWidth = maxW
        let tH = titleLabel.stringValue.isEmpty ? 0 : titleLabel.sizeThatFits(
            NSSize(width: maxW, height: .greatestFiniteMagnitude)).height
        let dH = detailLabel.stringValue.isEmpty ? 0 : detailLabel.sizeThatFits(
            NSSize(width: maxW, height: .greatestFiniteMagnitude)).height

        let gap: CGFloat = 8
        let total = iconH + (iconH > 0 ? gap : 0) + tH + (dH > 0 ? gap : 0) + dH
        var y = (bounds.height + total) / 2      // ustten asagi ilerliyoruz

        if iconH > 0 {
            y -= iconH
            icon.frame = NSRect(x: (bounds.width - 40) / 2, y: y, width: 40, height: iconH)
            y -= gap
        }
        y -= tH
        titleLabel.frame = NSRect(x: (bounds.width - maxW) / 2, y: y, width: maxW, height: tH)
        if dH > 0 {
            y -= gap + dH
            detailLabel.frame = NSRect(x: (bounds.width - maxW) / 2, y: y, width: maxW, height: dH)
        }
    }
}

extension NSViewController {
    /// Panelin kokune yapisan, her boyutta ortada kalan bos-durum katmani.
    func emptyState() -> EmptyStateView {
        if let e = view.subviews.compactMap({ $0 as? EmptyStateView }).first { return e }
        let e = EmptyStateView(frame: view.bounds)
        e.autoresizingMask = [.width, .height]
        e.translatesAutoresizingMaskIntoConstraints = true
        view.addSubview(e)
        return e
    }
}
