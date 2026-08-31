import AppKit
import AndrOSCore

/// Sol (veya ust) kategoriler + sag icerik. AndrOS'un ana penceresi.
///
/// UYARLANABILIR YERLESIM: aynalama acikken ve telefon YATAY ise kategoriler
/// ust barda duruyor. Sebep: yatay goruntu genis ve alcak; yanina dikey bir
/// kategori sutunu koyunca ustte/altta kocaman bosluk kaliyor. Dikey
/// goruntude ise yan sutun dogal duruyor.
final class MainWindowController: NSWindowController {

    enum Category: String, CaseIterable {
        case device, emulator, mirroring, notifications, messages, calls, contacts, files, gallery, music, apps

        var title: String {
            switch self {
            case .device:    return L("Cihazlar", "Devices")
            case .emulator:  return L("Emülatör", "Emulator")
            case .notifications: return L("Bildirimler", "Notifications")
            case .mirroring: return L("Ekran Yansıtma", "Screen Mirroring")
            case .messages:  return L("Mesajlar", "Messages")
            case .calls:     return L("Aramalar", "Calls")
            case .contacts:  return L("Kişiler", "Contacts")
            case .files:     return L("Dosyalar", "Files")
            case .gallery:   return L("Galeri", "Gallery")
            case .music:     return L("Müzik", "Music")
            case .apps:      return L("Uygulamalar", "Apps")
            }
        }
        var symbol: String {
            switch self {
            case .device:    return "iphone.gen3"
            case .emulator:  return "cpu"
            case .notifications: return "bell.fill"
            case .mirroring: return "iphone.and.arrow.right.outward"
            case .messages:  return "message.fill"
            case .calls:     return "phone.fill"
            case .contacts:  return "person.crop.circle.fill"
            case .files:     return "folder.fill"
            case .gallery:   return "photo.fill"
            case .music:     return "music.note"
            case .apps:      return "square.grid.2x2.fill"
            }
        }
    }

    // Disari acilan baglantilar
    var onStartMirroring: ((HubDevice) -> Void)?
    var onStopMirroring: (() -> Void)?
    var onMirrorSetting: ((String, Any) -> Void)?
    /// Cihazlar panelinden baska bir cihaz secilince.
    var onSelectDevice: ((_ serial: String?, _ companionId: String?) -> Void)?
    var session: MirrorSession?

    private(set) var current: Category = .device
    private var buttons: [Category: CategoryButton] = [:]
    private var panels: [Category: NSViewController] = [:]

    private let barStack = NSStackView()
    private let barContainer = NSVisualEffectView()
    private let contentBox = ContentContainerView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let deviceLabel = NSTextField(labelWithString: L("Cihaz yok", "No device"))

    /// Kategoriler ust barda mi (yatay yerlesim)?
    private var horizontalBar = false
    /// Yan panel daraltilmis mi (yalniz ikonlar)?
    private var sidebarCollapsed = UserDefaults.standard.bool(forKey: "sidebarCollapsed")
    private let collapseButton = IconRowButton()
    /// Sag alt kosedeki ayarlar dislisi.
    private let settingsButton = IconRowButton()
    private let settingsHost = NSPopover()
    private let dock = BottomDock()
    /// Panel genisligi: animasyon icin sabit tutuluyor.
    private var barWidthC: NSLayoutConstraint?

