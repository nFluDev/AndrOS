import AppKit
import AndrOSCore

/// Uygulama ayarlari.
///
/// Pencerenin sag alt kosesindeki disliden aciliyor ve bir POPOVER
/// olarak beliriyor — ayri bir pencere acmak bu boyuttaki bir ayar
/// kumesi icin fazla.
///
/// Her satirin altinda NE YAPTIGI yaziyor. Bir anahtarin anlamini
/// tahmin ettirmek, kullaniciyi ya hic dokundurmuyor ya da yanlislikla
/// actiriyor.
final class SettingsPanel: NSViewController {

    static let shared = SettingsPanel()

    var onOpenDevices: (() -> Void)?
    var onClose: (() -> Void)?

    private let width: CGFloat = 340
    private let statusLine = NSTextField(labelWithString: "")
    private var updateButton: NSButton?

    override func loadView() {
        let root = NSView()

        let title = NSTextField(labelWithString: L("Ayarlar", "Settings"))
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        let version = NSTextField(labelWithString: Self.versionLine())
        version.font = .systemFont(ofSize: 11)
        version.textColor = .secondaryLabelColor

        // --- Genel
        let general = section(L("GENEL", "GENERAL"), [
            toggle(L("Girişte başlat", "Start at login"),
                   L("Mac açıldığında AndrOS kendiliğinden çalışır.",
                     "AndrOS runs automatically when the Mac starts."),
                   key: "runAtLogin", default: false) { on in
                LoginItem.setEnabled(on)
            },
            toggle(L("Otomatik güncelleme", "Automatic updates"),
                   L("Yeni sürüm çıktığında haber verir. Kurulumu sen onaylarsın.",
                     "Tells you when a new version is out. You approve the install."),
                   key: "autoUpdate", default: true) { _ in },
        ])

        // --- Telefondan Mac'i yonetme
        let remote = section(L("TELEFONDAN YÖNETME", "CONTROL FROM PHONE"), [
            toggle(L("Telefon dokunmatik yüzey olsun", "Use the phone as a trackpad"),
                   L("Telefondaki Kumanda sekmesi Mac'in faresi ve klavyesi olur. "
                   + "macOS bunun için Erişilebilirlik izni ister.",
                     "The Control tab on the phone drives the Mac's mouse and keyboard. "
                   + "macOS asks for the Accessibility permission for this."),
                   key: "remoteControl", default: true) { on in
                // Izni ACARKEN soruyoruz: kapatirken sormak sacma olurdu.
                if on, !RemoteControl.isTrusted { RemoteControl.requestTrust() }
            },
            axRow(),
        ])

        // --- AndrOS agi
        signalField.stringValue = SignalHub.serverURL
        signalField.placeholderString = "wss://sunucu/ws"
        signalField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        signalField.target = self
        signalField.action = #selector(signalURLChanged)
        signalIdentity.stringValue = L("Kimliğin: \(SignalHub.shared.id)",
                                       "Your identity: \(SignalHub.shared.id)")
        signalIdentity.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        signalIdentity.textColor = .tertiaryLabelColor
        let signalNote = NSTextField(labelWithString:
            L("Uçtan uca şifreli mesaj ve arama için kendi sunucun. Sunucu içeriği "
            + "göremez; yalnızca iki cihazı tanıştırır. Boş bırakırsan ağ kapalı kalır.",
              "Your own server for end-to-end encrypted messages and calls. It cannot "
            + "read content; it only introduces two devices. Leave empty to keep the "
            + "network off."))
        signalNote.font = .systemFont(ofSize: 10)
        signalNote.textColor = .secondaryLabelColor
        signalNote.maximumNumberOfLines = 3
        signalNote.preferredMaxLayoutWidth = 420
        let signalStack = NSStackView(views: [head(L("ANDROS AĞI", "ANDROS NETWORK")),
                                              signalField, signalIdentity, signalNote])
        signalStack.orientation = .vertical
        signalStack.alignment = .leading
        signalStack.spacing = 6

        // --- Menu cubugu
        let menubar = section(L("MENÜ ÇUBUĞU", "MENU BAR"), [
            toggle(L("Yansıtma yönetimi", "Mirroring controls"),
                   L("Menü çubuğu panelinde başlat/durdur düğmesi.",
                     "Start/stop button in the menu bar panel."),
                   key: "mbMirroring", default: true) { _ in
                NotificationCenter.default.post(name: .androsSettingsChanged, object: nil)
            },
            toggle(L("Oynatıcı", "Player"),
                   L("Müzik ve video çalarken menü çubuğunda kontrol.",
                     "Controls in the menu bar while music or video plays."),
                   key: "mbPlayer", default: true) { _ in
                NotificationCenter.default.post(name: .androsSettingsChanged, object: nil)
            },
            toggle(L("Kamera simgesi", "Camera icon"),
                   L("Kamera açıkken menü çubuğunda simge ve mini oynatıcı.",
                     "Icon and mini player in the menu bar while the camera is on."),
                   key: "mbCamera", default: true) { _ in
                NotificationCenter.default.post(name: .androsSettingsChanged, object: nil)
            },
            toggle(L("Menü çubuğu animasyonları", "Menu bar animation"),
                   L("Uzun parça adları kayarak görünür. Kapalıyken kırpılır.",
                     "Long track names scroll. When off they are truncated."),
                   key: "mbAnimate", default: true) { _ in
                NotificationCenter.default.post(name: .androsSettingsChanged, object: nil)
            },
            toggle(L("Telefon etkinlikleri", "Phone activities"),
                   L("Kurye, geri sayım, indirme gibi süren işler menü çubuğunda.",
                     "Ongoing things — delivery, countdown, downloads — in the menu bar."),
                   key: "mbActivities", default: true) { _ in
                NotificationCenter.default.post(name: .androsSettingsChanged, object: nil)
            },
        ])

        // --- Telefon
        let install = NSButton(title: L("Telefona kur…", "Install on phone…"),
                               target: self, action: #selector(installOnPhone))
        install.bezelStyle = .rounded
        let check = NSButton(title: L("Güncellemeleri denetle", "Check for updates"),
                             target: self, action: #selector(checkUpdates))
        check.bezelStyle = .rounded
        updateButton = check
        let clear = NSButton(title: L("Önbelleği temizle", "Clear cache"),
                             target: self, action: #selector(clearCache))
        clear.bezelStyle = .rounded
        let reset = NSButton(title: L("Her şeyi sıfırla…", "Reset everything…"),
                             target: self, action: #selector(resetAll))
        reset.bezelStyle = .rounded

        statusLine.font = .systemFont(ofSize: 11)
        statusLine.textColor = .tertiaryLabelColor

        let row1 = NSStackView(views: [install, check])
        row1.orientation = .horizontal; row1.distribution = .fillEqually; row1.spacing = 8
        let row2 = NSStackView(views: [clear, reset])
        row2.orientation = .horizontal; row2.distribution = .fillEqually; row2.spacing = 8

        let actions = NSStackView(views: [head(L("BAKIM", "MAINTENANCE")),
                                          row1, row2, statusLine])
        actions.orientation = .vertical
        actions.alignment = .leading
        actions.spacing = 8

        let stack = NSStackView(views: [title, version, general, remote, signalStack,
                                       menubar, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        let pad: CGFloat = 16
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: pad),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: pad),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -pad),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -pad),
            stack.widthAnchor.constraint(equalToConstant: width),
            row1.widthAnchor.constraint(equalToConstant: width),
            row2.widthAnchor.constraint(equalToConstant: width),
        ])
        view = root
    }

