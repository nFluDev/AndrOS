import AppKit
import AndrOSCore

/// AndrOS'un modulleri. Aynalama ilk ve su an tek calisan modul;
/// digerleri AndrOS mobil uygulamasi gelince acilacak.
enum AndrOSModule: String, CaseIterable {
    case mirroring, notifications, messages, files, clipboard

    var title: String {
        switch self {
        case .mirroring:     return "Android Mirroring"
        case .notifications: return "Bildirimler"
        case .messages:      return "SMS"
        case .files:         return "Dosyalar"
        case .clipboard:     return "Pano"
        }
    }

    var subtitle: String {
        switch self {
        case .mirroring:     return L("Ekranı yansıt ve kontrol et", "Mirror and control the screen")
        case .notifications: return L("Telefon bildirimleri menü çubuğunda", "Phone notifications in the menu bar")
        case .messages:      return L("Mesajları oku ve gönder", "Read and send messages")
        case .files:         return L("İki yönlü dosya aktarımı", "Two-way file transfer")
        case .clipboard:     return "Panoyu senkronize et"
        }
    }

    var symbol: String {
        switch self {
        case .mirroring:     return "iphone.and.arrow.right.outward"
        case .notifications: return "bell.badge"
        case .messages:      return "message"
        case .files:         return "folder"
        case .clipboard:     return "doc.on.clipboard"
        }
    }

    /// Aynalama ve pano kablo (adb) uzerinden calisiyor. Digerleri
    /// AndrOS mobil uygulamasini gerektiriyor — o gelene kadar pasif.
    var isAvailable: Bool { self == .mirroring || self == .clipboard }

    var requirement: String? {
        isAvailable ? nil : L("AndrOS mobil uygulaması gerekli", "AndrOS mobile app required")
    }
}

/// Listelenen bir cihaz.
struct HubDevice {
    let serial: String
    let model: String
    let manufacturer: String
    let android: String
    let overWifi: Bool

    var title: String {
        let m = manufacturer.isEmpty ? "" : manufacturer + " "
        return (m + model).trimmingCharacters(in: .whitespaces)
    }
    /// Seri numarasi / IP MASKELI gosterilir — ekran paylasirken ya da
    /// yanindaki biri varken goze carpmasin. Gercek deger satirdaki
    /// kopyala dugmesiyle alinabilir, ekrana hic yazilmaz.
    var detail: String {
        let link = overWifi ? "Wi-Fi" : "USB"
        let ver = android.isEmpty ? "" : " · Android \(android)"
        return "\(link)\(ver) · \(Privacy.mask(serial))"
    }
}

/// AndrOS ana penceresi: modul secimi + cihaz listesi.
final class HubWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {

    var onLaunch: ((AndrOSModule, HubDevice) -> Void)?

