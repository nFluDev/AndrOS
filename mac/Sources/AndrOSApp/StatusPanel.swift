import AppKit
import AndrOSCore

/// Menu cubugundaki AndrOS simgesine tiklayinca acilan DENETIM PANELI.
///
/// Eskiden burada duz bir menu vardi ve gunluk kullanilan seyler
/// (telefonu Mac'in ses aygiti yapmak, kamerayi acmak) ana pencerenin
/// icinde, kucuk kutucuklar halinde gizliydi — bulunmasi zordu ve dar
/// pencerede sigmiyordu. Artik hepsi burada: durum ustte, anahtarlar
/// altinda, her birinin ne yaptigi tek satirda yaziyor.
final class StatusPanel: NSViewController {

    static let shared = StatusPanel()

    var onOpenApp: (() -> Void)?
    var onToggleMirroring: (() -> Void)?
    var onWakePhone: (() -> Void)?
    var onQuit: (() -> Void)?
    var onAudio: ((Bool) -> Void)?
    var onCamera: ((Bool) -> Void)?
    var onMicrophone: ((Bool) -> Void)?
    var onOpenCategory: ((MainWindowController.Category) -> Void)?
    var onOpenSettings: (() -> Void)?

    private let deviceName = NSTextField(labelWithString: "")
    private let deviceState = NSTextField(labelWithString: "")
    private let dot = NSView()

    private let audioSwitch = NSSwitch()
    private let micSwitch = NSSwitch()
    private let cameraSwitch = NSSwitch()
    private let audioNote = NSTextField(labelWithString: "")
    private let cameraNote = NSTextField(labelWithString: "")
    private let mirrorButton = NSButton()

    private let width: CGFloat = 300

    override func loadView() {
        let root = NSView()

        // --- Baslik: cihaz ve durum
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true

        deviceName.font = .systemFont(ofSize: 13, weight: .semibold)
        deviceState.font = .systemFont(ofSize: 11)
        deviceState.textColor = .secondaryLabelColor

        let names = NSStackView(views: [deviceName, deviceState])
        names.orientation = .vertical
        names.alignment = .leading
        names.spacing = 1
        let head = NSStackView(views: [dot, names])
        head.orientation = .horizontal
        head.alignment = .centerY
        head.spacing = 8

        // --- Anahtarlar
        audioSwitch.target = self;  audioSwitch.action = #selector(audioChanged)
        micSwitch.target = self;    micSwitch.action = #selector(micChanged)
        cameraSwitch.target = self; cameraSwitch.action = #selector(cameraChanged)

        for l in [audioNote, cameraNote] {
            l.font = .systemFont(ofSize: 10)
            l.textColor = .tertiaryLabelColor
            l.lineBreakMode = .byWordWrapping
            l.maximumNumberOfLines = 2
            l.preferredMaxLayoutWidth = width
        }

        let audioRow = switchRow(
            L("Telefonu ses aygıtı yap", "Use phone as audio device"),
            L("Mac'in sesi telefondan çıkar", "Mac audio plays on the phone"),
            audioSwitch)
        let micRow = switchRow(
            L("Telefonun mikrofonu", "Phone microphone"),
            L("Mac'te mikrofon olarak görünür", "Appears as a microphone on the Mac"),
            micSwitch)
        let camRow = switchRow(
            L("Telefonun kamerası", "Phone camera"),
            L("Kamera kullanan uygulamalarda görünür", "Appears in apps that use a camera"),
            cameraSwitch)

        // --- Kisayollar
        mirrorButton.bezelStyle = .rounded
        mirrorButton.target = self
        mirrorButton.action = #selector(mirrorTapped)

        let openApp = NSButton(title: L("AndrOS'u aç", "Open AndrOS"),
                               target: self, action: #selector(openTapped))
        openApp.bezelStyle = .rounded
        let wake = NSButton(title: L("Telefon ekranını aç", "Wake phone screen"),
                            target: self, action: #selector(wakeTapped))
        wake.bezelStyle = .rounded

        // "Yansitma yonetimi" ayari kapaliysa dugme hic olmasin.
        let showMirror = UserDefaults.standard.object(forKey: "mbMirroring") as? Bool ?? true
        let quick = NSStackView(views: showMirror ? [mirrorButton, openApp] : [openApp])
        quick.orientation = .horizontal
        quick.distribution = .fillEqually
        quick.spacing = 8

        let jumps = NSStackView(views: [
            jump(L("Bildirimler", "Notifications"), "bell.fill", .notifications),
            jump(L("Mesajlar", "Messages"), "message.fill", .messages),
            jump(L("Dosyalar", "Files"), "folder.fill", .files),
            jump(L("Galeri", "Gallery"), "photo.fill", .gallery),
        ])
        jumps.orientation = .horizontal
        jumps.distribution = .fillEqually
        jumps.spacing = 6

        let settings = NSButton(title: L("Ayarlar…", "Settings…"),
                                target: self, action: #selector(settingsTapped))
        settings.bezelStyle = .rounded
        let quit = NSButton(title: L("AndrOS'tan çık", "Quit AndrOS"),
                            target: self, action: #selector(quitTapped))
        quit.bezelStyle = .rounded
        let bottom = NSStackView(views: [settings, quit])
        bottom.orientation = .horizontal
        bottom.distribution = .fillEqually
        bottom.spacing = 8

        let sep1 = NSBox(); sep1.boxType = .separator
        let sep2 = NSBox(); sep2.boxType = .separator

        let stack = NSStackView(views: [head, sep1, audioRow, micRow, camRow,
                                        sep2, quick, wake, jumps, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 11
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        // Bkz. CameraPanel: bosluk KISITLARLA veriliyor.
        let pad: CGFloat = 14
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: pad),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: pad),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -pad),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -pad),
            stack.widthAnchor.constraint(equalToConstant: width),
            quick.widthAnchor.constraint(equalToConstant: width),
            jumps.widthAnchor.constraint(equalToConstant: width),
            wake.widthAnchor.constraint(equalToConstant: width),
            bottom.widthAnchor.constraint(equalToConstant: width),
        ])
        view = root
    }