    private var data: AndroidData?
    private var caps = AndroidData.Capabilities()

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 680),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable,
                                     .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "AndrOS"
        w.titlebarAppearsTransparent = true
        // Baslik metni GIZLI: tam boy icerikli pencerede baslik, trafik
        // isiklarinin yanina konan kenar cubugu dugmesiyle ust uste
        // biniyordu. Pencerenin adi zaten menu cubugunda yaziyor.
        w.titleVisibility = .hidden
        w.minSize = NSSize(width: 820, height: 520)
        w.center()
        super.init(window: w)
        buildUI()
        observeConversationJump()
        select(.device)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Kurulum

    /// macOS 26 arayuzu: kenar cubugu pencereden icerlek, yuvarlak koseli
    /// bir panel. Eski surumlerde cubuk kenara yapisik ve kosesiz kalir.
    /// Karar CALISMA ZAMANI surumune gore — eski SDK ile derlense de dogru.
    static let tahoe = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
    private var sidebarInset: CGFloat { Self.tahoe ? 10 : 0 }

    private func buildUI() {
        guard let w = window else { return }
        let root = RootView()
        root.wantsLayer = true
        root.onLayout = { [weak self] in self?.layoutTitlebarChrome() }

        // macOS 26 gorunumu: cam zemin, yumusak kose, ince ayirici.
        barContainer.material = .sidebar
        barContainer.blendingMode = .behindWindow
        barContainer.state = .followsWindowActiveState
        barContainer.wantsLayer = true
        if Self.tahoe {
            barContainer.layer?.cornerRadius = 14
            if #available(macOS 10.15, *) { barContainer.layer?.cornerCurve = .continuous }
            barContainer.layer?.masksToBounds = true
        }
        barContainer.translatesAutoresizingMaskIntoConstraints = false

        barStack.spacing = 3
        barStack.translatesAutoresizingMaskIntoConstraints = false
        barContainer.addSubview(barStack)

        collapseButton.setSymbol(sidebarCollapsed ? "sidebar.trailing" : "sidebar.leading")
        // Dugme baslik cubugunda tek basina duruyor: ikon her zaman ORTALI.
        // "collapsed" bayragi kenar cubugu yigini icin sola yaslama/ortalama
        // ayirt ediyordu; burada yigin yok, hep ortali kalmali — yoksa ikon
        // dugmenin icinde kayik duruyor.
        collapseButton.collapsed = true
        collapseButton.setAccessibilityLabel(L("Yan paneli daralt", "Collapse sidebar"))
        collapseButton.toolTip = L("Yan paneli daralt / genişlet", "Collapse / expand the sidebar")
        collapseButton.target = self
        collapseButton.action = #selector(toggleCollapse)
        // Dugme yiginin ICINDE DEGIL: trafik isiklarinin sagina, onlarla
        // ayni hizaya konumlaniyor (Finder'daki kenar cubugu dugmesi gibi).
        // Boylece kenar cubugu daralip genislerken dugme YERINDEN OYNAMIYOR;
        // daha once genisken ortada, darken baska yerde duruyordu.
        collapseButton.translatesAutoresizingMaskIntoConstraints = false

        // Yan panelin EN ALTI: aktarimlar + mini oynatici
        // Daraltilmis genislik trafik isiklarina gore: grup 62 px, iki
        // yanda 12 px ic bosluk -> 86. Olculdu: 76'da sol bosluk 11 px,
        // sag bosluk 3 px kaliyordu; kart yesil dugmeye yapisik duruyordu.
        barWidthC = barContainer.widthAnchor.constraint(
            equalToConstant: sidebarCollapsed ? 86 : 196)
        dock.translatesAutoresizingMaskIntoConstraints = false
        dock.onExpand = { [weak self] in
            self?.select(NowPlaying.shared.kind == .video ? .gallery : .music)
        }
        // Serit artik NowPlaying uzerinden: muzik de video da ayni
        // dugmelerle kontrol ediliyor.
        dock.onPlayPause = { NowPlaying.shared.togglePlay() }
        dock.onPrev = { NowPlaying.shared.previous() }
        dock.onNext = { NowPlaying.shared.next() }
        dock.onStop = { NowPlaying.shared.stopAll() }
        dock.onSeek = { frac in
            NowPlaying.shared.seek(to: frac * NowPlaying.shared.duration)
        }
        barContainer.addSubview(dock)
        MusicEngine.shared.addObserver("dock") { [weak self] in self?.refreshDock() }
        NowPlaying.shared.addObserver("dock") { [weak self] in self?.refreshDock() }

        for c in Category.allCases {
            let b = CategoryButton(category: c)
            b.target = self
            b.action = #selector(pick(_:))
            buttons[c] = b
            barStack.addArrangedSubview(b)
        }

        titleLabel.font = .systemFont(ofSize: 19, weight: .bold)
        deviceLabel.font = .systemFont(ofSize: 11)
        deviceLabel.textColor = .secondaryLabelColor

        // Baslik ELLE kuruluyor, yigin ile degil.
        //
        // Yiginda {baslik, cihaz adi} dikey bir kutu oluyor ve dugme O
        // KUTUNUN ortasina hizalaniyordu; kutunun ortasi baslik satirinin
        // ortasindan asagida kaldigi icin ucu (trafik isiklari, daraltma
        // dugmesi, "Devices" yazisi) hicbir zaman ayni hizaya gelmiyordu.
        // Burada dugme dogrudan BASLIK SATIRINA hizalaniyor.
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        deviceLabel.translatesAutoresizingMaskIntoConstraints = false
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(collapseButton)
        header.addSubview(titleLabel)
        header.addSubview(deviceLabel)
        // Dugme, YAZININ govdesine hizalaniyor — etiket kutusuna degil.
        // Kutu alt kesme (descender) payini da tasidigi icin merkezi
        // harflerin merkezinden asagida kaliyor; goz harflere bakiyor.
        NSLayoutConstraint.activate([
            collapseButton.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            collapseButton.centerYAnchor.constraint(
                equalTo: titleLabel.firstBaselineAnchor,
                constant: -(titleLabel.font?.capHeight ?? 13) / 2),
            titleLabel.leadingAnchor.constraint(equalTo: collapseButton.trailingAnchor, constant: 6),
            titleLabel.topAnchor.constraint(equalTo: header.topAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor),
            deviceLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            deviceLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            deviceLabel.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            deviceLabel.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor),
        ])

        contentBox.translatesAutoresizingMaskIntoConstraints = false

        // Ayarlar dislisi: pencerenin sag alt kosesinde, icerik
        // kutusuyla AYNI ic bosluklarda — kenara yapisik durmasin.
        settingsButton.setSymbol("gearshape")
        settingsButton.collapsed = true
        settingsButton.toolTip = L("Ayarlar", "Settings")
        settingsButton.setAccessibilityLabel(L("Ayarlar", "Settings"))
        settingsButton.target = self
        settingsButton.action = #selector(showSettings)
        settingsButton.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(barContainer)
        root.addSubview(header)
        root.addSubview(contentBox)
        root.addSubview(settingsButton)
        self.header = header
        self.root = root

        w.contentView = root
        applyLayout()

        // Odak degisiminde takili hover'lari temizle.
        for name in [NSWindow.didResignKeyNotification, NSWindow.didBecomeKeyNotification,
                     NSApplication.didResignActiveNotification,
                     NSApplication.didBecomeActiveNotification] {
            NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.clearAllHover()
            }
        }
    }

    private func clearAllHover() {
        for (_, b) in buttons { b.clearHover() }
        collapseButton.clearHover()
    }

    private var header: NSView!
    /// Baslik satirinin dikey merkezi — trafik isiklarindan OLCULEREK ayarlanir.
    private var titleCenterC: NSLayoutConstraint?
    private var root: NSView!
    private var layoutConstraints: [NSLayoutConstraint] = []

    /// Yerlesimi (yan sutun / ust bar) yeniden kurar.
    private func applyLayout() {
        NSLayoutConstraint.deactivate(layoutConstraints)
        layoutConstraints.removeAll()

        barStack.orientation = horizontalBar ? .horizontal : .vertical
        // Daraltilinca dugmeler ORTALANIR; genisken sola hizali.
        barStack.alignment = horizontalBar ? .centerY
            : (sidebarCollapsed ? .centerX : .leading)
        for (_, b) in buttons { b.collapsed = horizontalBar || sidebarCollapsed }

        var c: [NSLayoutConstraint] = []
        // TEMEL CIZGIYE bagliyoruz: etiketin kendi ic bosluklari degisse de
        // harflerin dikey ortasi hep ayni yerde kalir. `centerYAnchor`
        // kullanildiginda yazi olculerek 1,5 px asagida kaliyordu.
        let capHalf = (titleLabel.font?.capHeight ?? 13) / 2
        let titleCenter = titleLabel.firstBaselineAnchor.constraint(
            equalTo: root.topAnchor, constant: (titleCenterC?.constant ?? 30) + capHalf)
        titleCenterC = titleCenter
        if horizontalBar {
            // Kategoriler USTTE, icerik altta: yatay goruntude dikey alani israf etmez.
            c += [
                barContainer.topAnchor.constraint(equalTo: root.topAnchor),
                barContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                barContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                barContainer.heightAnchor.constraint(equalToConstant: 64),

                barStack.leadingAnchor.constraint(equalTo: barContainer.leadingAnchor, constant: 88),
                barStack.centerYAnchor.constraint(equalTo: barContainer.centerYAnchor, constant: 8),


                header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
                header.centerYAnchor.constraint(equalTo: barStack.centerYAnchor),

                contentBox.topAnchor.constraint(equalTo: barContainer.bottomAnchor),
                contentBox.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                contentBox.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                contentBox.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ]
        } else {
            c += [
                barContainer.topAnchor.constraint(equalTo: root.topAnchor,
                                                  constant: sidebarInset),
                barContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor,
                                                      constant: sidebarInset),
                barContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor,
                                                     constant: -sidebarInset),
                barWidthC!,

                barStack.topAnchor.constraint(equalTo: barContainer.topAnchor, constant: 40),
                dock.leadingAnchor.constraint(equalTo: barContainer.leadingAnchor),
                dock.trailingAnchor.constraint(equalTo: barContainer.trailingAnchor),
                dock.bottomAnchor.constraint(equalTo: barContainer.bottomAnchor),
                barStack.leadingAnchor.constraint(equalTo: barContainer.leadingAnchor, constant: 14),
                barStack.trailingAnchor.constraint(equalTo: barContainer.trailingAnchor, constant: -14),

                header.leadingAnchor.constraint(equalTo: barContainer.trailingAnchor, constant: 22),
                header.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -22),
                // BASLIK SATIRININ merkezi trafik isiklarinin merkeziyle ayni.
                // Sabit sayi degil: gercek dugme cercevesi olculup
                // `layoutTitlebarChrome()` icinde bu sabit guncelleniyor.
                titleCenter,

                contentBox.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
                contentBox.leadingAnchor.constraint(equalTo: barContainer.trailingAnchor, constant: 22),
                contentBox.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
                contentBox.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),

                settingsButton.trailingAnchor.constraint(equalTo: root.trailingAnchor,
                                                         constant: -22),
                settingsButton.bottomAnchor.constraint(equalTo: root.bottomAnchor,
                                                       constant: -18),
            ]
        }
        layoutConstraints = c
        NSLayoutConstraint.activate(c)
        header.isHidden = horizontalBar && current == .mirroring ? false : header.isHidden
    }

    /// Mini oynaticiyi motorun durumuyla tazeler.
    func refreshDock() {
        // "Oynatici" ayari kapaliysa serit hic gorunmesin.
        guard UserDefaults.standard.object(forKey: "mbPlayer") as? Bool ?? true else {
            dock.hidePlayer(); return
        }
        let e = NowPlaying.shared
        dock.updatePlayer(title: e.title,
                          subtitle: e.subtitle,
                          artwork: e.artwork,
                          playing: e.isPlaying,
                          progressValue: e.duration > 0 ? e.currentTime / e.duration : 0,
                          canStop: e.kind == .video)
        dock.setCollapsed(sidebarCollapsed)
        // Muzik paneli aciksa onun seridini de tazele
        (panels[.music] as? MusicPanel)?.refreshPlayer()
    }

    /// Trafik isiklarini kenar cubugu KARTININ icine tasir.
    ///
    /// Kart pencereden icerlek oldugu icin sistemin koydugu yer kartin
    /// disina denk geliyordu. Isiklari elle tasiyoruz; AppKit her yeniden
    /// duzenlemede kendi yerine geri koydugu icin bu HER `layout()`
    /// turunda tekrar uygulaniyor — tek seferlik ayar tutmuyor.
    ///
    /// Gruptaki bagil aralik korunuyor: yalniz tumunu birlikte oteliyoruz,
    /// boylece dugmeler arasi mesafe sistemin verdigi gibi kaliyor.
    private func layoutTitlebarChrome() {
        guard let w = window, let root = w.contentView else { return }
        let lights = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { w.standardWindowButton($0) }
        guard let first = lights.first, let holder = first.superview else { return }

        var box = first.frame
        for b in lights.dropFirst() { box = box.union(b.frame) }

        if Self.tahoe {
            // Kartin sol-ust kosesinden 12 px ic bosluk.
            let pad: CGFloat = 12
            let targetInRoot = NSPoint(x: sidebarInset + pad,
                                       y: root.bounds.height - sidebarInset - pad - box.height)
            let target = holder.convert(targetInRoot, from: root)
            let dx = target.x - box.minX, dy = target.y - box.minY
            if abs(dx) > 0.5 || abs(dy) > 0.5 {
                for b in lights {
                    b.setFrameOrigin(NSPoint(x: b.frame.minX + dx, y: b.frame.minY + dy))
                }
                box = box.offsetBy(dx: dx, dy: dy)
            }
        }

        // Baslik satirini isiklarin GERCEK merkezine hizala. Sabit sayi
        // yazmak macOS surumleri arasinda tutmuyor; olcu her duzende
        // yeniden aliniyor.
        // `box` dugmelerin kendi ust gorunumunun koordinatinda; koke cevir.
        let boxInRoot = holder.convert(box, to: root)
        let centerFromTop = root.bounds.height - boxInRoot.midY
        let capHalf = (titleLabel.font?.capHeight ?? 13) / 2
        if let c = titleCenterC, abs(c.constant - (centerFromTop + capHalf)) > 0.5,
           !horizontalBar {
            c.constant = centerFromTop + capHalf
        }

        // Dugmenin KENDI olculeri (40x32) kullaniliyor: daha kucuk bir
        // cerceve verince ic yerlesimi tasip ikon kayiyordu.
    }

    /// Ayarlar: acilir panel olarak, dislinin uzerinden.
    @objc private func showSettings() {
        if settingsHost.isShown { settingsHost.performClose(nil); return }
        let p = SettingsPanel.shared
        p.onClose = { [weak self] in self?.settingsHost.performClose(nil) }
        p.onOpenDevices = { [weak self] in
            self?.settingsHost.performClose(nil)
            self?.select(.device)
        }
        settingsHost.behavior = .transient
        settingsHost.contentViewController = p
        settingsHost.contentSize = p.view.fittingSize
        settingsHost.show(relativeTo: settingsButton.bounds, of: settingsButton,
                          preferredEdge: .minY)
    }

    @objc private func toggleCollapse() {
        sidebarCollapsed.toggle()
        UserDefaults.standard.set(sidebarCollapsed, forKey: "sidebarCollapsed")
        collapseButton.setSymbol(sidebarCollapsed ? "sidebar.trailing" : "sidebar.leading")
        // Dugme baslik cubugunda tek basina duruyor: ikon her zaman ORTALI.
        // "collapsed" bayragi kenar cubugu yigini icin sola yaslama/ortalama
        // ayirt ediyordu; burada yigin yok, hep ortali kalmali — yoksa ikon
        // dugmenin icinde kayik duruyor.
        collapseButton.collapsed = true

        for (_, b) in buttons { b.collapsed = horizontalBar || sidebarCollapsed }
        barStack.alignment = sidebarCollapsed ? .centerX : .leading
        dock.setCollapsed(sidebarCollapsed)
        refreshDock()       // serit icerigi kaybolmasin
        // Genisligi ANIMASYONLA degistir: aninda ziplamasin.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            barWidthC?.animator().constant = sidebarCollapsed ? 86 : 196
            root.layoutSubtreeIfNeeded()
        }
    }

    /// Aynalama boyutuna gore yerlesimi secer.
    func updateLayoutForStream(width: Int, height: Int) {
        let wide = width > height
        let want = (current == .mirroring) && wide
        guard want != horizontalBar else { return }
        horizontalBar = want
        applyLayout()
    }

    // MARK: - Kategori secimi

    @objc private func pick(_ sender: CategoryButton) {
        select(sender.category)
    }

    /// Aramalar panelinden mesaj yazilmak istendiginde Mesajlar'a gecer.
    private func observeConversationJump() {
        NotificationCenter.default.addObserver(
            forName: .androsOpenConversation, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.current != .messages else { return }
            self.select(.messages)
        }
    }

    /// Menuden (⌃⌘S) cagrilir.
    func toggleSidebar() { toggleCollapse() }

    func select(_ c: Category) {
        // Eski panele haber ver: muzik/video calmaya devam etmesin.
        (panels[current] as? AndrOSPanel)?.willDisappear()
        current = c
        for (k, b) in buttons { b.isSelected = (k == c) }
        titleLabel.stringValue = c.title

        // Aynalama disina cikildiginda yan sutuna geri don
        if c != .mirroring, horizontalBar {
            horizontalBar = false
            applyLayout()
        }

        let vc = panel(for: c)
        contentBox.subviews.forEach { $0.removeFromSuperview() }
        // Panel kok view'ini ContentContainerView her duzenlemede kendi
        // sinirlarina oturtuyor.
        //
        // Neden Auto Layout degil: kisitlarla baglandiginda panel icindeki
        // bir cakisma cozulurken "ustten baglama" kisitim kirilabiliyordu ve
        // panel icerigine gore kuculup alta yapisiyordu (galeride arac cubugu
        // y=716'ya dusmustu). Autoresizing mask de yetmedi, cunku select()
        // aninda contentBox.bounds henuz sifirdi ve olcekleme yanlis basliyordu.
        vc.view.translatesAutoresizingMaskIntoConstraints = true
        contentBox.addSubview(vc.view)
        contentBox.needsLayout = true
        (vc as? AndrOSPanel)?.didAppear()
    }

    private func panel(for c: Category) -> NSViewController {
        if let p = panels[c] { return p }
        let vc: NSViewController
        switch c {
        case .mirroring:
            let p = MirroringPanel()
            p.onStart = { [weak self] d in self?.onStartMirroring?(d) }
            p.onStop = { [weak self] in self?.onStopMirroring?() }
            p.onSetting = { [weak self] k, v in self?.onMirrorSetting?(k, v) }
            vc = p
        case .messages:  vc = MessagesPanel()
        case .contacts:  vc = ContactsPanel()
        case .files:     vc = FilesPanel()
        case .gallery:   vc = GalleryPanel()
        case .calls:     vc = CallsPanel()
        case .emulator:  vc = EmulatorPanel()
        case .notifications: vc = NotificationsPanel()
        case .device:
            let p = DevicePanel()
            p.onSelectDevice = { [weak self] serial, cid in
                self?.onSelectDevice?(serial, cid)
            }
            vc = p
        case .apps:      vc = AppsPanel()
        case .music:     vc = MusicPanel()
        }
        (vc as? AndrOSPanel)?.data = data
        panels[c] = vc
        return vc
    }

    // MARK: - Cihaz

    /// Son cihaz imzasi: ayni cihaz icin paneli YENIDEN YUKLEMIYORUZ.
    /// Eskiden 3 saniyede bir didAppear() cagriliyor, tablolar reload olup
    /// kullanicinin SECIMI kayboluyordu.
    private var deviceSignature = ""

    /// AYNI cihaz icin bir kez gorulen yetenek BIR DAHA KAPANMAZ.
    ///
    /// Olculen sorun: yetenekler her 3 saniyede adb ile yeniden
    /// yoklaniyor; adb baska bir is yaparken (muzik listesi, kucuk resim)
    /// yoklama zaman asimina ugrayip `false` donuyordu. Kategoriler bir
    /// anligina griye donup geri geliyordu — "muzigi actim, Aramalar
    /// kayboldu" tam olarak buydu. Cihaz degisince sifirlaniyor.
    private var stickyCaps = AndroidData.Capabilities()
    private var stickySerial = ""

    func setDevice(_ d: AndroidData?, label: String, caps: AndroidData.Capabilities) {
        let sig = (d?.adb.serial ?? "yok") + "|" + label
        let changed = sig != deviceSignature
        deviceSignature = sig
        self.data = d

        let serial = d?.adb.serial ?? "yok"
        if serial != stickySerial { stickySerial = serial; stickyCaps = AndroidData.Capabilities() }
        var caps = caps
        stickyCaps.sms      = stickyCaps.sms      || caps.sms
        stickyCaps.contacts = stickyCaps.contacts || caps.contacts
        stickyCaps.callLog  = stickyCaps.callLog  || caps.callLog
        stickyCaps.media    = stickyCaps.media    || caps.media
        stickyCaps.files    = stickyCaps.files    || caps.files
        caps = stickyCaps
        self.caps = caps
        // Cihaza bagli veriler (calma listeleri) bu cihaza gecsin.
        //
        // Anahtar once UYGULAMA KIMLIGI: yalniz uygulamayla bagli
        // telefonun adb seri numarasi yok, hepsi "default" altinda
        // birikirdi. Kimlik ayni telefon icin USB/Wi-Fi farketmeksizin
        // sabit — listeler kablo takilip cikarilinca kaybolmuyor.
        let companionKey = UserDefaults.standard.string(forKey: "activeCompanion") ?? ""
        PlaylistStore.deviceKey = !companionKey.isEmpty ? companionKey
            : (d?.adb.serial ?? "default")
        deviceLabel.stringValue = label
        for (_, p) in panels { (p as? AndrOSPanel)?.data = d }
        // Cihaz YOKSA veri gerektiren hicbir kategori acik olmamali.
        // Pano ve Ekran Yansitma da cihaza bagli — eskiden `default`
        // dalina dusup cihaz olmadan da tiklanabiliyorlardi.
        let hasDevice = d != nil
        for (c, b) in buttons {
            switch c {
            case .device, .emulator: b.isAvailable = true
            case .messages:  b.isAvailable = hasDevice && caps.sms
            case .contacts:  b.isAvailable = hasDevice && caps.contacts
            case .gallery:   b.isAvailable = hasDevice && caps.media
            case .files:     b.isAvailable = hasDevice && caps.files
            case .calls:     b.isAvailable = hasDevice && caps.callLog
            case .apps:      b.isAvailable = hasDevice && caps.files
            case .music:     b.isAvailable = hasDevice && caps.media
            case .mirroring: b.isAvailable = hasDevice
            case .notifications: b.isAvailable = hasDevice
            }
        }
        // Acik olan kategori kapandiysa Cihazlar'a don: bos beyaz ekranda
        // kalmak yerine kullaniciyi yapacak bir sey olan yere goturuyoruz.
        if !hasDevice, current != .device, current != .emulator { select(.device) }
        // Yalniz cihaz GERCEKTEN degistiyse paneli tazele.
        if changed { (panels[current] as? AndrOSPanel)?.didAppear() }
    }

    /// Yansitma durumunu panele bildirir (goruntu ayri pencerede).
    func setMirroring(_ on: Bool) {
        (panel(for: .mirroring) as? MirroringPanel)?.setMirroring(on)
    }

    func setDevices(_ list: [HubDevice], mirroring: Bool) {
        (panel(for: .mirroring) as? MirroringPanel)?.update(list, mirroring: mirroring)
    }
}

