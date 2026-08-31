import AppKit
import AndrOSCore
import UniformTypeIdentifiers

/// Telefonun dosya sistemi. Surukle-birak her iki yonde de tam calisir:
///
///  - **Disari**: dosya ya da KLASOR, Mac'te herhangi bir yere surukleneblir
///    (Finder, Masaustu, baska uygulama). NSFilePromiseProvider kullanildigi
///    icin surukleme aninda baslar, indirme birakildigi yerde olur.
///  - **Iceri**: Mac'ten gelen dosyalar panelin HERHANGI bir yerine
///    birakilabilir; bir KLASORUN uzerine birakilirsa oraya gider.
///    Klasorun uzerinde ~0.8 sn beklenirse klasor acilir (Finder gibi).
final class FilesPanel: NSViewController, AndrOSPanel,
                        NSTableViewDataSource, NSTableViewDelegate {
    private var isLoading = false
    private var refreshObserverInstalled = false
    var data: AndroidData? {
        didSet { promises.data = data }
    }

    private var path = "/sdcard"
    private var entries: [AndroidData.FileEntry] = []
    /// Su an YERINDE yeniden adlandirilan dosyanin yolu.
    private var renamingPath: String?
    private let table = DropTableView()
    private let pathBar = NSStackView()
    private let spinner = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let promises = FilePromiseDelegate()
    private let spring = SpringLoader()
    private var viewer: MediaViewerController?
    private let searchBox = SearchToggle()
    /// Finder gibi: nokta ile baslayan dosyalar varsayilan olarak GIZLI.
    private var showHidden = UserDefaults.standard.bool(forKey: "filesShowHidden")
    /// Suzulmus liste; tum girdiler `allEntries`.
    private var allEntries: [AndroidData.FileEntry] = []

    private func applyFilter() {
        let q = searchBox.text.trimmingCharacters(in: .whitespaces).lowercased()
        entries = allEntries
            .filter { showHidden || !$0.name.hasPrefix(".") }
            .filter { SearchMatch.matches(q, $0.name) }
        if entries.isEmpty {
            emptyState().show(
                allEntries.isEmpty ? L("Klasör boş", "This folder is empty")
                                   : L("Eşleşen dosya yok", "No matching file"),
                allEntries.isEmpty
                    ? L("Buraya dosya sürükleyerek telefona yükleyebilirsin.",
                        "Drop files here to upload them to the phone.")
                    : L("Aramayı değiştir ya da temizle.", "Change or clear the search."),
                symbol: "folder")
        } else { emptyState().isHidden = true }
        table.reloadData()
    }

    override func loadView() {
        let root = NSView()

        // ARAC CUBUGU SADE. Finder'da oldugu gibi eylemler SAG TIK
        // menusunde; ustte yalniz gezinme, arama ve durum var. Onceki
        // surumde alti dugme yan yana duruyor ve arama kutusunu
        // ortada birakiyordu.
        let up = NSButton(title: "↑", target: self, action: #selector(goUp))
        up.bezelStyle = .rounded
        up.toolTip = L("Üst klasör", "Parent folder")

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        searchBox.placeholder = L("Bu klasörde ara", "Search this folder")
        searchBox.onChange = { [weak self] _ in self?.applyFilter() }

        // Arama HER PANELDE en sagda: goz onceki kategoriden kalan yeri
        // aradigi icin yer degistirmesi rahatsiz ediyordu.
        let bar = NSStackView(views: [up, spinner, NSView(), searchBox])
        bar.orientation = .horizontal
        bar.spacing = 6
        bar.translatesAutoresizingMaskIntoConstraints = false

        pathBar.orientation = .horizontal
        pathBar.spacing = 2
        pathBar.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.stringValue = L("Sürükle: dosya/klasör → Mac'e  ·  Mac'ten → buraya veya bir klasörün üstüne", "Drag: file/folder → to the Mac  ·  from the Mac → here or onto a folder")

        let col = NSTableColumn(identifier: .init("f"))
        col.width = 560
        table.addTableColumn(col)
        table.headerView = nil
        table.style = .fullWidth
        table.intercellSpacing = NSSize(width: 0, height: 4)
        table.backgroundColor = .clear
        table.allowsEmptySelection = true
        table.rowHeight = 30
        table.dataSource = self
        table.delegate = self
        table.doubleAction = #selector(open)
        table.target = self
        table.allowsMultipleSelection = true
        table.setDraggingSourceOperationMask([.copy], forLocal: false)
        table.registerForDraggedTypes([.fileURL])
        table.onBackgroundDrop = { [weak self] urls in self?.push(urls, to: nil) }
        table.menu = buildMenu()

        promises.onProgress = { [weak self] name, busy in
            DispatchQueue.main.async {
                self?.statusLabel.stringValue = busy ? L("İndiriliyor: \(name)…", "Downloading: \(name)…")
                    : L("Hazır: \(name)", "Ready: \(name)")
                if busy { self?.spinner.startAnimation(nil) }
                else { self?.spinner.stopAnimation(nil) }
            }
        }
        spring.onOpen = { [weak self] p in
            self?.path = p
            self?.reload()
        }

        let scroll = scrollWrap(table)
        root.addSubview(bar)
        root.addSubview(pathBar)
        root.addSubview(scroll)
        root.addSubview(statusLabel)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            pathBar.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),
            pathBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            pathBar.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: pathBar.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -6),
            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    /// Sag tik menusu. NSTableView tiklanan satiri `clickedRow` ile verir,
    /// bu yuzden eylemler secime degil TIKLANAN ogeye bakiyor.
    private func buildMenu() -> NSMenu {
        let m = NSMenu()
        func add(_ t: String, _ sel: Selector, _ key: String = "") {
            let i = NSMenuItem(title: t, action: sel, keyEquivalent: key)
            i.target = self
            m.addItem(i)
        }
        add(L("Aç", "Open"), #selector(open))
        add(L("Mac'e indir…", "Download to Mac…"), #selector(downloadSelected))
        m.addItem(.separator())
        add(L("Kopyala", "Copy"), #selector(copyContent), "c")
        add(L("Yolu kopyala", "Copy path"), #selector(copyPath))
        add(L("Buraya yapıştır", "Paste Here"), #selector(pasteHere), "v")
        m.addItem(.separator())
        add(L("Yeniden adlandır", "Rename"), #selector(renameSelected))
        add(L("Yeni klasör", "New Folder"), #selector(makeFolder))
        add(L("Buraya yükle…", "Upload Here…"), #selector(uploadFiles))
        m.addItem(.separator())
        add(L("Üst klasör", "Parent Folder"), #selector(goUp))
        add(L("Yenile", "Refresh"), #selector(refreshNow), "r")
        let hid = NSMenuItem(title: L("Gizli dosyaları göster", "Show Hidden Files"),
                             action: #selector(toggleHidden), keyEquivalent: ".")
        hid.keyEquivalentModifierMask = [.command, .shift]
        hid.target = self
        hid.state = showHidden ? .on : .off
        m.addItem(hid)
        m.addItem(.separator())
        add(L("Sil", "Delete"), #selector(deleteSelected))
        return m
    }

    /// Finder'daki ⇧⌘. — gizli dosyalar.
    @objc private func toggleHidden() {
        showHidden.toggle()
        UserDefaults.standard.set(showHidden, forKey: "filesShowHidden")
        table.menu = buildMenu()
        applyFilter()
    }

    @objc private func refreshNow() { reload(force: true) }

    /// Sag tiklanan satir yoksa secimi kullan.
    private var actionTargets: [AndroidData.FileEntry] {
        let r = table.clickedRow
        if r >= 0, r < entries.count, !table.selectedRowIndexes.contains(r) {
            return [entries[r]]
        }
        return selectedEntries
    }

    /// Dosyayi panoya ICERIK olarak koyar: Finder'a yapistirilabilir.
    @objc private func copyContent() {
        guard let d = data else { return }
        let picked = actionTargets.filter { !$0.isDirectory }
        guard !picked.isEmpty else {
            statusLabel.stringValue = L("Klasörler içerik olarak kopyalanamaz; sürükleyerek taşı", "Folders cannot be copied as content — drag them instead")
            return
        }
        spinner.startAnimation(nil)
        CopyContent.copy(picked.map { ($0.path, $0.name) }, data: d,
                         onProgress: { [weak self] m in self?.statusLabel.stringValue = m },
                         onDone: { [weak self] n in
                             self?.spinner.stopAnimation(nil)
                             self?.statusLabel.stringValue = L("\(n) dosya panoya kopyalandı", "\(n) files copied to the clipboard")
                         })
    }

    @objc private func copyPath() {
        let paths = actionTargets.map(\.path).joined(separator: "\n")
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths, forType: .string)
        statusLabel.stringValue = L("Yol panoya kopyalandı", "Path copied to the clipboard")
    }

    /// Mac panosundaki dosyalari bu klasore yukler.
    @objc private func pasteHere() {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           !urls.isEmpty {
            push(urls, to: nil)
            return
        }
        // Pano metin ise: metni dosya olarak yaz
        if let text = pb.string(forType: .string), !text.isEmpty {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("pano.txt")
            try? text.write(to: tmp, atomically: true, encoding: .utf8)
            push([tmp], to: nil)
            return
        }
        statusLabel.stringValue = L("Panoda yapıştırılacak dosya yok", "No file on the clipboard to paste")
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
        reload()
    }

    // MARK: - Gezinme

    /// `force`: kullanicinin dogrudan yol actigi tazelemeler (yeni klasor,
    /// silme, ⌘R). Bunlar surmekte olan bir yuklemeye takilmamali.
    private func reload(force: Bool = false) {
        // AYNI ANDA tek yukleme. Ust uste binen istekler adb'yi
        // doyuruyor, uygulama koprusunun istekleri de arkada bekleyip
        // zaman asimina ugruyordu — panel dakikalarca bos kaliyordu.
        if isLoading && !force { return }
        guard let d = data else { return }
        isLoading = true
        buildPathBar()
        spinner.startAnimation(nil)
        let p = path
        // SECIM ve KAYDIRMA korunuyor: arka plan tazelemesi kullanicinin
        // sectigi dosyayi ve baktigi yeri kaydirmasin.
        let keep = Set(selectedEntries.map(\.path))
        let scrollY = table.enclosingScrollView?.contentView.bounds.origin.y
        DispatchQueue.global().async { [weak self] in
            let list = d.listPreferringApp(p)
            DispatchQueue.main.async {
                guard let self else { return }
                // Bayragi HER DURUMDA sifirla. Sifirlanmadigi icin ilk
                // yuklemeden sonra `reload()` kalici olarak olu kaliyordu:
                // yeni klasor gorunmuyor, silme ekrana yansimiyordu.
                self.isLoading = false
                self.spinner.stopAnimation(nil)
                guard self.path == p else { return }   // arada klasor degistiyse birak
                self.allEntries = list
                self.applyFilter()
                if !keep.isEmpty {
                    let rows = self.entries.enumerated()
                        .filter { keep.contains($0.element.path) }.map(\.offset)
                    if !rows.isEmpty {
                        self.table.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
                    }
                }
                if let y = scrollY {
                    self.table.enclosingScrollView?.contentView
                        .scroll(to: NSPoint(x: 0, y: y))
                    self.table.enclosingScrollView?.reflectScrolledClipView(
                        self.table.enclosingScrollView!.contentView)
                }
            }
        }
    }

    /// Tiklanabilir yol parcalari: /sdcard / DCIM / Camera
    private func buildPathBar() {
        pathBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var acc = ""
        for part in path.split(separator: "/") {
            acc += "/" + part
            let b = NSButton(title: String(part), target: self, action: #selector(jumpTo(_:)))
            b.bezelStyle = .inline
            b.font = .systemFont(ofSize: 11)
            b.identifier = NSUserInterfaceItemIdentifier(acc)
            pathBar.addArrangedSubview(b)
            let sep = NSTextField(labelWithString: "›")
            sep.font = .systemFont(ofSize: 11)
            sep.textColor = .tertiaryLabelColor
            pathBar.addArrangedSubview(sep)
        }
    }

    @objc private func jumpTo(_ sender: NSButton) {
        guard let p = sender.identifier?.rawValue else { return }
        path = p
        reload()
    }

    @objc private func goUp() {
        guard path != "/" else { return }
        path = (path as NSString).deletingLastPathComponent
        if path.isEmpty { path = "/" }
        reload()
    }

    @objc private func open() {
        let r = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard r >= 0, r < entries.count else { return }
        let e = entries[r]
        if e.isDirectory { path = e.path; reload(); return }
        let ext = (e.name as NSString).pathExtension.lowercased()
        if let d = data, MediaFilter.imageExts.contains(ext) || MediaFilter.videoExts.contains(ext) {
            let v = MediaViewerController(title: e.name)
            viewer = v
            v.present(path: e.path, name: e.name,
                      isVideo: MediaFilter.videoExts.contains(ext), data: d)
        } else {
            downloadSelected()
        }
    }

    private var selectedEntries: [AndroidData.FileEntry] {
        table.selectedRowIndexes.compactMap { $0 < entries.count ? entries[$0] : nil }
    }

    // MARK: - Dosya islemleri

    @objc private func makeFolder() {
        guard let d = data else { return }
        guard let name = prompt(L("Yeni klasör", "New folder"), L("Klasör adı:", "Folder name:")) , !name.isEmpty else { return }
        let target = path + "/" + name
        statusLabel.stringValue = L("Klasör oluşturuluyor…", "Creating folder…")
        DispatchQueue.global().async { [weak self] in
            let ok = d.mkdirPreferringApp(target)
            DispatchQueue.main.async {
                guard let self else { return }
                self.statusLabel.stringValue = ok
                    ? L("Klasör oluşturuldu: \(name)", "Folder created: \(name)")
                    : L("Klasör oluşturulamadı: \(name)", "Could not create folder: \(name)")
                // ZORLA tazele: arka planda suren bir yukleme varsa bile
                // yeni klasor hemen gorunmeli.
                self.reload(force: true)
            }
        }
    }

    /// Yerinde duzenlemeyi baslatir — acilir pencere YOK.
    @objc private func renameSelected() {
        guard let e = actionTargets.first,
              let i = entries.firstIndex(where: { $0.path == e.path }) else { return }
        renamingPath = e.path
        table.reloadData(forRowIndexes: [i], columnIndexes: [0])
    }

    @objc private func deleteSelected() {
        guard let d = data else { return }
        let picked = actionTargets
        guard !picked.isEmpty else { return }
        let a = NSAlert()
        a.messageText = picked.count == 1 ? "\"\(picked[0].name)\" silinsin mi?"
                                          : L("\(picked.count) öğe silinsin mi?", "Delete \(picked.count) items?")
        a.informativeText = L("Bu işlem geri alınamaz. Telefondan kalıcı olarak silinir.", "This cannot be undone. It is permanently removed from the phone.")
        a.alertStyle = .warning
        a.addButton(withTitle: L("Sil", "Delete"))
        a.addButton(withTitle: L("Vazgeç", "Cancel"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        statusLabel.stringValue = L("Siliniyor…", "Deleting…")
        DispatchQueue.global().async { [weak self] in
            var n = 0
            for e in picked where d.deletePreferringApp(e.path) { n += 1 }
            DispatchQueue.main.async {
                guard let self else { return }
                self.statusLabel.stringValue = L("\(n)/\(picked.count) öğe silindi",
                                                 "\(n)/\(picked.count) items deleted")
                self.reload(force: true)
            }
        }
    }

    private func prompt(_ title: String, _ label: String, initial: String = "") -> String? {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = label
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        f.stringValue = initial
        a.accessoryView = f
        a.addButton(withTitle: L("Tamam", "OK"))
        a.addButton(withTitle: L("Vazgeç", "Cancel"))
        a.window.initialFirstResponder = f
        return a.runModal() == .alertFirstButtonReturn ? f.stringValue : nil
    }

    @objc private func downloadSelected() {
        let picked = actionTargets
        guard !picked.isEmpty, let d = data else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Buraya indir"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        for f in picked {
            TransferQueue.shared.enqueue(name: f.name, remote: f.path,
                                         local: dir.appendingPathComponent(f.name).path,
                                         direction: .download)
        }
        statusLabel.stringValue = L("\(picked.count) öğe indirme sırasında", "\(picked.count) items queued for download")
        _ = d
    }

    @objc private func uploadFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        push(panel.urls, to: nil)
    }

    /// `dest` nil ise bulundugumuz klasore.
    private func push(_ urls: [URL], to dest: String?) {
        guard let d = data, !urls.isEmpty else { return }
        let target = dest ?? path
        statusLabel.stringValue = L("\(urls.count) öğe yükleme sırasında → \(target)", "\(urls.count) items queued for upload → \(target)")
        for u in urls {
            TransferQueue.shared.enqueue(
                name: u.lastPathComponent,
                remote: target, local: u.path, direction: .upload) { [weak self] _ in
                    DispatchQueue.main.async { self?.reload() }
                }
        }
        _ = d
    }

    // MARK: - Tablo

    /// Yuvarlak kose vurgu — tum listelerde ayni dil.
    func tableView(_ t: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        DeviceRowView()
    }

    func numberOfRows(in t: NSTableView) -> Int { entries.count }

    func tableView(_ t: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        // SINIR KONTROLU: reloadData islenmeden eski indeks gelebiliyor.
        guard row < entries.count else { return nil }
        let e = entries[row]
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: e.isDirectory ? "folder.fill" : FilesPanel.symbol(e.name),
                             accessibilityDescription: nil)
        icon.contentTintColor = e.isDirectory ? .controlAccentColor : .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true

        let name = InlineEditLabel.label(e.name)
        name.font = .systemFont(ofSize: 12)
        name.lineBreakMode = .byTruncatingMiddle
        name.onCommit = { [weak self] new in
            guard let self, let d = self.data, !new.isEmpty, new != e.name else { return }
            let dest = self.path + "/" + new
            DispatchQueue.global().async {
                let ok = d.movePreferringApp(e.path, dest)
                DispatchQueue.main.async { [weak self] in
                    if !ok { self?.statusLabel.stringValue = L("Yeniden adlandırılamadı", "Could not rename") }
                    self?.reload(force: true)
                }
            }
        }
        name.onEnd = { [weak self] in self?.renamingPath = nil }
        // Finder gibi YERINDE duzenleme; acilir pencere yok.
        if e.path == renamingPath { DispatchQueue.main.async { name.beginEditing() } }

        let size = NSTextField(labelWithString: e.isDirectory ? "" : FilesPanel.human(e.size))
        size.font = .systemFont(ofSize: 11)
        size.textColor = .tertiaryLabelColor

        let r = NSStackView(views: [icon, name, NSView(), size])
        r.orientation = .horizontal
        r.spacing = 8
        r.edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
        return r
    }

    // MARK: - Disari surukleme (dosya + klasor)

    func tableView(_ t: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row < entries.count else { return nil }
        let e = entries[row]
        let type = e.isDirectory ? UTType.folder
            : (UTType(filenameExtension: (e.name as NSString).pathExtension) ?? .data)
        let p = RemoteFilePromise(fileType: type.identifier, delegate: promises)
        p.entry = e
        return p
    }

    // MARK: - Iceri birakma (satira ya da bos alana)

    func tableView(_ t: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int,
                   proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        // Kaynak biz isek (kendi icinde tasima) simdilik desteklemiyoruz
        guard info.draggingSource as? NSTableView !== t else { return [] }

        if op == .on, row >= 0, row < entries.count, entries[row].isDirectory {
            // Klasorun uzerinde beklenirse ac (spring loading)
            spring.hover(entries[row].path)
            return .copy
        }
        spring.hover(nil)
        // Satir arasi/bos alan: bulundugumuz klasore
        t.setDropRow(-1, dropOperation: .on)
        return .copy
    }

    func tableView(_ t: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation op: NSTableView.DropOperation) -> Bool {
        spring.cancel()
        guard let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty else { return false }
        var dest: String? = nil
        if op == .on, row >= 0, row < entries.count, entries[row].isDirectory {
            dest = entries[row].path
        }
        push(urls, to: dest)
        return true
    }

    // MARK: - Yardimcilar

    static func human(_ bytes: Int) -> String {
        let u = ["B", "KB", "MB", "GB"]
        var v = Double(bytes), i = 0
        while v >= 1024, i < u.count - 1 { v /= 1024; i += 1 }
        return String(format: i == 0 ? "%.0f %@" : "%.1f %@", v, u[i])
    }

    static func symbol(_ name: String) -> String {
        let e = (name as NSString).pathExtension.lowercased()
        if MediaFilter.imageExts.contains(e) { return "photo" }
        if MediaFilter.videoExts.contains(e) { return "film" }
        switch e {
        case "mp3", "m4a", "wav", "ogg", "flac": return "music.note"
        case "pdf": return "doc.richtext"
        case "zip", "rar", "7z", "tar", "gz": return "doc.zipper"
        case "apk": return "shippingbox"
        case "txt", "md", "log": return "doc.text"
        default: return "doc"
        }
    }
}

/// Tablonun BOS alanina da birakilabilmesi icin: NSTableView bos alanda
/// varsayilan olarak birakmayi reddediyor; arkaplan birakmalarini yakaliyoruz.
final class DropTableView: NSTableView {
    var onBackgroundDrop: (([URL]) -> Void)?

    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation {
        super.draggingEntered(s) == [] ? .copy : super.draggingEntered(s)
    }

    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        if super.performDragOperation(s) { return true }
        guard let urls = s.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: nil) as? [URL] else { return false }
        onBackgroundDrop?(urls)
        return true
    }
}
