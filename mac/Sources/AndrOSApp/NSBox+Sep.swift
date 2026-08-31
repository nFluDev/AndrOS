import AppKit

extension NSBox {
    /// Arac cubugunda kullanilan ince dikey ayirac.
    static func vSeparator() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        b.translatesAutoresizingMaskIntoConstraints = false
        b.heightAnchor.constraint(equalToConstant: 22).isActive = true
        b.widthAnchor.constraint(equalToConstant: 1).isActive = true
        return b
    }
}
