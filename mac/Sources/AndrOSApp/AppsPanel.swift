import AppKit
import AndrOSCore
import UniformTypeIdentifiers

/// Yuklu uygulamalar: baslat, kaldir, APK'yi Mac'e cikar, APK yukle.
/// Hepsi adb ile calisiyor (kullanici uygulamalari icin `pm uninstall --user 0`).
final class AppsPanel: NSViewController, AndrOSPanel,
                       NSTableViewDataSource, NSTableViewDelegate {
    private var isLoading = false
    private var refreshObserverInstalled = false
    var data: AndroidData? { didSet { promises.data = data } }

    struct App: Hashable {
        let package: String
        var version: String = ""
        var apkPath: String = ""
    }

    private var apps: [App] = []
    private var filtered: [App] = []
    private let table = DropTableView()
    private let search = SearchToggle()
    private let spinner = NSProgressIndicator()
    private let status = NSTextField(labelWithString: "")
    private let systemToggle = NSButton(checkboxWithTitle: L("Sistem uygulamalarını da göster", "Include system apps"),
                                        target: nil, action: nil)
    private let promises = FilePromiseDelegate()
    private var icons: [String: NSImage] = [:]
    private var iconLoading = Set<String>()
    private static let iconDir: URL = {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("AndrOS/icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// Ikonu cihazda APK icinden ayiklayip ceker (20-70 KB).
    private func loadIcon(_ pkg: String) {
        guard icons[pkg] == nil, !iconLoading.contains(pkg), let d = data else { return }
        iconLoading.insert(pkg)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let url = d.appIconPreferringApp(pkg, cacheDir: AppsPanel.iconDir)
            let img = url.flatMap { NSImage(contentsOf: $0) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.iconLoading.remove(pkg)
                guard let img else { return }
                self.icons[pkg] = img
                if let i = self.filtered.firstIndex(where: { $0.package == pkg }) {
                    self.table.reloadData(forRowIndexes: [i], columnIndexes: [0])
                }
            }
        }
    }

    override func loadView() {
        let root = NSView()
        search.placeholder = L("Uygulama ara", "Search apps")
        search.onChange = { [weak self] _ in self?.filterChanged() }
        search.translatesAutoresizingMaskIntoConstraints = false

        systemToggle.target = self
        systemToggle.action = #selector(reload)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        // Eylemler SAG TIK menusunde (Finder gibi). Ustte yalniz suzgec,
        // durum ve arama var — arama her panelde ayni yerde, en sagda.
        let bar = NSStackView(views: [systemToggle, spinner, flexSpacer(), search])
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.spacing = 8
        bar.translatesAutoresizingMaskIntoConstraints = false

        status.font = .systemFont(ofSize: 11)
        status.textColor = .tertiaryLabelColor
        status.stringValue = L("APK sürükleyip bırakarak da yükleyebilirsin.", "You can also install by dropping an APK here.")
        status.translatesAutoresizingMaskIntoConstraints = false

        let col = NSTableColumn(identifier: .init("a"))
        col.width = 560
        table.addTableColumn(col)
        table.headerView = nil
        table.style = .fullWidth
        table.intercellSpacing = NSSize(width: 0, height: 4)
        table.backgroundColor = .clear
        table.allowsEmptySelection = true
        table.rowHeight = 44
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.doubleAction = #selector(launchSelected)
        table.target = self
        table.setDraggingSourceOperationMask([.copy], forLocal: false)
        table.registerForDraggedTypes([.fileURL])
        table.onBackgroundDrop = { [weak self] urls in self?.install(urls) }
        let m = NSMenu()
        for (t, sel) in [(L("Başlat", "Launch"), #selector(launchSelected)),
                         (L("APK'yı Mac'e indir…", "Download APK to Mac…"), #selector(extractSelected)),
                         (L("Paket adını kopyala", "Copy package name"), #selector(copyPackage)),
                         (L("Kaldır", "Uninstall"), #selector(uninstallSelected)),
                         (L("—", "—"), nil),
                         (L("APK / XAPK yükle…", "Install APK / XAPK…"), #selector(installAPK)),
                         (L("Yenile", "Refresh"), #selector(reload))] as [(String, Selector?)] {
            guard let sel else { m.addItem(.separator()); continue }
            let i = NSMenuItem(title: t, action: sel, keyEquivalent: "")
            i.target = self
            m.addItem(i)
        }
        table.menu = m

        let scroll = scrollWrap(table)
        root.addSubview(bar)
        root.addSubview(scroll)
        root.addSubview(status)
        systemToggle.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -6),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            status.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    func didAppear() {
        // Uygulama baglantisi panel acildiktan SONRA hazir olabiliyor;
        // o zaman veriyi kendiliginden yeniden istiyoruz. Eskiden panel
        // bos aciliyor ve ancak kategori degistirip donunce doluyordu.
        // BIR KEZ kaydol: `didAppear` her kategori gecisinde cagriliyor,
        // her seferinde yeni gozlemci eklenince tek bir tazeleme onlarca
        // yukleme baslatiyordu (olculdu: ayni anda birden fazla adb
        // sorgusu, panel dakikalarca bos kaliyor).
        if !refreshObserverInstalled {
            refreshObserverInstalled = true
            NotificationCenter.default.addObserver(
                forName: .androsRefresh, object: nil, queue: .main) { [weak self] _ in
            guard let self, !self.view.isHiddenOrHasHiddenAncestor else { return }
            UserBusy.run { [weak self] in self?.reload() }
            }
        }
        if apps.isEmpty { reload() }
    }

    @objc private func reload() {
        // AYNI ANDA tek yukleme. Ust uste binen istekler adb'yi
        // doyuruyor, uygulama koprusunun istekleri de arkada bekleyip
        // zaman asimina ugruyordu — panel dakikalarca bos kaliyordu.
        guard !isLoading else { return }
        guard let d = data else { return }
        isLoading = true
        spinner.startAnimation(nil)
        let includeSystem = systemToggle.state == .on
        DispatchQueue.global().async { [weak self] in
            var labels: [String: String] = [:]
            var list: [App]

            // Uygulama eslesmisse GERCEK adlari oradan aliyoruz; adb yolu
            // yalniz paket adini veriyor.
            if let fromApp = d.appsPreferringApp(includeSystem: includeSystem) {
                list = fromApp.map { App(package: $0.package) }
                for e in fromApp { labels[e.package] = e.label }
                list.sort { (labels[$0.package] ?? $0.package)
                    .localizedCaseInsensitiveCompare(labels[$1.package] ?? $1.package)
                    == .orderedAscending }
            } else {
                let args = includeSystem ? ["shell", "pm", "list", "packages"]
                                         : ["shell", "pm", "list", "packages", "-3"]
                let out = (try? d.adb.checked(args, timeout: 30)) ?? ""
                list = out.split(separator: "\n").compactMap { l -> App? in
                    let s = l.trimmingCharacters(in: .whitespaces)
                    guard s.hasPrefix("package:") else { return nil }
                    return App(package: String(s.dropFirst(8)))
                }.sorted { $0.package < $1.package }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLoading = false     // bkz. FilesPanel: sifirlanmazsa panel donuyor
                self.spinner.stopAnimation(nil)
                self.realLabels = labels
                self.apps = list
                self.status.stringValue = L("\(list.count) uygulama", "\(list.count) apps")
                self.filterChanged()
            }
        }
    }

    /// Uygulamanin GERCEK adi.
    ///
    /// adb yalniz paket adini veriyor ("com.ark.mzxqteq.gp"); ondan isim
    /// tahmin etmek kotu sonuc veriyordu. Mobil uygulama `PackageManager`
    /// uzerinden gercek etiketi dondurdugu icin, eslesmisse o kullaniliyor.
    func label(for package: String) -> String {
        realLabels[package] ?? PackageNaming.friendly(package)
    }
    private var realLabels: [String: String] = [:]

    @objc private func filterChanged() {
        let q = search.text.trimmingCharacters(in: .whitespaces).lowercased()
        let oldIDs = filtered.map(\.package)
        filtered = apps.filter {
            SearchMatch.matchesAny(q, [$0.package, self.label(for: $0.package)])
        }
        if filtered.isEmpty {
            emptyState().show(
                apps.isEmpty ? L("Uygulama yok", "No apps")
                             : L("Eşleşen uygulama yok", "No matching app"),
                apps.isEmpty
                    ? L("Telefon bağlandığında yüklü uygulamalar burada listelenir.",
                        "Installed apps are listed here once a phone is connected.")
                    : L("Aramayı değiştir ya da temizle.", "Change or clear the search."),
                symbol: "square.grid.2x2")
        } else { emptyState().isHidden = true }
        reloadKeepingState(table, oldIDs: oldIDs, newIDs: filtered.map(\.package))
    }

    private var selectedApps: [App] {
        table.selectedRowIndexes.compactMap { $0 < filtered.count ? filtered[$0] : nil }
    }

    @objc private func copyPackage() {
        let p = selectedApps.map(\.package).joined(separator: "\n")
        guard !p.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(p, forType: .string)
        status.stringValue = L("Paket adı kopyalandı", "Package name copied")
    }

    @objc private func launchSelected() {
        guard let d = data, let a = selectedApps.first else { return }
        _ = try? d.adb.run(["shell", "monkey", "-p", a.package,
                            "-c", "android.intent.category.LAUNCHER", "1"])
        status.stringValue = L("Başlatıldı: \(a.package)", "Launched: \(a.package)")
    }

    @objc private func uninstallSelected() {
        guard let d = data else { return }
        let picked = selectedApps
        guard !picked.isEmpty else { return }
        let al = NSAlert()
        al.messageText = picked.count == 1 ? L("\(picked[0].package) kaldırılsın mı?", "Uninstall \(picked[0].package)?")
                                           : L("\(picked.count) uygulama kaldırılsın mı?", "Uninstall \(picked.count) apps?")
        al.informativeText = L("Uygulama ve verileri telefondan silinir.", "The app and its data are removed from the phone.")
        al.alertStyle = .warning
        al.addButton(withTitle: L("Kaldır", "Uninstall"))
        al.addButton(withTitle: L("Vazgeç", "Cancel"))
        guard al.runModal() == .alertFirstButtonReturn else { return }
        spinner.startAnimation(nil)
        DispatchQueue.global().async { [weak self] in
            var failed: [String] = []
            for a in picked {
                let r = try? d.adb.run(["uninstall", a.package], timeout: 60)
                if r?.out.contains("Success") != true { failed.append(a.package) }
            }
            DispatchQueue.main.async {
                self?.spinner.stopAnimation(nil)
                self?.status.stringValue = failed.isEmpty
                    ? L("\(picked.count) uygulama kaldırıldı", "\(picked.count) apps uninstalled")
                    : L("Kaldırılamadı: ", "Could not uninstall: ") + failed.joined(separator: ", ")
                self?.reload()
            }
        }
    }

    @objc private func extractSelected() {
        guard let d = data, let a = selectedApps.first else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = a.package + ".apk"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        spinner.startAnimation(nil)
        DispatchQueue.global().async { [weak self] in
            let p = (try? d.adb.checked(["shell", "pm", "path", a.package])) ?? ""
            let apk = p.split(separator: "\n").first
                .map { String($0).replacingOccurrences(of: "package:", with: "") } ?? ""
            let ok = !apk.isEmpty && d.pull(apk, to: url.path)
            DispatchQueue.main.async {
                self?.spinner.stopAnimation(nil)
                self?.status.stringValue = ok
                    ? L("APK indirildi: \(url.lastPathComponent)",
                        "APK downloaded: \(url.lastPathComponent)")
                    : L("APK indirilemedi", "APK download failed")
                if ok { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
    }

    @objc private func installAPK() {
        let panel = NSOpenPanel()
        // XAPK/APKS/APKM'nin kayitli bir UTI'si yok; uzantidan turetiyoruz.
        panel.allowedContentTypes = ["apk", "xapk", "apks", "apkm"].compactMap {
            UTType(filenameExtension: $0)
        } + [.data]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        install(panel.urls)
    }

    /// Paketli kurulumlar: bir uygulama birden cok APK'ya bolunmus olabilir.
    private static let bundleExts: Set<String> = ["xapk", "apks", "apkm"]

    private func install(_ urls: [URL]) {
        guard let d = data else { return }
        let apks = urls.filter { $0.pathExtension.lowercased() == "apk" }
        let bundles = urls.filter { AppsPanel.bundleExts.contains($0.pathExtension.lowercased()) }
        guard !apks.isEmpty || !bundles.isEmpty else {
            status.stringValue = L("Yalnızca .apk / .xapk / .apks dosyaları yüklenebilir",
                                   "Only .apk / .xapk / .apks files can be installed")
            return
        }
        spinner.startAnimation(nil)
        let total = apks.count + bundles.count
        DispatchQueue.global().async { [weak self] in
            var ok = 0
            for u in apks {
                let r = try? d.adb.run(["install", "-r", u.path], timeout: 600)
                if r?.out.contains("Success") == true { ok += 1 }
            }
            for u in bundles where self?.installBundle(u, d) == true { ok += 1 }
            DispatchQueue.main.async {
                self?.spinner.stopAnimation(nil)
                self?.status.stringValue = L("\(ok)/\(total) paket yüklendi",
                                             "\(ok)/\(total) packages installed")
                self?.reload()
            }
        }
    }

    /// XAPK / APKS / APKM kurulumu.
    ///
    /// Bunlar aslinda ZIP: icinde `base.apk` ve mimari/dil basina
    /// "split" APK'lar var; bazen de `Android/obb/<paket>/…` altinda veri
    /// dosyalari. Tek tek `install` calismaz — Android hepsini AYNI
    /// oturumda ister, bu da `install-multiple` demek. OBB varsa kurulumdan
    /// sonra dogru klasore itiliyor, yoksa oyun acilista veri indirmek
    /// istiyor.
    private func installBundle(_ url: URL, _ d: AndroidData) -> Bool {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("AndrOS/xapk-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-o", "-q", url.path, "-d", tmp.path]
        try? unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { return false }

        let all = (FileManager.default.enumerator(at: tmp, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }) ?? []
        let parts = all.filter { $0.pathExtension.lowercased() == "apk" }
        guard !parts.isEmpty else { return false }

        // base.apk once: oturumu o baslatmali.
        let ordered = parts.sorted { a, _ in a.lastPathComponent.lowercased() == "base.apk" }
        let args = ["install-multiple", "-r"] + ordered.map(\.path)
        let r = try? d.adb.run(args, timeout: 900)
        let ok = r?.out.contains("Success") == true
        guard ok else { return false }

        // OBB verisi varsa yerine koy.
        for obb in all where obb.pathExtension.lowercased() == "obb" {
            // .../Android/obb/<paket>/<dosya>.obb yapisini koru
            let pkg = obb.deletingLastPathComponent().lastPathComponent
            let dest = "/sdcard/Android/obb/" + pkg
            _ = d.mkdirPreferringApp(dest)
            _ = d.push(obb.path, to: dest)
        }
        return true
    }

    // MARK: - Tablo

    /// Yuvarlak kose vurgu — tum listelerde ayni dil.
    func tableView(_ t: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        DeviceRowView()
    }

    func numberOfRows(in t: NSTableView) -> Int { filtered.count }

    func tableView(_ t: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        guard row < filtered.count else { return nil }
        let a = filtered[row]
        let icon = NSImageView()
        if let img = icons[a.package] {
            icon.image = img
            icon.wantsLayer = true
            icon.layer?.cornerRadius = 6
            icon.layer?.masksToBounds = true
        } else {
            icon.image = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
            icon.contentTintColor = .tertiaryLabelColor
            loadIcon(a.package)
        }
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 28).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 28).isActive = true

        // Gercek etiket/ikon cihazda yok (aapt yok, dumpsys vermiyor);
        // paket adindan okunabilir isim turetip tam paketi parantezde veriyoruz.
        let name = NSTextField(labelWithString: label(for: a.package))
        name.font = .systemFont(ofSize: 12, weight: .medium)
        let pkg = NSTextField(labelWithString: "(\(a.package))")
        pkg.font = .systemFont(ofSize: 10)
        pkg.textColor = .tertiaryLabelColor
        pkg.lineBreakMode = .byTruncatingMiddle

        let texts = NSStackView(views: [name, pkg])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 0

        let r = NSStackView(views: [icon, texts])
        r.orientation = .horizontal
        r.spacing = 8
        r.edgeInsets = NSEdgeInsets(top: 3, left: 6, bottom: 3, right: 6)
        return r
    }

    /// APK'yi surukleyip Mac'e cikarma.
    func tableView(_ t: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row < filtered.count, let d = data else { return nil }
        let a = filtered[row]
        let p = (try? d.adb.checked(["shell", "pm", "path", a.package])) ?? ""
        let apk = p.split(separator: "\n").first
            .map { String($0).replacingOccurrences(of: "package:", with: "") } ?? ""
        guard !apk.isEmpty else { return nil }
        let promise = RemoteFilePromise(
            fileType: (UTType(filenameExtension: "apk") ?? .data).identifier,
            delegate: promises)
        promise.entry = AndroidData.FileEntry(name: a.package + ".apk", path: apk,
                                              isDirectory: false, size: 0)
        return promise
    }

    func tableView(_ t: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingSource as? NSTableView !== t else { return [] }
        t.setDropRow(-1, dropOperation: .on)
        return .copy
    }

    func tableView(_ t: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation op: NSTableView.DropOperation) -> Bool {
        guard let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: nil) as? [URL] else { return false }
        install(urls)
        return true
    }
}
