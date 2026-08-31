import AppKit
import AndrOSCore

/// Emulator: solda sanal cihaz listesi, sagda ya secili cihazin ayarlari
/// ya da indirilebilir Android surumleri.
///
/// Emulator kendini adb'ye normal bir cihaz gibi verdigi icin, calistigi
/// anda AndrOS'un DIGER TUM modulleri (yansitma, dosyalar, galeri,
/// uygulamalar, pano) uzerinde oldugu gibi calisir.
final class EmulatorPanel: NSViewController, AndrOSPanel,
                           NSTableViewDataSource, NSTableViewDelegate {
    var data: AndroidData?

    private enum Mode { case settings, images }
    private var mode: Mode = .settings

    private let mgr = EmulatorManager.shared
    private var avds: [AVD] = []
    private var shown: [AVD] = []
    private var images: [SystemImage] = []
    private var selectedName: String?
    private var renamingName: String?
    private var busy = false

    private let table = FittedTableView()
    private var listScroll: NSScrollView?
    private let searchBox = SearchToggle()
    private let spinner = NSProgressIndicator()
    private let progress = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let form = NSStackView()
    private let detailTitle = NSTextField(labelWithString: "")
    private let detailSub = NSTextField(labelWithString: "")
    private let startButton = NSButton()
    private let modeButton = NSButton()
    private lazy var empty = EmptyStateView(frame: .zero)
    private var timer: Timer?
    /// Hedef-eylem sahipleri burada tutuluyor (bkz. StepperBox).
    private var keepAlive: [NSObject] = []
    private var infoPopover: NSPopover?

    // MARK: - Kurulum

    override func loadView() {
        let root = NSView()

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 100
        progress.isHidden = true
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.heightAnchor.constraint(equalToConstant: 6).isActive = true

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        // Bunu unutmak tum sag sutunu bozuyordu: otomatik boyut maskesi
        // kisitlara cevrilince benim yerlesim zincirimle cakisiyor ve
        // AppKit benimkileri kirip dugmeleri pencerenin dibine itiyordu.
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        // ---- Sol sutun
        let listHead = NSTextField(labelWithString: L("Sanal cihazlar", "Virtual devices"))
        listHead.font = .systemFont(ofSize: 13, weight: .semibold)
        listHead.setContentCompressionResistancePriority(.required, for: .horizontal)

        searchBox.placeholder = L("Cihaz ara", "Search devices")
        searchBox.openWidth = 140
        searchBox.onChange = { [weak self] _ in self?.applyFilter() }

        let addButton = smallIcon("plus", L("Yeni sanal cihaz", "New virtual device"),
                                  #selector(newAVD))

        let listBar = NSStackView(views: [listHead, addButton, flexSpacer(), searchBox])
        listBar.orientation = .horizontal
        listBar.alignment = .centerY
        listBar.spacing = 6
        listBar.translatesAutoresizingMaskIntoConstraints = false
        listBar.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let col = NSTableColumn(identifier: .init("e"))
        col.width = 236
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 54
        table.dataSource = self
        table.delegate = self
        table.style = .fullWidth
        table.selectionHighlightStyle = .regular
        table.intercellSpacing = NSSize(width: 0, height: 4)
        table.backgroundColor = .clear
        table.translatesAutoresizingMaskIntoConstraints = true
        table.autoresizingMask = [.width]

        let scroll = scrollWrap(table)
        listScroll = scroll
        let listCard = NSView()
        listCard.wantsLayer = true
        listCard.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.04).cgColor
        listCard.layer?.cornerRadius = 12
        if #available(macOS 10.15, *) { listCard.layer?.cornerCurve = .continuous }
        listCard.translatesAutoresizingMaskIntoConstraints = false
        listCard.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: listCard.topAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: listCard.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: listCard.trailingAnchor, constant: -4),
            scroll.bottomAnchor.constraint(equalTo: listCard.bottomAnchor, constant: -6),
        ])

        // ---- Sag sutun
        detailTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        detailSub.font = .systemFont(ofSize: 11)
        detailSub.textColor = .secondaryLabelColor

        let head = NSStackView(views: [detailTitle, detailSub])
        head.orientation = .vertical
        head.alignment = .leading
        head.spacing = 1
        head.translatesAutoresizingMaskIntoConstraints = false

        startButton.bezelStyle = .rounded
        startButton.target = self
        startButton.action = #selector(toggleRun)
        startButton.title = L("Başlat", "Start")

        modeButton.bezelStyle = .rounded
        modeButton.target = self
        modeButton.action = #selector(toggleMode)
        modeButton.title = L("Android sürümleri", "Android versions")

        let actions = NSStackView(views: [startButton, modeButton, NSView(), spinner])
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.translatesAutoresizingMaskIntoConstraints = false

        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 10
        form.translatesAutoresizingMaskIntoConstraints = false
        let formScroll = scrollWrap(form)

        empty.translatesAutoresizingMaskIntoConstraints = false

        for v in [listBar, listCard, head, actions, progress, statusLabel,
                  formScroll, empty] as [NSView] { root.addSubview(v) }
        NSLayoutConstraint.activate([
            listBar.topAnchor.constraint(equalTo: root.topAnchor),
            listBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            listBar.widthAnchor.constraint(equalToConstant: 244),

            listCard.topAnchor.constraint(equalTo: listBar.bottomAnchor, constant: 8),
            listCard.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            listCard.widthAnchor.constraint(equalToConstant: 244),
            listCard.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            empty.topAnchor.constraint(equalTo: listCard.topAnchor),
            empty.leadingAnchor.constraint(equalTo: listCard.leadingAnchor),
            empty.trailingAnchor.constraint(equalTo: listCard.trailingAnchor),
            empty.bottomAnchor.constraint(equalTo: listCard.bottomAnchor),

            head.topAnchor.constraint(equalTo: root.topAnchor),
            head.leadingAnchor.constraint(equalTo: listCard.trailingAnchor, constant: 18),
            head.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor),

            actions.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 10),
            actions.leadingAnchor.constraint(equalTo: listCard.trailingAnchor, constant: 18),
            actions.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            progress.topAnchor.constraint(equalTo: actions.bottomAnchor, constant: 8),
            progress.leadingAnchor.constraint(equalTo: listCard.trailingAnchor, constant: 18),
            progress.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            statusLabel.topAnchor.constraint(equalTo: progress.bottomAnchor, constant: 4),
            statusLabel.leadingAnchor.constraint(equalTo: listCard.trailingAnchor, constant: 18),
            statusLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            formScroll.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 10),
            formScroll.leadingAnchor.constraint(equalTo: listCard.trailingAnchor, constant: 18),
            formScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            formScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            form.widthAnchor.constraint(equalTo: formScroll.widthAnchor, constant: -20),
        ])
        view = root
    }

    private func smallIcon(_ symbol: String, _ tip: String, _ sel: Selector) -> NSButton {
        let b = NSButton(title: "", target: self, action: sel)
        b.bezelStyle = .rounded
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        b.toolTip = tip
        b.setAccessibilityLabel(tip)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 28).isActive = true
        return b
    }

    func didAppear() {
        refresh()
        timer?.invalidate()
        // Calisma durumu disaridan da degisebilir (emulator elle kapatilirsa).
        let t = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
            guard self?.view.window?.isVisible == true, self?.busy == false else { return }
            UserBusy.run { [weak self] in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func willDisappear() { timer?.invalidate(); timer = nil }

    // MARK: - Liste

    private func refresh() {
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            let list = self.mgr.isBootstrapped ? self.mgr.listAVDs() : []
            DispatchQueue.main.async {
                self.avds = list
                if self.selectedName == nil || !list.contains(where: { $0.name == self.selectedName }) {
                    self.selectedName = list.first?.name
                }
                self.applyFilter()
                self.rebuildRight()
            }
        }
    }

    private func applyFilter() {
        let q = searchBox.text.trimmingCharacters(in: .whitespaces).lowercased()
        shown = avds.filter { SearchMatch.matchesAny(q, [$0.displayName, $0.name]) }
        table.reloadData()
        if let i = shown.firstIndex(where: { $0.name == selectedName }) {
            table.selectRowIndexes([i], byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
        empty.isHidden = !shown.isEmpty
        if shown.isEmpty {
            if !mgr.isBootstrapped {
                empty.show(L("Emülatör kurulu değil", "Emulator not installed"),
                           L("Android sürümleri’ne geçip kurulumu başlat.",
                             "Open Android versions to run the setup."),
                           symbol: "square.and.arrow.down")
            } else {
                empty.show(avds.isEmpty ? L("Sanal cihaz yok", "No virtual devices")
                                        : L("Eşleşen cihaz yok", "No matching device"),
                           avds.isEmpty ? L("+ ile yeni bir Android cihaz oluştur.",
                                            "Create a new Android device with +.")
                                        : L("Aramayı değiştir ya da temizle.",
                                            "Change or clear the search."),
                           symbol: "iphone.badge.play")
            }
        }
    }

    func numberOfRows(in t: NSTableView) -> Int { shown.count }
    func tableView(_ t: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { DeviceRowView() }

    func tableView(_ t: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let a = shown[row]

        let av = AvatarView()
        av.initial = "A"
        av.seed = a.name.hashValue
        av.translatesAutoresizingMaskIntoConstraints = false
        av.widthAnchor.constraint(equalToConstant: 30).isActive = true
        av.heightAnchor.constraint(equalToConstant: 30).isActive = true

        let name = InlineEditLabel.label(a.displayName)
        name.onCommit = { [weak self] new in
            self?.mgr.rename(a, to: new)
            self?.refresh()
        }
        name.onEnd = { [weak self] in self?.renamingName = nil }
        if a.name == renamingName { DispatchQueue.main.async { name.beginEditing() } }

        let sub = NSTextField(labelWithString:
            (a.running ? "● " : "○ ") + "Android \(a.androidVersion) · \(a.settings.ramMB / 1024) GB")
        sub.font = .systemFont(ofSize: 10)
        sub.textColor = a.running ? .systemGreen : .tertiaryLabelColor

        let texts = NSStackView(views: [name, sub])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1
        texts.setContentHuggingPriority(.init(250), for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        let rename = rowIcon("pencil", L("Yeniden adlandır", "Rename"),
                             #selector(renameRow(_:)), a.name)
        let dup = rowIcon("plus.square.on.square", L("Klonla", "Clone"),
                          #selector(cloneRow(_:)), a.name)
        let del = rowIcon("trash", L("Sil", "Delete"), #selector(deleteRow(_:)), a.name)

        let r = NSStackView(views: [av, texts, spacer, rename, dup, del])
        r.orientation = .horizontal
        r.spacing = 4
        r.distribution = .fill
        r.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 10)
        return r
    }

    private func rowIcon(_ symbol: String, _ tip: String,
                         _ sel: Selector, _ id: String) -> NSButton {
        let b = NSButton(title: "", target: self, action: sel)
        b.bezelStyle = .inline
        b.isBordered = false
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        b.contentTintColor = .secondaryLabelColor
        b.toolTip = tip
        b.setAccessibilityLabel(tip)
        b.identifier = NSUserInterfaceItemIdentifier(id)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 22).isActive = true
        return b
    }

    func tableViewSelectionDidChange(_ n: Notification) {
        let r = table.selectedRow
        guard r >= 0, r < shown.count, shown[r].name != selectedName else { return }
        selectedName = shown[r].name
        mode = .settings
        rebuildRight()
    }

    private var selected: AVD? { avds.first { $0.name == selectedName } }

    // MARK: - Satir eylemleri

    @objc private func renameRow(_ s: NSButton) {
        guard let id = s.identifier?.rawValue,
              let i = shown.firstIndex(where: { $0.name == id }) else { return }
        renamingName = id
        table.reloadData(forRowIndexes: [i], columnIndexes: [0])
    }

    @objc private func cloneRow(_ s: NSButton) {
        guard let id = s.identifier?.rawValue, let a = avds.first(where: { $0.name == id })
        else { return }
        var n = a.displayName + L(" kopya", " copy")
        var i = 2
        while avds.contains(where: { $0.displayName == n }) { n = a.displayName + " \(i)"; i += 1 }
        if let err = mgr.clone(a, as: n) {
            warn(L("Klonlanamadı", "Could not clone"), EmulatorPanel.describe(err))
        }
        refresh()
    }

    @objc private func deleteRow(_ s: NSButton) {
        guard let id = s.identifier?.rawValue, let a = avds.first(where: { $0.name == id })
        else { return }
        let al = NSAlert()
        al.messageText = L("\"\(a.displayName)\" silinsin mi?", "Delete \"\(a.displayName)\"?")
        al.informativeText = L("Sanal cihaz ve içindeki tüm veriler kalıcı olarak silinir.",
                               "The virtual device and all its data are permanently deleted.")
        al.alertStyle = .warning
        al.addButton(withTitle: L("Sil", "Delete"))
        al.addButton(withTitle: L("Vazgeç", "Cancel"))
        guard al.runModal() == .alertFirstButtonReturn else { return }
        if a.running { mgr.stop(a) }
        mgr.delete(a)
        refresh()
    }

    @objc private func toggleRun() {
        guard let a = selected else { return }
        if a.running { mgr.stop(a) } else { mgr.start(a) }
        statusLabel.stringValue = a.running
            ? L("Kapatılıyor…", "Stopping…")
            : L("Başlatılıyor — ilk açılış birkaç dakika sürebilir.",
                "Starting — the first boot can take a few minutes.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.refresh() }
    }

    @objc private func toggleMode() {
        mode = (mode == .settings) ? .images : .settings
        if mode == .images, images.isEmpty { loadImages() }
        rebuildRight()
    }

    // MARK: - Yeni cihaz

    @objc private func newAVD() {
        guard mgr.isBootstrapped else {
            mode = .images; loadImages(); rebuildRight(); return
        }
        let installed = mgr.installedImagePaths()
        guard !installed.isEmpty else {
            mode = .images; loadImages(); rebuildRight()
            statusLabel.stringValue = L("Önce bir Android sürümü indir.",
                                        "Download an Android version first.")
            return
        }
        // Kurulu en YENI surumu sec: kullaniciyi ek bir secimle yormayalim,
        // istedigini sonra ayarlardan degistirebilir.
        let best = installed.map { p -> (Int, String) in
            let api = Int(p.split(separator: ";").dropFirst().first?
                .replacingOccurrences(of: "android-", with: "") ?? "") ?? 0
            return (api, p)
        }.max { $0.0 < $1.0 }!
        let parts = best.1.split(separator: ";").map(String.init)
        let img = SystemImage(path: best.1, api: best.0,
                              tag: parts.count > 2 ? parts[2] : "google_apis",
                              abi: parts.count > 3 ? parts[3] : "x86_64", installed: true)

        var name = "Android \(img.androidVersion)"
        var i = 2
        while avds.contains(where: { $0.displayName == name }) {
            name = "Android \(img.androidVersion) \(i)"; i += 1
        }
        busy = true
        statusLabel.stringValue = L("Oluşturuluyor…", "Creating…")
        spinner.startAnimation(nil)
        DispatchQueue.global().async { [weak self] in
            let err = self?.mgr.createAVD(name: name, image: img, settings: AVDSettings())
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                self.spinner.stopAnimation(nil)
                self.statusLabel.stringValue = err ?? ""
                if let err { self.warn(L("Oluşturulamadı", "Could not create"), err) }
                self.selectedName = EmulatorManager.safeName(name)
                self.renamingName = self.selectedName
                self.refresh()
            }
        }
    }

    /// Cekirdek katman dil bilmedigi icin ADIM ANAHTARI yolluyor; metne
    /// burada cevriliyor.
    static func describe(_ key: String) -> String {
        if key.hasPrefix("pkg:") {
            let p = String(key.dropFirst(4))
            return L("\(p) kuruluyor…", "Installing \(p)…")
        }
        if key.hasPrefix("pkg.failed:") {
            let p = String(key.dropFirst("pkg.failed:".count))
            return L("\(p) kurulamadı", "Could not install \(p)")
        }
        switch key {
        case "tools.download": return L("Komut satırı araçları indiriliyor…",
                                        "Downloading command-line tools…")
        case "tools.unzip":    return L("Arşiv açılıyor…", "Extracting…")
        case "licenses":       return L("Lisanslar onaylanıyor…", "Accepting licenses…")
        case "tools.notfound": return L("Komut satırı araçları bulunamadı",
                                        "Command-line tools not found")
        case "repo.unreachable": return L("Android deposuna ulaşılamadı",
                                          "Could not reach the Android repository")
        case "image.failed":   return L("Sistem imajı kurulamadı",
                                        "Could not install the system image")
        case "clone.exists":   return L("Bu adda bir cihaz zaten var",
                                        "A device with that name already exists")
        default:
            if key.hasPrefix("unzip.failed:") {
                return L("Arşiv açılamadı", "Could not extract") + key.dropFirst(13)
            }
            if key.hasPrefix("download.failed:") {
                return L("İndirme başarısız", "Download failed") + key.dropFirst(16)
            }
            return key
        }
    }

    private func warn(_ t: String, _ b: String) {
        let a = NSAlert(); a.messageText = t; a.informativeText = b; a.runModal()
    }
}

// MARK: - Sag sutun: ayarlar ve surumler

extension EmulatorPanel {

    func rebuildRight() {
        form.arrangedSubviews.forEach { $0.removeFromSuperview() }
        keepAlive.removeAll()
        modeButton.title = (mode == .settings)
            ? L("Android sürümleri", "Android versions")
            : L("Ayarlar", "Settings")

        if mode == .images { buildImageList(); return }

        guard let a = selected else {
            detailTitle.stringValue = L("Sanal cihaz seçili değil", "No virtual device selected")
            detailSub.stringValue = mgr.isBootstrapped
                ? L("Soldan bir cihaz seç ya da + ile yeni oluştur.",
                    "Pick a device on the left, or create one with +.")
                : L("Emülatör henüz kurulu değil.", "The emulator is not installed yet.")
            startButton.isEnabled = false
            return
        }
        startButton.isEnabled = true
        startButton.title = a.running ? L("Durdur", "Stop") : L("Başlat", "Start")
        detailTitle.stringValue = a.displayName
        detailSub.stringValue = "Android \(a.androidVersion) · "
            + (EmulatorManager.hardwareAccelerated
               ? L("donanım hızlandırma açık", "hardware acceleration on")
               : L("donanım hızlandırma YOK", "no hardware acceleration"))

        var s = a.settings
        func save() { mgr.applySettings(name: a.name, displayName: nil, settings: s)
                      refresh() }

        section(L("Başarım", "Performance"))
        form.addArrangedSubview(stepperRow(L("RAM", "RAM"), value: s.ramMB,
                                           min: 1024, max: 16384, step: 1024, unit: "MB") {
            s.ramMB = $0; save()
        })
        form.addArrangedSubview(stepperRow(L("İşlemci çekirdeği", "CPU cores"), value: s.cores,
                                           min: 1, max: 8, step: 1, unit: "") {
            s.cores = $0; save()
        })
        form.addArrangedSubview(stepperRow(L("VM yığını", "VM heap"), value: s.heapMB,
                                           min: 128, max: 4096, step: 128, unit: "MB") {
            s.heapMB = $0; save()
        })
        form.addArrangedSubview(popupRow(L("GPU", "GPU"),
            options: [("host", L("host — en hızlı (Mac GPU'su)", "host — fastest (Mac GPU)")),
                      ("auto", L("auto — otomatik seç", "auto — pick automatically")),
                      ("swiftshader_indirect", L("swiftshader — yazılım", "swiftshader — software")),
                      ("angle_indirect", "angle — Metal/ANGLE"),
                      ("off", L("kapalı", "off"))],
            selected: s.gpuMode) { s.gpuMode = $0; save() })
        form.addArrangedSubview(checkRow(L("Donanım hızlandırma (Hypervisor)",
                                           "Hardware acceleration (Hypervisor)"),
                                         on: s.accelerated,
                                         enabled: EmulatorManager.hardwareAccelerated) {
            s.accelerated = $0; save()
        })
        form.addArrangedSubview(checkRow(L("Her açılışta soğuk başlat",
                                           "Cold boot every time"), on: s.coldBoot) {
            s.coldBoot = $0; save()
        })

        section(L("Ekran", "Display"))
        form.addArrangedSubview(popupRow(L("Çözünürlük", "Resolution"),
            options: EmulatorPanel.resolutions.map { ("\($0.w)x\($0.h)@\($0.d)", $0.label) },
            selected: "\(s.width)x\(s.height)@\(s.density)") { key in
                let parts = key.split(whereSeparator: { $0 == "x" || $0 == "@" }).compactMap { Int($0) }
                if parts.count == 3 { s.width = parts[0]; s.height = parts[1]; s.density = parts[2] }
                save()
        })

        section(L("Depolama", "Storage"))
        form.addArrangedSubview(stepperRow(L("Dahili depolama", "Internal storage"),
                                           value: s.dataPartitionGB,
                                           min: 2, max: 256, step: 2, unit: "GB") {
            s.dataPartitionGB = $0; save()
        })
        form.addArrangedSubview(note(L(
            "Disk SEYREK ayrılır: dosya ancak kullanıldıkça büyür, baştan bu kadar yer kaplamaz.",
            "The disk is sparse: the file grows as it is used, it does not take this much up front.")))
        form.addArrangedSubview(stepperRow(L("SD kart (0 = yok)", "SD card (0 = none)"),
                                           value: s.sdCardMB, min: 0, max: 32768, step: 512,
                                           unit: "MB") { s.sdCardMB = $0; save() })

        section(L("Donanım", "Hardware"))
        form.addArrangedSubview(checkRow(L("Mac klavyesini geçir", "Pass through Mac keyboard"),
                                         on: s.keyboard) { s.keyboard = $0; save() })
        let cams: [(String, String)] = [
            ("emulated", L("emüle", "emulated")), ("webcam0", L("Mac kamerası", "Mac camera")),
            ("none", L("yok", "none")),
        ]
        form.addArrangedSubview(popupRow(L("Arka kamera", "Back camera"), options: cams,
                                         selected: s.cameraBack) { s.cameraBack = $0; save() })
        form.addArrangedSubview(popupRow(L("Ön kamera", "Front camera"), options: cams,
                                         selected: s.cameraFront) { s.cameraFront = $0; save() })

        form.addArrangedSubview(note(L(
            "Emülatör çalışırken adb'ye normal bir cihaz gibi görünür — Yansıtma, "
          + "Dosyalar, Galeri, Uygulamalar ve Pano üzerinde olduğu gibi çalışır.",
            "While running, the emulator appears to adb as a normal device — Mirroring, "
          + "Files, Gallery, Apps and Clipboard all work on it as-is.")))
    }

    static let resolutions: [(w: Int, h: Int, d: Int, label: String)] = [
        (720, 1280, 320, "720 × 1280 · HD"),
        (1080, 1920, 420, "1080 × 1920 · FHD"),
        (1080, 2400, 440, "1080 × 2400 · FHD+"),
        (1440, 3120, 560, "1440 × 3120 · QHD+"),
        (1600, 2560, 320, "1600 × 2560 · Tablet"),
    ]

    // ---- Surum listesi

    func loadImages() {
        spinner.startAnimation(nil)
        statusLabel.stringValue = L("Sürümler alınıyor…", "Fetching versions…")
        mgr.availableImages { [weak self] list in
            guard let self else { return }
            self.spinner.stopAnimation(nil)
            self.statusLabel.stringValue = ""
            self.images = list
            if self.mode == .images { self.rebuildRight() }
        }
    }

    private func buildImageList() {
        detailTitle.stringValue = L("Android sürümleri", "Android versions")
        detailSub.stringValue = L("İndirilen sürümlerden sanal cihaz oluşturabilirsin.",
                                  "You can create virtual devices from downloaded versions.")
        startButton.isEnabled = false

        if !mgr.isBootstrapped {
            let b = NSButton(title: L("Emülatörü kur (~500 MB)", "Install emulator (~500 MB)"),
                             target: self, action: #selector(bootstrap))
            b.bezelStyle = .rounded
            form.addArrangedSubview(b)
            form.addArrangedSubview(note(L(
                "Android SDK komut satırı araçları, platform-tools ve emülatör "
              + "Google'ın deposundan indirilir. Kurulum yeri: "
              + "~/Library/Application Support/AndrOS",
                "The Android SDK command-line tools, platform-tools and emulator are "
              + "downloaded from Google's repository. Installed into: "
              + "~/Library/Application Support/AndrOS")))
            return
        }

        if images.isEmpty {
            form.addArrangedSubview(note(L("Sürüm listesi alınamadı — ağ bağlantısını kontrol et.",
                                           "Could not fetch the list — check your connection.")))
            return
        }
        var lastAPI = -1
        for img in images {
            if img.api != lastAPI {
                lastAPI = img.api
                section("Android \(img.androidVersion)")
            }
            form.addArrangedSubview(imageRow(img))
        }
    }

    private func imageRow(_ img: SystemImage) -> NSView {
        let title = NSTextField(labelWithString: img.title)
        title.font = .systemFont(ofSize: 12, weight: .medium)
        let sub = NSTextField(labelWithString: img.abi + " · " + (img.installed
            ? L("kurulu", "installed") : L("indirilmedi", "not downloaded")))
        sub.font = .systemFont(ofSize: 10)
        sub.textColor = img.installed ? .systemGreen : .tertiaryLabelColor

        let texts = NSStackView(views: [title, sub])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1

        let info = NSButton(title: "", target: self, action: #selector(showInfo(_:)))
        info.bezelStyle = .inline
        info.isBordered = false
        info.image = NSImage(systemSymbolName: "info.circle",
                             accessibilityDescription: L("Bu sürüm nedir?", "What is this?"))?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        info.contentTintColor = .secondaryLabelColor
        info.toolTip = EmulatorPanel.explain(img)
        info.identifier = NSUserInterfaceItemIdentifier(img.path)
        info.translatesAutoresizingMaskIntoConstraints = false
        info.widthAnchor.constraint(equalToConstant: 20).isActive = true

        let b = NSButton(title: img.installed ? L("Kurulu", "Installed")
                                              : L("İndir", "Download"),
                         target: self, action: #selector(installImage(_:)))
        b.bezelStyle = .rounded
        b.isEnabled = !img.installed && !busy
        b.identifier = NSUserInterfaceItemIdentifier(img.path)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        let row = NSStackView(views: [texts, spacer, info, b])
        row.orientation = .horizontal
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        row.wantsLayer = true
        row.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
        row.layer?.cornerRadius = 9
        row.translatesAutoresizingMaskIntoConstraints = false
        form.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true
        return row
    }

    /// Varyantlar arasindaki farki anlatir.
    ///
    /// Bu ucu ayirt etmek onemli: Play Store'lu imaj CTS SERTIFIKALI, yani
    /// Play Integrity / SafetyNet denetimi yapan uygulamalar (bankalar,
    /// bircok oyun) yalniz onda calisir — ama `adb root` kapalidir.
    static func explain(_ img: SystemImage) -> String {
        switch img.kind {
        case .aosp:
            return L("""
                Saf Android (AOSP). Google Play Hizmetleri ve Play Store YOK.

                • En hafif ve en hızlı açılan imaj
                • Google hesabı, Haritalar, bildirim gönderme çalışmaz
                • Play Store'dan uygulama kuramazsın; yalnız APK yükleyerek
                • `adb root` açık — sistem dosyalarına erişebilirsin

                Uygun: sistem düzeyi test, Google'a ihtiyaç duymayan APK'lar.
                """, """
                Plain Android (AOSP). No Google Play services, no Play Store.

                • Lightest image, fastest to boot
                • No Google account, Maps, or push notifications
                • You cannot install from the Play Store — only by sideloading APKs
                • `adb root` is available — full access to system files

                Good for: system-level testing, APKs that don't need Google.
                """)
        case .googleAPIs:
            return L("""
                Google Play Hizmetleri VAR, Play Store uygulaması YOK.

                • Haritalar, Google ile giriş, push bildirimleri çalışır
                • Play Store yok — uygulamaları APK olarak kurarsın
                • CTS sertifikası YOK: Play Integrity / SafetyNet denetimi
                  yapan uygulamalar (bankacılık, bazı oyunlar) çalışmayabilir
                • `adb root` açık

                Uygun: Google servislerini kullanan ama mağaza gerektirmeyen işler.
                """, """
                Google Play services included, but NOT the Play Store app.

                • Maps, Google sign-in and push notifications work
                • No Play Store — you install apps by sideloading APKs
                • NOT CTS-certified: apps that check Play Integrity / SafetyNet
                  (banking, some games) may refuse to run
                • `adb root` is available

                Good for: work that uses Google services but not the store.
                """)
        case .playStore:
            return L("""
                Play Store DAHİL ve CTS SERTİFİKALI. Aradığın bu.

                • Play Store'dan doğrudan uygulama kurabilirsin
                • Google Play Hizmetleri tam çalışır
                • CTS sertifikalı: Play Integrity / SafetyNet denetimi geçer,
                  yani bankacılık uygulamaları ve mağaza koruması olan oyunlar
                  çalışır
                • `adb root` KAPALI — sertifika bunu gerektiriyor
                • Biraz daha büyük ve açılışı biraz daha yavaş

                Uygun: gerçek bir telefon gibi davranması gereken her şey.
                """, """
                Play Store INCLUDED and CTS-CERTIFIED. This is the one you want.

                • Install apps straight from the Play Store
                • Google Play services fully functional
                • CTS-certified: passes Play Integrity / SafetyNet, so banking
                  apps and games with store protection will run
                • `adb root` is DISABLED — certification requires this
                • Slightly larger and slower to boot

                Good for: anything that must behave like a real phone.
                """)
        }
    }

    @objc private func showInfo(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue,
              let img = images.first(where: { $0.path == path }) else { return }
        let text = NSTextField(wrappingLabelWithString: EmulatorPanel.explain(img))
        text.font = .systemFont(ofSize: 11)
        text.preferredMaxLayoutWidth = 340
        let title = NSTextField(labelWithString: img.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        let stack = NSStackView(views: [title, text])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let host = NSViewController()
        host.view = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 300))
        host.view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: host.view.topAnchor),
            stack.leadingAnchor.constraint(equalTo: host.view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: host.view.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: host.view.bottomAnchor),
            host.view.widthAnchor.constraint(equalToConstant: 380),
        ])

        let pop = NSPopover()
        pop.contentViewController = host
        pop.behavior = .transient
        infoPopover = pop
        pop.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    @objc private func bootstrap() {
        busy = true
        progress.isHidden = false
        progress.doubleValue = 0
        mgr.bootstrap(onProgress: { [weak self] step, pct in
            DispatchQueue.main.async {
                self?.statusLabel.stringValue = EmulatorPanel.describe(step)
                self?.progress.doubleValue = Double(pct)
            }
        }, done: { [weak self] err in
            guard let self else { return }
            self.busy = false
            self.progress.isHidden = true
            self.statusLabel.stringValue = err.map(EmulatorPanel.describe)
                ?? L("Emülatör hazır.", "Emulator ready.")
            if err == nil { self.loadImages() }
            self.refresh()
        })
    }

    @objc private func installImage(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue,
              let img = images.first(where: { $0.path == path }) else { return }
        busy = true
        progress.isHidden = false
        progress.doubleValue = 0
        statusLabel.stringValue = L("\(img.title) indiriliyor…", "Downloading \(img.title)…")
        sender.isEnabled = false
        mgr.installImage(img, onProgress: { [weak self] p in
            self?.progress.doubleValue = Double(p)
        }, done: { [weak self] err in
            guard let self else { return }
            self.busy = false
            self.progress.isHidden = true
            self.statusLabel.stringValue = err.map(EmulatorPanel.describe)
                ?? L("\(img.title) kuruldu.", "\(img.title) installed.")
            self.loadImages()
        })
    }

    // ---- Form yapi taslari

    private func section(_ t: String) {
        let l = NSTextField(labelWithString: t)
        l.font = .systemFont(ofSize: 11, weight: .semibold)
        l.textColor = .secondaryLabelColor
        form.addArrangedSubview(l)
    }

    private func note(_ t: String) -> NSView {
        let l = NSTextField(wrappingLabelWithString: t)
        l.font = .systemFont(ofSize: 10)
        l.textColor = .tertiaryLabelColor
        l.preferredMaxLayoutWidth = 460
        return l
    }

    private func labelled(_ t: String, _ control: NSView) -> NSView {
        let l = NSTextField(labelWithString: t)
        l.font = .systemFont(ofSize: 12)
        l.translatesAutoresizingMaskIntoConstraints = false
        l.widthAnchor.constraint(equalToConstant: 190).isActive = true
        let r = NSStackView(views: [l, control, NSView()])
        r.orientation = .horizontal
        r.spacing = 10
        return r
    }

    private func stepperRow(_ t: String, value: Int, min lo: Int, max hi: Int,
                            step: Int, unit: String,
                            onChange: @escaping (Int) -> Void) -> NSView {
        let field = NSTextField(string: "\(value)")
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        field.alignment = .right
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 78).isActive = true

        let stepper = NSStepper()
        stepper.minValue = Double(lo)
        stepper.maxValue = Double(hi)
        stepper.increment = Double(step)
        stepper.integerValue = value
        stepper.valueWraps = false

        let box = StepperBox(field: field, stepper: stepper, lo: lo, hi: hi, onChange: onChange)
        field.target = box; field.action = #selector(StepperBox.fieldChanged)
        stepper.target = box; stepper.action = #selector(StepperBox.stepped)
        keepAlive.append(box)

        let u = NSTextField(labelWithString: unit)
        u.font = .systemFont(ofSize: 11)
        u.textColor = .secondaryLabelColor

        let r = NSStackView(views: [field, stepper, u])
        r.orientation = .horizontal
        r.spacing = 4
        return labelled(t, r)
    }

    private func popupRow(_ t: String, options: [(String, String)], selected: String,
                          onChange: @escaping (String) -> Void) -> NSView {
        let p = NSPopUpButton()
        for (key, label) in options {
            p.addItem(withTitle: label)
            p.lastItem?.representedObject = key
        }
        if let i = options.firstIndex(where: { $0.0 == selected }) { p.selectItem(at: i) }
        let box = PopupBox(onChange: onChange)
        p.target = box; p.action = #selector(PopupBox.changed(_:))
        keepAlive.append(box)
        return labelled(t, p)
    }

    private func checkRow(_ t: String, on: Bool, enabled: Bool = true,
                          onChange: @escaping (Bool) -> Void) -> NSView {
        let c = NSButton(checkboxWithTitle: t, target: nil, action: nil)
        c.state = on ? .on : .off
        c.isEnabled = enabled
        let box = CheckBox(onChange: onChange)
        c.target = box; c.action = #selector(CheckBox.changed(_:))
        keepAlive.append(box)
        return c
    }
}

/// Hedef-eylem sahipleri. NSControl hedefini ZAYIF tuttugu icin bu kucuk
/// nesneleri panelde saklamak gerekiyor; yoksa kapanislar aninda serbest
/// birakiliyor ve denetimler sessizce calismiyor.
final class StepperBox: NSObject {
    let field: NSTextField, stepper: NSStepper, lo: Int, hi: Int
    let onChange: (Int) -> Void
    init(field: NSTextField, stepper: NSStepper, lo: Int, hi: Int,
         onChange: @escaping (Int) -> Void) {
        self.field = field; self.stepper = stepper
        self.lo = lo; self.hi = hi; self.onChange = onChange
    }
    @objc func stepped() { field.stringValue = "\(stepper.integerValue)"; onChange(stepper.integerValue) }
    @objc func fieldChanged() {
        let v = Swift.min(Swift.max(field.integerValue, lo), hi)
        field.stringValue = "\(v)"; stepper.integerValue = v; onChange(v)
    }
}

final class PopupBox: NSObject {
    let onChange: (String) -> Void
    init(onChange: @escaping (String) -> Void) { self.onChange = onChange }
    @objc func changed(_ s: NSPopUpButton) {
        if let k = s.selectedItem?.representedObject as? String { onChange(k) }
    }
}

final class CheckBox: NSObject {
    let onChange: (Bool) -> Void
    init(onChange: @escaping (Bool) -> Void) { self.onChange = onChange }
    @objc func changed(_ s: NSButton) { onChange(s.state == .on) }
}
