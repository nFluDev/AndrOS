import AppKit
import CoreImage
import AndrOSCore

/// "Telefona kur" penceresi.
///
/// Telefonu Mac'e baglamanin ilk adimi uygulamayi telefona kurmak;
/// bunu anlatmanin en kisa yolu ekranda bir karekod gostermek.
/// Kullanici telefonun kamerasini tutuyor, kurulum sayfasi aciliyor.
enum InstallSheet {

    static let url = "https://andros.gamehost.dev/install"

    static func present() {
        let vc = NSViewController()
        let root = NSView()

        let title = NSTextField(labelWithString: L("AndrOS'u telefona kur",
                                                   "Install AndrOS on your phone"))
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        let note = NSTextField(labelWithString: L(
            "Karekodu telefonunun kamerasıyla okut. Kurulum sayfası açılır; "
          + "APK'yı oradan indirip kurabilirsin.",
            "Scan the QR with your phone's camera. The install page opens and "
          + "you can download the APK from there."))
        note.font = .systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byWordWrapping
        note.maximumNumberOfLines = 3
        note.preferredMaxLayoutWidth = 300

        let qr = NSImageView()
        qr.image = makeQR(url)
        qr.wantsLayer = true
        qr.layer?.backgroundColor = NSColor.white.cgColor
        qr.layer?.cornerRadius = 10
        qr.translatesAutoresizingMaskIntoConstraints = false
        qr.widthAnchor.constraint(equalToConstant: 200).isActive = true
        qr.heightAnchor.constraint(equalToConstant: 200).isActive = true

        let link = NSButton(title: url.replacingOccurrences(of: "https://", with: ""),
                            target: nil, action: nil)
        link.bezelStyle = .inline
        link.isBordered = false
        link.contentTintColor = .controlAccentColor
        link.font = .systemFont(ofSize: 12)
        link.target = InstallActions.shared
        link.action = #selector(InstallActions.openLink)

        let copy = NSButton(title: L("Bağlantıyı kopyala", "Copy link"),
                            target: InstallActions.shared,
                            action: #selector(InstallActions.copyLink))
        copy.bezelStyle = .rounded

        let stack = NSStackView(views: [title, note, qr, link, copy])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
        ])
        vc.view = root

        let w = NSWindow(contentViewController: vc)
        w.title = L("Telefona kur", "Install on phone")
        w.styleMask = [.titled, .closable]
        w.setContentSize(NSSize(width: 340, height: 400))
        w.center()
        InstallActions.shared.window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Karekod — uygulamada eslestirme icin kullanilan uretecin ayni.
    static func makeQR(_ text: String) -> NSImage? {
        guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(text.data(using: .utf8), forKey: "inputMessage")
        f.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = f.outputImage else { return nil }
        let scaled = out.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}

/// Dugme hedefleri (NSButton zayif referans tutmuyor).
final class InstallActions: NSObject {
    static let shared = InstallActions()
    weak var window: NSWindow?

    @objc func openLink() {
        if let u = URL(string: InstallSheet.url) { NSWorkspace.shared.open(u) }
    }

    @objc func copyLink() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(InstallSheet.url, forType: .string)
    }
}