    /// Baslik + aciklama + anahtar; aciklama NE OLDUGUNU anlatiyor.
    private func switchRow(_ title: String, _ note: String, _ sw: NSSwitch) -> NSView {
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 12, weight: .medium)
        let n = NSTextField(labelWithString: note)
        n.font = .systemFont(ofSize: 10)
        n.textColor = .tertiaryLabelColor
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

    private func jump(_ title: String, _ symbol: String,
                      _ c: MainWindowController.Category) -> NSButton {
        let b = NSButton(title: "", target: self, action: #selector(jumpTapped(_:)))
        b.bezelStyle = .rounded
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        b.toolTip = title
        b.identifier = NSUserInterfaceItemIdentifier(c.rawValue)
        return b
    }

    // MARK: - Durum

    func refresh(deviceLabel: String, connected: Bool, mirroring: Bool) {
        deviceName.stringValue = connected ? deviceLabel : L("Cihaz yok", "No device")
        deviceState.stringValue = connected
            ? (mirroring ? L("bağlı · yansıtma açık", "connected · mirroring")
                         : L("bağlı", "connected"))
            : L("telefonu eşleştir", "pair a phone")
        dot.layer?.backgroundColor = (connected ? NSColor.systemGreen
                                                : NSColor.tertiaryLabelColor).cgColor
        mirrorButton.title = mirroring ? L("Yansıtmayı durdur", "Stop mirroring")
                                       : L("Yansıtmayı başlat", "Start mirroring")

        let d = UserDefaults.standard
        audioSwitch.state = d.bool(forKey: "audioBridgeOn") ? .on : .off
        micSwitch.state = (d.object(forKey: "audioBridgeMic") as? Bool ?? true) ? .on : .off
        cameraSwitch.state = d.bool(forKey: "cameraOn") ? .on : .off
        micSwitch.isEnabled = audioSwitch.state == .on
        for s in [audioSwitch, cameraSwitch] { s.isEnabled = connected }
    }

    // MARK: - Eylemler

    @objc private func audioChanged() {
        onAudio?(audioSwitch.state == .on)
        micSwitch.isEnabled = audioSwitch.state == .on
    }
    @objc private func micChanged()    { onMicrophone?(micSwitch.state == .on) }
    @objc private func cameraChanged() { onCamera?(cameraSwitch.state == .on) }
    @objc private func mirrorTapped()  { onToggleMirroring?() }
    @objc private func openTapped()    { onOpenApp?() }
    @objc private func wakeTapped()    { onWakePhone?() }
    @objc private func quitTapped()    { onQuit?() }
    @objc private func settingsTapped() { onOpenSettings?() }

    @objc private func jumpTapped(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let c = MainWindowController.Category(rawValue: raw) else { return }
        onOpenCategory?(c)
    }
}
