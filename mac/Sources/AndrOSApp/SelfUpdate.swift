import AppKit
import AndrOSCore

/// Gomulu guncelleyici: paketi indirir, acar ve uygulamayi kendisiyle
/// degistirir.
///
/// Neden tarayici degil: indirmeyi tarayiciya birakmak kullaniciyi
/// "indirilenler klasorunu bul, zip'i ac, uygulamayi surukle, Gatekeeper
/// uyarisini gec" zincirine sokuyordu. Ustelik tarayiciyla inen dosyaya
/// KARANTINA damgasi vuruluyor ve imzasiz uygulama acilmiyor;
/// `URLSession` ile inen dosyaya vurulmuyor. Yani gomulu indirici hem
/// daha kisa hem daha az kirik.
enum SelfUpdate {

    /// Indir → ac → yerine koy → yeniden baslat.
    static func run(from urlString: String, version: String) {
        guard let url = URL(string: urlString) else { return }
        let panel = ProgressPanel(version: version)
        panel.show()

        let task = URLSession.shared.downloadTask(with: url) { tmp, resp, err in
            DispatchQueue.main.async {
                if let err {
                    panel.fail(err.localizedDescription); return
                }
                guard let tmp,
                      let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                    panel.fail("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
                    return
                }
                // Gecici dosya bu blok bitince siliniyor: once tasi.
                let keep = FileManager.default.temporaryDirectory
                    .appendingPathComponent("AndrOS-\(version).zip")
                try? FileManager.default.removeItem(at: keep)
                do { try FileManager.default.moveItem(at: tmp, to: keep) }
                catch { panel.fail(error.localizedDescription); return }
                panel.status(L("Açılıyor…", "Extracting…"))
                DispatchQueue.global().async { unpackAndSwap(keep, panel: panel) }
            }
        }
        panel.onCancel = { task.cancel() }
        // Ilerleme: indirilen bayt / toplam.
        panel.observe(task)
        task.resume()
    }

    private static func unpackAndSwap(_ zip: URL, panel: ProgressPanel) {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("AndrOS-update-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: zip) }
        do { try FileManager.default.createDirectory(at: work,
                                                     withIntermediateDirectories: true) }
        catch { DispatchQueue.main.async { panel.fail(error.localizedDescription) }; return }

        // `ditto` kullaniyoruz: `unzip` paket iznini ve sembolik baglari
        // her zaman dogru tasimiyor, uygulama paketinde ikisi de var.
        let r = RawProcess.run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
        guard r.code == 0 else {
            DispatchQueue.main.async { panel.fail(L("Arşiv açılamadı.", "Could not extract.")) }
            return
        }
        guard let app = (try? FileManager.default.contentsOfDirectory(
                            at: work, includingPropertiesForKeys: nil))?
                .first(where: { $0.pathExtension == "app" }) else {
            DispatchQueue.main.async { panel.fail(L("Arşivde uygulama yok.",
                                                    "No app in the archive.")) }
            return
        }

        let target = Bundle.main.bundleURL
        // Paket olarak calismiyorsak (gelistirme sirasinda `swift run`)
        // degistirecek bir sey yok.
        guard target.pathExtension == "app" else {
            DispatchQueue.main.async {
                panel.fail(L("Uygulama paket olarak çalışmıyor; güncelleme kurulamaz.",
                             "The app is not running as a bundle; cannot install."))
            }
            return
        }
        // YAZILABILIR MI? /Applications kok kullaniciya aitse burada
        // durup soylemek, yarim kalmis bir degistirmeden iyidir.
        let parent = target.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            DispatchQueue.main.async {
                panel.fail(L("\(parent.path) yazılabilir değil. "
                           + "Güncellemeyi elle kur.",
                             "\(parent.path) is not writable. Install manually."))
            }
            return
        }

        // Degistirmeyi CALISAN uygulama yapamaz: kendi dosyalarini
        // silmis olur. Kucuk bir kabuk betigi cikmamizi bekliyor.
        let script = """
        #!/bin/sh
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        rm -rf "\(target.path)"
        /usr/bin/ditto "\(app.path)" "\(target.path)"
        /usr/bin/xattr -dr com.apple.quarantine "\(target.path)" 2>/dev/null
        rm -rf "\(work.path)"
        /usr/bin/open "\(target.path)"
        """
        let sh = work.deletingLastPathComponent()
            .appendingPathComponent("andros-update-\(UUID().uuidString).sh")
        do {
            try script.write(to: sh, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                 ofItemAtPath: sh.path)
        } catch {
            DispatchQueue.main.async { panel.fail(error.localizedDescription) }
            return
        }

        DispatchQueue.main.async {
            panel.status(L("Kuruluyor — uygulama yeniden başlayacak.",
                           "Installing — the app will restart."))
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = [sh.path]
            do { try p.run() } catch {
                panel.fail(error.localizedDescription); return
            }
            Log.write("güncelleme kuruluyor: \(app.lastPathComponent) -> \(target.path)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                NSApp.terminate(nil)
            }
        }
    }
}

/// Indirme penceresi: ilerleme, durum ve vazgecme.
final class ProgressPanel: NSObject {

    private let window: NSWindow
    private let bar = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")
    private var observation: NSKeyValueObservation?
    var onCancel: (() -> Void)?

    init(version: String) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 120),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "AndrOS \(version)"
        window.isReleasedWhenClosed = false
        super.init()

        bar.isIndeterminate = true
        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 1
        bar.startAnimation(nil)
        label.stringValue = L("İndiriliyor…", "Downloading…")
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor

        let cancel = NSButton(title: L("Vazgeç", "Cancel"), target: self,
                              action: #selector(cancel))
        cancel.bezelStyle = .rounded

        let row = NSStackView(views: [NSView(), cancel])
        row.orientation = .horizontal
        let stack = NSStackView(views: [label, bar, row])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let host = NSView()
        host.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: host.topAnchor),
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
        ])
        window.contentView = host
        window.center()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Indirme ilerlemesini cubuga baglar.
    func observe(_ task: URLSessionTask) {
        observation = task.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.bar.isIndeterminate = false
                self.bar.doubleValue = p.fractionCompleted
                self.label.stringValue = L("İndiriliyor… %\(Int(p.fractionCompleted * 100))",
                                           "Downloading… \(Int(p.fractionCompleted * 100))%")
            }
        }
    }

    func status(_ s: String) {
        label.stringValue = s
        bar.isIndeterminate = true
        bar.startAnimation(nil)
    }

    func fail(_ why: String) {
        close()
        let a = NSAlert()
        a.messageText = L("Güncelleme kurulamadı", "Could not install the update")
        a.informativeText = why
        a.addButton(withTitle: "Tamam")
        a.runModal()
    }

    func close() {
        observation = nil
        window.orderOut(nil)
    }

    @objc private func cancel() {
        onCancel?()
        close()
    }
}
