import AppKit
import AndrOSCore

/// Cihaz listesi ve yansitma denetimi.
/// Goruntu AYRI bir pencerede acilir; boylece yansitirken ana penceredeki
/// Mesajlar/Dosyalar/Galeri rahatca kullanilabilir.
final class MirroringPanel: NSViewController, AndrOSPanel,
                            NSTableViewDataSource, NSTableViewDelegate {
    var data: AndroidData?

    var onStart: ((HubDevice) -> Void)?
    var onStop: (() -> Void)?
    /// Ayar degisince AppDelegate'e bildirir (anahtar, deger).
    var onSetting: ((String, Any) -> Void)?

    private var devices: [HubDevice] = []
    private let table = NSTableView()
    private let startButton = NSButton()
    private let stopButton = NSButton()
    private let note = NSTextField(labelWithString: "")
    private let listArea = NSView()
    private let mirrorArea = NSView()
    private var lastSignature = ""
    private let bitratePopup = NSPopUpButton()
    private let fpsPopup = NSPopUpButton()
    private var sliderLabels: [String: (NSTextField, String)] = [:]
    private var sliders: [String: NSSlider] = [:]

    /// Etiketli, UserDefaults'a bagli kaydirac satiri.
    private func slider(_ title: String, _ key: String,
                        _ lo: Double, _ hi: Double, _ fallback: Double) -> NSView {
        let value = UserDefaults.standard.object(forKey: key) as? Double ?? fallback
        let label = NSTextField(labelWithString: String(format: "%@  %.2f", title, value))
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 108).isActive = true

        let sl = NSSlider(value: value, minValue: lo, maxValue: hi,
                          target: self, action: #selector(sliderMoved(_:)))
        sl.controlSize = .small
        sl.identifier = NSUserInterfaceItemIdentifier(key)
        sl.translatesAutoresizingMaskIntoConstraints = false
        sl.widthAnchor.constraint(equalToConstant: 190).isActive = true

        sliderLabels[key] = (label, title)
        sliders[key] = sl
        let row = NSStackView(views: [label, sl])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    @objc private func sliderMoved(_ sender: NSSlider) {
        guard let k = sender.identifier?.rawValue else { return }
        let v = sender.doubleValue
        UserDefaults.standard.set(v, forKey: k)
        if let (lbl, t) = sliderLabels[k] {
            lbl.stringValue = String(format: "%@  %.2f", t, v)
        }
        onSetting?(k, v)
    }

    @objc private func resetImage() {
        let defaults: [String: Double] = ["saturation": 1.15, "sharpen": 0.45,
                                          "contrast": 1.05, "gamma": 1.0]
        for (k, v) in defaults {
            UserDefaults.standard.set(v, forKey: k)
            sliders[k]?.doubleValue = v
            if let (lbl, t) = sliderLabels[k] { lbl.stringValue = String(format: "%@  %.2f", t, v) }
            onSetting?(k, v)
        }
    }

    /// UserDefaults'a bagli bir onay kutusu uretir.
    private func check(_ title: String, _ key: String, _ fallback: Bool,
                       _ tip: String) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: self, action: #selector(toggled(_:)))
        b.state = (UserDefaults.standard.object(forKey: key) as? Bool ?? fallback) ? .on : .off
        b.identifier = NSUserInterfaceItemIdentifier(key)
        b.toolTip = tip.isEmpty ? nil : tip
        b.font = .systemFont(ofSize: 12)
        return b
    }

    @objc private func toggled(_ sender: NSButton) {
        guard let k = sender.identifier?.rawValue else { return }
        let v = sender.state == .on
        UserDefaults.standard.set(v, forKey: k)
        onSetting?(k, v)
    }

    @objc private func bitrateChanged() {
        let mbps = [8, 16, 24, 40][bitratePopup.indexOfSelectedItem]
        UserDefaults.standard.set(mbps * 1_000_000, forKey: "bitRate")
        onSetting?("bitRate", mbps * 1_000_000)
    }

    @objc private func fpsChanged() {
        let f = [30, 45, 60][fpsPopup.indexOfSelectedItem]
        UserDefaults.standard.set(f, forKey: "maxFPS")
        onSetting?("maxFPS", f)
    }

    override func loadView() {
        let root = NSView()

        // --- Cihaz listesi
        let col = NSTableColumn(identifier: .init("d"))
        col.width = 460
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 50
        table.dataSource = self
        table.delegate = self
        table.doubleAction = #selector(start)
        table.target = self
        let scroll = scrollWrap(table)

        startButton.title = L("Yansıtmayı başlat", "Start mirroring")
        startButton.bezelStyle = .rounded
        startButton.keyEquivalent = "\r"
        startButton.target = self
        startButton.action = #selector(start)

        note.font = .systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor
        note.maximumNumberOfLines = 3
        note.preferredMaxLayoutWidth = 460

        // --- Yansitmaya ozel ayarlar (eskiden yalniz ayna penceresindeydi)
        let settingsTitle = NSTextField(labelWithString: L("Yansıtma ayarları", "Mirroring settings"))
        settingsTitle.font = .systemFont(ofSize: 12, weight: .semibold)

        let audio = check("Sesi Mac'e aktar", "audioOn", true,
                          L("Açıkken telefonun hoparlöründen ses gelmez", "While on, the phone speaker stays silent"))
        let screenOff = check(L("Telefon ekranını kapat", "Turn the phone screen off"), "screenOff", true,
                              L("Yansıtma sürerken telefon paneli söner, pil harcamaz", "The phone panel stays dark while mirroring, saving battery"))
        let smooth = check(L("Akıcılık önceliği", "Prefer smoothness"), "smoothing", true,
                           L("Kare kuyruğu ile titremeyi azaltır (+~17 ms gecikme)", "Reduces jitter with a frame queue (+~17 ms latency)"))
        let clip = check("Pano senkronizasyonu", "clipboardSync", true, "")
        let autoc = check(L("Açılışta otomatik bağlan", "Connect automatically at launch"), "autoConnect", true, "")

        let bitrateLabel = NSTextField(labelWithString: L("Bit hızı", "Bit rate"))
        bitratePopup.addItems(withTitles: ["8 Mbps", "16 Mbps", "24 Mbps", "40 Mbps"])
        let savedBR = UserDefaults.standard.object(forKey: "bitRate") as? Int ?? 24_000_000
        bitratePopup.selectItem(at: [8, 16, 24, 40].firstIndex(of: savedBR / 1_000_000) ?? 2)
        bitratePopup.target = self
        bitratePopup.action = #selector(bitrateChanged)

        let fpsLabel = NSTextField(labelWithString: L("Azami FPS", "Max FPS"))
        fpsPopup.addItems(withTitles: ["30", "45", "60"])
        let savedFPS = UserDefaults.standard.object(forKey: "maxFPS") as? Int ?? 60
        fpsPopup.selectItem(at: [30, 45, 60].firstIndex(of: savedFPS) ?? 2)
        fpsPopup.target = self
        fpsPopup.action = #selector(fpsChanged)

        let rowA = NSStackView(views: [bitrateLabel, bitratePopup, fpsLabel, fpsPopup])
        rowA.orientation = .horizontal
        rowA.spacing = 8

        // --- Goruntu ayarlari (eskiden yalniz menu cubugundaydi)
        let imageTitle = NSTextField(labelWithString: L("Görüntü", "Image"))
        imageTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        let sat  = slider("Doygunluk", "saturation", 0.5, 2.0, 1.15)
        let shrp = slider("Keskinlik", "sharpen",   0.0, 1.5, 0.45)
        let cont = slider("Kontrast",  "contrast",  0.7, 1.6, 1.05)
        let gam  = slider("Gama",      "gamma",     0.7, 1.5, 1.00)
        let reset = NSButton(title: L("Görüntüyü sıfırla", "Reset image"), target: self,
                             action: #selector(resetImage))
        reset.bezelStyle = .rounded

        // Burada YALNIZ baslatmadan once secilen ayarlar var.
        // Yayin sururken degistirilebilenler (ses, ekran, goruntu kaydiraclari)
        // Android Mirroring penceresindeki PANELIN ayarlarinda.
        let hint = NSTextField(labelWithString:
            L("Ses, telefon ekranı ve görüntü ayarları yansıtma penceresindeki panelde (⚙).", "Audio, phone screen and image settings live in the mirroring window's panel (⚙)."))
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        hint.maximumNumberOfLines = 2
        hint.preferredMaxLayoutWidth = 420
        let settings = NSStackView(views: [settingsTitle, autoc, rowA, hint])
        settings.orientation = .vertical
        settings.alignment = .leading
        settings.spacing = 5

        let listStack = NSStackView(views: [scroll, startButton, note, settings])
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 10
        listStack.translatesAutoresizingMaskIntoConstraints = false
        listArea.addSubview(listStack)
        NSLayoutConstraint.activate([
            listStack.topAnchor.constraint(equalTo: listArea.topAnchor),
            listStack.leadingAnchor.constraint(equalTo: listArea.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: listArea.trailingAnchor),
            listStack.bottomAnchor.constraint(equalTo: listArea.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: listStack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
        ])

        // --- Canli goruntu alani
        stopButton.title = L("Yansıtmayı durdur", "Stop mirroring")
        stopButton.bezelStyle = .rounded
        stopButton.target = self
        stopButton.action = #selector(stop)
        stopButton.translatesAutoresizingMaskIntoConstraints = false
        mirrorArea.addSubview(stopButton)
        NSLayoutConstraint.activate([
            stopButton.topAnchor.constraint(equalTo: mirrorArea.topAnchor),
            stopButton.trailingAnchor.constraint(equalTo: mirrorArea.trailingAnchor),
        ])

        listArea.translatesAutoresizingMaskIntoConstraints = false
        mirrorArea.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(listArea)
        root.addSubview(mirrorArea)
        NSLayoutConstraint.activate([
            listArea.topAnchor.constraint(equalTo: root.topAnchor),
            listArea.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            listArea.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            listArea.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            mirrorArea.topAnchor.constraint(equalTo: root.topAnchor),
            mirrorArea.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            mirrorArea.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            mirrorArea.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        mirrorArea.isHidden = true
        view = root
    }

    func didAppear() {}

    func update(_ list: [HubDevice], mirroring: Bool) {
        // Liste degismediyse reload ETME: secim kayboluyordu.
        let sig = list.map(\.serial).joined(separator: ",")
        if sig != lastSignature {
            lastSignature = sig
            let keep = table.selectedRow >= 0 && table.selectedRow < devices.count
                ? devices[table.selectedRow].serial : nil
            devices = list
            table.reloadData()
            if let k = keep, let i = list.firstIndex(where: { $0.serial == k }) {
                table.selectRowIndexes([i], byExtendingSelection: false)
            } else if !list.isEmpty, table.selectedRow < 0 {
                table.selectRowIndexes([0], byExtendingSelection: false)
            }
        } else {
            devices = list
        }
        startButton.isEnabled = !list.isEmpty && !mirroring
        // NEDEN BOS oldugunu ACIKCA soyle.
        note.stringValue = list.isEmpty
            ? L("Cihaz yok. Telefondaki AndrOS uygulamasını aç ve eşleştir "
              + "(ya da USB ile bağlanıp hata ayıklamayı aç).",
                "No device. Open the AndrOS app on the phone and pair it "
              + "(or attach over USB with debugging on).")
            : (list.contains { $0.viaApp }
               ? L("“Uygulama” yazan cihaz hata ayıklama İSTEMEZ: görüntü telefonun "
                 + "ekran kaydı izninden gelir, dokunma da erişilebilirlik "
                 + "hizmetinden. İkisini de telefondaki uygulamadan aç.",
                   "A device marked “App” needs NO debugging: the picture comes from "
                 + "the phone's screen-capture permission and touch from its "
                 + "accessibility service. Enable both in the app on the phone.")
               : L("USB/Wi-Fi ile bağlı cihazda yansıtma adb üzerinden çalışır.",
                   "On a USB/Wi-Fi device mirroring runs over adb."))
    }

    /// Yansitma ayri pencerede acildigi icin panel yalnizca DURUMU gosterir.
    func setMirroring(_ on: Bool) {
        stopButton.isHidden = !on
        startButton.isEnabled = !on && !devices.isEmpty
        startButton.title = on ? L("Yansıtma açık (ayrı pencerede)", "Mirroring is running (separate window)") : L("Yansıtmayı başlat", "Start mirroring")
    }

    @objc private func start() {
        let r = table.selectedRow
        guard r >= 0, r < devices.count else { return }
        onStart?(devices[r])
    }
    @objc private func stop() { onStop?() }

    // MARK: - Tablo

    func numberOfRows(in t: NSTableView) -> Int { devices.count }

    func tableView(_ t: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let d = devices[row]
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: d.overWifi ? "wifi" : "cable.connector",
                             accessibilityDescription: nil)
        icon.contentTintColor = d.overWifi ? .systemBlue : .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 22).isActive = true

        let title = NSTextField(labelWithString: d.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        let detail = NSTextField(labelWithString: d.detail)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor

        let texts = NSStackView(views: [title, detail])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        let r = NSStackView(views: [icon, texts, spacer])
        r.orientation = .horizontal
        r.spacing = 10
        r.distribution = .fill
        r.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        // Cerceveyi ELLE vermiyoruz: tablo hucre gorunumunu zaten sutun
        // genisligine oturtuyor. Elle verince ust uste binip icerik sagdan
        // tasiyordu. Saga yaslamayi bosluk gorunumu sagliyor.
        return r
    }
}