/// Tek alt view'ini HER duzenlemede kendi sinirlarina oturtan kapsayici.
/// Panel gecislerinde yerlesim belirsizligini tamamen ortadan kaldiriyor.
final class ContentContainerView: NSView {
    override func layout() {
        super.layout()
        for v in subviews {
            if v.frame != bounds { v.frame = bounds }
        }
        Log.write("contentBox.layout bounds=\(Int(bounds.width))x\(Int(bounds.height)) alt=\(subviews.count) altFrame=\(subviews.first.map { "\(Int($0.frame.width))x\(Int($0.frame.height))@\(Int($0.frame.minY))" } ?? "-")")
    }
}

/// Kategori dugmeleriyle AYNI ic bosluk ve hizaya sahip ikon dugmesi.
/// Daraltma dugmesi bagimsiz ortalandigi icin simetrisiz duruyordu.
final class IconRowButton: NSButton {
    var collapsed = false {
        didSet {
            row.edgeInsets = collapsed
                ? NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
                : NSEdgeInsets(top: 0, left: 11, bottom: 0, right: 10)
            leadingC?.isActive = !collapsed
            centerC?.isActive = collapsed
        }
    }
    private let iconView = NSImageView()
    private let row = NSStackView()
    private var leadingC: NSLayoutConstraint?
    private var centerC: NSLayoutConstraint?
    private var hovering = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        bezelStyle = .regularSquare
        title = ""
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        iconView.contentTintColor = .secondaryLabelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 18).isActive = true
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 9
        row.edgeInsets = NSEdgeInsets(top: 0, left: 11, bottom: 0, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(iconView)
        addSubview(row)
        leadingC = row.leadingAnchor.constraint(equalTo: leadingAnchor)
        centerC = row.centerXAnchor.constraint(equalTo: centerXAnchor)
        leadingC?.isActive = true
        row.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        // Kategoriler kadar genis DEGIL: yalnizca ikon kadar tiklanabilir alan.
        widthAnchor.constraint(equalToConstant: 40).isActive = true
        heightAnchor.constraint(equalToConstant: 32).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func setSymbol(_ n: String) {
        iconView.image = NSImage(systemSymbolName: n, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        // .activeAlways: pencere key degilken de olay alalim. Yalniz
        // .activeInKeyWindow ile Cmd+Tab sonrasi mouseExited gelmiyordu ve
        // dugmeler "hover olmus gibi" gri takili kaliyordu.
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self))
    }
    override func mouseEntered(with e: NSEvent) { hovering = true; refresh() }
    override func mouseExited(with e: NSEvent)  { hovering = false; refresh() }
    /// Disaridan cagrilir (pencere odagi degisince).
    func clearHover() { hovering = false; refresh() }
    private func refresh() {
        layer?.cornerRadius = 9
        if #available(macOS 10.15, *) { layer?.cornerCurve = .continuous }
        layer?.backgroundColor = hovering
            ? NSColor.labelColor.withAlphaComponent(0.08).cgColor : NSColor.clear.cgColor
    }
}

