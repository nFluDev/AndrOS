import AppKit
import AVKit
import AndrOSCore

/// Telefondaki bir resmi/videoyu uygulama icinde gosterir.
///
/// Neden gecici dosya: adb'nin akis (streaming) arayuzu yok, `pull` dosyayi
/// butun halinde getiriyor. Bu yuzden gecici klasore indirip oradan
/// gosteriyoruz. Ayni dosya ikinci kez istenirse yeniden indirilmiyor,
/// bu da "chunk gelmis gibi" hizli hissettiriyor.
final class MediaViewerController: NSWindowController, AVPlayerViewDelegate {

    private let imageView = NSImageView()
    private var player: AVPlayer?
    private let playerView = AVPlayerView()
    private let spinner = NSProgressIndicator()
    private let caption = NSTextField(labelWithString: "")
    private var localURL: URL?

    private static var cache: [String: URL] = [:]
    private static let cacheDir: URL = {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("AndrOS/view", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    init(title: String) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = title
        w.center()
        super.init(window: w)
        buildUI()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        guard let w = window else { return }
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor

        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        playerView.translatesAutoresizingMaskIntoConstraints = false
        // GOMULU oynaticida ".floating" kullanilmiyor: o bicim tam ekran icin
        // tasarlandigindan fare bir sure kipirdamayinca IMLECI GIZLIYOR.
        // Galeride video sekmesi acikken imlec kayboluyordu. ".inline"
        // imleci gizlemez; tam ekrana gecince asagida ".floating"e donuyor.
        playerView.controlsStyle = .inline
        playerView.delegate = self
        playerView.isHidden = true

        spinner.style = .spinning
        spinner.controlSize = .large
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        caption.font = .systemFont(ofSize: 11)
        caption.textColor = NSColor(calibratedWhite: 0.7, alpha: 1)
        caption.alignment = .center
        caption.translatesAutoresizingMaskIntoConstraints = false

        let openInFinder = NSButton(title: L("Mac'te aç", "Open on Mac"), target: self, action: #selector(openExternally))
        openInFinder.bezelStyle = .rounded
        let save = NSButton(title: L("Farklı kaydet…", "Save As…"), target: self, action: #selector(saveAs))
        save.bezelStyle = .rounded
        let bar = NSStackView(views: [openInFinder, save, caption])
        bar.orientation = .horizontal
        bar.spacing = 10
        bar.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(imageView)
        root.addSubview(playerView)
        root.addSubview(spinner)
        root.addSubview(bar)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            imageView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            imageView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            imageView.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -8),
            playerView.topAnchor.constraint(equalTo: imageView.topAnchor),
            playerView.leadingAnchor.constraint(equalTo: imageView.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: imageView.trailingAnchor),
            playerView.bottomAnchor.constraint(equalTo: imageView.bottomAnchor),
            spinner.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])
        w.contentView = root
    }

    /// Dosyayi indirip gosterir. Onbellekte varsa aninda acilir.
    func present(path: String, name: String, isVideo: Bool, data: AndroidData) {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)

        if let cached = MediaViewerController.cache[path],
           FileManager.default.fileExists(atPath: cached.path) {
            show(cached, isVideo: isVideo, name: name, cached: true)
            return
        }

        spinner.startAnimation(nil)
        caption.stringValue = L("İndiriliyor: \(name)…", "Downloading: \(name)…")
        let local = MediaViewerController.cacheDir
            .appendingPathComponent(String(abs(path.hashValue), radix: 16) + "-" + name)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok = data.pull(path, to: local.path)
            DispatchQueue.main.async {
                guard let self else { return }
                self.spinner.stopAnimation(nil)
                guard ok else {
                    self.caption.stringValue = L("İndirilemedi: \(name)", "Download failed: \(name)")
                    return
                }
                MediaViewerController.cache[path] = local
                self.show(local, isVideo: isVideo, name: name, cached: false)
            }
        }
    }

    private func show(_ url: URL, isVideo: Bool, name: String, cached: Bool) {
        localURL = url
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        caption.stringValue = "\(name) · \(FilesPanel.human(size ?? 0))"
            + (cached ? L(" · önbellekten", " · from cache") : "")

        if isVideo {
            imageView.isHidden = true
            playerView.isHidden = false
            let p = AVPlayer(url: url)
            player = p
            playerView.player = p
            p.play()
        } else {
            playerView.isHidden = true
            imageView.isHidden = false
            imageView.image = NSImage(contentsOf: url)
        }
    }

    @objc private func openExternally() {
        guard let u = localURL else { return }
        NSWorkspace.shared.open(u)
    }

    @objc private func saveAs() {
        guard let u = localURL else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = u.lastPathComponent
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: u, to: dest)
    }

    override func close() {
        player?.pause()
        player = nil
        super.close()
    }
}

/// Paket adindan okunabilir bir isim turetir.
///
/// Gercek uygulama etiketi ve ikonu icin cihazda `aapt` yok ve `dumpsys`
/// etiketi vermiyor; ikisi de AndrOS mobil uygulamasiyla gelecek
/// (`PackageManager.getApplicationLabel` orada tek satir).
enum PackageNaming {
    private static let noise: Set<String> = ["android", "gp", "mobile", "client", "main"]

    /// Paket adindan TAM okunabilir isim uretir.
    ///
    /// Onceki surum yalnizca SON anlamli parcayi aliyordu
    /// ("com.whatsapp.w4b" -> "W4b"); artik alan adi eklerini atip
    /// kalan parcalarin HEPSINI birlestiriyor ("Whatsapp W4b").
    static func friendly(_ pkg: String) -> String {
        var parts = pkg.split(separator: ".").map(String.init)
        // Bastaki alan adi eklerini at (com, net, org, io, tr...)
        while let f = parts.first, tld.contains(f.lowercased()), parts.count > 1 {
            parts.removeFirst()
        }
        // Tamami gurultuyse orijinali koru
        let meaningful = parts.filter { !noise.contains($0.lowercased()) }
        let use = meaningful.isEmpty ? parts : meaningful
        return use.map { humanize($0) }.joined(separator: " ")
    }

    private static let tld: Set<String> = ["com", "net", "org", "io", "co", "tr",
                                           "de", "ru", "cn", "me", "app", "dev"]

    /// camelCase / alt cizgi ayirip bas harfi buyutur.
    private static func humanize(_ s: String) -> String {
        var out = ""
        for (i, ch) in s.enumerated() {
            if ch == "_" || ch == "-" { out += " "; continue }
            if i > 0, ch.isUppercase, !out.hasSuffix(" ") { out += " " }
            out.append(ch)
        }
        return out.prefix(1).uppercased() + out.dropFirst()
    }

}

// MARK: - Tam ekran

extension MediaViewerController {
    /// Tam ekranda ".floating" istiyoruz: denetimler goruntunun uzerinde
    /// yuzsun ve fare durunca IMLEC GIZLENSIN — orada dogru davranis bu.
    func playerViewWillEnterFullScreen(_ v: AVPlayerView) {
        v.controlsStyle = .floating
    }
    func playerViewDidExitFullScreen(_ v: AVPlayerView) {
        v.controlsStyle = .inline
        NSCursor.unhide()   // cikista imlec gizli kalmasin
    }
}
