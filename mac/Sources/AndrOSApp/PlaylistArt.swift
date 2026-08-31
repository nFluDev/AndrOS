import AppKit

/// Calma listesi gorselleri diskte tutulur (UserDefaults gorsel icin uygun degil).
enum PlaylistArt {
    private static let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory,
                                         in: .userDomainMask)[0]
            .appendingPathComponent("AndrOS/playlists", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private static func url(_ id: UUID) -> URL {
        dir.appendingPathComponent(id.uuidString + ".png")
    }

    static func save(_ image: NSImage, for id: UUID) {
        // Kucult: liste satirinda 18px gosteriliyor, tam boy saklamak gereksiz.
        let side: CGFloat = 128
        let small = NSImage(size: NSSize(width: side, height: side))
        small.lockFocus()
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side),
                   from: .zero, operation: .copy, fraction: 1)
        small.unlockFocus()
        guard let tiff = small.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url(id))
    }

    static func load(_ id: UUID) -> NSImage? {
        NSImage(contentsOf: url(id))
    }

    /// Kapak yoksa: adin ilk harfinden renkli bir kutucuk uretir.
    /// Daraltilmis listede "yalniz gorseller" istendigi icin sembol yerine
    /// her zaman bir gorsel gosteriyoruz.
    static func placeholder(_ name: String, side: CGFloat = 36) -> NSImage {
        let letter = String(name.prefix(1)).uppercased()
        // Ada gore sabit bir renk: ayni liste hep ayni renkte olsun.
        let hue = CGFloat(abs(name.hashValue % 360)) / 360.0
        let bg = NSColor(calibratedHue: hue, saturation: 0.55,
                         brightness: 0.75, alpha: 1)

        let img = NSImage(size: NSSize(width: side, height: side))
        img.lockFocus()
        let rect = NSRect(x: 0, y: 0, width: side, height: side)
        let path = NSBezierPath(roundedRect: rect, xRadius: side * 0.22,
                                yRadius: side * 0.22)
        bg.setFill(); path.fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: side * 0.46, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let sz = letter.size(withAttributes: attrs)
        letter.draw(at: NSPoint(x: (side - sz.width)/2, y: (side - sz.height)/2),
                    withAttributes: attrs)
        img.unlockFocus()
        return img
    }

    static func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(id))
    }
}
