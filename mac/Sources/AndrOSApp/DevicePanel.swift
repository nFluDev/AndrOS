import AppKit
import CoreImage
import AndrOSCore

/// Cihazlar: solda kayitli cihaz listesi, sagda secili cihazin ozeti.
///
/// Liste `adb devices`'in otesine geciyor — cihazlar KALICI olarak
/// kaydediliyor, boylece kablo cikinca listeden dusmuyor, "çevrimdışı"
/// gorunuyor. Wi-Fi uzerinden cihaz eklenebiliyor; mobil uygulama
/// gelince eslestirme de buradan yurutulecek.
final class DevicePanel: NSViewController, AndrOSPanel,
                         NSTableViewDataSource, NSTableViewDelegate {
    private var refreshObserverInstalled = false
    var data: AndroidData? { didSet { reload() } }

    /// Kullanici baska bir cihaza gecince ana uygulamaya haber verir.
    /// Cihaz secildi: adb seri numarasi (varsa) VE uygulama kimligi.
    ///
    /// Ikisi birden gerekiyor: yalniz uygulamayla bagli bir telefonun
    /// adb seri numarasi yok, once boyle bir cihaz HIC secilemiyordu.
    var onSelectDevice: ((_ serial: String?, _ companionId: String?) -> Void)?

    private var known: [UnifiedDevice] = []
    private var shown: [UnifiedDevice] = []
    private let idCache = AndroidIDCache()
    private var selectedID: String?
    /// Su an YERINDE yeniden adlandirilan cihaz.
    private var renamingID: String?
    /// Sag sutun ne gosteriyor.
    private enum Mode { case details, pair, companion }
    private var mode: Mode = .details
    private let pairAddress = NSTextField()
    private let pairPairAddr = NSTextField()
    private let pairCode = NSTextField()

    private let table = FittedTableView()
    private let searchBox = SearchToggle()
    private let grid = NSStackView()
    private let spinner = NSProgressIndicator()
    private let detailTitle = NSTextField(labelWithString: "")
    private let detailSub = NSTextField(labelWithString: "")
    private var timer: Timer?
    private var wirelessButton: NSButton?
    private let advancedToggle = NSButton()
    private var advancedOpen = false
    private var stateObserverInstalled = false
    private let audioToggle = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let cameraToggle = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let pairButton = NSButton()
    private lazy var empty = EmptyStateView(frame: .zero)
    /// AndrOS uygulamasi calisan telefonlari agda OTOMATIK arar.
    /// ORTAK bulucu: panel kendi ornegini kurmuyor (bkz. CompanionBrowser.shared).
    private let browser = CompanionBrowser.shared
    private let companionStore = CompanionStore()
    private var companions: [CompanionDevice] = []
    private var link: CompanionLink?
    private let codeField = NSTextField()
    private var pendingQRCode: String?
    private let countdown = CountdownBar()
    /// Su an eslestirme yapilan cihaz — yeniden girisi engellemek icin.
    private var pairingDeviceId: String?
    private var lastRenderedState: CompanionLink.State?
    private var lastPairSignature = ""
    /// Programla secim kurarken delegeyi susturur.
    private var suppressSelection = false
    private let transportPrefs = TransportPrefs()
    private var qrTimer: Timer?
    private var listScroll: NSScrollView?

    // MARK: - Kurulum

    override func loadView() {
        let root = NSView()

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        // ---- Sol sutun: cihaz listesi
        let listHead = NSTextField(labelWithString: L("Cihazlar", "Devices"))
        listHead.font = .systemFont(ofSize: 13, weight: .semibold)

        // Yeniden adlandirma ve silme HER SATIRIN kendi dugmelerinde;
        // ust cubukta yalniz ekleme ve arama var. Boylece hangi cihaza
        // uygulandigi belirsiz kalmiyor.
        let addButton = iconButton("plus", L("Cihaz ekle (Wi-Fi)", "Add device (Wi-Fi)"),
                                   #selector(addDevice))
        searchBox.placeholder = L("Cihaz ara", "Search devices")
        searchBox.openWidth = 150
        searchBox.onChange = { [weak self] _ in self?.applyFilter() }

        let listBar = NSStackView(views: [listHead, addButton, flexSpacer(), searchBox])
        listBar.orientation = .horizontal
        // Arama kutusu acilinca yuksekligi degisiyor; hizalama ve sabit
        // yukseklik olmadan baslik birkac piksel yukari kayiyordu.
        listBar.alignment = .centerY
        listBar.spacing = 6
        listBar.translatesAutoresizingMaskIntoConstraints = false
        listBar.heightAnchor.constraint(equalToConstant: 28).isActive = true
        listHead.setContentCompressionResistancePriority(.required, for: .horizontal)

        let col = NSTableColumn(identifier: .init("d"))
        col.width = 230
        // Tablo, kaydirma alaninin GORUNUR genisligini izlesin. Bunu
        // yapmazsa kendi dar dogal genisliginde kaliyor ve satirin arka
        // plani ile saga yaslanan dugmeler sutunu doldurmuyordu; elle
        // cerceve vermek ise tersine tasmaya yol aciyordu.
        table.addTableColumn(col)
        table.translatesAutoresizingMaskIntoConstraints = true
        table.autoresizingMask = [.width]
        // Sutun genisligini ELLE gorunur alana esitliyoruz (asagida
        // matchTableWidth). Otomatik sutun boyutlandirma ile birlikte
        // kullanilinca tablo gorunur alandan 2 px genis kaliyor ve
        // saga yaslanan dugme kirpiliyordu.
        // KRITIK: macOS 11+ varsayilani (.automatic -> .inset) tabloya her
        // yandan 16 px ic bosluk ekliyor. Olculdu: gorunur alan 236 iken
        // tablo 262, sutun 230 — bu yuzden saga yaslanan cop kutusu
        // dugmesi gorunur alanin disina tasip kirpiliyordu.
        table.style = .fullWidth
        table.headerView = nil
        table.rowHeight = 54
        table.dataSource = self
        table.delegate = self
        table.doubleAction = #selector(rowDoubleClicked)
        table.target = self
        // ".regular" birakiyoruz: ".none" secildiginde AppKit
        // `drawSelection(in:)`'i HIC cagirmiyor, bu yuzden tiklayinca
        // arka plan degismiyordu. Sistem cizimini DeviceRowView'da
        // tamamen kendi yuvarlak vurgumuzla degistiriyoruz.
        table.selectionHighlightStyle = .regular
        table.intercellSpacing = NSSize(width: 0, height: 4)
        table.backgroundColor = .clear
        let listScroll = scrollWrap(table)
        self.listScroll = listScroll

        // Liste kendi KARTININ uzerinde duruyor: sag taraftaki bilgi
        // satirlariyla ayni dili konussun diye ayni soluk zemin ve
        // yuvarlak kose. Duz beyaz uzerinde liste "havada" duruyordu.
        let listCard = NSView()
        listCard.wantsLayer = true
        listCard.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.04).cgColor
        listCard.layer?.cornerRadius = 12
        if #available(macOS 10.15, *) { listCard.layer?.cornerCurve = .continuous }
        listCard.translatesAutoresizingMaskIntoConstraints = false
        listCard.addSubview(listScroll)
        NSLayoutConstraint.activate([
            listScroll.topAnchor.constraint(equalTo: listCard.topAnchor, constant: 6),
            listScroll.leadingAnchor.constraint(equalTo: listCard.leadingAnchor, constant: 4),
            listScroll.trailingAnchor.constraint(equalTo: listCard.trailingAnchor, constant: -4),
            listScroll.bottomAnchor.constraint(equalTo: listCard.bottomAnchor, constant: -6),
        ])

        listScroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: listScroll.contentView, queue: .main) { [weak self] _ in
            self?.matchTableWidth()
        }
        // NSTableView kendi DOGAL genisliginde kaliyor; kaydirma alani onu
        // buyutmuyor. Bu yuzden satirin arka plani (secim/hover vurgusu) ve
        // saga yaslanan dugmeler sutunun tamamini kullanmiyordu. Gorunur
        // alan degistikce tabloyu ve sutunu elle esitliyoruz.


        // ---- Sag sutun: ozet
        detailTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        detailSub.font = .systemFont(ofSize: 11)
        detailSub.textColor = .secondaryLabelColor

        let refresh = textButton(L("Yenile", "Refresh"), #selector(reload))
        let screenshot = textButton(L("Ekran görüntüsü al", "Take Screenshot"), #selector(screenshot))
        let reboot = textButton(L("Yeniden başlat", "Restart"), #selector(reboot))

        // Eslestir dugmesi ARAC CUBUGUNDA da var: sag sutundaki serit
        // kaydirma alaninin icinde oldugu icin erisilebilirlik agacindan
        // gorunmuyor (VoiceOver de goremiyor). Burada her zaman ulasilabilir.
        pairButton.title = L("Eşleştir", "Pair")
        pairButton.bezelStyle = .rounded
        pairButton.target = self
        pairButton.action = #selector(pairSelected)
        pairButton.isHidden = true
        pairButton.setAccessibilityLabel(L("Eşleştir", "Pair"))

        // Telefonu Mac'in ses aygiti yap: kulakligi TELEFONA takip Mac'in
        // sesini oradan dinlemek, ayni anda telefonun mikrofonunu Mac'te
        // kullanmak. Ses paneline iki cihaz olarak dusuyor.
        audioToggle.title = L("Mac'in ses aygıtı", "Use as Mac audio device")
        audioToggle.target = self
        audioToggle.action = #selector(toggleAudioBridge)
        audioToggle.state = UserDefaults.standard.bool(forKey: "audioBridgeOn") ? .on : .off
        audioToggle.toolTip = L(
            "Mac'in sesi telefondan çıkar, telefonun mikrofonu Mac'te görünür.",
            "Mac audio plays on the phone and the phone's mic appears on the Mac.")

        // Telefonu Mac'e webcam yap. Acikken menu cubugunda canli kucuk
        // onizleme duruyor — kamera akiyorken bu her zaman gorunur olmali.
        cameraToggle.title = L("Kamera", "Camera")
        cameraToggle.target = self
        cameraToggle.action = #selector(toggleCamera)
        cameraToggle.state = UserDefaults.standard.bool(forKey: "cameraOn") ? .on : .off
        cameraToggle.toolTip = L(
            "Telefonun kamerasını Mac'e getirir; menü çubuğunda canlı önizleme çıkar.",
            "Brings the phone camera to the Mac; a live preview appears in the menu bar.")

        // Efektler MENU CUBUGUNDA (kamera acikken oraya bakiliyor).
        // SES ve KAMERA anahtarlari MENU CUBUGUNDA (StatusPanel):
        // burada bulunmasi zordu ve dar pencerede sigmiyordu.
        // "Kablosuz baglan" KALDIRILDI: uygulama zaten kendi TLS
        // baglantisiyla Wi-Fi uzerinden calisiyor; adb'yi tcpip kipine
        // almanin bir faydasi kalmadi.
        let reconnect = textButton(L("Yeniden bağlan", "Reconnect"), #selector(reconnectNow))
        reconnect.toolTip = L("Bağlantı koptuysa yeniden kurar — uygulamayı kapatıp "
                            + "açmaya gerek yok.",
                              "Re-establishes a dropped connection — no need to restart "
                            + "the app.")

        let actions = NSStackView(views: [refresh, screenshot, reboot, reconnect,
                                          pairButton, NSView(), spinner])
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.translatesAutoresizingMaskIntoConstraints = false

        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 10
        grid.translatesAutoresizingMaskIntoConstraints = false
        let gridScroll = scrollWrap(grid)

        let head = NSStackView(views: [detailTitle, detailSub])
        head.orientation = .vertical
        head.alignment = .leading
        head.spacing = 1
        head.translatesAutoresizingMaskIntoConstraints = false

        empty.translatesAutoresizingMaskIntoConstraints = false
        for v in [listBar, listCard, actions, head, gridScroll, empty] as [NSView] {
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            listBar.topAnchor.constraint(equalTo: root.topAnchor),
            listBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            listBar.widthAnchor.constraint(equalToConstant: 236),

            listCard.topAnchor.constraint(equalTo: listBar.bottomAnchor, constant: 8),
            listCard.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            listCard.widthAnchor.constraint(equalToConstant: 236),
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

            gridScroll.topAnchor.constraint(equalTo: actions.bottomAnchor, constant: 12),
            gridScroll.leadingAnchor.constraint(equalTo: listCard.trailingAnchor, constant: 18),
            gridScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            gridScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            grid.widthAnchor.constraint(equalTo: gridScroll.widthAnchor, constant: -20),
        ])
        view = root

        // BIR KEZ kaydol: `didAppear` her kategori gecisinde cagriliyor,
        // her seferinde yeni gozlemci eklenince tek bir tazeleme onlarca
        // yukleme baslatiyordu (olculdu: ayni anda birden fazla adb
        // sorgusu, panel dakikalarca bos kaliyor).
        if !refreshObserverInstalled {
            refreshObserverInstalled = true
            NotificationCenter.default.addObserver(
                forName: .androsRefresh, object: nil, queue: .main) { [weak self] _ in
                guard let self, !self.view.isHiddenOrHasHiddenAncestor else { return }
                UserBusy.run { [weak self] in
                    self?.refreshList()
                    self?.reload()
                }
            }
        }
    }

    private func matchTableWidth() {
        guard let sc = listScroll else { return }
        table.setFrameSize(NSSize(width: sc.contentView.bounds.width,
                                  height: table.frame.height))
    }

    private func iconButton(_ symbol: String, _ tip: String, _ sel: Selector) -> NSButton {
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

    private func textButton(_ title: String, _ sel: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: sel)
        b.bezelStyle = .rounded
        b.font = .systemFont(ofSize: 11)
        return b
    }

    func didAppear() {
        matchTableWidth()
        // Uygulamayi calistiran telefonlar kendiliginden listeye dussun:
        // kullanici IP yazmasin, dugmeye basmasin.
        if !stateObserverInstalled {
            stateObserverInstalled = true
            NotificationCenter.default.addObserver(
                forName: .androsCompanionStateChanged, object: nil, queue: .main) { [weak self] _ in
                guard let self, !self.view.isHiddenOrHasHiddenAncestor else { return }
                self.applyFilter()
            }
        }
        browser.addListener("devicePanel") { [weak self] list in
            self?.companions = list
            self?.refreshList()
        }
        browser.start()
        refreshList()
        reload()
        timer?.invalidate()
        let t = Timer(timeInterval: 6, repeats: true) { [weak self] _ in
            guard self?.view.window?.isVisible == true else { return }
            // Yeniden adlandirma kutusu acikken ya da satir surukleniyorken
            // tazeleme kullanicinin isini boluyordu.
            UserBusy.run { [weak self] in self?.refreshList() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func willDisappear() {
        timer?.invalidate(); timer = nil
        // Bulucu ORTAK: durdurmuyoruz, yalniz dinlemeyi birakiyoruz.
        browser.removeListener("devicePanel")
    }

    // MARK: - Liste

    /// `adb devices` ile kaydi birlestirir: bagli olanlar "çevrimiçi",
    /// gecmiste gorulup simdi olmayanlar "çevrimdışı" olarak listede kalir.
    /// adb (USB/Wi-Fi) ve uygulama uzerinden gorunen cihazlari ANDROID_ID
    /// ile eslestirip TEK listede toplar.
    private func refreshList() {
        let comps = companions
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            let adb = try? ADB()
            let found = (try? adb?.devices()) ?? []

            var byKey: [String: UnifiedDevice] = [:]
            for d in found {
                guard let path = adb?.path else { continue }
                let key = self.idCache.id(for: d.serial, adbPath: path)
                var u = byKey[key] ?? UnifiedDevice(key: key, name: d.model)
                if d.model != "?" { u.name = d.model }
                if d.transport == "tcp" { u.wifiSerial = d.serial } else { u.usbSerial = d.serial }
                byKey[key] = u
            }
            for c in comps {
                // Uygulama ANDROID_ID'yi duyuruda veriyor; vermiyorsa
                // kendi kimligiyle ayri satir olur (eski surum).
                // Uygulamanin kimligi, adb tarafinda isaret dosyasindan
                // okunan degerle AYNI olacak sekilde secildi.
                let key = c.deviceId.isEmpty ? "app:" + c.id : c.deviceId
                var u = byKey[key] ?? UnifiedDevice(key: key, name: c.name)
                if u.name.isEmpty { u.name = c.name }
                u.companionId = c.id
                u.companionPaired = self.companionStore.isPaired(c.id)
                u.companionOverUSB = c.overUSB
                byKey[key] = u
            }

            // Gecmiste gorulup simdi olmayanlar "cevrimdisi" olarak kalsin.
            var remembered = DeviceRegistry.load()
            for (k, u) in byKey {
                if let i = remembered.firstIndex(where: { $0.id == k }) {
                    remembered[i].model = u.name
                    remembered[i].lastSeen = Date()
                } else {
                    remembered.append(KnownDevice(id: k, model: u.name))
                }
            }
            DeviceRegistry.save(remembered)
            var list = byKey.values.map { u -> UnifiedDevice in
                var v = u
                v.alias = remembered.first { $0.id == u.key }?.alias ?? ""
                return v
            }
            // Hayalet kayitlari ele: eski surumlerin "app:" anahtarlari
            // ve canli bir cihazla AYNI ADI tasiyan cevrimdisi kopyalar.
            // Ikisi de ayni telefonun birden fazla satir gorunmesine
            // yol aciyordu.
            let liveNames = Set(byKey.values.map { $0.name })
            remembered.removeAll { $0.id.hasPrefix("app:") }
            remembered.removeAll { r in
                byKey[r.id] == nil && liveNames.contains(r.model) && r.alias.isEmpty
            }
            DeviceRegistry.save(remembered)
            for r in remembered where byKey[r.id] == nil {
                var v = UnifiedDevice(key: r.id, name: r.model.isEmpty ? r.id : r.model)
                v.alias = r.alias
                v.lastSeen = r.lastSeen
                list.append(v)
            }
            list.sort {
                if $0.isOnline != $1.isOnline { return $0.isOnline }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                    == .orderedAscending
            }
            DispatchQueue.main.async {
                self.known = list
                // "Cihaz" menusu ayni listeyi kullansin: birlestirme
                // mantigi TEK yerde kalsin, menu icin ikinci bir kopya
                // yazilmasin.
                NotificationCenter.default.post(name: .androsDevicesListed,
                                                object: list)
                if self.selectedID == nil || !list.contains(where: { $0.key == self.selectedID }) {
                    self.selectedID = list.first(where: { $0.isOnline })?.key ?? list.first?.key
                }
                self.applyFilter()
                let sel = self.selected
                self.wirelessButton?.isEnabled = (sel?.usbSerial != nil)
                // Uygulama SONRADAN bulunabiliyor (Bonjour taramasi liste
                // ilk cizildikten saniyeler sonra sonuc veriyor). Bu durumda
                // "Eşleştir" seridi hic gorunmuyordu; secili cihazin
                // eslestirme durumu degistiginde sag sutunu tazeliyoruz.
                self.pairButton.isHidden = !(sel?.companionId != nil
                                             && sel?.companionPaired == false)
                let sig = (sel?.companionId ?? "") + (sel?.companionPaired == true ? "1" : "0")
                if sig != self.lastPairSignature {
                    self.lastPairSignature = sig
                    if self.mode == .details { self.reload() }
                }
            }
        }
    }

    private func applyFilter() {
        let q = searchBox.text.trimmingCharacters(in: .whitespaces).lowercased()
        shown = known.filter { SearchMatch.matchesAny(q, [$0.displayName, $0.key, $0.name]) }
        table.reloadData()
        // Secim, YALNIZ etkin cihaz icin kuruluyor ve bunu vurgulu (hover
        // degil) bir bicimde ciziyoruz. Onceden liste her tazelendiginde
        // ilk satir secilip "uzerine gelinmis" gibi gri kaliyordu.
        // Secimi PROGRAMLA kurarken delege calismamali: aksi halde her
        // liste tazelemesi eslestirmeyi yeniden baslatiyor.
        suppressSelection = true
        if let i = shown.firstIndex(where: { $0.key == selectedID }) {
            table.selectRowIndexes([i], byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
        suppressSelection = false
        empty.isHidden = !shown.isEmpty
        if shown.isEmpty {
            empty.show(known.isEmpty ? L("Cihaz yok", "No devices")
                                     : L("Eşleşen cihaz yok", "No matching device"),
                       known.isEmpty
                         ? L("Telefonu USB ile bağla, ya da + ile Wi-Fi üzerinden ekle.",
                             "Attach a phone over USB, or add one over Wi-Fi with +.")
                         : L("Aramayı değiştir ya da temizle.", "Change or clear the search."),
                       symbol: "iphone.slash")
        }
    }

    func numberOfRows(in t: NSTableView) -> Int { shown.count }

    func tableView(_ t: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        DeviceRowView()
    }

    func tableView(_ t: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let d = shown[row]

        let av = AvatarView()
        av.initial = String(d.displayName.prefix(1)).uppercased()
        av.seed = d.key.hashValue
        av.translatesAutoresizingMaskIntoConstraints = false
        av.widthAnchor.constraint(equalToConstant: 30).isActive = true
        av.heightAnchor.constraint(equalToConstant: 30).isActive = true

        let name = InlineEditLabel.label(d.displayName)
        name.onCommit = { [weak self] new in
            DeviceRegistry.rename(d.key, to: new)
            self?.refreshList()
        }
        name.onEnd = { [weak self] in self?.renamingID = nil }
        if d.key == renamingID { DispatchQueue.main.async { name.beginEditing() } }

        // Tek satir, TUM yollar: "USB + Wi-Fi + AndrOS".
        let transports = d.transportLabel(appName: L("AndrOS", "AndrOS"))
        let needsPairing = d.companionId != nil && !d.companionPaired
        // CANLI durum: "eşleşmiş" olmak "bağlı" demek degil. Baglanti
        // kopukken satir hala eslesmis gorunuyor ve kullanici neden
        // calismadigini anlamiyordu.
        let linked = d.companionId.map { CompanionStatus.isConnected($0) } ?? false
        let connecting = d.companionId.map {
            CompanionStatus.state($0) == .connecting
        } ?? false
        let state: String
        if !d.isOnline {
            state = L("çevrimdışı", "offline")
        } else if needsPairing {
            state = L("eşleşme bekliyor", "not paired")
        } else if d.companionId != nil && !linked {
            state = connecting ? L("bağlanıyor…", "connecting…")
                               : L("eşleşmiş · bağlı değil", "paired · not connected")
        } else {
            state = transports
        }
        // NOKTA YOK, renk yeterli: "● USB + Wi-Fi + AndrOS" satira
        // sigmiyor ve son kelime kesiliyordu ("…+ AndrO"). Durum zaten
        // renkle anlatiliyor.
        let sub = NSTextField(labelWithString: state)
        sub.font = .systemFont(ofSize: 10)
        sub.lineBreakMode = .byTruncatingTail
        sub.textColor = needsPairing ? .systemOrange
                      : (!d.isOnline ? .tertiaryLabelColor
                         : (d.companionId != nil && !linked) ? .systemOrange
                                                             : .systemGreen)

        let texts = NSStackView(views: [name, sub])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1
        texts.setContentHuggingPriority(.init(250), for: .horizontal)


        let rename = rowButton("pencil", L("Yeniden adlandır", "Rename"),
                               #selector(renameRow(_:)), d.key)
        let remove = rowButton("trash", L("Listeden çıkar", "Remove from list"),
                               #selector(removeRow(_:)), d.key)

        // BOSLUK YOK: yer metne kalsin — yollar tam yazilsin.
        let r = NSStackView(views: [av, texts, rename, remove])
        r.orientation = .horizontal
        r.spacing = 4
        r.distribution = .fill
        r.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 10)
        return r
    }

    private func rowButton(_ symbol: String, _ tip: String,
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

    @objc private func renameRow(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        beginRename(id)
    }

    /// Yerinde duzenlemeyi baslatir — acilir pencere YOK.
    private func beginRename(_ id: String) {
        renamingID = id
        guard let i = shown.firstIndex(where: { $0.id == id }) else { return }
        table.reloadData(forRowIndexes: [i], columnIndexes: [0])
    }

    @objc private func removeRow(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        remove(id)
    }

    /// Cift tiklama: cihaz eslesmemisse ESLESTIRME acilir, aksi halde
    /// yeniden adlandirma. Once yalniz yeniden adlandirmaya bagliydi ve
    /// kullanici eslestirmeyi hicbir yerden baslatamiyordu.
    @objc private func rowDoubleClicked() {
        if let d = selected, let cid = d.companionId, !d.companionPaired {
            mode = .companion
            connectCompanion(cid)
            return
        }
        renameSelected()
    }

    @objc private func renameSelected() {
        guard let id = selectedID else { return }
        beginRename(id)
    }

    func tableViewSelectionDidChange(_ n: Notification) {
        guard !suppressSelection else { return }
        let r = table.selectedRow
        guard r >= 0, r < shown.count else { return }
        let d = shown[r]
        // Ayni satir yeniden secilse bile ESLESMEMIS cihazda eslestirmeyi
        // ac: liste tazelenirken ilk cihaz kendiliginden secili kaldigi
        // icin kullanici uzerine tiklayinca hicbir sey olmuyordu.
        let needsPairing = d.companionId != nil && !d.companionPaired
        if d.key == selectedID && !needsPairing { return }
        selectedID = d.key
        mode = .details
        wirelessButton?.isEnabled = (d.usbSerial != nil)
        // Uygulama bagli ama eslesmemisse once eslestirme ekrani.
        if let cid = d.companionId, !d.companionPaired {
            // AYRI KIP: yoksa `reload()` sag sutunu ezip eslestirme
            // kutusunu ekrandan siliyordu.
            mode = .companion
            connectCompanion(cid)
            return
        }
        // Icerik SECILEN cihaza gecsin — hangi yoldan bagli olursa olsun.
        onSelectDevice?(d.adbSerial, d.companionId)
        reload()
    }

    private var selected: UnifiedDevice? { known.first { $0.key == selectedID } }

    // MARK: - Cihaz ekle / adlandir / kaldir

    /// Cihaz ekleme SAG SUTUNDA aciliyor — acilir pencere yok.
    @objc private func addDevice() {
        mode = .pair
        table.deselectAll(nil)
        buildPairPane()
    }

    /// "+" ile acilan ekran: CIHAZ EKLEMENIN ilk adimi.
    ///
    /// Eskiden burada adb kablosuz eslestirme kodu alanlari vardi.
    /// Artik eslestirme mobil uygulamayla yapiliyor ve kod gerekmiyor;
    /// yeni bir telefon eklemenin gercek ilk adimi UYGULAMAYI KURMAK.
    /// Bu yuzden karekod dogrudan burada — ayri bir pencere acmak
    /// gereksiz bir adim.
    ///
    /// Eski adb yolu kayboldu degil, "Gelismis" altina alindi:
    /// uygulamayi kuramayan biri icin hala bir cikis yolu.
    private func buildPairPane() {
        grid.arrangedSubviews.forEach { $0.removeFromSuperview() }
        detailTitle.stringValue = L("Cihaz ekle", "Add a device")
        detailSub.stringValue = L("Telefona AndrOS'u kur; gerisi kendiliğinden.",
                                  "Install AndrOS on the phone; the rest is automatic.")

        // --- 1) Karekod karti
        let qr = NSImageView()
        qr.image = InstallSheet.makeQR(InstallSheet.url)
        qr.wantsLayer = true
        qr.layer?.backgroundColor = NSColor.white.cgColor
        qr.layer?.cornerRadius = 10
        qr.translatesAutoresizingMaskIntoConstraints = false
        qr.widthAnchor.constraint(equalToConstant: 168).isActive = true
        qr.heightAnchor.constraint(equalToConstant: 168).isActive = true

        let qrTitle = NSTextField(labelWithString: L("Telefona kur", "Install on phone"))
        qrTitle.font = .systemFont(ofSize: 14, weight: .semibold)

        let qrNote = NSTextField(wrappingLabelWithString: L(
            "Karekodu telefonunun kamerasıyla okut; kurulum sayfası açılır. "
          + "Uygulamayı kurup açtığında bu Mac telefonda listede görünür — "
          + "tek dokunuşla eşleşir. Hata ayıklama seçeneklerine gerek yok.",
            "Scan the QR with your phone's camera; the install page opens. "
          + "Once you install and open the app, this Mac appears in its list — "
          + "one tap pairs them. No developer options needed."))
        qrNote.font = .systemFont(ofSize: 11)
        qrNote.textColor = .secondaryLabelColor
        qrNote.preferredMaxLayoutWidth = 250

        let link = NSButton(title: InstallSheet.url
                                .replacingOccurrences(of: "https://", with: ""),
                            target: InstallActions.shared,
                            action: #selector(InstallActions.openLink))
        link.bezelStyle = .inline
        link.isBordered = false
        link.contentTintColor = .controlAccentColor
        link.font = .systemFont(ofSize: 11)

        let copy = NSButton(title: L("Bağlantıyı kopyala", "Copy link"),
                            target: InstallActions.shared,
                            action: #selector(InstallActions.copyLink))
        copy.bezelStyle = .rounded

        let texts = NSStackView(views: [qrTitle, qrNote, link, copy])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 8

        let card = NSStackView(views: [qr, texts])
        card.orientation = .horizontal
        card.alignment = .top
        card.spacing = 16
        card.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        grid.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true

        // --- 2) Gelismis: adb kablosuz (uygulama kurulamiyorsa)
        advancedToggle.title = L("Gelişmiş: adb ile kablosuz bağlan",
                                 "Advanced: connect wirelessly over adb")
        advancedToggle.setButtonType(.onOff)
        advancedToggle.bezelStyle = .inline
        advancedToggle.isBordered = false
        advancedToggle.font = .systemFont(ofSize: 11)
        advancedToggle.contentTintColor = .secondaryLabelColor
        advancedToggle.target = self
        advancedToggle.action = #selector(toggleAdvanced)
        advancedToggle.state = advancedOpen ? .on : .off
        grid.addArrangedSubview(advancedToggle)

        guard advancedOpen else {
            let cancel = NSButton(title: L("Vazgeç", "Cancel"), target: self,
                                  action: #selector(cancelPair))
            cancel.bezelStyle = .rounded
            grid.addArrangedSubview(cancel)
            return
        }

        for (f, ph) in [(pairAddress, L("Bağlantı adresi — 192.168.1.42:5555",
                                        "Connect address — 192.168.1.42:5555")),
                        (pairPairAddr, L("Eşleştirme adresi (Android 11+) — 192.168.1.42:37123",
                                         "Pairing address (Android 11+) — 192.168.1.42:37123")),
                        (pairCode, L("Eşleştirme kodu (6 hane)", "Pairing code (6 digits)"))] {
            f.placeholderString = ph
            f.font = .systemFont(ofSize: 12)
            f.translatesAutoresizingMaskIntoConstraints = false
            grid.addArrangedSubview(f)
            f.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
            f.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }

        let connect = NSButton(title: L("Bağlan", "Connect"), target: self,
                               action: #selector(doConnect))
        connect.bezelStyle = .rounded
        let cancel = NSButton(title: L("Vazgeç", "Cancel"), target: self,
                              action: #selector(cancelPair))
        cancel.bezelStyle = .rounded
        let row = NSStackView(views: [connect, cancel, NSView()])
        row.orientation = .horizontal
        row.spacing = 8
        grid.addArrangedSubview(row)

        let note = NSTextField(wrappingLabelWithString: L(
            "Bu yol yalnızca AndrOS uygulamasını kuramadığın durumlar için. "
          + "Telefonda Geliştirici Seçenekleri › Kablosuz hata ayıklama açık olmalı; "
          + "eşleştirme portu bağlantı portundan FARKLIDIR.",
            "This path is only for when you cannot install the AndrOS app. "
          + "Developer options › Wireless debugging must be on; the pairing port is "
          + "DIFFERENT from the connection port."))
        note.font = .systemFont(ofSize: 10)
        note.textColor = .tertiaryLabelColor
        note.preferredMaxLayoutWidth = 460
        grid.addArrangedSubview(note)
    }

    @objc private func toggleAdvanced() {
        advancedOpen.toggle()
        buildPairPane()
    }

    private func pairCard(symbol: String, title: String, body: String,
                          badge: String) -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 20, weight: .regular))
        icon.contentTintColor = .controlAccentColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 28).isActive = true

        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 13, weight: .semibold)
        let b = NSTextField(wrappingLabelWithString: body)
        b.font = .systemFont(ofSize: 11)
        b.textColor = .secondaryLabelColor
        b.preferredMaxLayoutWidth = 420

        let tag = NSTextField(labelWithString: badge)
        tag.font = .systemFont(ofSize: 10, weight: .medium)
        tag.textColor = .systemOrange

        let texts = NSStackView(views: [t, b, tag])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 4

        let row = NSStackView(views: [icon, texts])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        row.wantsLayer = true
        row.layer?.backgroundColor = NSColor.controlAccentColor
            .withAlphaComponent(0.08).cgColor
        row.layer?.cornerRadius = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    @objc private func cancelPair() {
        mode = .details
        reload()
        refreshList()
    }

    @objc private func doConnect() {
        let address = pairAddress.stringValue.trimmingCharacters(in: .whitespaces)
        let pAddr = pairPairAddr.stringValue.trimmingCharacters(in: .whitespaces)
        let pCode = pairCode.stringValue.trimmingCharacters(in: .whitespaces)
        guard !address.isEmpty else { return }

        spinner.startAnimation(nil)
        DispatchQueue.global().async { [weak self] in
            var err: String?
            do {
                let adb = try ADB()
                if !pAddr.isEmpty, !pCode.isEmpty { _ = try adb.pair(pAddr, code: pCode) }
                _ = try adb.connect(address)
            } catch { err = "\(error)" }
            DispatchQueue.main.async {
                guard let self else { return }
                self.spinner.stopAnimation(nil)
                if let err {
                    self.warn(L("Bağlanılamadı", "Could not connect"), err)
                } else {
                    self.mode = .details
                    self.reload()
                }
                self.refreshList()
            }
        }
    }

    private func remove(_ id: String) {
        guard let d = known.first(where: { $0.key == id }) else { return }
        let a = NSAlert()
        a.messageText = L("\"\(d.displayName)\" kaldırılsın mı?",
                          "Remove \"\(d.displayName)\"?")
        a.informativeText = L(
            "Cihaz listeden çıkar, eşleştirme silinir ve Wi-Fi bağlantısı kesilir. "
          + "Kabloyla takılıysa bir sonraki taramada yeniden görünür.",
            "The device leaves the list, its pairing is removed and any Wi-Fi "
          + "connection is dropped. If it is attached over USB it reappears "
          + "on the next scan.")
        a.alertStyle = .warning
        a.addButton(withTitle: L("Kaldır", "Remove"))
        a.addButton(withTitle: L("Vazgeç", "Cancel"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        if let w = d.wifiSerial, let adb = try? ADB() { adb.disconnect(w) }
        if let c = d.companionId { companionStore.forget(c) }
        DeviceRegistry.forget(d.key)
        if selectedID == d.key { selectedID = nil }
        // Kimlik onbellegini de temizle: yoksa silinen cihaz bir sonraki
        // taramada ESKI anahtariyla geri geliyordu ve ancak uygulamayi
        // yeniden baslatinca kayboluyordu.
        idCache.invalidate()
        // Bonjour listesindeki kopyayi da dusur; tarayici bir sonraki
        // degisime kadar eski kaydi tutuyor.
        companions.removeAll { $0.id == d.companionId }
        link?.disconnect(); link = nil
        NotificationCenter.default.post(name: .androsPaired, object: nil)
        refreshList()
    }

    /// USB'deki cihazi kablosuza gecirir — kablo sonrasinda cikarilabilir.
    @objc private func enableWireless() {
        guard let d = selected, let usb = d.usbSerial else { return }
        spinner.startAnimation(nil)
        DispatchQueue.global().async { [weak self] in
            var result: String?, err: String?
            do {
                let adb = try ADB(serial: usb)
                let addr = try adb.enableWireless()
                _ = try adb.connect(addr)
                result = addr
            } catch { err = "\(error)" }
            DispatchQueue.main.async {
                self?.spinner.stopAnimation(nil)
                if let err {
                    self?.warn(L("Kablosuz açılamadı", "Could not enable Wi-Fi"), err)
                } else if let result {
                    self?.warn(L("Kablosuz bağlantı hazır", "Wireless connection ready"),
                               L("Cihaz \(result) adresinden bağlandı. Artık kabloyu "
                               + "çıkarabilirsin.",
                                 "Connected at \(result). You can unplug the cable now."))
                }
                self?.refreshList()
            }
        }
    }

    func warn(_ title: String, _ body: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.runModal()
    }

    // MARK: - Secili cihazin ozeti

    /// Ses koprusunu ac/kapa. Surucu kurulu degilse ne yapilmasi
    /// gerektigini ACIKCA soyluyoruz — sessizce basarisiz olmak en kotusu.
    @objc private func toggleAudioBridge() {
        let on = audioToggle.state == .on
        // Kurulu ama ESKI surucu: paketle gelen yenisiyle degistir.
        if on, AudioDriverInstaller.isInstalled, AudioDriverInstaller.needsUpdate {
            let u = NSAlert()
            u.messageText = L("Ses sürücüsü güncellensin mi?",
                              "Update the audio driver?")
            u.informativeText = L("Uygulamayla gelen sürüm daha yeni.",
                                  "The version shipped with the app is newer.")
            u.addButton(withTitle: L("Güncelle", "Update"))
            u.addButton(withTitle: L("Şimdilik geç", "Skip"))
            if u.runModal() == .alertFirstButtonReturn {
                AudioDriverInstaller.install { _ in }
            }
        }
        guard !on || AudioDriverInstaller.isInstalled else {
            audioToggle.state = .off
            let a = NSAlert()
            a.messageText = L("Ses sürücüsü kurulsun mu?",
                              "Install the audio driver?")
            a.informativeText = L(
                "Telefonun macOS ses panelinde hoparlör ve mikrofon olarak "
              + "görünmesi için tek seferlik küçük bir sürücü gerekiyor. "
              + "Kurulum için macOS parolanı soracak; başka hiçbir şey "
              + "değişmiyor ve istediğin zaman kaldırabilirsin.",
                "For the phone to appear as a speaker and microphone in the macOS "
              + "sound panel, a small one-time driver is needed. macOS will ask "
              + "for your password; nothing else changes and you can remove it "
              + "any time.")
            a.addButton(withTitle: L("Kur", "Install"))
            a.addButton(withTitle: L("Vazgeç", "Cancel"))
            guard a.runModal() == .alertFirstButtonReturn else { return }
            spinner.startAnimation(nil)
            AudioDriverInstaller.install { [weak self] err in
                guard let self else { return }
                self.spinner.stopAnimation(nil)
                if let err {
                    let f = NSAlert()
                    f.messageText = L("Sürücü kurulamadı", "Could not install the driver")
                    f.informativeText = err
                    f.runModal()
                    return
                }
                self.audioToggle.state = .on
                (NSApp.delegate as? AppDelegate)?.setAudioBridge(true)
            }
            return
        }
        (NSApp.delegate as? AppDelegate)?.setAudioBridge(on)
    }

    @objc private func toggleCamera() {
        let on = cameraToggle.state == .on
        // Sanal kamera uzantisi kurulu degilse SOR: kurulmadan telefon
        // yalniz menu cubugunda gorunur, FaceTime/Zoom goremez.
        if on, !VirtualCamera.extensionInstalled {
            let a = NSAlert()
            a.messageText = L("Sanal kamera kurulsun mu?",
                              "Install the virtual camera?")
            a.informativeText = L(
                "Telefonun FaceTime, Zoom gibi kamera kullanan tüm "
              + "uygulamalarda görünmesi için bir sistem uzantısı gerekiyor. "
              + "macOS onay isteyecek. Kurmazsan kamera yalnızca menü "
              + "çubuğundaki önizlemede görünür.",
                "For the phone to appear in every app that uses a camera "
              + "(FaceTime, Zoom…), a system extension is needed. macOS will "
              + "ask for approval. Without it the camera only appears in the "
              + "menu bar preview.")
            a.addButton(withTitle: L("Kur", "Install"))
            a.addButton(withTitle: L("Sadece önizleme", "Preview only"))
            if a.runModal() == .alertFirstButtonReturn {
                spinner.startAnimation(nil)
                VirtualCamera.shared.installExtension { [weak self] err in
                    self?.spinner.stopAnimation(nil)
                    guard let err else { return }
                    let f = NSAlert()
                    f.messageText = L("Sanal kamera kurulamadı",
                                      "Could not install the virtual camera")
                    f.informativeText = err
                    f.runModal()
                }
            }
        }
        (NSApp.delegate as? AppDelegate)?.setCamera(on)
    }

    @objc private func reconnectNow() {
        spinner.startAnimation(nil)
        NotificationCenter.default.post(name: .androsReconnectRequested, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.spinner.stopAnimation(nil)
            self?.refreshList()
        }
    }

    @objc private func reload() {
        // Cihaz ekleme ya da eslestirme ekrani aciksa sag sutunu EZME.
        guard mode == .details else { return }
        guard let d = data else {
            grid.arrangedSubviews.forEach { $0.removeFromSuperview() }
            detailTitle.stringValue = L("Cihaz seçili değil", "No device selected")
            detailSub.stringValue = L("Kabloyla bağla ya da Wi-Fi'den ekle.",
                                      "Attach over USB or add one over Wi-Fi.")
            return
        }
        spinner.startAnimation(nil)
        DispatchQueue.global().async { [weak self] in
            let adb = d.adb
            func prop(_ k: String) -> String { adb.getProp(k) }

            let battery = (try? adb.checked(["shell", "dumpsys", "battery"])) ?? ""
            func batt(_ key: String) -> String {
                for l in battery.split(separator: "\n") {
                    let t = l.trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix(key + ":") {
                        return t.replacingOccurrences(of: key + ":", with: "")
                            .trimmingCharacters(in: .whitespaces)
                    }
                }
                return "?"
            }
            let df = (try? adb.checked(["shell", "df", "-h", "/data"])) ?? ""
            let dfLine = df.split(separator: "\n").last.map(String.init) ?? ""
            let dfParts = dfLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)

            let temp = Double(batt("temperature")).map { $0 / 10 }
            let level = batt("level")
            let charging = batt("status") == "2"

            let uptime = (try? adb.checked(["shell", "uptime"])) ?? ""
            let wm = (try? adb.checked(["shell", "wm", "size"])) ?? ""
            let ipAddr = (try? adb.wifiAddress()).flatMap { $0.isEmpty ? nil : $0 } ?? "—"
            let title = "\(prop("ro.product.manufacturer")) \(prop("ro.product.model"))"
                .trimmingCharacters(in: .whitespaces)

            let rows: [(String, String, String)] = [
                (L("Model", "Model"), title, "iphone"),
                (L("Android", "Android"),
                 "\(prop("ro.build.version.release")) · API \(prop("ro.build.version.sdk"))",
                 "gearshape"),
                (L("Yonga", "Chipset"), prop("ro.board.platform").uppercased(), "cpu"),
                (L("Pil", "Battery"), "%\(level)"
                    + (charging ? L(" · şarj oluyor", " · charging") : "")
                    + (temp.map { String(format: " · %.1f°C", $0) } ?? ""), "battery.100"),
                (L("Depolama", "Storage"), dfParts.count >= 4
                    ? L("\(dfParts[3]) boş / \(dfParts[1]) toplam",
                        "\(dfParts[3]) free / \(dfParts[1]) total")
                    : "—", "internaldrive"),
                (L("Ekran", "Display"),
                 wm.replacingOccurrences(of: "Physical size: ", with: ""),
                 "rectangle.on.rectangle"),
                (L("IP adresi", "IP address"), ipAddr, "network"),
                (L("Çalışma süresi", "Uptime"),
                 uptime.split(separator: ",").first.map(String.init) ?? "—", "clock"),
                (L("Seri", "Serial"), adb.serial ?? "—", "number"),
            ]
            let sensitiveKeys: Set<String> = [L("IP adresi", "IP address"), L("Seri", "Serial")]

            DispatchQueue.main.async {
                guard let self else { return }
                // Blok baslarken kip .details idi ama bu arada kullanici
                // eslestirme ekranina gecmis olabilir; gec gelen yanit
                // sag sutunu EZMESIN.
                guard self.mode == .details else { return }
                self.spinner.stopAnimation(nil)
                self.detailTitle.stringValue = self.selected?.displayName
                    ?? (title.isEmpty ? L("Cihaz", "Device") : title)
                self.detailSub.stringValue = title
                self.grid.arrangedSubviews.forEach { $0.removeFromSuperview() }

                // Eslesmemis uygulama varsa EN USTE acik bir dugme.
                // Secime guvenmek yetmiyordu: satir zaten secili oldugunda
                // tekrar tiklamak hicbir bildirim uretmiyor, dolayisiyla
                // eslestirme hicbir yerden baslatilamiyordu.
                if let sel = self.selected, let cid = sel.companionId,
                   !sel.companionPaired {
                    self.grid.addArrangedSubview(self.pairBanner(cid))
                }
                // IP ve seri numarasi gibi hassas alanlar VARSAYILAN GIZLI:
                // ekran paylasirken ya da yanindaki biri varken goze carpmasin.
                for (k, v, sym) in rows {
                    let c = self.card(k, v, sym, sensitive: sensitiveKeys.contains(k))
                    self.grid.addArrangedSubview(c)
                    // Genislik kisiti view hiyerarsiye GIRDIKTEN sonra kurulmali
                    c.widthAnchor.constraint(equalTo: self.grid.widthAnchor).isActive = true
                }
            }
        }
    }

    /// "Bu telefonda AndrOS uygulaması var, eşleştir" seridi.
    private func pairBanner(_ companionId: String) -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "iphone.radiowaves.left.and.right",
                             accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
        icon.contentTintColor = .systemOrange
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 26).isActive = true

        let t = NSTextField(labelWithString:
            L("AndrOS uygulaması bulundu — eşleştirilmedi",
              "AndrOS app found — not paired"))
        t.font = .systemFont(ofSize: 12, weight: .medium)
        let d = NSTextField(labelWithString:
            L("Eşleştirince USB kablosuna ve hata ayıklamaya gerek kalmaz.",
              "Once paired, no USB cable or debugging is needed."))
        d.font = .systemFont(ofSize: 11)
        d.textColor = .secondaryLabelColor

        let texts = NSStackView(views: [t, d])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1

        let b = NSButton(title: L("Eşleştir", "Pair"), target: self,
                         action: #selector(startPairing(_:)))
        b.bezelStyle = .rounded
        b.keyEquivalent = "\r"
        b.identifier = NSUserInterfaceItemIdentifier(companionId)
        // Erisilebilirlik etiketi: VoiceOver icin dogru, ayrica arayuzu
        // disaridan surulebilir kiliyor.
        b.setAccessibilityLabel(L("Eşleştir", "Pair"))

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        let row = NSStackView(views: [icon, texts, spacer, b])
        row.orientation = .horizontal
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        row.wantsLayer = true
        row.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.12).cgColor
        row.layer?.cornerRadius = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    @objc private func pairSelected() {
        guard let cid = selected?.companionId else { return }
        mode = .companion
        connectCompanion(cid)
    }

    @objc private func startPairing(_ sender: NSButton) {
        guard let cid = sender.identifier?.rawValue else { return }
        mode = .companion
        connectCompanion(cid)
    }

    private var revealed = Set<String>()

    @objc private func toggleReveal(_ sender: NSButton) {
        guard let k = sender.identifier?.rawValue else { return }
        if revealed.contains(k) { revealed.remove(k) } else { revealed.insert(k) }
        reload()
    }

    /// Tiklayinca gercek deger panoya gider (maskeli gorunse bile).
    @objc private func copyValue(_ sender: NSButton) {
        guard let v = sender.toolTip else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(v, forType: .string)
    }

    func card(_ key: String, _ value: String, _ symbol: String,
                      sensitive: Bool = false) -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = .controlAccentColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 22).isActive = true

        let k = NSTextField(labelWithString: key)
        k.font = .systemFont(ofSize: 11)
        k.textColor = .secondaryLabelColor

        let shown = !sensitive || revealed.contains(key)
        let v = NSTextField(labelWithString: shown ? value : Privacy.mask(value))
        v.font = shown ? .systemFont(ofSize: 13, weight: .medium)
                       : .monospacedSystemFont(ofSize: 13, weight: .medium)
        v.textColor = shown ? .labelColor : .secondaryLabelColor

        let texts = NSStackView(views: [k, v])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1

        var views: [NSView] = [icon, texts]
        if sensitive {
            let copy = NSButton(title: L("Kopyala", "Copy"), target: self,
                                action: #selector(copyValue(_:)))
            copy.bezelStyle = .inline
            copy.font = .systemFont(ofSize: 11)
            copy.toolTip = value          // gercek deger burada saklaniyor

            let eye = NSButton(title: "", target: self, action: #selector(toggleReveal(_:)))
            eye.bezelStyle = .inline
            eye.image = NSImage(systemSymbolName: shown ? "eye.slash" : "eye",
                                accessibilityDescription: shown ? L("Gizle", "Hide")
                                                                : L("Göster", "Show"))
            eye.identifier = NSUserInterfaceItemIdentifier(key)
            eye.toolTip = shown ? L("Gizle", "Hide") : L("Göster", "Show")

            views += [NSView(), copy, eye]
        }

        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 9, left: 12, bottom: 9, right: 12)
        row.wantsLayer = true
        row.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
        row.layer?.cornerRadius = 9
        row.translatesAutoresizingMaskIntoConstraints = false
        // Ekleme ISI CAGIRANA ait: burada da eklersek ayni view iki kez
        // eklenmis oluyor ve genislik kisiti yanlis zamanda kuruluyor.
        return row
    }

    @objc private func screenshot() {
        guard let d = data else { return }
        spinner.startAnimation(nil)
        DispatchQueue.global().async { [weak self] in
            let remote = "/sdcard/andros_shot.png"
            _ = try? d.adb.run(["shell", "screencap", "-p", remote], timeout: 30)
            let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let dir = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("AndrOS", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let local = dir.appendingPathComponent("Telefon_\(fmt.string(from: Date())).png")
            let ok = d.pull(remote, to: local.path)
            _ = try? d.adb.run(["shell", "rm", "-f", remote])
            DispatchQueue.main.async {
                self?.spinner.stopAnimation(nil)
                if ok {
                    // Panoya da koy: hemen yapistirilabilsin
                    if let img = NSImage(contentsOf: local) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects([img])
                    }
                    NSWorkspace.shared.activateFileViewerSelecting([local])
                }
            }
        }
    }

    @objc private func reboot() {
        guard let d = data else { return }
        let a = NSAlert()
        a.messageText = L("Telefon yeniden başlatılsın mı?", "Restart the phone?")
        a.informativeText = L("Bağlantı kesilecek ve cihaz yeniden açılana kadar kullanılamayacak.",
                              "The connection drops and the device is unusable until it boots.")
        a.alertStyle = .warning
        a.addButton(withTitle: L("Yeniden başlat", "Restart"))
        a.addButton(withTitle: L("Vazgeç", "Cancel"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        _ = try? d.adb.run(["reboot"])
    }
}

/// Cihaz satiri: YUVARLAK kosleri olan secim ve uzerine gelme vurgusu.
///
/// `NSTableView`'in kendi vurgusu koseden koseye duz bir dikdortgen ciziyor
/// ve secili satir "uzerine gelinmis" gibi duruyordu. Burada ikisini
/// birbirinden ayiriyoruz: SECIM vurgu rengiyle, UZERINE GELME cok daha
/// soluk bir tonla ciziliyor.
final class DeviceRowView: NSTableRowView {
    private var hovered = false
    private var tracking: NSTrackingArea?

    /// AppKit secili satirin icerigini "vurgulu" sayip etiketleri BEYAZA
    /// ceviriyor. Bizim vurgumuz soluk bir tint oldugundan beyaz yazi
    /// okunmuyordu; icerigi normal sayarak kendi renklerini koruyoruz.
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        // ".activeAlways": ".activeInKeyWindow" ile Cmd+Tab sonrasi
        // mouseExited gelmiyor ve satir gri takili kaliyordu.
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with e: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with e: NSEvent)  { hovered = false; needsDisplay = true }

    override func drawBackground(in dirtyRect: NSRect) {
        guard hovered, !isSelected else { return }
        NSColor.labelColor.withAlphaComponent(0.09).setFill()
        roundedPath().fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        // Rengi GECERLI gorunumde cozup oyle soluklastiriyoruz: dinamik
        // katalog renklerinde dogrudan alfa vermek koyu/acik temada
        // beklenmedik tonlar veriyor.
        let base = NSColor.controlAccentColor.usingColorSpace(.sRGB)
            ?? NSColor.systemBlue
        base.withAlphaComponent(0.20).setFill()
        roundedPath().fill()
    }

    private func roundedPath() -> NSBezierPath {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 0), xRadius: 9, yRadius: 9)
    }
}

/// Genisligini HER ZAMAN kaydirma alanina esitleyen tablo.
///
/// Neden gerekli: NSTableView kendi genisligini sutunlardan, ic bosluk
/// bicemi (`style`) ve kaydiraga ayrilan yerden turetiyor. Olculdu:
/// gorunur alan 228 px iken tablo 242 px kaliyordu — satirin yuvarlak
/// secim vurgusu ve saga yaslanan cop kutusu dugmesi sag kenardan
/// tasip kirpiliyordu. Kisitlar, `autoresizingMask` ve elle cerceve
/// verme denendi; hicbiri tek basina tutmadi. Genisligi tek noktadan
/// kelepceleyince sorun tamamen bitiyor.
final class FittedTableView: NSTableView {
    override func setFrameSize(_ newSize: NSSize) {
        var s = newSize
        if let clip = enclosingScrollView?.contentView, clip.bounds.width > 1 {
            s.width = clip.bounds.width
        }
        super.setFrameSize(s)
        // Tek sutun da ayni genislikte olmali, yoksa hucre gorunumu
        // tablodan genis kalip yine tasiyor. Esitse dokunmuyoruz:
        // aksi halde cerceve/sutun birbirini surekli tetikler.
        if let c = tableColumns.first, abs(c.width - s.width) > 0.5 {
            c.width = s.width
        }
    }
}

// MARK: - AndrOS uygulamasiyla eslestirme

extension DevicePanel {

    /// Secilen telefona baglanir; eslestirilmemisse kod ekranini acar.
    func connectCompanion(_ deviceId: String) {
        guard let dev = companions.first(where: { $0.id == deviceId }) else { return }
        // YENIDEN GIRISI ENGELLE. Bu koruma olmadan sonsuz dongu olusuyordu:
        // baglanma -> tarama tazeleme -> liste yenileme -> secimin yeniden
        // kurulmasi -> baglanma. Saniyede onlarca tur donup her turda yeni
        // QR uretiyor ve uygulamayi dusuruyordu.
        if pairingDeviceId == deviceId, let l = link,
           l.state == .connecting || l.state == .awaitingCode || l.state == .ready {
            return
        }
        pairingDeviceId = deviceId
        lastRenderedState = nil
        // ONCEKI baglantiyi kapat: her secimde yeni bir baglanti acilinca
        // telefonda yarim acik soketler birikiyor ve yeni baglanti
        // el sikismasini bitiremeden asili kaliyordu.
        link?.disconnect()
        qrTimer?.invalidate()
        pendingQRCode = nil
        let l = CompanionLink(device: dev, store: companionStore)
        link = l
        l.onState = { [weak self] state in
            guard let self else { return }
            // Ayni durum icin paneli TEKRAR cizme: yoksa her durum
            // bildiriminde QR yeniden uretiliyor gibi gorunuyordu.
            guard state != self.lastRenderedState else { return }
            self.lastRenderedState = state
            switch state {
            case .connecting:
                self.showCompanion(dev, L("Bağlanılıyor…", "Connecting…"), code: false)
            case .awaitingCode:
                self.showCompanion(dev,
                    L("Telefondaki 6 haneli kodu yaz.", "Type the 6-digit code from the phone."),
                    code: true)
            case .ready:
                self.showCompanionReady(dev)
            case .failed(let e):
                self.showCompanion(dev, L("Bağlanamadı: ", "Could not connect: ") + e,
                                   code: false)
            case .idle:
                break
            }
        }
        l.connect()
    }

    /// `andros://pair?...` iceren QR uretir.
    ///
    /// Mac'te kamera yok, telefonda var — bu yuzden QR MAC'TE gosteriliyor
    /// ve TELEFONUN kendi kamera uygulamasiyla okunuyor. Okununca derin
    /// baglanti uygulamayi acip kodu on onayliyor; kullanici hicbir sey
    /// yazmiyor. Rakamli kutu yine duruyor: kamerasi olmayan ya da QR
    /// okumayan telefonlarda o yol calisiyor.
    static func qrImage(_ text: String, side: CGFloat) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        // "M": %15 hata duzeltme — ekrandan okunurken fazlasi gereksiz.
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = filter.outputImage else { return nil }
        let scale = side / out.extent.width
        let scaled = out.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }

    private func showCompanion(_ dev: CompanionDevice, _ message: String, code: Bool) {
        grid.arrangedSubviews.forEach { $0.removeFromSuperview() }
        detailTitle.stringValue = dev.name
        detailSub.stringValue = L("AndrOS mobil uygulaması", "AndrOS mobile app")

        let msg = NSTextField(wrappingLabelWithString: message)
        msg.font = .systemFont(ofSize: 12)
        msg.preferredMaxLayoutWidth = 420
        grid.addArrangedSubview(msg)

        guard code else { return }

        // QR: telefonun kamerasiyla okunup dogrudan eslesme.
        let macName = Host.current().localizedName ?? "Mac"
        // Kod PERIYODIK yenileniyor (15 sn). Sonsuza kadar gecerli bir kod
        // guvenlik acigi olurdu; her yeniden cizimde yenilemek ise telefonun
        // okudugu kodu gecersiz kiliyordu. Ikisinin ortasi: sabit periyot.
        let qrCode = pendingQRCode ?? String(format: "%06d", Int.random(in: 0...999_999))
        pendingQRCode = qrCode
        let payload = "andros://pair?c=\(qrCode)&n="
            + (macName.addingPercentEncoding(
                withAllowedCharacters: .urlQueryAllowed) ?? "Mac")
        if let img = Self.qrImage(payload, side: 168) {
            let iv = NSImageView()
            iv.image = img
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.widthAnchor.constraint(equalToConstant: 168).isActive = true
            iv.heightAnchor.constraint(equalToConstant: 168).isActive = true
            grid.addArrangedSubview(iv)

            let cap = NSTextField(wrappingLabelWithString: L(
                "Telefonun kamerasını buna tut — eşleşme kendiliğinden tamamlanır. "
              + "Ya da aşağıya telefondaki kodu yaz.",
                "Point the phone's camera at this — pairing completes on its own. "
              + "Or type the code shown on the phone below."))
            cap.font = .systemFont(ofSize: 11)
            cap.textColor = .secondaryLabelColor
            cap.preferredMaxLayoutWidth = 420
            grid.addArrangedSubview(cap)

            // Kalan sure cubugu — bitince yeni kod uretilip yeniden cizilir.
            countdown.translatesAutoresizingMaskIntoConstraints = false
            countdown.widthAnchor.constraint(equalToConstant: 168).isActive = true
            countdown.period = 15
            countdown.onExpire = { [weak self] in
                guard let self, self.mode == .companion else { return }
                self.pendingQRCode = nil
                self.showCompanion(dev, message, code: true)
            }
            grid.addArrangedSubview(countdown)
            countdown.restart()

            // Telefon QR'i okuyunca kod ON ONAYLI olur; burada periyodik
            // deneyerek kullaniciya "artik bas" dedirtmiyoruz.
            startQRPolling()
        }

        codeField.placeholderString = L("6 haneli kod", "6-digit code")
        codeField.font = .monospacedDigitSystemFont(ofSize: 20, weight: .medium)
        codeField.stringValue = ""
        codeField.translatesAutoresizingMaskIntoConstraints = false
        codeField.widthAnchor.constraint(equalToConstant: 160).isActive = true
        codeField.target = self
        codeField.action = #selector(submitCode)
        codeField.setAccessibilityLabel(L("Eşleştirme kodu", "Pairing code"))

        let go = NSButton(title: L("Eşleştir", "Pair"), target: self, action: #selector(submitCode))
        go.bezelStyle = .rounded
        go.setAccessibilityLabel(L("Kodu gönder", "Submit code"))
        go.keyEquivalent = "\r"

        let row = NSStackView(views: [codeField, go, NSView()])
        row.orientation = .horizontal
        row.spacing = 8
        grid.addArrangedSubview(row)
        view.window?.makeFirstResponder(codeField)
    }

    func showCompanionReady(_ dev: CompanionDevice) {
        grid.arrangedSubviews.forEach { $0.removeFromSuperview() }
        detailTitle.stringValue = dev.name
        detailSub.stringValue = L("AndrOS mobil uygulaması · eşleşmiş",
                                  "AndrOS mobile app · paired")
        // Baglanti kurulunca cihazin kendi bilgisini SORUP gosteriyoruz:
        // "eslesti" demek yeterli degil, veri gercekten akiyor mu gorulsun.
        link?.request("device.info", [:]) { [weak self] data, err in
            guard let self else { return }
            if let err {
                self.grid.addArrangedSubview(
                    NSTextField(labelWithString: L("Hata: ", "Error: ") + err))
                return
            }
            guard let d = data else { return }
            let rows: [(String, String)] = [
                (L("Model", "Model"),
                 "\(d["manufacturer"] as? String ?? "") \(d["model"] as? String ?? "")"),
                ("Android", "\(d["android"] as? String ?? "") · API \(d["sdk"] as? Int ?? 0)"),
                (L("Depolama", "Storage"),
                 FilesPanel.human((d["storageFree"] as? Int) ?? 0) + " / "
                 + FilesPanel.human((d["storageTotal"] as? Int) ?? 0)),
            ]
            for (k, v) in rows {
                let c = self.card(k, v, "iphone")
                self.grid.addArrangedSubview(c)
                c.widthAnchor.constraint(equalTo: self.grid.widthAnchor).isActive = true
            }
            self.addTransportPicker(dev)
        }
    }

    /// Baglanti yolu ve OLCULEN hiz.
    ///
    /// Once "Wi-Fi" ve "USB" ayri ayri zorlanip olculuyordu; bu makinede
    /// yanlis sonuc veriyordu cunku ag baglantisi KABLOLU Ethernet — Wi-Fi
    /// arayuzu hic yok, dolayisiyla "Wi-Fi olculemedi" cikiyor, olculen de
    /// USB degil LAN oluyordu. Artik telefonun hangi arayuzlerden
    /// duyuruldugunu gosterip GERCEKTEN kullanilan yolu olcuyoruz.
    private func addTransportPicker(_ dev: CompanionDevice) {
        let head = NSTextField(labelWithString: L("Bağlantı yolu", "Connection path"))
        head.font = .systemFont(ofSize: 11, weight: .semibold)
        head.textColor = .secondaryLabelColor
        grid.addArrangedSubview(head)

        let paths = dev.interfaces.isEmpty
            ? L("bilinmiyor", "unknown") : dev.interfaces.joined(separator: ", ")
        let speed = transportPrefs.speed(dev.id, .auto)
        var txt = L("Telefon şu arayüzlerden görünüyor: ", "The phone is visible over: ") + paths
        if let s = speed { txt += String(format: "\n%.0f MB/s ölçüldü", s) }
        else { txt += L("\nHenüz ölçülmedi.", "\nNot measured yet.") }
        let info = NSTextField(wrappingLabelWithString: txt)
        info.font = .systemFont(ofSize: 10)
        info.textColor = .tertiaryLabelColor
        info.preferredMaxLayoutWidth = 420
        grid.addArrangedSubview(info)

        let measure = NSButton(title: L("Hızı ölç", "Measure speed"), target: self,
                               action: #selector(measureTransports(_:)))
        measure.bezelStyle = .rounded
        measure.identifier = NSUserInterfaceItemIdentifier(dev.id)
        measure.setAccessibilityLabel(L("Hızı ölç", "Measure speed"))
        grid.addArrangedSubview(measure)
    }

    /// Gercek yuk uzerinden olcum: 8 MB cekip suresine bakiyoruz.
    @objc private func measureTransports(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let dev = companions.first(where: { $0.id == id }),
              let l = link, l.state == .ready else { return }
        sender.isEnabled = false
        spinner.startAnimation(nil)
        l.measureThroughput { [weak self] mbps in
            guard let self else { return }
            self.spinner.stopAnimation(nil)
            if let mbps { self.transportPrefs.setSpeed(mbps, dev.id, .auto) }
            self.showCompanionReady(dev)
        }
    }

    /// QR okunmus mu diye kodu araliklarla dener.
    private func startQRPolling() {
        qrTimer?.invalidate()
        guard let code = pendingQRCode else { return }
        var tries = 0
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            tries += 1
            if tries > 90 { timer.invalidate(); return }   // 3 dk
            guard let l = self.link else { timer.invalidate(); return }
            // Telefon uygulamasi yeniden baslarsa baglanti duser; kodu
            // gecersiz saymadan YENIDEN BAGLANIP denemeye devam ediyoruz.
            if case .idle = l.state { l.connect(); return }
            if case .failed = l.state { l.connect(); return }
            l.confirmPairing(code: code) { err in
                if err == nil {
                    timer.invalidate()
                    NotificationCenter.default.post(name: .androsPaired, object: nil)
                    self.refreshList()
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        qrTimer = t
    }

    @objc func submitCode() {
        let code = codeField.stringValue.trimmingCharacters(in: .whitespaces)
        guard code.count == 6 else { return }
        link?.confirmPairing(code: code) { [weak self] err in
            guard let self else { return }
            if let err {
                self.warn(L("Eşleştirilemedi", "Pairing failed"), err)
            } else {
                self.qrTimer?.invalidate()
                // Kalici baglanti AppDelegate'te kuruluyor; eslesme biter
                // bitmez haber ver, yoksa moduller bir sonraki Bonjour
                // degisimine kadar uygulamayi kullanamiyor.
                NotificationCenter.default.post(name: .androsPaired, object: nil)
                self.refreshList()
            }
        }
    }
}