/// Kategori dugmesi.
///
/// NSButton'in kendi image+title yerlesimi kullanilmiyor: vurgu (mavi zemin)
/// acikken ikon sol kenara yapisik duruyordu ve NSButton'da ic bosluk
/// verilemiyordu. Bunun yerine dugme kendi zeminini ciziyor, icerigi ise
/// ic bosluklu bir yigin tasiyor.
final class CategoryButton: NSButton {
    let category: MainWindowController.Category
    var isSelected = false { didSet { refresh() } }
    var isAvailable = true { didSet { refresh() } }
    /// Daraltilmis panel: yalniz ikon.
    var collapsed = false {
        didSet {
            label.isHidden = collapsed
            widthC?.constant = collapsed ? 40 : 176
            // Daraltilinca ikon zeminde ORTALANIR. Eskiden sola dayali
            // kaliyordu ve vurgu acikken kotu duruyordu.
            row.edgeInsets = collapsed
                ? NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
                : NSEdgeInsets(top: 0, left: 11, bottom: 0, right: 10)
            row.alignment = .centerY
            leadingC?.isActive = !collapsed
            centerC?.isActive = collapsed
            toolTip = collapsed ? category.title : nil
        }
    }

    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let row = NSStackView()
    private var widthC: NSLayoutConstraint?
    private var leadingC: NSLayoutConstraint?
    private var centerC: NSLayoutConstraint?
    private var hovering = false

