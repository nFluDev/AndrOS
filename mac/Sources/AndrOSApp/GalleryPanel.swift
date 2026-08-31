import AppKit
import AVKit
import AVFoundation
import AndrOSCore
import UniformTypeIdentifiers

/// Telefondaki resim ve videolar. Kucuk resimler talep uzerine (gorunur
/// olduklarinda) indirilir — 400 dosyayi bastan cekmek hem yavas hem gereksiz.
final class GalleryPanel: NSViewController, AndrOSPanel,
                          NSCollectionViewDataSource, NSCollectionViewDelegate,
                          NSDraggingDestination, AVPlayerViewDelegate {
    private var isLoading = false
    private var refreshObserverInstalled = false
    var data: AndroidData? { didSet { promises.data = data } }
    private let promises = FilePromiseDelegate()
    /// Mac'ten gelen medyanin gidecegi klasor.
    private let inbox = "/sdcard/DCIM/AndrOS"
    private let viewerArea = ViewerAreaView()
    private let imageView = NSImageView()
    private let playerView = AVPlayerView()
    private let backButton = NSButton()
    private let viewerCaption = NSTextField(labelWithString: "")
    private let viewerSpinner = NSProgressIndicator()
    private var player: AVPlayer?
    private var currentLocal: URL?
    /// Hangi ogenin acilmasi istendi — gec gelen indirmeler eskisini acmasin.
    private var pendingPath: String?
    private var viewCache: [String: URL] = [:]
    private let searchBox = SearchToggle()
    private var allItems: [AndroidData.MediaItem] = []

    private func applyFilter() {
        let q = searchBox.text.trimmingCharacters(in: .whitespaces).lowercased()
        let old = items
        items = allItems.filter { SearchMatch.matches(q, $0.name) }
        if items.isEmpty {
            emptyState().show(
                allItems.isEmpty ? L("Burada bir şey yok", "Nothing here")
                                 : L("Eşleşen öğe yok", "No matching item"),
                allItems.isEmpty
                    ? L("Telefondaki resim ve videolar burada görünür.",
                        "Photos and videos from the phone show up here.")
                    : L("Aramayı değiştir ya da temizle.", "Change or clear the search."),
                symbol: "photo.on.rectangle")
        } else { emptyState().isHidden = true }
        countLabel.stringValue = L("\(items.count) öğe", "\(items.count) items")
        // Tazeleme kullanicinin YERINI bozmasin: secili ogeler ve
        // kaydirma konumu korunuyor. Onceki surumde arka plan tazelemesi
        // secimi silip listeyi basa sariyordu — resim secerken can
        // sikiciydi.
        let keep = Set(collection.selectionIndexPaths.compactMap {
            $0.item < old.count ? old[$0.item].path : nil
        })
        let y = gridScroll?.contentView.bounds.origin.y
        collection.reloadData()
        if !keep.isEmpty {
            let paths = items.enumerated()
                .filter { keep.contains($0.element.path) }
                .map { IndexPath(item: $0.offset, section: 0) }
            if !paths.isEmpty { collection.selectionIndexPaths = Set(paths) }
        }
        if let y, let sv = gridScroll {
            sv.contentView.scroll(to: NSPoint(x: 0, y: y))
            sv.reflectScrolledClipView(sv.contentView)
        }
    }

    private var items: [AndroidData.MediaItem] = []
    private let collection = NSCollectionView()
    private let segmented = NSSegmentedControl(labels: ["Resimler", "Videolar"],
                                               trackingMode: .selectOne, target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private let countLabel = NSTextField(labelWithString: "")
    private var thumbs: [String: NSImage] = [:]
    private var loading = Set<String>()
    private weak var gridScroll: NSScrollView?
    /// Goruntuleyicide su an gosterilen ogenin listedeki yeri.
    private var viewerIndex: Int?
    private let progress = NSProgressIndicator()
    private var downloadHandle: RawProcess.Handle?
    private let cacheDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("AndrOS/thumbs", isDirectory: true)

    override func loadView() {
        let root = GalleryRootView()
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        segmented.selectedSegment = 0
        segmented.target = self
        segmented.action = #selector(kindChanged)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor

        searchBox.placeholder = L("Dosya adı", "File name")
        searchBox.onChange = { [weak self] _ in self?.applyFilter() }

        // Eylemler SAG TIK menusunde (Finder gibi); ustte yalniz sekme,
        // durum ve arama var. Arama HER PANELDE en sagda duruyor.
        let bar = NSStackView(views: [segmented, spinner, countLabel,
                                      flexSpacer(), searchBox])
        bar.orientation = .horizontal
        bar.spacing = 10
        bar.translatesAutoresizingMaskIntoConstraints = false

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 132, height: 132)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        collection.collectionViewLayout = layout
        collection.dataSource = self
        collection.delegate = self
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.backgroundColors = [.clear]
        collection.register(ThumbItem.self,
                            forItemWithIdentifier: .init("thumb"))
        // Disari surukleme (promise) ve iceri birakma
        collection.setDraggingSourceOperationMask([.copy], forLocal: false)
        collection.registerForDraggedTypes([.fileURL])
        collection.menu = buildMenu()
        // Cift tik: TIKLANAN KONUMDAN oge bulunuyor.
        // Onceki surum `selectionIndexPaths` kullaniyordu; secim henuz
        // guncellenmedigi icin bir onceki ogeyi aciyordu.
        let dbl = NSClickGestureRecognizer(target: self, action: #selector(doubleClicked(_:)))
        dbl.numberOfClicksRequired = 2
        // Tanimlayici varsayilan olarak ilk tiklamayi BEKLETIYOR (cift tik
        // olacak mi diye). Bu yuzden secim gec olusuyordu. Kapatinca tek tik
        // aninda gecerken cift tik da calismaya devam ediyor.
        dbl.delaysPrimaryMouseButtonEvents = false
        collection.addGestureRecognizer(dbl)

        // --- Gomulu goruntuleyici: AYRI PENCERE YOK.
        // Geri tuslarina ya da "Resimler/Videolar"a basinca kapanir.
        backButton.title = "‹ Geri"
        backButton.bezelStyle = .rounded
        backButton.target = self
        backButton.action = #selector(closeViewer)
        viewerCaption.font = .systemFont(ofSize: 11)
        viewerCaption.textColor = .secondaryLabelColor

        let openExt = NSButton(title: L("Mac'te aç", "Open on Mac"), target: self, action: #selector(openExternally))
        openExt.bezelStyle = .rounded
        let viewerBar = NSStackView(views: [backButton, openExt, viewerSpinner, viewerCaption])
        viewerBar.orientation = .horizontal
        // Gezinme KAYDIRMA ile: iki parmakla saga/sola cekince onceki/
        // sonraki ogeye geciliyor. Ok dugmeleri goruntunun uzerini
        // kapatiyordu; kaydirma hem daha az yer kapliyor hem telefondaki
        // galeri deneyimine benziyor. Ok TUSLARI da duruyor.
        viewerArea.onSwipe = { [weak self] dir in self?.step(dir) }

        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 100
        progress.isHidden = true
        progress.controlSize = .small
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.widthAnchor.constraint(equalToConstant: 160).isActive = true
        viewerBar.addArrangedSubview(progress)

        viewerBar.spacing = 10
        viewerBar.translatesAutoresizingMaskIntoConstraints = false

        viewerSpinner.style = .spinning
        viewerSpinner.controlSize = .small
        viewerSpinner.isDisplayedWhenStopped = false

        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        // GOMULU oynaticida ".floating" kullanilmiyor: o bicim tam ekran icin
        // tasarlandigindan fare bir sure kipirdamayinca IMLECI GIZLIYOR.
        // Galeride video sekmesi acikken imlec kayboluyordu. ".inline"
        // imleci gizlemez; tam ekrana gecince asagida ".floating"e donuyor.
        playerView.controlsStyle = .inline
        playerView.delegate = self
        playerView.translatesAutoresizingMaskIntoConstraints = false
        playerView.isHidden = true

        // KRITIK: NSImageView buyuk bir resim yuklendiginde, AVPlayerView de
        // denetimleri yuzunden BUYUK icsel boyut talep ediyor. Bu talepler
        // panelin "arac cubugunu uste baglama" kisitiyla cakisiyordu ve
        // AppKit benim kisitimi kirip icerigi alta itiyordu.
        // Ikisini de sikistirilabilir yapiyoruz: alan neyse ona uysunlar.
        for v in [imageView, playerView] as [NSView] {
            v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
            v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            v.setContentHuggingPriority(.defaultLow, for: .vertical)
            v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }

        viewerArea.wantsLayer = true
        // OPAK zemin: yari saydam olunca arkadaki izgara gorunuyor ve
        // kaydirilabiliyordu — goruntuleyici acikken orada olmamali.
        viewerArea.layer?.backgroundColor = NSColor.black.cgColor
        viewerArea.layer?.cornerRadius = 10
        viewerArea.translatesAutoresizingMaskIntoConstraints = false
        viewerArea.isHidden = true
        imageView.translatesAutoresizingMaskIntoConstraints = true
        playerView.translatesAutoresizingMaskIntoConstraints = true
        viewerBar.translatesAutoresizingMaskIntoConstraints = true
        viewerArea.bar = viewerBar
        viewerArea.image = imageView
        viewerArea.player = playerView
        viewerArea.addSubview(viewerBar)
        viewerArea.addSubview(imageView)
        viewerArea.addSubview(playerView)

        // ELLE YERLESIM. Auto Layout burada hicbir uyari vermeden yanlis
        // sonuc uretiyordu (arac cubugu asagi kayiyor, liste 48px'e
        // sikisiyordu). Panel kokunu kendi layout()'unda konumlandirmak
        // belirsizligi tamamen kaldiriyor — contentBox'ta da ayni cozum.
        let scroll = scrollWrap(collection)
        gridScroll = scroll
        scroll.translatesAutoresizingMaskIntoConstraints = true
        bar.translatesAutoresizingMaskIntoConstraints = true
        viewerArea.translatesAutoresizingMaskIntoConstraints = true
        root.bar = bar
        root.list = scroll
        root.viewer = viewerArea
        root.addSubview(bar)
        root.addSubview(scroll)
        root.addSubview(viewerArea)
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
            UserBusy.run { [weak self] in self?.load() }
            }
        }
        if items.isEmpty { load() }
        reattachPlayingVideo()
    }

    // MARK: - Disari surukleme

    func collectionView(_ c: NSCollectionView,
                        pasteboardWriterForItemAt path: IndexPath) -> NSPasteboardWriting? {
        guard path.item < items.count else { return nil }
        let m = items[path.item]
        let ext = (m.name as NSString).pathExtension
        let type = UTType(filenameExtension: ext) ?? .data
        let p = RemoteFilePromise(fileType: type.identifier, delegate: promises)
        p.entry = AndroidData.FileEntry(name: m.name, path: m.path,
                                        isDirectory: false, size: m.size)
        return p
    }

    // MARK: - Iceri birakma (YALNIZ resim ve video)

    func collectionView(_ c: NSCollectionView, validateDrop info: NSDraggingInfo,
                        proposedIndexPath path: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation op: UnsafeMutablePointer<NSCollectionView.DropOperation>)
                        -> NSDragOperation {
        guard let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: nil) as? [URL] else { return [] }
        // Medya olmayanlar reddedilir: bu panel galeri, dosya deposu degil.
        return MediaFilter.split(urls).accepted.isEmpty ? [] : .copy
    }

    func collectionView(_ c: NSCollectionView, acceptDrop info: NSDraggingInfo,
                        indexPath: IndexPath,
                        dropOperation op: NSCollectionView.DropOperation) -> Bool {
        guard let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: nil) as? [URL] else { return false }
        return upload(urls)
    }

    /// Mac'ten gelen medyayi telefona yukler.
    ///
    /// Video birakilirsa yukleme bitince VIDEO sekmesine geciyoruz —
    /// aksi halde dosya "kayboldu" gibi gorunuyor.
    @discardableResult
    private func upload(_ urls: [URL]) -> Bool {
        guard let d = data else { return false }
        let (accepted, rejected) = MediaFilter.split(urls)
        guard !accepted.isEmpty else { return false }
        let droppedVideo = accepted.contains {
            MediaFilter.videoExts.contains($0.pathExtension.lowercased())
        }

        spinner.startAnimation(nil)
        let dest = inbox
        DispatchQueue.global().async { [weak self] in
            _ = try? d.adb.run(["shell", "mkdir", "-p", dest])
            var ok = 0
            for u in accepted where d.push(u.path, to: dest) { ok += 1 }
            // Galeri uygulamasi yeni dosyalari gorsun diye MediaStore'u tetikle
            _ = try? d.adb.run(["shell", "am", "broadcast",
                                "-a", "android.intent.action.MEDIA_SCANNER_SCAN_FILE",
                                "-d", "file://\(dest)"])
            DispatchQueue.main.async {
                guard let self else { return }
                self.spinner.stopAnimation(nil)
                var msg = L("\(ok)/\(accepted.count) medya yüklendi → \(dest)", "\(ok)/\(accepted.count) media uploaded → \(dest)")
                if !rejected.isEmpty { msg += L("  ·  \(rejected.count) dosya atlandı (medya değil)", "  ·  \(rejected.count) files skipped (not media)") }
                self.countLabel.stringValue = msg
                // Video birakildiysa VIDEO sekmesine gec: yuklenen dosya
                // resimler sekmesinde gorunmedigi icin kaybolmus sanilıyordu.
                if droppedVideo, self.segmented.selectedSegment != 1 {
                    self.segmented.selectedSegment = 1
                    self.items = []; self.thumbs = [:]
                }
                self.refreshNow()
            }
        }
        return true
    }

    private func buildMenu() -> NSMenu {
        let m = NSMenu()
        for (t, sel) in [(L("Aç", "Open"), #selector(openSelected)),
                         (L("Mac'e kaydet…", "Save to Mac…"), #selector(saveSelected)),
                         (L("", ""), nil),
                         (L("Kopyala", "Copy"), #selector(copyContent)),
                         (L("Yolu kopyala", "Copy path"), #selector(copyPath)),
                         (L("", ""), nil),
                         (L("Mac'ten yükle…", "Upload from Mac…"), #selector(uploadFromMac)),
                         (L("Yenile", "Refresh"), #selector(refreshNow)),
                         (L("", ""), nil),
                         (L("Telefondan sil", "Delete from phone"), #selector(deleteSelected))]
                        as [(String, Selector?)] {
            guard let sel else { m.addItem(.separator()); continue }
            let i = NSMenuItem(title: t, action: sel, keyEquivalent: "")
            i.target = self
            m.addItem(i)
        }
        return m
    }

    @objc private func refreshNow() {
        allItems = []; items = []
        isLoading = false
        load()
    }

    /// Mac'ten resim/video sec ve telefona yukle (surukle-birakla ayni yol).
    @objc private func uploadFromMac() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .movie]
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        upload(panel.urls)
    }

    @objc private func doubleClicked(_ g: NSClickGestureRecognizer) {
        let p = g.location(in: collection)
        guard let ip = collection.indexPathForItem(at: p), ip.item < items.count else { return }
        collection.selectionIndexPaths = [ip]
        openItem(items[ip.item])
    }

    @objc private func openSelected() {
        guard let ip = collection.selectionIndexPaths.first, ip.item < items.count else { return }
        openItem(items[ip.item])
    }

    /// Ogeyi PANEL ICINDE acar (ayri pencere yok).
    private func openItem(_ m: AndroidData.MediaItem) {
        guard let d = data else { return }
        viewerArea.isHidden = false
        viewerArea.startTracking()
        gridScroll?.isHidden = true          // arkadan gorunmesin/kaydirilmasin
        viewerIndex = items.firstIndex { $0.path == m.path }
        pendingPath = m.path
        // KURAL: calan video ancak BASKA BIR VIDEO acilinca ya da
        // seritteki kapatma dugmesiyle durur. Resme gecmek onu
        // susturmaz — video muzik ya da konusma iceriyor olabilir.
        if m.isVideo { stopPlayback() } else { detachPlayer() }
        imageView.image = nil
        viewerCaption.stringValue = m.name

        // Zaten CALAN video yeniden acildiysa bastan baslatma: gorunume
        // geri bagla, kaldigi saniyeden devam etsin.
        let np = NowPlaying.shared
        if m.isVideo, np.kind == .video, np.videoPath == m.path, let p = np.videoPlayer {
            imageView.isHidden = true
            playerView.isHidden = false
            player = p
            playerView.player = p
            viewerCaption.stringValue = "\(m.name) · \(FilesPanel.human(m.size))"
                + L(" · devam ediyor", " · resuming")
            return
        }

        if let local = viewCache[m.path], FileManager.default.fileExists(atPath: local.path) {
            showLocal(local, m: m, cached: true)
            return
        }
        // VIDEO: indirmeden AKIT. Telefondaki kucuk HTTP sunucusu
        // byte-range destekliyor, `AVPlayer` ilk saniyeler gelir gelmez
        // basliyor — buyuk dosyayi bastan sona indirmeye gerek yok.
        if m.isVideo, d.companion?.isReady == true {
            viewerSpinner.startAnimation(nil)
            viewerCaption.stringValue = L("Bağlanılıyor…", "Connecting…")
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let url = d.streamURL(for: m.path)
                DispatchQueue.main.async {
                    guard let self, self.pendingPath == m.path else { return }
                    self.viewerSpinner.stopAnimation(nil)
                    guard let url else {
                        // Akis kurulamadiysa eski yola dus: indirip oynat.
                        self.downloadAndShow(m, d)
                        return
                    }
                    self.playStream(url, m: m)
                }
            }
            return
        }
        downloadAndShow(m, d)
    }

    /// Dosyayi indirip gosterir (akis yoksa ya da resimlerde).
    private func downloadAndShow(_ m: AndroidData.MediaItem, _ d: AndroidData) {
        viewerSpinner.startAnimation(nil)
        viewerCaption.stringValue = L("İndiriliyor: \(m.name)…", "Downloading: \(m.name)…")
        // Buyuk video birkac saniye surebiliyor; ilerleme gostermeden
        // "hicbir sey olmadi" hissi veriyordu (kullanici cift tikladi,
        // sonra gezinirken video birden aciliyordu).
        progress.isHidden = false
        progress.doubleValue = 0
        let local = FileManager.default.temporaryDirectory
            .appendingPathComponent("AndrOS/view", isDirectory: true)
            .appendingPathComponent(String(abs(m.path.hashValue), radix: 16) + "-" + m.name)
        try? FileManager.default.createDirectory(
            at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        downloadHandle?.cancel()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var args = d.adb.serial.map { ["-s", $0] } ?? []
            args += ["pull", m.path, local.path]
            let r = RawProcess.runStreaming(
                d.adb.path, args,
                onHandle: { h in DispatchQueue.main.async { self?.downloadHandle = h } },
                onProgress: { pct in
                    DispatchQueue.main.async {
                        guard self?.pendingPath == m.path else { return }
                        self?.progress.doubleValue = Double(pct)
                    }
                },
                timeout: 600)
            let ok = r.code == 0
                && (try? FileManager.default.attributesOfItem(atPath: local.path)[.size] as? Int)
                    .flatMap { $0 }.map { $0 > 0 } == true
            DispatchQueue.main.async {
                guard let self else { return }
                self.downloadHandle = nil
                self.progress.isHidden = true
                // Bu arada baska bir oge secildiyse bunu ACMA.
                guard self.pendingPath == m.path else { return }
                self.viewerSpinner.stopAnimation(nil)
                guard ok else { self.viewerCaption.stringValue = L("İndirilemedi: \(m.name)", "Download failed: \(m.name)"); return }
                self.viewCache[m.path] = local
                self.showLocal(local, m: m, cached: false)
            }
        }
    }

    /// HTTP kaynagindan akitarak oynatir.
    private func playStream(_ url: URL, m: AndroidData.MediaItem) {
        currentLocal = nil
        viewerCaption.stringValue = "\(m.name) · \(FilesPanel.human(m.size))"
            + L(" · akış", " · streaming")
        imageView.isHidden = true
        playerView.isHidden = false
        let p = AVPlayer(url: url)
        player = p
        playerView.player = p
        p.play()
        // Sol alttaki serit de bu videoyu gostersin.
        NowPlaying.shared.beginVideo(p, title: m.name,
                                     subtitle: L("Video · akış", "Video · streaming"),
                                     poster: thumbs[m.path], path: m.path)
    }

    private func showLocal(_ url: URL, m: AndroidData.MediaItem, cached: Bool) {
        currentLocal = url
        viewerCaption.stringValue = "\(m.name) · \(FilesPanel.human(m.size))"
            + (cached ? L(" · önbellekten", " · from cache") : "")
        if m.isVideo {
            imageView.isHidden = true
            playerView.isHidden = false
            let p = AVPlayer(url: url)
            player = p
            playerView.player = p
            p.play()
            NowPlaying.shared.beginVideo(p, title: m.name, subtitle: L("Video", "Video"),
                                         poster: thumbs[m.path], path: m.path)
        } else {
            playerView.isHidden = true
            imageView.isHidden = false
            imageView.image = NSImage(contentsOf: url)
        }
    }

    /// Slayt gezinmesi: listedeki onceki/sonraki ogeye gec.
    ///
    /// Klavye oklari da ayni yolu kullaniyor — goruntuleyici acikken
    /// resimden resme gecmek icin fareyle dugmeye basmak gerekmesin.
    @objc private func showPrevious() { step(-1) }
    @objc private func showNext() { step(1) }

    private func step(_ delta: Int) {
        guard let i = viewerIndex else { return }
        let j = i + delta
        guard j >= 0, j < items.count else { return }
        openItem(items[j])
    }

    override func keyDown(with e: NSEvent) {
        guard !viewerArea.isHidden else { super.keyDown(with: e); return }
        switch e.keyCode {
        case 123: showPrevious()          // sol ok
        case 124: showNext()              // sag ok
        case 53:  closeViewer()           // Esc
        default:  super.keyDown(with: e)
        }
    }

    /// Oynatmayi KESIN olarak durdurur (baska bir oge acilirken).
    private func stopPlayback() {
        NowPlaying.shared.stopVideo()
        playerView.player = nil
        player = nil
    }

    /// Goruntuleyiciden AYIR — ama calmaya devam etsin.
    ///
    /// Kullanicinin istedigi davranis: video penceresi kapansa da,
    /// baska kategoriye gecilse de ses/goruntu sol alttaki seritten
    /// yonetilmeye devam etsin. Bu yuzden burada `AVPlayer` durmuyor;
    /// yalnizca gorunumle bagi kesiliyor. Oynatici `NowPlaying` icinde
    /// gucli tutuldugu icin ayakta kaliyor.
    private func detachPlayer() {
        playerView.player = nil
        player = nil
    }

    @objc private func closeViewer() {
        detachPlayer()
        pendingPath = nil
        viewerSpinner.stopAnimation(nil)
        viewerArea.stopTracking()
        viewerArea.isHidden = true
        gridScroll?.isHidden = false
        imageView.image = nil
        downloadHandle?.cancel()
        downloadHandle = nil
        progress.isHidden = true
    }

    @objc private func openExternally() {
        guard let u = currentLocal else { return }
        NSWorkspace.shared.open(u)
    }

    /// Panelden cikilinca oynatma DURMAZ: serit devrali(yor).
    func willDisappear() { closeViewer() }

    /// Galeriye geri donuldugunde halen oynayan videoyu goruntuye geri bagla.
    private func reattachPlayingVideo() {
        let np = NowPlaying.shared
        guard np.kind == .video, let p = np.videoPlayer else { return }
        viewerArea.isHidden = false
        viewerArea.startTracking()
        gridScroll?.isHidden = true
        imageView.isHidden = true
        playerView.isHidden = false
        player = p
        playerView.player = p
        pendingPath = np.videoPath
        viewerCaption.stringValue = np.videoTitle
        if let path = np.videoPath {
            viewerIndex = items.firstIndex { $0.path == path }
        }
    }

    /// Resmi/videoyu panoya ICERIK olarak koyar (yol degil).
    @objc private func copyContent() {
        guard let d = data else { return }
        let picked = collection.selectionIndexPaths.map { items[$0.item] }
        guard !picked.isEmpty else { return }
        spinner.startAnimation(nil)
        CopyContent.copy(picked.map { ($0.path, $0.name) }, data: d,
                         onProgress: { [weak self] m in self?.countLabel.stringValue = m },
                         onDone: { [weak self] n in
                             self?.spinner.stopAnimation(nil)
                             self?.countLabel.stringValue = L("\(n) öğe panoya kopyalandı", "\(n) items copied to the clipboard")
                         })
    }

    @objc private func copyPath() {
        let paths = collection.selectionIndexPaths.map { items[$0.item].path }
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    @objc private func deleteSelected() {
        guard let d = data else { return }
        let picked = collection.selectionIndexPaths.map { items[$0.item] }
        guard !picked.isEmpty else { return }
        let a = NSAlert()
        a.messageText = L("\(picked.count) öğe telefondan silinsin mi?", "Delete \(picked.count) items from the phone?")
        a.informativeText = L("Bu işlem geri alınamaz.", "This cannot be undone.")
        a.alertStyle = .warning
        a.addButton(withTitle: L("Sil", "Delete")); a.addButton(withTitle: L("Vazgeç", "Cancel"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        spinner.startAnimation(nil)
        DispatchQueue.global().async { [weak self] in
            for m in picked { _ = try? d.adb.run(["shell", "rm", "-f", "\"\(m.path)\""]) }
            DispatchQueue.main.async { self?.spinner.stopAnimation(nil); self?.load() }
        }
    }

    @objc private func kindChanged() {
        // Sekme degistirmek de videoyu DURDURMAZ; serit devam eder.
        closeViewer()
        items = []; thumbs = [:]; load()
    }

    private func load() {
        // AYNI ANDA tek yukleme. Ust uste binen istekler adb'yi
        // doyuruyor, uygulama koprusunun istekleri de arkada bekleyip
        // zaman asimina ugruyordu — panel dakikalarca bos kaliyordu.
        guard !isLoading else { return }
        // Goruntuleyici ACIKKEN tazeleme yok: liste altindan degisince
        // kaydirmayla gecilen "sonraki" oge kayiyordu.
        guard viewerArea.isHidden else { return }
        guard let d = data else { return }
        isLoading = true
        let videos = segmented.selectedSegment == 1
        spinner.startAnimation(nil)
        DispatchQueue.global().async { [weak self] in
            let list = d.mediaPreferringApp(videos: videos)
            DispatchQueue.main.async {
                guard let self else { return }
                // Bayragi HER DURUMDA sifirla: sifirlanmazsa ilk
                // yuklemeden sonra sekme degisimleri (Resimler/Videolar)
                // hicbir sey yapmiyor, panel kalici olarak sikisiyor.
                self.isLoading = false
                self.spinner.stopAnimation(nil)
                self.allItems = list
                self.applyFilter()
            }
        }
    }

    @objc private func saveSelected() {
        let picked = collection.selectionIndexPaths.map { items[$0.item] }
        guard !picked.isEmpty, let d = data else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = L("Buraya kaydet", "Save here")
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        // Kuyruga ekle: ilerleme sol alttaki aktarim seridinde gorunur.
        for m in picked {
            TransferQueue.shared.enqueue(name: m.name, remote: m.path,
                                         local: dir.appendingPathComponent(m.name).path,
                                         direction: .download)
        }
        countLabel.stringValue = L("\(picked.count) öğe indirme sırasında", "\(picked.count) items queued for download")
        _ = d
    }

    // MARK: - Koleksiyon

    func collectionView(_ c: NSCollectionView, numberOfItemsInSection s: Int) -> Int { items.count }

    func collectionView(_ c: NSCollectionView,
                        itemForRepresentedObjectAt path: IndexPath) -> NSCollectionViewItem {
        let item = c.makeItem(withIdentifier: .init("thumb"), for: path) as! ThumbItem
        // SINIR KONTROLU: AppKit, `items` degistikten sonra ama
        // `reloadData()` islenmeden once eski indeksle hucre isteyebiliyor.
        // Kontrolsuz erisim uygulamayi dusuruyordu (olculdu: crash raporu,
        // GalleryPanel.swift:482 "Index out of range").
        guard path.item < items.count else {
            item.configure(name: "", isVideo: false, image: nil)
            return item
        }
        let m = items[path.item]
        item.configure(name: m.name, isVideo: m.isVideo, image: thumbs[m.path])
        if thumbs[m.path] == nil { fetchThumb(m) }
        return item
    }

    /// Kucuk resmi indirir. Videolarda MediaStore'un hazir kucuk resmi
    /// kullaniliyor — videoyu indirip kare cikarmaya gerek yok.
    /// Tek hucreyi tazele — SECIMI silmeden.
    ///
    /// `reloadItems(at:)` macOS'ta o hucrenin secimini dusuruyor; kucuk
    /// resimler arka planda geldigi icin kullanicinin secimi kendiliginden
    /// kayboluyordu.
    private func reloadItemKeepingSelection(_ i: Int) {
        let sel = collection.selectionIndexPaths
        collection.reloadItems(at: [IndexPath(item: i, section: 0)])
        if !sel.isEmpty { collection.selectionIndexPaths = sel }
    }

    private func fetchThumb(_ m: AndroidData.MediaItem) {
        guard !loading.contains(m.path), let d = data else { return }
        if m.isVideo {
            loading.insert(m.path)
            let dir = cacheDir
            DispatchQueue.global(qos: .utility).async { [weak self] in
                // Uygulama eslesmisse kucuk resmi ORADAN al: adb yolunda
                // kucuk resmi olmayan videolar icin saglayici hata METNI
                // donuyordu (olculdu: 644 bayt).
                let img = (d.thumbnailPreferringApp(mediaID: m.mediaID, video: true,
                                                    cacheDir: dir)
                           ?? d.videoThumb(mediaID: m.mediaID, cacheDir: dir))
                    .flatMap { NSImage(contentsOf: $0) }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.loading.remove(m.path)
                    guard let img else { return }
                    self.thumbs[m.path] = img
                    if let i = self.items.firstIndex(where: { $0.path == m.path }) {
                        self.reloadItemKeepingSelection(i)
                    }
                }
            }
            return
        }
        loading.insert(m.path)
        let local = cacheDir.appendingPathComponent(
            String(m.path.hashValue, radix: 16) + "-" + m.name)
        let dir = cacheDir
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // Uygulama eslesmisse kucuk resmi ORADAN al: tam boy dosyayi
            // cekmek yerine 256 px'lik JPEG geliyor, cok daha hizli.
            if let t = d.thumbnailPreferringApp(mediaID: m.mediaID, video: false,
                                                cacheDir: dir),
               let img = NSImage(contentsOf: t) {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.loading.remove(m.path)
                    self.thumbs[m.path] = img
                    if let i = self.items.firstIndex(where: { $0.path == m.path }) {
                        self.reloadItemKeepingSelection(i)
                    }
                }
                return
            }
            if !FileManager.default.fileExists(atPath: local.path) {
                guard d.pull(m.path, to: local.path) else {
                    DispatchQueue.main.async { self?.loading.remove(m.path) }
                    return
                }
            }
            guard let img = NSImage(contentsOf: local) else {
                DispatchQueue.main.async { self?.loading.remove(m.path) }
                return
            }
            // Bellekte tam boy tutmayalim
            let small = NSImage(size: NSSize(width: 128, height: 128))
            small.lockFocus()
            img.draw(in: NSRect(x: 0, y: 0, width: 128, height: 128),
                     from: .zero, operation: .copy, fraction: 1)
            small.unlockFocus()

            DispatchQueue.main.async {
                guard let self else { return }
                self.loading.remove(m.path)
                self.thumbs[m.path] = small
                if let i = self.items.firstIndex(where: { $0.path == m.path }) {
                    self.reloadItemKeepingSelection(i)
                }
            }
        }
    }
}

/// Tek bir kucuk resim hucresi.
final class ThumbItem: NSCollectionViewItem {
    private let thumb = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let badge = NSImageView()

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.cornerRadius = 8
        v.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor

        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 6
        thumb.layer?.masksToBounds = true
        thumb.translatesAutoresizingMaskIntoConstraints = false

        label.font = .systemFont(ofSize: 9)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false

        badge.image = NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: nil)
        badge.contentTintColor = .white
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.isHidden = true

        v.addSubview(thumb)
        v.addSubview(label)
        v.addSubview(badge)
        NSLayoutConstraint.activate([
            thumb.topAnchor.constraint(equalTo: v.topAnchor, constant: 6),
            thumb.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 6),
            thumb.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -6),
            thumb.heightAnchor.constraint(equalToConstant: 102),
            label.topAnchor.constraint(equalTo: thumb.bottomAnchor, constant: 3),
            label.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -4),
            badge.centerXAnchor.constraint(equalTo: thumb.centerXAnchor),
            badge.centerYAnchor.constraint(equalTo: thumb.centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 26),
            badge.heightAnchor.constraint(equalToConstant: 26),
        ])
        view = v
    }

    func configure(name: String, isVideo: Bool, image: NSImage?) {
        label.stringValue = name
        badge.isHidden = !isVideo
        if let i = image {
            thumb.image = i
        } else {
            thumb.image = NSImage(systemSymbolName: isVideo ? "film" : "photo",
                                  accessibilityDescription: nil)
            thumb.contentTintColor = .tertiaryLabelColor
        }
    }

    override var isSelected: Bool {
        didSet {
            view.layer?.borderWidth = isSelected ? 2 : 0
            view.layer?.borderColor = NSColor.controlAccentColor.cgColor
        }
    }
}


