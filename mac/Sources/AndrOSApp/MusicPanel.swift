import AppKit
import AVFoundation
import AndrOSCore
import UniformTypeIdentifiers

/// Girise calma listeleri GRID olarak gelir; bir kutucuga tiklayinca
/// parca listesine gecilir, geri tusu grid'e dondurur.
/// Altta oynatici serit, ustte tek ikonlu arama.
final class MusicPanel: NSViewController, AndrOSPanel,
                        NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate,
                        NSCollectionViewDataSource, NSCollectionViewDelegate {
    private var isLoading = false
    private var refreshObserverInstalled = false
    var data: AndroidData? { didSet { promises.data = data } }
    /// Disari surukleme: dosya telefondan BIRAKILAN yere iniyor.
    private let promises = FilePromiseDelegate()
    /// Mac'ten gelen muzigin gidecegi klasor.
    private let inbox = "/sdcard/Music/AndrOS"

    private var allTracks: [AndroidData.Track] = []
    private var shown: [AndroidData.Track] = []
    private var playlists: [Playlist] = []
    /// nil = L("Tüm şarkılar", "All songs")
    private var selectedPlaylist: UUID?
    /// Su an YERINDE yeniden adlandirilan calma listesi.
    private var renamingPlaylist: UUID?
    private var showingGrid = true

    private let grid = NSCollectionView()
    private let trackTable = NSTableView()
    private let searchBox = SearchToggle()
    private let spinner = NSProgressIndicator()
    private let backButton = NSButton()
    private let headTitle = NSTextField(labelWithString: L("Çalma listeleri", "Playlists"))
    private var newPlButton: NSButton?

    // Oynatici
    private let art = NSImageView()
    private let titleLabel = MarqueeLabel()
    private let artistLabel = MarqueeLabel()
    private let elapsed = NSTextField(labelWithString: "0:00")
    private let total = NSTextField(labelWithString: "0:00")
    private let scrub = NSSlider()
    private let playButton = NSButton()
    private let shuffleButton = NSButton()
    private let repeatButton = NSButton()
    private let volume = NSSlider()
    private var eqPopover: NSPopover?
    private weak var eqBoostLabel: NSTextField?

    private var cache: [String: URL] = [:]
    private var prefetching = Set<String>()
    private var artCache: [String: NSImage] = [:]
    private var artLoading = Set<String>()

    private static let cacheDir: URL = dir("music")
    private static let artDir: URL = dir("albumart")
    private static func dir(_ n: String) -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("AndrOS/\(n)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    // MARK: - Kurulum

    override func loadView() {
        let root = MusicRootView()

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 150, height: 196)
        layout.minimumInteritemSpacing = 14
        layout.minimumLineSpacing = 18
        layout.sectionInset = NSEdgeInsets(top: 4, left: 2, bottom: 8, right: 2)
        grid.collectionViewLayout = layout
        grid.dataSource = self
        grid.delegate = self
        grid.isSelectable = true
        grid.backgroundColors = [.clear]
        grid.register(PlaylistTile.self, forItemWithIdentifier: .init("tile"))
        let gc = NSClickGestureRecognizer(target: self, action: #selector(gridOpened(_:)))
        gc.numberOfClicksRequired = 1
        gc.delaysPrimaryMouseButtonEvents = false
        grid.addGestureRecognizer(gc)
        let gm = NSMenu(); gm.delegate = self; grid.menu = gm
        // Calma listesi kutucuguna birakma: dosya once telefona yuklenir,
        // sonra O LISTEYE eklenir — "hem tum parcalara hem listeye".
        grid.registerForDraggedTypes([.fileURL])

        let tc = NSTableColumn(identifier: .init("t")); tc.width = 520
        trackTable.addTableColumn(tc)
        trackTable.headerView = nil
        trackTable.style = .fullWidth
        trackTable.intercellSpacing = NSSize(width: 0, height: 4)
        trackTable.backgroundColor = .clear
        trackTable.allowsEmptySelection = true
        trackTable.rowHeight = 42
        trackTable.dataSource = self
        trackTable.delegate = self
        trackTable.doubleAction = #selector(playClicked)
        trackTable.target = self
        trackTable.allowsMultipleSelection = true
        // Finder ile iki yonlu surukleme: parca -> Mac, muzik dosyasi -> telefon.
        trackTable.setDraggingSourceOperationMask([.copy], forLocal: false)
        trackTable.registerForDraggedTypes([.fileURL])
        let tm = NSMenu(); tm.delegate = self; trackTable.menu = tm

        backButton.isBordered = false
        backButton.image = NSImage(systemSymbolName: "chevron.left",
                                   accessibilityDescription: L("Geri", "Back"))?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        backButton.target = self
        backButton.action = #selector(goBack)
        backButton.isHidden = true
        headTitle.font = .systemFont(ofSize: 15, weight: .semibold)

        let newPl = NSButton(title: L("+ Çalma listesi", "+ Playlist"), target: self,
                             action: #selector(newPlaylist))
        newPl.bezelStyle = .rounded
        newPl.font = .systemFont(ofSize: 11)
        newPlButton = newPl

        searchBox.placeholder = L("Parça, sanatçı, liste", "Track, artist, playlist")
        searchBox.onChange = { [weak self] _ in self?.filterChanged() }

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let head = NSStackView(views: [backButton, headTitle, NSView(),
                                       newPl, searchBox, spinner])
        head.orientation = .horizontal
        head.alignment = .centerY
        head.spacing = 10

        root.head = head
        root.grid = scrollWrap(grid)
        root.list = scrollWrap(trackTable)
        root.player = buildPlayerBar()
        for v in [head, root.grid!, root.list!, root.player!] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = true
            root.addSubview(v)
        }
        view = root

        MusicEngine.shared.addObserver("panel") { [weak self] in self?.refreshPlayer() }
        MusicEngine.shared.provideFile = { [weak self] t, done in self?.fetch(t, done) }
        // Ust uste basarisizlikta motor duruyor; sebebini kullaniciya yaz.
        MusicEngine.shared.onPlaybackFailed = { [weak self] why in
            DispatchQueue.main.async { self?.showPlaybackError(why) }
        }
    }

    private func buildPlayerBar() -> NSView {
        art.wantsLayer = true
        art.layer?.cornerRadius = 8
        art.layer?.masksToBounds = true
        art.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        art.imageScaling = .scaleProportionallyUpOrDown
        art.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)
        art.contentTintColor = .tertiaryLabelColor
        art.translatesAutoresizingMaskIntoConstraints = false
        art.widthAnchor.constraint(equalToConstant: 54).isActive = true
        art.heightAnchor.constraint(equalToConstant: 54).isActive = true

        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        artistLabel.font = .systemFont(ofSize: 11)
        artistLabel.textColor = .secondaryLabelColor
        for l in [titleLabel, artistLabel] {
            l.translatesAutoresizingMaskIntoConstraints = false
            l.heightAnchor.constraint(equalToConstant: l === titleLabel ? 18 : 14).isActive = true
            l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        for l in [elapsed, total] {
            l.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            l.textColor = .tertiaryLabelColor
        }
        scrub.minValue = 0; scrub.maxValue = 1
        scrub.controlSize = .small
        scrub.target = self; scrub.action = #selector(scrubbed)
        scrub.translatesAutoresizingMaskIntoConstraints = false
        scrub.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        let timeRow = NSStackView(views: [elapsed, scrub, total])
        timeRow.orientation = .horizontal
        timeRow.spacing = 6
        let texts = NSStackView(views: [titleLabel, artistLabel, timeRow])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2
        texts.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.widthAnchor.constraint(equalTo: texts.widthAnchor).isActive = true
        artistLabel.widthAnchor.constraint(equalTo: texts.widthAnchor).isActive = true

        shuffleButton.isBordered = false
        shuffleButton.target = self; shuffleButton.action = #selector(toggleShuffle)
        repeatButton.isBordered = false
        repeatButton.target = self; repeatButton.action = #selector(cycleRepeat)
        playButton.isBordered = false
        playButton.target = self; playButton.action = #selector(togglePlay)
        let eqButton = NSButton(title: "EQ", target: self, action: #selector(showEQ))
        eqButton.bezelStyle = .rounded

        volume.minValue = 0; volume.maxValue = 1
        volume.doubleValue = Double(MusicEngine.shared.volume)
        volume.controlSize = .small
        volume.target = self; volume.action = #selector(volumeChanged)
        volume.translatesAutoresizingMaskIntoConstraints = false
        volume.widthAnchor.constraint(equalToConstant: 74).isActive = true

        let controls = NSStackView(views: [shuffleButton,
                                           icon("backward.fill", #selector(previous)),
                                           playButton,
                                           icon("forward.fill", #selector(nextTrack)),
                                           repeatButton, eqButton, volume])
        controls.orientation = .horizontal
        controls.spacing = 7
        controls.setContentCompressionResistancePriority(.required, for: .horizontal)

        let bar = NSStackView(views: [art, texts, NSView(), controls])
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.spacing = 14
        bar.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
        bar.layer?.cornerRadius = 12
        return bar
    }

    private func icon(_ s: String, _ sel: Selector) -> NSButton {
        let b = NSButton()
        b.isBordered = false
        b.image = NSImage(systemSymbolName: s, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        b.target = self; b.action = sel
        return b
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
            UserBusy.run { [weak self] in self?.loadTracks() }
            }
        }
        playlists = PlaylistStore.load()
        grid.reloadData()
        refreshPlayer()
        loadTracks()
    }

    /// Panelden cikilinca calma DEVAM eder (mini oynatici var).
    func willDisappear() {}

    // MARK: - Dosya saglama

    /// Calma durdu: sebebi panelde goster (acilir pencere degil —
    /// kullanici sarki dinlemeye calisiyor, uyari kutusu bogucu olur).
    private func showPlaybackError(_ why: String) {
        emptyState().isHidden = true
        headTitle.stringValue = why
        headTitle.textColor = .systemOrange
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self else { return }
            self.headTitle.textColor = .labelColor
            let pl = self.playlists.first { $0.id == self.selectedPlaylist }
            self.headTitle.stringValue = self.showingGrid
                ? L("Çalma listeleri", "Playlists")
                : (pl?.name ?? L("Tüm şarkılar", "All songs"))
        }
    }

    private func fetch(_ t: AndroidData.Track, _ done: @escaping (URL?) -> Void) {
        let local = MusicPanel.cacheDir.appendingPathComponent(MusicPanel.cacheName(t))
        // Onbellek DISKTEN kontrol ediliyor: sozluk uygulama yeniden
        // baslayinca bosaliyor ve ayni parca tekrar tekrar iniyordu.
        let size = ((try? FileManager.default
            .attributesOfItem(atPath: local.path)[.size]) as? Int) ?? 0
        if size > 1024 {
            cache[t.path] = local
            done(local)
            prefetchNext()
            return
        }
        guard data != nil else { done(nil); return }
        TransferQueue.shared.enqueue(name: t.title, remote: t.path,
                                     local: local.path, direction: .download) { [weak self] ok in
            DispatchQueue.main.async {
                if ok {
                    self?.cache[t.path] = local
                    done(local)
                    // ONDEN INDIRME yalniz BASARIDAN sonra: basarisizken
                    // her denemede bir indirme daha eklemek, telefon
                    // erisilemezken kuyrugu sisiriyordu.
                    self?.prefetchNext()
                } else {
                    done(nil)
                }
            }
        }
    }

    /// Onbellek adi ASCII tutulur.
    static func cacheName(_ t: AndroidData.Track) -> String {
        let ext = (t.name as NSString).pathExtension
        let h = String(UInt(bitPattern: t.path.hashValue), radix: 16)
        return ext.isEmpty ? h : "\(h).\(ext)"
    }

    private func prefetchNext() {
        let e = MusicEngine.shared
        guard e.index >= 0, e.index + 1 < e.queue.count, let d = data else { return }
        let t = e.queue[e.index + 1]
        let local = MusicPanel.cacheDir.appendingPathComponent(MusicPanel.cacheName(t))
        guard cache[t.path] == nil, !prefetching.contains(t.path),
              !FileManager.default.fileExists(atPath: local.path) else { return }
        prefetching.insert(t.path)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let ok = d.pull(t.path, to: local.path)
            DispatchQueue.main.async {
                self?.prefetching.remove(t.path)
                if ok { self?.cache[t.path] = local }
            }
        }
    }

    /// Album kapagi: sarkiyi indirmeden MediaStore'dan.
    /// Parca listesini ceker. Baglanti sonradan hazir olursa yeniden
    /// cagriliyor — panel bos acilip oyle kalmasin.
    func loadTracks() {
        // AYNI ANDA tek yukleme. Ust uste binen istekler adb'yi
        // doyuruyor, uygulama koprusunun istekleri de arkada bekleyip
        // zaman asimina ugruyordu — panel dakikalarca bos kaliyordu.
        guard !isLoading else { return }
        guard let d = data else { applyFilter(); return }
        isLoading = true
        spinner.startAnimation(nil)
        DispatchQueue.global().async { [weak self] in
            let list = d.tracksPreferringApp()
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLoading = false     // bkz. FilesPanel: sifirlanmazsa panel donuyor
                self.spinner.stopAnimation(nil)
                guard !list.isEmpty || self.allTracks.isEmpty else { return }
                self.allTracks = list
                self.applyFilter()
                self.grid.reloadData()
            }
        }
    }

    private func loadArt(_ t: AndroidData.Track) {
        let key = t.albumID
        guard !key.isEmpty, artCache[key] == nil, !artLoading.contains(key),
              let d = data else { return }
        artLoading.insert(key)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let img = d.albumArt(albumID: key, cacheDir: MusicPanel.artDir)
                .flatMap { NSImage(contentsOf: $0) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.artLoading.remove(key)
                guard let img else { return }
                self.artCache[key] = img
                self.trackTable.reloadData()
            }
        }
    }

    // MARK: - Suzgec / gezinme

    private var query: String {
        searchBox.text.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private func applyFilter() {
        var base = allTracks
        if let pid = selectedPlaylist, let pl = playlists.first(where: { $0.id == pid }) {
            let set = Set(pl.paths)
            base = allTracks.filter { set.contains($0.path) }
        }
        let q = query
        shown = base.filter { SearchMatch.matchesAny(q, [$0.title, $0.artist]) }
        if shown.isEmpty, !showingGrid {
            emptyState().show(
                base.isEmpty ? L("Parça yok", "No tracks")
                             : L("Eşleşen parça yok", "No matching track"),
                base.isEmpty
                    ? L("Telefondaki müzikler burada listelenir.",
                        "Music from the phone is listed here.")
                    : L("Aramayı değiştir ya da temizle.", "Change or clear the search."),
                symbol: "music.note.list")
        } else { emptyState().isHidden = true }
        trackTable.reloadData()
    }

    @objc private func filterChanged() {
        applyFilter()
        if showingGrid { grid.reloadData() }
    }

    /// Grid kutucuklari. Arama HEM liste adinda HEM icindeki sarkilarda arar.
    private var gridItems: [Playlist?] {
        let q = query
        guard !q.isEmpty else { return [nil] + playlists.map { Optional($0) } }
        var out: [Playlist?] = []
        if allTracks.contains(where: { SearchMatch.matchesAny(q, [$0.title, $0.artist]) }) {
            out.append(nil)
        }
        for pl in playlists {
            if SearchMatch.matches(q, pl.name) { out.append(pl); continue }
            let set = Set(pl.paths)
            if allTracks.contains(where: {
                set.contains($0.path) && SearchMatch.matchesAny(q, [$0.title, $0.artist])
            }) { out.append(pl) }
        }
        return out
    }

    @objc private func gridOpened(_ g: NSClickGestureRecognizer) {
        let p = g.location(in: grid)
        guard let ip = grid.indexPathForItem(at: p) else { return }
        let items = gridItems
        guard ip.item < items.count else { return }
        grid.selectionIndexPaths = [ip]
        let pl = items[ip.item]
        selectedPlaylist = pl?.id
        headTitle.stringValue = pl?.name ?? L("Tüm şarkılar", "All songs")
        showList(true)
        applyFilter()
    }

    @objc private func goBack() {
        showList(false)
        playlists = PlaylistStore.load()
        grid.reloadData()
    }

    private func showList(_ list: Bool) {
        showingGrid = !list
        backButton.isHidden = !list
        newPlButton?.isHidden = list
        (view as? MusicRootView)?.showGrid = !list
        if !list { headTitle.stringValue = L("Çalma listeleri", "Playlists") }
        view.needsLayout = true
    }

    private var clickedTile: Int? {
        let p = grid.convert(grid.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        return grid.indexPathForItem(at: p)?.item
    }
    private var clickedPlaylist: Playlist? {
        guard let i = clickedTile else { return nil }
        let items = gridItems
        return i < items.count ? items[i] : nil
    }

    // MARK: - Surukle birak

    /// Parcayi Mac'in herhangi bir yerine surukle (soz/promise).
    func tableView(_ t: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row < shown.count else { return nil }
        let tr = shown[row]
        let ext = (tr.name as NSString).pathExtension
        let type = UTType(filenameExtension: ext) ?? .audio
        let p = RemoteFilePromise(fileType: type.identifier, delegate: promises)
        p.entry = AndroidData.FileEntry(name: tr.name, path: tr.path,
                                        isDirectory: false, size: tr.size)
        return p
    }

    func tableView(_ t: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int,
                   proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        guard !audioURLs(from: info).isEmpty else { return [] }
        t.setDropRow(-1, dropOperation: .on)      // listenin tamamina
        return .copy
    }

    func tableView(_ t: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation op: NSTableView.DropOperation) -> Bool {
        let urls = audioURLs(from: info)
        guard !urls.isEmpty else { return false }
        // Acik bir liste varsa yuklenen parcalar ona da eklensin.
        upload(urls, addTo: selectedPlaylist)
        return true
    }

    /// Grid: kutucugun UZERINE birakinca o listeye ekle.
    func collectionView(_ c: NSCollectionView, validateDrop info: NSDraggingInfo,
                        proposedIndexPath path: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation op: UnsafeMutablePointer<NSCollectionView.DropOperation>)
                        -> NSDragOperation {
        audioURLs(from: info).isEmpty ? [] : .copy
    }

    func collectionView(_ c: NSCollectionView, acceptDrop info: NSDraggingInfo,
                        indexPath: IndexPath,
                        dropOperation op: NSCollectionView.DropOperation) -> Bool {
        let urls = audioURLs(from: info)
        guard !urls.isEmpty else { return false }
        let items = gridItems
        let target = indexPath.item < items.count ? items[indexPath.item]?.id : nil
        upload(urls, addTo: target)
        return true
    }

    private static let audioExts: Set<String> =
        ["mp3", "m4a", "aac", "flac", "wav", "ogg", "opus", "wma", "aiff", "alac"]

    private func audioURLs(from info: NSDraggingInfo) -> [URL] {
        guard let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: nil) as? [URL] else { return [] }
        return urls.filter { MusicPanel.audioExts.contains($0.pathExtension.lowercased()) }
    }

    /// Dosyalari telefona yukler; `addTo` verilirse o calma listesine de ekler.
    private func upload(_ urls: [URL], addTo playlist: UUID?) {
        guard let d = data else { return }
        spinner.startAnimation(nil)
        let dest = inbox
        DispatchQueue.global().async { [weak self] in
            _ = try? d.adb.run(["shell", "mkdir", "-p", "\"\(dest)\""])
            var pushed: [String] = []
            for u in urls where d.push(u.path, to: dest) {
                pushed.append(dest + "/" + u.lastPathComponent)
            }
            // Muzik uygulamalari yeni dosyayi gorsun.
            _ = try? d.adb.run(["shell", "am", "broadcast", "-a",
                                "android.intent.action.MEDIA_SCANNER_SCAN_FILE",
                                "-d", "file://\(dest)"])
            DispatchQueue.main.async {
                guard let self else { return }
                self.spinner.stopAnimation(nil)
                if let pl = playlist, !pushed.isEmpty {
                    PlaylistStore.add(paths: pushed, to: pl)
                    self.playlists = PlaylistStore.load()
                    self.grid.reloadData()
                }
                self.loadTracks()
            }
        }
    }

    // MARK: - Menuler

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ t: String, _ sel: Selector) {
            let i = NSMenuItem(title: t, action: sel, keyEquivalent: "")
            i.target = self
            menu.addItem(i)
        }
        if menu === trackTable.menu {
            add(L("Çal", "Play"), #selector(playClicked))
            add(L("Çalma listesine ekle…", "Add to playlist…"), #selector(addToPlaylist))
            // L("Tüm şarkılar", "All songs") bir liste degil: cikarma anlamsiz.
            if selectedPlaylist != nil { add(L("Listeden çıkar", "Remove from playlist"), #selector(removeFromPlaylist)) }
            return
        }
        add(L("Karışık çal", "Shuffle"), #selector(shufflePlaySource))
        if clickedPlaylist != nil {
            menu.addItem(.separator())
            add(L("Görsel seç…", "Choose image…"), #selector(pickPlaylistImage))
            add(L("Yeniden adlandır", "Rename"), #selector(renamePlaylist))
            add(L("Listeyi sil", "Delete playlist"), #selector(deletePlaylist))
        }
    }

    // MARK: - Calma listeleri

    /// Listeyi varsayilan adla olusturup adi HEMEN duzenlemeye aciyoruz —
    /// Finder'da "Yeni klasor" nasil olusuyorsa oyle. Acilir pencere yok.
    @objc private func newPlaylist() {
        let pl = PlaylistStore.add(L("Yeni çalma listesi", "New Playlist"))
        playlists = PlaylistStore.load()
        renamingPlaylist = pl.id
        showingGrid = true
        grid.reloadData()
    }

    /// Yerinde duzenleme — acilir pencere YOK, ad kutucugun uzerinde
    /// degistiriliyor (Finder'daki dosya adi gibi).
    @objc private func renamePlaylist() {
        guard let pl = clickedPlaylist else { return }
        renamingPlaylist = pl.id
        grid.reloadData()
    }

    @objc private func deletePlaylist() {
        guard let pl = clickedPlaylist else { return }
        PlaylistStore.remove(pl.id)
        PlaylistArt.remove(pl.id)
        if selectedPlaylist == pl.id { selectedPlaylist = nil }
        playlists = PlaylistStore.load()
        grid.reloadData()
        applyFilter()
    }

    @objc private func pickPlaylistImage() {
        guard let pl = clickedPlaylist else { return }
        let a = NSAlert()
        a.messageText = L("“\(pl.name)” görseli", "“\(pl.name)” artwork")
        a.informativeText = L("Bilgisayardan bir resim seç ya da çalan parçanın kapağını kullan.", "Pick an image from this Mac, or use the cover of the playing track.")
        a.addButton(withTitle: L("Bilgisayardan seç…", "Choose from Mac…"))
        if MusicEngine.shared.artwork != nil { a.addButton(withTitle: L("Çalan parçanın kapağı", "Cover of the playing track")) }
        a.addButton(withTitle: L("Vazgeç", "Cancel"))
        let r = a.runModal()
        if r == .alertFirstButtonReturn {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.image]
            guard panel.runModal() == .OK, let u = panel.url,
                  let img = NSImage(contentsOf: u) else { return }
            PlaylistArt.save(img, for: pl.id)
        } else if r == .alertSecondButtonReturn, let img = MusicEngine.shared.artwork {
            PlaylistArt.save(img, for: pl.id)
        } else { return }
        grid.reloadData()
    }

    @objc private func shufflePlaySource() {
        var list = allTracks
        if let pl = clickedPlaylist {
            let set = Set(pl.paths)
            list = allTracks.filter { set.contains($0.path) }
        }
        guard !list.isEmpty else { return }
        MusicEngine.shared.shuffle = true
        MusicEngine.shared.setQueue(list, startAt: Int.random(in: 0..<list.count))
    }

    @objc private func addToPlaylist() {
        let picked = selectedTracks
        guard !picked.isEmpty else { return }
        guard !playlists.isEmpty else {
            info(L("Önce bir çalma listesi oluştur", "Create a playlist first"), L("Üstteki “+ Çalma listesi”.", "Use “+ Playlist” above."))
            return
        }
        let menu = NSMenu()
        for pl in playlists {
            let i = NSMenuItem(title: pl.name, action: #selector(addToChosen(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = pl.id.uuidString
            menu.addItem(i)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func addToChosen(_ s: NSMenuItem) {
        guard let raw = s.representedObject as? String, let id = UUID(uuidString: raw) else { return }
        PlaylistStore.add(paths: selectedTracks.map(\.path), to: id)
        playlists = PlaylistStore.load()
        grid.reloadData()
    }

    @objc private func removeFromPlaylist() {
        guard let pid = selectedPlaylist else { return }
        PlaylistStore.remove(paths: selectedTracks.map(\.path), from: pid)
        playlists = PlaylistStore.load()
        applyFilter()
    }

    private var selectedTracks: [AndroidData.Track] {
        let r = trackTable.clickedRow
        if r >= 0, r < shown.count, !trackTable.selectedRowIndexes.contains(r) { return [shown[r]] }
        return trackTable.selectedRowIndexes.compactMap { $0 < shown.count ? shown[$0] : nil }
    }

    private func prompt(_ t: String, _ l: String, _ initial: String = "") -> String? {
        let a = NSAlert(); a.messageText = t; a.informativeText = l
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        f.stringValue = initial
        a.accessoryView = f
        a.addButton(withTitle: L("Tamam", "OK")); a.addButton(withTitle: L("Vazgeç", "Cancel"))
        a.window.initialFirstResponder = f
        return a.runModal() == .alertFirstButtonReturn ? f.stringValue : nil
    }
    private func info(_ t: String, _ b: String) {
        let a = NSAlert(); a.messageText = t; a.informativeText = b
        a.addButton(withTitle: L("Tamam", "OK")); a.runModal()
    }

    // MARK: - Oynatma

    @objc private func playClicked() {
        let r = trackTable.clickedRow >= 0 ? trackTable.clickedRow : trackTable.selectedRow
        guard r >= 0, r < shown.count else { return }
        MusicEngine.shared.setQueue(shown, startAt: r)
    }
    @objc private func togglePlay() {
        if MusicEngine.shared.current == nil, trackTable.selectedRow >= 0 { playClicked() }
        else { MusicEngine.shared.togglePlay() }
    }
    @objc private func nextTrack() { MusicEngine.shared.next() }
    @objc private func previous()  { MusicEngine.shared.previous() }
    @objc private func scrubbed()  {
        MusicEngine.shared.seek(to: scrub.doubleValue * MusicEngine.shared.duration)
    }
    @objc private func volumeChanged() { MusicEngine.shared.volume = Float(volume.doubleValue) }
    @objc private func toggleShuffle() { MusicEngine.shared.shuffle.toggle(); refreshPlayer() }
    @objc private func cycleRepeat() {
        MusicEngine.shared.repeatMode = MusicEngine.shared.repeatMode.next; refreshPlayer()
    }

    func refreshPlayer() {
        let e = MusicEngine.shared
        titleLabel.text = e.current?.title ?? L("Bir parça seç", "Select a track")
        artistLabel.text = e.current.map {
            $0.artist + ($0.album.isEmpty ? "" : " · " + $0.album) } ?? ""
        elapsed.stringValue = MusicPanel.time(e.currentTime)
        total.stringValue = MusicPanel.time(e.duration)
        scrub.doubleValue = e.duration > 0 ? e.currentTime / e.duration : 0
        playButton.image = NSImage(
            systemSymbolName: e.isPlaying ? "pause.circle.fill" : "play.circle.fill",
            accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 26, weight: .regular))
        art.image = e.artwork ?? NSImage(systemSymbolName: "music.note",
                                         accessibilityDescription: nil)
        art.contentTintColor = e.artwork == nil ? .tertiaryLabelColor : nil

        shuffleButton.image = NSImage(systemSymbolName: "shuffle", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        shuffleButton.contentTintColor = e.shuffle ? .controlAccentColor : .secondaryLabelColor
        shuffleButton.toolTip = e.shuffle ? L("Karışık: açık", "Shuffle: on") : L("Karışık: kapalı", "Shuffle: off")
        repeatButton.image = NSImage(systemSymbolName: e.repeatMode.symbol,
                                     accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        repeatButton.contentTintColor = e.repeatMode == .off ? .secondaryLabelColor
                                                             : .controlAccentColor
        repeatButton.toolTip = e.repeatMode.title
        trackTable.reloadData()
    }

    static func time(_ s: TimeInterval) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        return String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }

    // MARK: - Ekolayzer

    @objc private func showEQ() {
        eqPopover?.close()
        let vc = NSViewController()
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 430, height: 210))
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let t = NSTextField(labelWithString: L("Ekolayzer  (−12 … +12 dB)", "Equalizer  (−12 … +12 dB)"))
        t.font = .boldSystemFont(ofSize: 12)
        stack.addArrangedSubview(t)

        let bandsRow = NSStackView()
        bandsRow.orientation = .horizontal
        bandsRow.spacing = 6
        for (i, f) in MusicEngine.bands.enumerated() {
            let s = NSSlider(value: Double(MusicEngine.shared.bandGain(i)),
                             minValue: -12, maxValue: 12,
                             target: self, action: #selector(bandChanged(_:)))
            s.isVertical = true
            s.controlSize = .small
            s.tag = i
            s.translatesAutoresizingMaskIntoConstraints = false
            s.heightAnchor.constraint(equalToConstant: 96).isActive = true
            let lbl = NSTextField(labelWithString: f >= 1000 ? "\(Int(f/1000))k" : "\(Int(f))")
            lbl.font = .systemFont(ofSize: 8)
            lbl.textColor = .tertiaryLabelColor
            lbl.alignment = .center
            let col = NSStackView(views: [s, lbl])
            col.orientation = .vertical
            col.alignment = .centerX
            col.spacing = 2
            bandsRow.addArrangedSubview(col)
        }
        stack.addArrangedSubview(bandsRow)

        let boostLabel = NSTextField(labelWithString:
            String(format: L("Ses yükseltme  %+.0f dB", "Gain boost  %+.0f dB"), MusicEngine.shared.boostDB))
        boostLabel.font = .systemFont(ofSize: 11)
        boostLabel.textColor = .secondaryLabelColor
        eqBoostLabel = boostLabel
        let boost = NSSlider(value: Double(MusicEngine.shared.boostDB),
                             minValue: -12, maxValue: 12,
                             target: self, action: #selector(boostChanged(_:)))
        boost.controlSize = .small
        boost.translatesAutoresizingMaskIntoConstraints = false
        boost.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let reset = NSButton(title: L("Sıfırla", "Reset"), target: self, action: #selector(resetEQ))
        reset.bezelStyle = .rounded
        let boostRow = NSStackView(views: [boostLabel, boost, reset])
        boostRow.orientation = .horizontal
        boostRow.spacing = 8
        stack.addArrangedSubview(boostRow)

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: 430),
        ])
        vc.view = root
        let pop = NSPopover()
        pop.contentViewController = vc
        pop.behavior = .transient
        pop.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
        eqPopover = pop
    }

    @objc private func bandChanged(_ s: NSSlider) {
        MusicEngine.shared.setBandGain(s.tag, Float(s.doubleValue))
    }
    @objc private func boostChanged(_ s: NSSlider) {
        MusicEngine.shared.boostDB = Float(s.doubleValue)
        eqBoostLabel?.stringValue = String(format: L("Ses yükseltme  %+.0f dB", "Gain boost  %+.0f dB"), s.doubleValue)
    }
    @objc private func resetEQ() {
        MusicEngine.shared.resetEQ()
        eqPopover?.close()
    }

    // MARK: - Grid verisi

    func collectionView(_ c: NSCollectionView, numberOfItemsInSection s: Int) -> Int {
        gridItems.count
    }

    func collectionView(_ c: NSCollectionView,
                        itemForRepresentedObjectAt path: IndexPath) -> NSCollectionViewItem {
        let item = c.makeItem(withIdentifier: .init("tile"), for: path) as! PlaylistTile
        let items = gridItems
        guard path.item < items.count else { return item }
        if let pl = items[path.item] {
            item.configure(title: pl.name, count: pl.paths.count,
                           image: PlaylistArt.load(pl.id)
                               ?? PlaylistArt.placeholder(pl.name, side: 132))
            item.name.onCommit = { [weak self] new in
                PlaylistStore.rename(pl.id, to: new)
                self?.playlists = PlaylistStore.load()
                self?.grid.reloadData()
            }
            item.name.onEnd = { [weak self] in self?.renamingPlaylist = nil }
            if pl.id == renamingPlaylist {
                DispatchQueue.main.async { item.name.beginEditing() }
            }
        } else {
            item.configure(title: L("Tüm şarkılar", "All songs"), count: allTracks.count,
                           image: PlaylistArt.placeholder("♪", side: 132))
        }
        return item
    }

    // MARK: - Parca listesi

    /// Yuvarlak kose vurgu — tum listelerde ayni dil.
    func tableView(_ t: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        DeviceRowView()
    }

    func numberOfRows(in t: NSTableView) -> Int { shown.count }

    func tableView(_ t: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        guard row < shown.count else { return nil }
        let tr = shown[row]
        let playing = MusicEngine.shared.current?.path == tr.path

        let cover = NSImageView()
        if let img = artCache[tr.albumID] {
            cover.image = img
            cover.wantsLayer = true
            cover.layer?.cornerRadius = 4
            cover.layer?.masksToBounds = true
            cover.imageScaling = .scaleProportionallyUpOrDown
        } else {
            cover.image = NSImage(systemSymbolName: playing ? "speaker.wave.2.fill" : "music.note",
                                  accessibilityDescription: nil)
            cover.contentTintColor = playing ? .controlAccentColor : .tertiaryLabelColor
            loadArt(tr)
        }
        cover.translatesAutoresizingMaskIntoConstraints = false
        cover.widthAnchor.constraint(equalToConstant: 30).isActive = true
        cover.heightAnchor.constraint(equalToConstant: 30).isActive = true

        let title = NSTextField(labelWithString: tr.title)
        title.font = .systemFont(ofSize: 12, weight: playing ? .semibold : .regular)
        title.lineBreakMode = .byTruncatingTail
        let sub = NSTextField(labelWithString: tr.artist)
        sub.font = .systemFont(ofSize: 10)
        sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byTruncatingTail
        let texts = NSStackView(views: [title, sub])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 0

        let dur = NSTextField(labelWithString: tr.durationText)
        dur.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        dur.textColor = .tertiaryLabelColor

        let r = NSStackView(views: [cover, texts, NSView(), dur])
        r.orientation = .horizontal
        r.spacing = 10
        r.edgeInsets = NSEdgeInsets(top: 3, left: 6, bottom: 3, right: 6)
        return r
    }
}

/// Muzik panelini elle yerlestirir: ustte baslik, ortada grid VEYA liste,
/// altta oynatici serit.
final class MusicRootView: NSView {
    var head: NSView?
    var grid: NSView?
    var list: NSView?
    var player: NSView?
    var showGrid = true { didSet { needsLayout = true } }

    override func layout() {
        super.layout()
        guard let head, let grid, let list, let player else { return }
        let playerH: CGFloat = 78
        player.frame = NSRect(x: 0, y: 0, width: bounds.width, height: playerH)
        let headH: CGFloat = 30
        head.frame = NSRect(x: 0, y: bounds.height - headH, width: bounds.width, height: headH)
        let content = NSRect(x: 0, y: playerH + 10, width: bounds.width,
                             height: max(bounds.height - playerH - headH - 20, 0))
        grid.frame = content
        list.frame = content
        grid.isHidden = !showGrid
        list.isHidden = showGrid
    }
}