    init(category: MainWindowController.Category) {
        self.category = category
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        title = ""
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        iconView.image = NSImage(systemSymbolName: category.symbol,
                                 accessibilityDescription: category.title)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 18).isActive = true

        label.stringValue = category.title
        label.font = .systemFont(ofSize: 13)

        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 9
        // SOL IC BOSLUK: mavi zemin acikken ikon kenara yapismasin.
        row.edgeInsets = NSEdgeInsets(top: 0, left: 11, bottom: 0, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(iconView)
        row.addArrangedSubview(label)
        addSubview(row)
        leadingC = row.leadingAnchor.constraint(equalTo: leadingAnchor)
        centerC = row.centerXAnchor.constraint(equalTo: centerXAnchor)
        leadingC?.isActive = true
        NSLayoutConstraint.activate([
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        widthC = widthAnchor.constraint(equalToConstant: 176)
        widthC?.isActive = true
        heightAnchor.constraint(equalToConstant: 32).isActive = true
        // Baslik bos oldugu icin (etiket ayri bir alt view) erisilebilirlik
        // adini elle veriyoruz: VoiceOver ve otomasyon dugmeyi bulabilsin.
        setAccessibilityLabel(category.title)
        setAccessibilityTitle(category.title)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        // .activeAlways: pencere key degilken de olay alalim. Yalniz
        // .activeInKeyWindow ile Cmd+Tab sonrasi mouseExited gelmiyordu ve
        // dugmeler "hover olmus gibi" gri takili kaliyordu.
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self))
    }
    override func mouseEntered(with e: NSEvent) { hovering = true; refresh() }
    override func mouseExited(with e: NSEvent)  { hovering = false; refresh() }
    /// Pencere odagi degisince cagrilir: takili kalan hover temizlenir.
    func clearHover() { hovering = false; refresh() }

    private func refresh() {
        layer?.cornerRadius = 9
        if #available(macOS 10.15, *) { layer?.cornerCurve = .continuous }
        let bg: NSColor
        if isSelected    { bg = .controlAccentColor.withAlphaComponent(0.92) }
        else if hovering { bg = NSColor.labelColor.withAlphaComponent(0.08) }
        else             { bg = .clear }
        layer?.backgroundColor = bg.cgColor

        let fg: NSColor = isSelected ? .white
            : (isAvailable ? .labelColor : .tertiaryLabelColor)
        iconView.contentTintColor = fg
        label.textColor = fg
        label.font = .systemFont(ofSize: 13, weight: isSelected ? .semibold : .regular)
    }
}

/// Duzen turunda geri cagri veren kok gorunum.
///
/// Trafik isiklarinin konumu SISTEMDEN geliyor ve macOS 26'da degisti;
/// sabit sayi yazmak yerine her duzende gercek cerceveyi okuyup daraltma
/// dugmesini ona gore koyuyoruz.
final class RootView: NSView {
    var onLayout: (() -> Void)?
    override func layout() {
        super.layout()
        onLayout?()
    }
}