/// Galeri kokunu ELLE yerlestirir: ustte arac cubugu, altinda liste
/// (ya da acikken goruntuleyici) — ikisi de kalan alani tamamen kaplar.
final class GalleryRootView: NSView {
    var bar: NSView?
    var list: NSView?
    var viewer: NSView?

    override func layout() {
        super.layout()
        guard let bar, let list, let viewer else { return }
        let barH = bar.fittingSize.height > 0 ? bar.fittingSize.height : 26
        bar.frame = NSRect(x: 0, y: bounds.height - barH,
                           width: bounds.width, height: barH)
        let rest = NSRect(x: 0, y: 0, width: bounds.width,
                          height: max(bounds.height - barH - 10, 0))
        list.frame = rest
        viewer.frame = rest
    }
}

/// Goruntuleyici alani: ustte kucuk arac cubugu, altinda resim/oynatici.
final class ViewerAreaView: NSView {
    var bar: NSView?
    var image: NSView?
    var player: NSView?
    /// Yatay kaydirmada cagrilir: -1 onceki, +1 sonraki.
    var onSwipe: ((Int) -> Void)?

    override func layout() {
        super.layout()
        guard let bar, let image, let player else { return }
        let barH = bar.fittingSize.height > 0 ? bar.fittingSize.height : 24
        bar.frame = NSRect(x: 10, y: bounds.height - barH - 8,
                           width: bounds.width - 20, height: barH)
        let media = NSRect(x: 8, y: 8, width: bounds.width - 16,
                           height: max(bounds.height - barH - 24, 0))
        image.frame = media
        player.frame = media
    }