    private var devices: [HubDevice] = []
    private var selectedModule: AndrOSModule = .mirroring
    private let deviceTable = NSTableView()
    private let launchButton = NSButton()
    private let emptyLabel = NSTextField(labelWithString: "")
    private var moduleButtons: [AndrOSModule: NSButton] = [:]
    private var refreshTimer: Timer?

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 430),
                         styleMask: [.titled, .closable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "AndrOS"
        w.center()
        super.init(window: w)
        buildUI()
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refresh()
        startAutoRefresh()
    }

    private func startAutoRefresh() {
        refreshTimer?.invalidate()
        let t = Timer(timeInterval: 2.5, repeats: true) { [weak self] _ in
            guard self?.window?.isVisible == true else { return }
            self?.refresh()
        }
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
    }

    // MARK: - Arayuz

    private func buildUI() {
        guard let w = window else { return }
        let root = NSView()

        // --- Sol: moduller
        let modTitle = NSTextField(labelWithString: L("MODÜLLER", "MODULES"))
        modTitle.font = .systemFont(ofSize: 10, weight: .semibold)
        modTitle.textColor = .tertiaryLabelColor

        let modStack = NSStackView(views: [modTitle])
        modStack.orientation = .vertical
        modStack.alignment = .leading
        modStack.spacing = 4

        for m in AndrOSModule.allCases {
            let b = NSButton()
            b.title = "  \(m.title)"
            b.image = NSImage(systemSymbolName: m.symbol, accessibilityDescription: m.title)
            b.imagePosition = .imageLeading
            b.bezelStyle = .regularSquare
            b.isBordered = false
            b.alignment = .left
            b.font = .systemFont(ofSize: 13)
            b.target = self
            b.action = #selector(pickModule(_:))
            b.identifier = NSUserInterfaceItemIdentifier(m.rawValue)
            b.isEnabled = m.isAvailable
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 210).isActive = true
            b.heightAnchor.constraint(equalToConstant: 30).isActive = true
            moduleButtons[m] = b
            modStack.addArrangedSubview(b)

            if let req = m.requirement {
                let note = NSTextField(labelWithString: "      " + req)
                note.font = .systemFont(ofSize: 10)
                note.textColor = .tertiaryLabelColor
                modStack.addArrangedSubview(note)
            }
        }

        // --- Sag: cihazlar
        let devTitle = NSTextField(labelWithString: L("CİHAZLAR", "DEVICES"))
        devTitle.font = .systemFont(ofSize: 10, weight: .semibold)
        devTitle.textColor = .tertiaryLabelColor

        let refreshButton = NSButton(title: L("Yenile", "Refresh"), target: self, action: #selector(refresh))
        refreshButton.bezelStyle = .rounded
        refreshButton.controlSize = .small

        let devHeader = NSStackView(views: [devTitle, NSView(), refreshButton])
        devHeader.orientation = .horizontal

        let col = NSTableColumn(identifier: .init("dev"))
        col.width = 400
        deviceTable.addTableColumn(col)
        deviceTable.headerView = nil
        deviceTable.rowHeight = 46
        deviceTable.dataSource = self
        deviceTable.delegate = self
        deviceTable.doubleAction = #selector(launch)
        deviceTable.target = self

        let scroll = NSScrollView()
        scroll.documentView = deviceTable
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 240).isActive = true

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.maximumNumberOfLines = 3

        launchButton.title = L("Başlat", "Launch")
        launchButton.bezelStyle = .rounded
        launchButton.keyEquivalent = "\r"
        launchButton.target = self
        launchButton.action = #selector(launch)

        let devStack = NSStackView(views: [devHeader, scroll, emptyLabel, launchButton])
        devStack.orientation = .vertical
        devStack.alignment = .leading
        devStack.spacing = 8
        devHeader.translatesAutoresizingMaskIntoConstraints = false
        devHeader.widthAnchor.constraint(equalTo: devStack.widthAnchor).isActive = true
        scroll.widthAnchor.constraint(equalTo: devStack.widthAnchor).isActive = true

        let sep = NSBox(); sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.widthAnchor.constraint(equalToConstant: 1).isActive = true

        let cols = NSStackView(views: [modStack, sep, devStack])
        cols.orientation = .horizontal
        cols.alignment = .top
        cols.spacing = 18
        cols.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        cols.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(cols)
        NSLayoutConstraint.activate([
            cols.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            cols.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            cols.topAnchor.constraint(equalTo: root.topAnchor),
            cols.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sep.heightAnchor.constraint(equalTo: cols.heightAnchor, constant: -32),
        ])
        w.contentView = root
        highlightModule()
    }

    private func highlightModule() {
        for (m, b) in moduleButtons {
            let on = (m == selectedModule)
            b.contentTintColor = on ? .controlAccentColor
                                    : (m.isAvailable ? .labelColor : .tertiaryLabelColor)
            b.font = .systemFont(ofSize: 13, weight: on ? .semibold : .regular)
        }
    }

    @objc private func pickModule(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let m = AndrOSModule(rawValue: id), m.isAvailable else { return }
        selectedModule = m
        highlightModule()
        updateLaunchState()
    }

    // MARK: - Cihazlar

    @objc func refresh() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var found: [HubDevice] = []
            if let adb = try? ADB(), let list = try? adb.devices() {
                for d in list {
                    let one = (try? ADB(serial: d.serial)) ?? adb
                    found.append(HubDevice(
                        serial: d.serial,
                        model: d.model,
                        manufacturer: one.getProp("ro.product.manufacturer"),
                        android: one.getProp("ro.build.version.release"),
                        overWifi: d.transport == "tcp"))
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                let keep = self.selectedSerial
                self.devices = found
                self.deviceTable.reloadData()
                if let k = keep, let i = found.firstIndex(where: { $0.serial == k }) {
                    self.deviceTable.selectRowIndexes([i], byExtendingSelection: false)
                } else if !found.isEmpty, self.deviceTable.selectedRow < 0 {
                    self.deviceTable.selectRowIndexes([0], byExtendingSelection: false)
                }
                self.emptyLabel.stringValue = found.isEmpty
                    ? L("Cihaz yok. Telefonu USB ile bağla ve USB hata ayıklamayı aç.\n",
              "No device. Attach the phone over USB and turn on USB debugging.\n")
                    + L("Wi-Fi cihazlar için AndrOS mobil uygulaması gerekiyor.", "Wi-Fi devices need the AndrOS mobile app.")
                    : L("Wi-Fi üzerinden bağlanmak için AndrOS mobil uygulaması gerekiyor.", "Connecting over Wi-Fi needs the AndrOS mobile app.")
                self.updateLaunchState()
            }
        }
    }

    private var selectedSerial: String? {
        let r = deviceTable.selectedRow
        return r >= 0 && r < devices.count ? devices[r].serial : nil
    }

    private func updateLaunchState() {
        launchButton.isEnabled = selectedSerial != nil && selectedModule.isAvailable
        launchButton.title = selectedModule == .mirroring ? L("Yansıtmayı başlat", "Start mirroring") : L("Başlat", "Launch")
    }

    @objc private func launch() {
        let r = deviceTable.selectedRow
        guard r >= 0, r < devices.count, selectedModule.isAvailable else { return }
        onLaunch?(selectedModule, devices[r])
    }

    // MARK: - Tablo

    func numberOfRows(in t: NSTableView) -> Int { devices.count }

    func tableView(_ t: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let d = devices[row]
        let title = NSTextField(labelWithString: d.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        let detail = NSTextField(labelWithString: d.detail)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: d.overWifi ? "wifi" : "cable.connector",
                             accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 22).isActive = true

        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        let row = NSStackView(views: [icon, text])
        row.orientation = .horizontal
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        return row
    }

    func tableViewSelectionDidChange(_ n: Notification) { updateLaunchState() }
}
