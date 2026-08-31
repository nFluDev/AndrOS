import AppKit

/// Tek ikonlu arama: kapaliyken yalniz buyutec dugmesi gorunur, tiklayinca
/// arama kutusu acilir ve dugme GIZLENIR — NSSearchField'in kendi buyuteci
/// oldugu icin ekranda iki ikon kalmaz.
///
/// Kutu bosken odagi kaybederse kendiliginden kapanir.
final class SearchToggle: NSView, NSSearchFieldDelegate {

    /// Metin degisince cagrilir.
    var onChange: ((String) -> Void)?

    var placeholder: String = L("Ara", "Search") {
        didSet { field.placeholderString = placeholder }
    }
    var text: String { field.stringValue }

    private let button = NSButton()
    private let field = NSSearchField()
    private var widthC: NSLayoutConstraint?
    private var open = false
    /// Acikken kutunun genisligi.
    var openWidth: CGFloat = 200

    override init(frame: NSRect) {
        super.init(frame: frame)

        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.image = NSImage(systemSymbolName: "magnifyingglass",
                               accessibilityDescription: L("Ara", "Search"))?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = L("Ara", "Search")
        button.target = self
        button.action = #selector(openSearch)
        button.translatesAutoresizingMaskIntoConstraints = false

        field.placeholderString = placeholder
        field.delegate = self
        field.target = self
        field.action = #selector(changed)
        field.isHidden = true
        field.translatesAutoresizingMaskIntoConstraints = false
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false

        addSubview(button)
        addSubview(field)
        widthC = widthAnchor.constraint(equalToConstant: 24)
        widthC?.isActive = true
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 24),
            field.leadingAnchor.constraint(equalTo: leadingAnchor),
            field.trailingAnchor.constraint(equalTo: trailingAnchor),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 24),
        ])

        // ⌘F: yalniz GORUNUR paneldeki kutu acilsin. Kategoriler ayni
        // pencerede degistigi icin gizli panellerdeki kutular da bu
        // bildirimi aliyor; gorunurluk kontrolu onlari eliyor.
        NotificationCenter.default.addObserver(
            forName: .androsFocusSearch, object: nil, queue: .main) { [weak self] _ in
            guard let self, let w = self.window, w.isKeyWindow,
                  !self.isHiddenOrHasHiddenAncestor else { return }
            if self.open { w.makeFirstResponder(self.field) } else { self.openSearch() }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func openSearch() {
        guard !open else { return }
        open = true
        button.isHidden = true      // iki buyutec gorunmesin
        field.isHidden = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.allowsImplicitAnimation = true
            self.widthC?.animator().constant = self.openWidth
            self.superview?.layoutSubtreeIfNeeded()
        }, completionHandler: {
            self.window?.makeFirstResponder(self.field)
        })
    }

    /// Kutuyu kapatir (bos ve odaksizsa).
    func closeIfIdle() {
        guard open, field.stringValue.isEmpty else { return }
        close()
    }

    private func close() {
        open = false
        field.stringValue = ""
        onChange?("")
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            ctx.allowsImplicitAnimation = true
            self.widthC?.animator().constant = 24
            self.superview?.layoutSubtreeIfNeeded()
        }, completionHandler: {
            self.field.isHidden = true
            self.button.isHidden = false
        })
    }

    @objc private func changed() { onChange?(field.stringValue) }

    func controlTextDidChange(_ n: Notification) { onChange?(field.stringValue) }

    /// Odak gidince bos kutuyu topla.
    func controlTextDidEndEditing(_ n: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.closeIfIdle()
        }
    }
}