    // MARK: - Kaydirma

    /// Olay GOZLEMCISI kullaniyoruz, yanit zinciri degil.
    ///
    /// Olculen sorun: `AVPlayerView` fare ve kaydirma olaylarini kendi
    /// yutuyor, `NSImageView` de bazi olaylari ust gorunume vermiyordu —
    /// bu yuzden `scrollWheel(with:)` gecersiz kilmak videoda hic,
    /// resimde de yalnizca bos alanda calisiyordu. Yerel gozlemci
    /// olaylari gorunumlere DAGITILMADAN once goruyor; hem izmarit
    /// (trackpad) hem FARE SURUKLEMESI boylece her yerde isliyor.
    ///
    /// Fare surukleme olaylari TUKETILMIYOR (`return e`): oynaticinin
    /// kendi denetimleri calismaya devam etsin diye.
    private var monitor: Any?
    private var scrollAccum: CGFloat = 0
    private var scrollFired = false
    private var dragStart: NSPoint?
    private var dragMoved: CGFloat = 0

    /// Oynaticinin alt denetim seridi: orada suruklemek "ileri sar"dir,
    /// oge degistirmemeli.
    private var controlStripHeight: CGFloat { 52 }

    func startTracking() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.scrollWheel, .leftMouseDown, .leftMouseDragged, .leftMouseUp]) {
            [weak self] e in self?.handle(e) ?? e
        }
    }

    func stopTracking() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        dragStart = nil
        scrollAccum = 0
        scrollFired = false
    }

    deinit { if let m = monitor { NSEvent.removeMonitor(m) } }

    /// Olay bu goruntuleyicinin MEDYA alaninda mi?
    private func mediaPoint(_ e: NSEvent) -> NSPoint? {
        guard !isHiddenOrHasHiddenAncestor, let w = window,
              e.window === w, let media = image else { return nil }
        let p = convert(e.locationInWindow, from: nil)
        guard media.frame.contains(p) else { return nil }
        return p
    }

    private func handle(_ e: NSEvent) -> NSEvent? {
        switch e.type {
        case .scrollWheel:
            guard let _ = mediaPoint(e) else { return e }
            // Momentum artiklari birden fazla oge atlatiyordu.
            if e.momentumPhase != [] { return e }
            if e.phase == .began { scrollAccum = 0; scrollFired = false }
            if e.phase == .ended || e.phase == .cancelled {
                scrollAccum = 0; scrollFired = false; return e
            }
            guard abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) else { return e }
            if scrollFired { return nil }
            scrollAccum += e.scrollingDeltaX
            // Esik dusuk: hizli ve kisa bir hareket de yetmeli.
            let threshold: CGFloat = 16
            if scrollAccum <= -threshold { scrollFired = true; onSwipe?(1) }
            else if scrollAccum >= threshold { scrollFired = true; onSwipe?(-1) }
            return nil

        case .leftMouseDown:
            guard let p = mediaPoint(e) else { dragStart = nil; return e }
            // Oynaticinin denetim seridinde surukleme = ileri sar.
            if let pl = player, !pl.isHidden,
               p.y < pl.frame.minY + controlStripHeight { dragStart = nil; return e }
            dragStart = p
            dragMoved = 0
            return e

        case .leftMouseDragged:
            guard dragStart != nil else { return e }
            dragMoved += e.deltaX
            return e

        case .leftMouseUp:
            defer { dragStart = nil }
            guard let s = dragStart, let p = mediaPoint(e) else { return e }
            let dx = p.x - s.x, dy = p.y - s.y
            // Fare surukleme esigi kaydirmadan yuksek: tiklama ile
            // karismasin ama "eli kaydi" diyecek kadar da uzun olmasin.
            guard abs(dx) >= 40, abs(dx) > abs(dy) * 1.5 else { return e }
            onSwipe?(dx < 0 ? 1 : -1)     // sola cek -> sonraki
            return e

        default: return e
        }
    }
}

// MARK: - Tam ekran

extension GalleryPanel {
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
