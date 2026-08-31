import AppKit

/// Calma listesi kutucugu: buyuk kapak, altinda ad (en fazla 2 satir,
/// tasarsa ucnokta) ve parca sayisi. Hepsi ayni boyutta.
final class PlaylistTile: NSCollectionViewItem {

    private let cover = NSImageView()
    let name = InlineEditLabel.label("")
    private let count = NSTextField(labelWithString: "")
    private let card = NSView()

    override func loadView() {
        let v = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        if #available(macOS 10.15, *) { card.layer?.cornerCurve = .continuous }
        card.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
        card.translatesAutoresizingMaskIntoConstraints = false

        cover.imageScaling = .scaleProportionallyUpOrDown
        cover.wantsLayer = true
        cover.layer?.cornerRadius = 9
        if #available(macOS 10.15, *) { cover.layer?.cornerCurve = .continuous }
        cover.layer?.masksToBounds = true
        cover.translatesAutoresizingMaskIntoConstraints = false

        name.font = .systemFont(ofSize: 12, weight: .medium)
        name.maximumNumberOfLines = 2
        name.lineBreakMode = .byTruncatingTail
        name.alignment = .left
        name.translatesAutoresizingMaskIntoConstraints = false

        count.font = .systemFont(ofSize: 10)
        count.textColor = .secondaryLabelColor
        count.translatesAutoresizingMaskIntoConstraints = false

        v.addSubview(card)
        card.addSubview(cover)
        card.addSubview(name)
        card.addSubview(count)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: v.topAnchor),
            card.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: v.bottomAnchor),

            cover.topAnchor.constraint(equalTo: card.topAnchor, constant: 9),
            cover.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 9),
            cover.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -9),
            cover.heightAnchor.constraint(equalTo: cover.widthAnchor),

            name.topAnchor.constraint(equalTo: cover.bottomAnchor, constant: 8),
            name.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            name.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),

            count.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2),
            count.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            count.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -10),
        ])
        view = v
    }

    func configure(title: String, count n: Int, image: NSImage?) {
        name.stringValue = title
        count.stringValue = L("\(n) parça", "\(n) tracks")
        cover.image = image
        view.toolTip = title
    }

    override var isSelected: Bool {
        didSet {
            card.layer?.borderWidth = isSelected ? 2 : 0
            card.layer?.borderColor = NSColor.controlAccentColor.cgColor
        }
    }
}