    static func versionLine() -> String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "AndrOS \(v) (\(b)) · macOS \(os.majorVersion).\(os.minorVersion)"
    }

    // MARK: - Parcalar

    private func head(_ t: String) -> NSTextField {
        let l = NSTextField(labelWithString: t)
        l.font = .systemFont(ofSize: 10, weight: .semibold)
        l.textColor = .tertiaryLabelColor
        return l
    }

    private func section(_ title: String, _ rows: [NSView]) -> NSView {
        let s = NSStackView(views: [head(title)] + rows)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 8
        return s
    }

    private func toggle(_ title: String, _ note: String, key: String,
                        default def: Bool, _ onChange: @escaping (Bool) -> Void) -> NSView {
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 12, weight: .medium)
        let n = NSTextField(labelWithString: note)
        n.font = .systemFont(ofSize: 10)
        n.textColor = .tertiaryLabelColor
        n.lineBreakMode = .byWordWrapping
        n.maximumNumberOfLines = 2
        n.preferredMaxLayoutWidth = width - 60

        let sw = NSSwitch()
        sw.state = (UserDefaults.standard.object(forKey: key) as? Bool ?? def) ? .on : .off
        sw.identifier = NSUserInterfaceItemIdentifier(key)
        sw.target = self
        sw.action = #selector(switched(_:))
        handlers[key] = onChange

        let texts = NSStackView(views: [t, n])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 0
        let row = NSStackView(views: [texts, flexSpacer(), sw])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: width).isActive = true
        return row
    }

    private var handlers: [String: (Bool) -> Void] = [:]

    @objc private func switched(_ s: NSSwitch) {
        guard let key = s.identifier?.rawValue else { return }
        let on = s.state == .on
        UserDefaults.standard.set(on, forKey: key)
        handlers[key]?(on)
    }

    // MARK: - Eylemler

    private let signalField = NSTextField()
    private let signalIdentity = NSTextField(labelWithString: "")

    /// Adres degisince agi yeniden kur — kullanicinin uygulamayi
    /// kapatip acmasi gerekmesin.
    @objc private func signalURLChanged() {
        let v = signalField.stringValue.trimmingCharacters(in: .whitespaces)
        guard v.isEmpty || SignalClient.isAllowed(v) else {
            statusLine.stringValue = L("Adres wss:// ile başlamalı.",
                                       "The address must start with wss://")
            return
        }
        SignalHub.serverURL = v
        statusLine.stringValue = v.isEmpty
            ? L("AndrOS ağı kapatıldı.", "AndrOS network turned off.")
            : L("Bağlanılıyor…", "Connecting…")
        if v.isEmpty { SignalHub.shared.stop() } else { SignalHub.shared.start() }
    }

    /// Erisilebilirlik izninin GERCEK durumu ve bozulduysa onarim.
    ///
    /// Listede isaretli gorunup calismamasi mumkun: macOS izni
    /// uygulamanin imzasina bagliyor ve eski surumlerin imzasi her
    /// derlemede degisiyordu. Buradaki satir "gercekten calisiyor mu"
    /// sorusunu yanitliyor.
    private func axRow() -> NSView {
        let ok = RemoteControl.isTrusted
        let label = NSTextField(labelWithString: ok
            ? L("Erişilebilirlik izni: çalışıyor", "Accessibility permission: working")
            : L("Erişilebilirlik izni: yok ya da eskimiş",
                "Accessibility permission: missing or stale"))
        label.font = .systemFont(ofSize: 11)
        label.textColor = ok ? .secondaryLabelColor : .systemOrange

        let fix = NSButton(title: L("Sıfırla", "Reset"), target: self,
                           action: #selector(resetAX))
        fix.bezelStyle = .rounded
        fix.controlSize = .small
        fix.isHidden = ok
        fix.toolTip = L("İzin kaydını siler; macOS bir daha sorar.",
                        "Removes the record so macOS asks again.")

        let row = NSStackView(views: [label, fix])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    @objc private func resetAX() {
        let r = RawProcess.run("/usr/bin/tccutil",
                               ["reset", "Accessibility", "dev.naer.andros"])
        UserDefaults.standard.set(false, forKey: "axGrantedOnce")
        statusLine.stringValue = r.code == 0
            ? L("İzin kaydı silindi — telefondan bir hareket yap, macOS yeniden soracak.",
                "Record removed — move on the phone and macOS will ask again.")
            : L("Sıfırlanamadı (kod \(r.code)).", "Could not reset (code \(r.code)).")
    }

    @objc private func installOnPhone() {
        onClose?()
        InstallSheet.present()
    }

    @objc private func checkUpdates() {
        statusLine.stringValue = L("Bakılıyor…", "Checking…")
        updateButton?.isEnabled = false
        Updates.check { [weak self] r in
            guard let self else { return }
            self.updateButton?.isEnabled = true
            switch r {
            case .upToDate:
                self.statusLine.stringValue = L("En güncel sürümdesin.",
                                                "You are up to date.")
            case .noReleases:
                self.statusLine.stringValue = L("Henüz yayımlanmış sürüm yok.",
                                                "No published releases yet.")
            case .available(let v, let url, let notes):
                self.statusLine.stringValue = L("Yeni sürüm: \(v)", "New version: \(v)")
                let a = NSAlert()
                a.messageText = L("Yeni sürüm: \(v)", "New version: \(v)")
                a.informativeText = notes.isEmpty
                    ? L("Değişiklik notu yok.", "No release notes.") : notes
                // Tarayiciya ATMIYORUZ: indirme, acma ve degistirme
                // uygulamanin icinde.
                a.addButton(withTitle: L("İndir ve kur", "Download and install"))
                a.addButton(withTitle: L("Şimdi değil", "Not now"))
                if a.runModal() == .alertFirstButtonReturn {
                    SelfUpdate.run(from: url, version: v)
                }
            case .failed(let why):
                self.statusLine.stringValue = L("Bakılamadı: \(why)",
                                                "Could not check: \(why)")
            }
        }
    }

    @objc private func clearCache() {
        let dirs = ["AndrOS/thumbs", "AndrOS/view", "AndrOS/icons", "AndrOS/art"]
        var freed = 0
        let tmp = FileManager.default.temporaryDirectory
        for d in dirs {
            let u = tmp.appendingPathComponent(d)
            freed += (try? FileManager.default.allocatedSize(of: u)) ?? 0
            try? FileManager.default.removeItem(at: u)
        }
        statusLine.stringValue = L("Önbellek temizlendi (\(FilesPanel.human(freed)))",
                                   "Cache cleared (\(FilesPanel.human(freed)))")
    }

    @objc private func resetAll() {
        let a = NSAlert()
        a.messageText = L("Her şey sıfırlansın mı?", "Reset everything?")
        a.informativeText = L(
            "Eşleşmeler, çalma listeleri, ayarlar ve önbellek silinir. "
          + "Sanal kamera ve ses sürücüsü kalır — onları ayrıca kaldırabilirsin.",
            "Pairings, playlists, settings and cache are removed. The virtual "
          + "camera and audio driver stay — you can remove those separately.")
        a.alertStyle = .warning
        a.addButton(withTitle: L("Sıfırla", "Reset"))
        a.addButton(withTitle: L("Vazgeç", "Cancel"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        if let id = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: id)
        }
        clearCache()
        statusLine.stringValue = L("Sıfırlandı. Uygulamayı yeniden başlat.",
                                   "Reset. Restart the app.")
    }
}

extension Notification.Name {
    /// Ayar degisti — menu cubugu ogelerini tazele.
    static let androsSettingsChanged = Notification.Name("androsSettingsChanged")
}

private extension FileManager {
    /// Klasorun kapladigi yer (yaklasik).
    func allocatedSize(of url: URL) throws -> Int {
        guard let e = enumerator(at: url, includingPropertiesForKeys: [.fileAllocatedSizeKey])
        else { return 0 }
        var total = 0
        for case let f as URL in e {
            total += (try? f.resourceValues(forKeys: [.fileAllocatedSizeKey]))?.fileAllocatedSize ?? 0
        }
        return total
    }
}
