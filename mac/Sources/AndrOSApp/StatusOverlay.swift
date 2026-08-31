import AppKit

/// Kare akmadigi surece pencerede ne oldugunu anlatan katman.
///
/// Bunsuz pencere sadece siyah duruyordu ve kullanici uygulamanin
/// bozuldugunu saniyordu — bagliyor mu, kilit mi bekliyor, hata mi var
/// hicbiri belli olmuyordu.
final class StatusOverlay: NSView {

    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let iconView = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        // Aynayla AYNI kose yaricapi: aksi halde bu katman goruntunun
        // uzerine koseli siyah bir kare olarak biniyor ve pencerenin
        // yuvarlak koseleri bozulmus gibi gorunuyor.
        layer?.cornerRadius = 12
        if #available(macOS 10.15, *) { layer?.cornerCurve = .continuous }
        layer?.masksToBounds = true

        // ZEMIN SIYAH: sistem anlamsal renkleri (labelColor vb.) acik temada
        // KOYU oluyor ve yazi siyah uzerinde kayboluyor. Bu yuzden hem
        // katmani koyu temaya sabitliyoruz hem de acik renkleri elle veriyoruz.
        appearance = NSAppearance(named: .darkAqua)

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = NSColor(calibratedWhite: 0.80, alpha: 1)

        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = NSColor(calibratedWhite: 0.97, alpha: 1)
        title.alignment = .center

        detail.font = .systemFont(ofSize: 12)
        detail.textColor = NSColor(calibratedWhite: 0.72, alpha: 1)
        detail.alignment = .center
        detail.maximumNumberOfLines = 4
        detail.lineBreakMode = .byWordWrapping
        detail.preferredMaxLayoutWidth = 380

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let stack = NSStackView(views: [iconView, title, detail, spinner])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            iconView.widthAnchor.constraint(equalToConstant: 44),
            iconView.heightAnchor.constraint(equalToConstant: 44),
        ])
        // Tiklamalari gecirme: altta bir sey yok, ama fare olaylari
        // pencereye gitsin ki ⌘+surukleme calissin.
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Katmani gunceller. `symbol` nil ise ikon gizlenir.
    func show(title t: String, detail d: String, symbol: String?, busy: Bool) {
        title.stringValue = t
        detail.stringValue = d
        detail.isHidden = d.isEmpty
        if let s = symbol {
            let cfg = NSImage.SymbolConfiguration(pointSize: 34, weight: .regular)
            iconView.image = NSImage(systemSymbolName: s, accessibilityDescription: t)?
                .withSymbolConfiguration(cfg)
            iconView.isHidden = false
        } else {
            iconView.isHidden = true
        }
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        isHidden = false
    }

    func hide() {
        spinner.stopAnimation(nil)
        isHidden = true
    }
}
