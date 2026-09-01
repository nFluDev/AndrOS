import AppKit
import AndrOSCore

/// Tum panellerin ortak arayuzu.
protocol AndrOSPanel: AnyObject {
    var data: AndroidData? { get set }
    func didAppear()
    /// Panel gorunurlukten cikarken: oynatma/indirme gibi seyler durmali.
    func willDisappear()
}

extension AndrOSPanel {
    func willDisappear() {}
}

/// Yigin icinde YALNIZ bu genisler — arama kutusunu saga itmek icin.
///
/// Duz `NSView()` yeterli degil: varsayilan sarilma onceligi etiketlerle
/// esit oldugundan bazen etiket, bazen bosluk buyuyordu ve arama kutusu
/// panelden panele yer degistiriyordu.
func flexSpacer() -> NSView {
    let v = NSView()
    v.setContentHuggingPriority(.init(1), for: .horizontal)
    v.setContentCompressionResistancePriority(.init(1), for: .horizontal)
    return v
}

/// Tazeleme kullanicinin YERINI bozmasin.
///
/// `reloadData()` secimi ve kaydirma konumunu sifirliyor; arka planda
/// her birkac saniyede bir tazeleme donunce kullanici tam bir satiri
/// secmisken elinden aliniyordu. Satirlari KIMLIKLE eslestirip secimi
/// ve kaydirmayi geri koyuyoruz — liste degistiyse bile dogru satir
/// secili kaliyor.
func reloadKeepingState(_ table: NSTableView, oldIDs: [String], newIDs: [String]) {
    let keep = Set(table.selectedRowIndexes.compactMap {
        $0 < oldIDs.count ? oldIDs[$0] : nil
    })
    let y = table.enclosingScrollView?.contentView.bounds.origin.y
    table.reloadData()
    if !keep.isEmpty {
        let rows = newIDs.enumerated().filter { keep.contains($0.element) }.map(\.offset)
        if !rows.isEmpty {
            table.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
        }
    }
    if let y, let sv = table.enclosingScrollView {
        sv.contentView.scroll(to: NSPoint(x: 0, y: y))
        sv.reflectScrolledClipView(sv.contentView)
    }
}

/// Panellerde tekrar eden "veri yok / modul kapali" gorunumu.
func scrollWrap(_ v: NSView) -> NSScrollView {
    let s = NSScrollView()
    // Icerik USTTEN baslasin (bkz. TopClipView).
    let clip = TopClipView()
    clip.drawsBackground = false
    s.contentView = clip
    s.documentView = v
    s.hasVerticalScroller = true
    s.drawsBackground = false
    s.borderType = .noBorder
    s.translatesAutoresizingMaskIntoConstraints = false
    return s
}

// MARK: - Pano

/// Pano gecmisi. Icerik VARSAYILAN OLARAK GIZLI: ekranda baskasi varken
/// sifre/kod gibi seyler goze carpmasin. Tek tek ya da topluca acilir.
final class ClipboardPanel: NSViewController, AndrOSPanel {
    private var isLoading = false
    private var refreshObserverInstalled = false
    var data: AndroidData?

    /// Pano gecmisi uygulama genelinde tutulur.
    static var history: [(text: String, date: Date)] = []
    static func record(_ text: String) {
        guard !text.isEmpty else { return }
        if history.first?.text == text { return }
        history.insert((text, Date()), at: 0)
        if history.count > 100 { history.removeLast() }
        NotificationCenter.default.post(name: .androsClipboardChanged, object: nil)
    }

    private var revealed = Set<Int>()
    private var revealAll = false
    private let stack = NSStackView()
    private let revealButton = NSButton()
    private let pullButton = NSButton()
    private let searchBox = SearchToggle()
    private var macWatch: Timer?

    override func loadView() {
        let root = NSView()

        revealButton.title = L("Tümünü göster", "Show all")
        revealButton.bezelStyle = .rounded
        revealButton.target = self
        revealButton.action = #selector(toggleRevealAll)

        let clearButton = NSButton(title: L("Geçmişi temizle", "Clear history"), target: self,
                                   action: #selector(clearHistory))
        clearButton.bezelStyle = .rounded

        let note = NSTextField(labelWithString: L("İçerik gizli tutulur. Göstermek için satıra tıkla.", "Contents stay hidden. Click a row to reveal it."))
        note.font = .systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor

        pullButton.title = L("Telefondan al", "Get from phone")
        pullButton.bezelStyle = .rounded
        pullButton.target = self
        pullButton.action = #selector(pullFromPhoneTapped)
        pullButton.toolTip = L("Telefonun panosunu okumak için yansıtma açık olmalı", "Mirroring must be running to read the phone's clipboard")

        searchBox.placeholder = L("Panoda ara", "Search clipboard")
        searchBox.onChange = { [weak self] _ in self?.rebuild() }

        let bar = NSStackView(views: [revealButton, pullButton, clearButton, note,
                                      flexSpacer(), searchBox])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = scrollWrap(stack)
        root.addSubview(bar)
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -20),
        ])
        view = root

        NotificationCenter.default.addObserver(
            forName: .androsClipboardChanged, object: nil, queue: .main) { [weak self] _ in
            self?.rebuild()
        }
    }

    func didAppear() {
        // Mac panosunu da izle: yansitma kapaliyken bile gecmis dolsun.
        // Onceki surumde gecmis YALNIZ yansitma sirasinda doluyordu, bu
        // yuzden panel bos gorunuyordu.
        seedFromMac()
        // Telefonun panosunu da kendiliginden al: kullanicinin ayrica
        // dugmeye basmasi gerekmesin.
        pullFromPhone()
        macWatch?.invalidate()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.seedFromMac()
        }
        // Telefon panosunu daha seyrek yokla: her saniye sormak gereksiz.
        let pt = Timer(timeInterval: 4.0, repeats: true) { [weak self] _ in
            guard let self, !self.view.isHiddenOrHasHiddenAncestor else { return }
            UserBusy.run { [weak self] in self?.pullFromPhone() }
        }
        RunLoop.main.add(pt, forMode: .common)
        phoneWatch = pt
        RunLoop.main.add(t, forMode: .common)
        macWatch = t
        rebuild()
    }

    func willDisappear() {
        macWatch?.invalidate(); macWatch = nil
        phoneWatch?.invalidate(); phoneWatch = nil
    }

    private var phoneWatch: Timer?
    private var lastMacChange = -1
    private func seedFromMac() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastMacChange else { return }
        lastMacChange = pb.changeCount
        if let s = pb.string(forType: .string), !s.isEmpty {
            ClipboardPanel.record(s)
        }
    }

    /// Telefonun ANLIK panosunu ister.
    ///
    /// Mobil uygulama eslesmisse dogrudan okunuyor — YANSITMA GEREKMIYOR.
    /// Uygulama yoksa eski yol: Android 10+ arka planda pano okumayi
    /// engelledigi icin kontrol soketi (yansitma) acik olmali.
    /// @param silent Otomatik yoklamada UYARI GOSTERME.
    ///
    /// Panel her 4 saniyede bir telefonu yokluyor; uygulama hazir
    /// degilken bu, saniyede bir kipli uyari acip kategori degistirmeyi
    /// bile imkansiz kiliyordu. Uyari yalniz kullanici dugmeye BASINCA.
    private func pullFromPhone(silent: Bool = true) {
        if let d = data, d.companion?.isReady == true {
            DispatchQueue.global().async { [weak self] in
                let text = d.clipboardText()
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let t = text, !t.isEmpty {
                        ClipboardPanel.record(t)
                        self.rebuild()
                    }
                }
            }
            return
        }
        guard !silent else { return }
        NotificationCenter.default.post(name: .androsRequestPhoneClipboard, object: nil)
    }

    @objc private func pullFromPhoneTapped() { pullFromPhone(silent: false) }

    @objc private func toggleRevealAll() {
        revealAll.toggle()
        revealButton.title = revealAll ? L("Tümünü gizle", "Hide all") : L("Tümünü göster", "Show all")
        rebuild()
    }

    @objc private func clearHistory() {
        ClipboardPanel.history.removeAll()
        revealed.removeAll()
        rebuild()
    }

    @objc private func rowClicked(_ sender: NSButton) {
        let i = sender.tag
        if revealed.contains(i) { revealed.remove(i) } else { revealed.insert(i) }
        rebuild()
    }

    @objc private func copyRow(_ sender: NSButton) {
        let i = sender.tag
        guard i < ClipboardPanel.history.count else { return }
        let text = ClipboardPanel.history[i].text
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        // Uygulama eslesmisse telefonun panosuna da yaz: iki yonlu olsun.
        if let d = data, d.companion?.isReady == true {
            DispatchQueue.global().async { _ = d.setClipboard(text) }
        }
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard !ClipboardPanel.history.isEmpty else {
            emptyState().show(
                L("Pano geçmişi boş", "Clipboard history is empty"),
                // Mesaj eslestirme durumuna gore degisiyor: uygulama
                // varken "yansitmayi baslat" demek yanlis yonlendirme.
                (data?.companion?.isReady == true
                 ? L("Mac'te ya da telefonda bir şey kopyaladığında anında burada görünür.",
                     "Anything you copy on the Mac or the phone shows up here right away.")
                 : L("Mac'te bir şey kopyaladığında anında burada görünür.\n"
                   + "Telefonun panosu için AndrOS mobil uygulamasını eşleştir "
                   + "(ya da yansıtmayı başlat) — Android 10+ arka planda pano "
                   + "okumayı engelliyor.",
                     "Anything you copy on the Mac shows up here right away.\n"
                   + "Pair the AndrOS mobile app for the phone's clipboard "
                   + "(or start mirroring) — Android 10+ blocks background "
                   + "clipboard reads.")),
                symbol: "doc.on.clipboard")
            return
        }
        emptyState().isHidden = true
        let fmt = DateFormatter()
        fmt.dateFormat = "d MMM HH:mm"

        let q = searchBox.text.trimmingCharacters(in: .whitespaces).lowercased()
        let rows = ClipboardPanel.history.enumerated().filter {
            SearchMatch.matches(q, $0.element.text)
        }
        for (i, item) in rows {
            let shown = revealAll || revealed.contains(i)
            let text = shown ? item.text : ClipboardPanel.mask(item.text)

            let body = NSTextField(labelWithString: text)
            body.font = shown ? .systemFont(ofSize: 12)
                              : .monospacedSystemFont(ofSize: 12, weight: .regular)
            body.textColor = shown ? .labelColor : .secondaryLabelColor
            body.maximumNumberOfLines = 3
            body.lineBreakMode = .byTruncatingTail

            let meta = NSTextField(labelWithString:
                L("\(fmt.string(from: item.date)) · \(item.text.count) karakter",
                   "\(fmt.string(from: item.date)) · \(item.text.count) characters"))
            meta.font = .systemFont(ofSize: 10)
            meta.textColor = .tertiaryLabelColor

            let eye = NSButton(title: shown ? L("Gizle", "Hide") : L("Göster", "Show"), target: self,
                               action: #selector(rowClicked(_:)))
            eye.bezelStyle = .inline
            eye.tag = i
            let copy = NSButton(title: L("Kopyala", "Copy"), target: self, action: #selector(copyRow(_:)))
            copy.bezelStyle = .inline
            copy.tag = i

            let actions = NSStackView(views: [eye, copy])
            actions.orientation = .horizontal
            actions.spacing = 6

            let texts = NSStackView(views: [body, meta])
            texts.orientation = .vertical
            texts.alignment = .leading
            texts.spacing = 2

            let row = NSStackView(views: [texts, NSView(), actions])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 10
            row.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
            row.wantsLayer = true
            row.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
            row.layer?.cornerRadius = 8
            row.translatesAutoresizingMaskIntoConstraints = false
            // Once ekle, sonra kisitla (bkz. MessagesPanel'deki ayni tuzak).
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    /// Icerigi gizler ama sekli hakkinda fikir verir.
    static func mask(_ s: String) -> String {
        let firstLine = s.split(separator: "\n").first.map(String.init) ?? s
        let n = min(firstLine.count, 42)
        guard n > 0 else { return "" }
        // Bas ve sondan birer karakter birak: hangi kayit oldugu ayirt edilsin.
        if n <= 4 { return String(repeating: "•", count: n) }
        let chars = Array(firstLine)
        return String(chars[0]) + String(repeating: "•", count: n - 2) + String(chars[n - 1])
    }
}

extension Notification.Name {
    static let androsClipboardChanged = Notification.Name("androsClipboardChanged")
    static let androsRequestPhoneClipboard = Notification.Name("androsRequestPhoneClipboard")
    /// ⌘F — gorunur paneldeki arama kutusunu ac ve odakla.
    static let androsFocusSearch = Notification.Name("androsFocusSearch")
    /// ⌘R — gorunur paneli yeniden yukle.
    static let androsRefresh = Notification.Name("androsRefresh")
    /// Bir telefonla eslesildi — kalici baglantiyi hemen kur.
    static let androsPaired = Notification.Name("androsPaired")
    /// Telefondan yeni bildirim geldi.
    static let androsNotificationsChanged = Notification.Name("androsNotificationsChanged")
    /// Birlesik cihaz listesi guncellendi (Cihaz menusu icin).
    static let androsDevicesListed = Notification.Name("androsDevicesListed")
    /// Numara ile sohbet ac (Aramalar -> Mesajlar).
    static let androsOpenConversation = Notification.Name("androsOpenConversation")
}

// MARK: - Kisiler

final class ContactsPanel: NSViewController, AndrOSPanel, NSTableViewDataSource,
                           NSTableViewDelegate, NSMenuDelegate {
    var data: AndroidData?
    private var items: [AndroidData.Contact] = []
    private var filtered: [AndroidData.Contact] = []
    /// "Bu telefon" — telefonun kendi sahibi. Rehberde en ustte AYRI
    /// duruyor, telefon da boyle gosteriyor.
    private var owner: AndroidData.Contact?
    /// Kendi numaran ekranda ACIK durmasin: seri numarasi ve IP ile ayni
    /// kural. Tiklayinca panoya gidiyor.
    private var ownerRevealed = false
    private let table = NSTableView()
    private let search = SearchToggle()

    override func loadView() {
        let root = NSView()
        search.placeholder = L("Kişi ara", "Search contacts")
        search.onChange = { [weak self] _ in self?.filterChanged() }
        search.translatesAutoresizingMaskIntoConstraints = false

        let col = NSTableColumn(identifier: .init("c"))
        col.width = 460
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 42
        table.dataSource = self
        table.delegate = self

        table.allowsMultipleSelection = true
        let cm = NSMenu(); cm.delegate = self; table.menu = cm

        let scroll = scrollWrap(table)
        root.addSubview(search)
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: root.topAnchor),
            // Arama HER PANELDE en sagda.
            search.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    func didAppear() {
        guard let d = data else { return }
        DispatchQueue.global().async { [weak self] in
            // UYGULAMA yolu: `contacts()` yalniz adb kullaniyor ve hata
            // ayiklama kapaliyken hep bos donuyordu — kisiler hic
            // gelmiyordu.
            let c = d.contactsPreferringApp()
            let me = AndroidData.phoneOwner
            DispatchQueue.main.async {
                self?.owner = me
                self?.items = c
                self?.filterChanged()
            }
        }
    }

    @objc private func filterChanged() {
        let q = search.text.trimmingCharacters(in: .whitespaces).lowercased()
        let oldIDs = filtered.map { $0.name + $0.number }
        filtered = items.filter { SearchMatch.matchesAny(q, [$0.name, $0.number]) }
        if filtered.isEmpty {
            // Bos liste yeterli degil: SEBEBINI soyle. En sik sebep
            // telefonda kisiler izninin verilmemis olmasi.
            let why = AndroidData.lastFailure ?? ""
            let detail: String
            if !items.isEmpty {
                detail = L("Aramayı değiştir ya da temizle.", "Change or clear the search.")
            } else if why.contains("permission") || why.contains("CONTACTS") {
                detail = L("Telefondaki AndrOS uygulamasında “Kişiler” iznini ver; "
                         + "sonra bu sayfayı yenile.",
                           "Grant the “Contacts” permission in the AndrOS app on the "
                         + "phone, then refresh this page.")
            } else if why == "notconnected" {
                detail = L("Telefon bağlı değil. Cihazlar’dan eşleştir.",
                           "The phone is not connected. Pair it in Devices.")
            } else {
                detail = L("Telefon bağlandığında kişiler burada listelenir.",
                           "Contacts appear here once a phone is connected.")
            }
            emptyState().show(
                items.isEmpty ? L("Kişi yok", "No contacts")
                              : L("Eşleşen kişi yok", "No matching contact"),
                detail, symbol: "person.crop.circle")
        } else { emptyState().isHidden = true }
        reloadKeepingState(table, oldIDs: oldIDs, newIDs: filtered.map { $0.name + $0.number })
    }

    // MARK: - Sag tik menusu

    private var actionContacts: [AndroidData.Contact] {
        var r = table.clickedRow
        if r < 0, let w = table.window {
            r = table.row(at: table.convert(w.mouseLocationOutsideOfEventStream, from: nil))
        }
        if r >= 0, r < filtered.count, !table.selectedRowIndexes.contains(r) {
            return [filtered[r]]
        }
        return table.selectedRowIndexes.compactMap { $0 < filtered.count ? filtered[$0] : nil }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ t: String, _ sel: Selector) {
            let i = NSMenuItem(title: t, action: sel, keyEquivalent: "")
            i.target = self
            menu.addItem(i)
        }
        guard !actionContacts.isEmpty else { return }
        if actionContacts.count == 1 {
            add(L("Ara", "Call"), #selector(callContact))
            add(L("Mesaj yaz", "Message"), #selector(messageContact))
            menu.addItem(.separator())
        }
        add(L("Numarayı kopyala", "Copy number"), #selector(copyContactNumber))
        add(L("Adı kopyala", "Copy name"), #selector(copyContactName))
    }

    @objc private func callContact() {
        guard let c = actionContacts.first, let d = data else { return }
        DispatchQueue.global().async { _ = d.dial(c.number) }
    }

    @objc private func messageContact() {
        guard let c = actionContacts.first else { return }
        NotificationCenter.default.post(name: .androsOpenConversation, object: c.number)
    }

    @objc private func copyContactNumber() {
        let v = actionContacts.map(\.number).joined(separator: "\n")
        guard !v.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(v, forType: .string)
    }

    @objc private func copyContactName() {
        let v = actionContacts.map(\.name).joined(separator: "\n")
        guard !v.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(v, forType: .string)
    }

    /// Sahip satiri yalniz ARAMA BOSKEN gosteriliyor: suzgecte
    /// gorunmesi listeyi yaniltiyor.
    private var showsOwner: Bool {
        owner != nil && search.text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func numberOfRows(in t: NSTableView) -> Int {
        filtered.count + (showsOwner ? 1 : 0)
    }

    func tableView(_ t: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        DeviceRowView()
    }

    func tableView(_ t: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        if showsOwner, row == 0 { return ownerRow() }
        let index = row - (showsOwner ? 1 : 0)
        guard index < filtered.count else { return nil }
        let c = filtered[index]
        let name = NSTextField(labelWithString: c.name)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        let num = NSTextField(labelWithString: c.number)
        num.font = .systemFont(ofSize: 11)
        num.textColor = .secondaryLabelColor

        let initials = AvatarView()
        initials.initial = String(c.name.prefix(1)).uppercased()
        initials.seed = c.name.hashValue
        initials.translatesAutoresizingMaskIntoConstraints = false
        initials.widthAnchor.constraint(equalToConstant: 30).isActive = true
        initials.heightAnchor.constraint(equalToConstant: 30).isActive = true

        let texts = NSStackView(views: [name, num])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1

        // Aramalar'daki gibi: SAGA cek = ara, SOLA cek = mesaj yaz.
        let r = SwipeRow(views: [initials, texts])
        r.orientation = .horizontal
        r.spacing = 10
        r.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        r.onSwipeRight = { [weak self] in self?.callNumber(c.number) }
        r.onSwipeLeft = { [weak self] in
            NotificationCenter.default.post(name: .androsOpenConversation, object: c.number)
        }
        return r
    }

    /// "Bu telefon" satiri.
    ///
    /// Numara MASKELI duruyor — seri numarasi ve IP ile ayni kural:
    /// ekran paylasirken ya da yanindaki biri varken kendi numaran goze
    /// carpmasin. Tiklayinca panoya kopyalaniyor, ⌥ ile de gorunuyor.
    private func ownerRow() -> NSView {
        guard let c = owner else { return NSView() }
        let title = NSTextField(labelWithString:
            c.name.isEmpty ? L("Bu telefon", "This phone") : c.name)
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        let shown = c.number.isEmpty
            ? L("numara yok", "no number")
            : (ownerRevealed ? c.number : Privacy.mask(c.number))
        let num = NSTextField(labelWithString: shown)
        num.font = .systemFont(ofSize: 11)
        num.textColor = .secondaryLabelColor

        let badge = NSTextField(labelWithString: L("BU TELEFON", "THIS PHONE"))
        badge.font = .systemFont(ofSize: 9, weight: .semibold)
        badge.textColor = .controlAccentColor

        let avatar = AvatarView()
        avatar.initial = String((c.name.isEmpty ? "?" : c.name).prefix(1)).uppercased()
        avatar.seed = 0
        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.widthAnchor.constraint(equalToConstant: 30).isActive = true
        avatar.heightAnchor.constraint(equalToConstant: 30).isActive = true

        let texts = NSStackView(views: [title, num, badge])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1

        let row = ClickableRow(views: [avatar, texts])
        row.orientation = .horizontal
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        row.toolTip = L("Tıkla: numarayı panoya kopyala · ⌥ tıkla: göster",
                        "Click: copy the number · ⌥ click: reveal")
        row.onClick = { [weak self] alt in
            guard let self, !c.number.isEmpty else { return }
            if alt {
                self.ownerRevealed.toggle()
                self.table.reloadData()
            } else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(c.number, forType: .string)
            }
        }
        return row
    }

    /// Telefonda aramayi baslatir (Aramalar panelindeki yolun ayni).
    private func callNumber(_ number: String) {
        guard let d = data, !number.isEmpty else { return }
        DispatchQueue.global().async { [weak self] in
            let err = d.dial(number)
            guard let err else { return }
            DispatchQueue.main.async {
                let a = NSAlert()
                a.messageText = L("Arama başlatılamadı", "Could not start the call")
                a.informativeText = err == "notpaired"
                    ? L("Telefon eşleşmiş değil. Cihazlar’dan eşleştir.",
                        "The phone is not paired. Pair it in Devices.")
                    : err
                a.runModal()
            }
        }
    }
}

// MARK: - Aramalar (companion app gerekli)

final class CallsPanel: NSViewController, AndrOSPanel,
                       NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    var data: AndroidData?

    private var refreshObserverInstalled = false
    private var isLoading = false
    private var calls: [AndroidData.CallEntry] = []
    private var shown: [AndroidData.CallEntry] = []
    private let table = NSTableView()
    private let search = SearchToggle()
    private let spinner = NSProgressIndicator()
    private lazy var empty = EmptyStateView(frame: .zero)

    override func loadView() {
        let root = NSView()

        search.placeholder = L("Numara, kişi ara", "Search number or name")
        search.onChange = { [weak self] _ in self?.applyFilter() }
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let bar = NSStackView(views: [spinner, flexSpacer(), search])
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.spacing = 8
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let col = NSTableColumn(identifier: .init("c"))
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 52
        table.style = .fullWidth
        table.dataSource = self
        table.delegate = self
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 4)
        // Panel acilinca hicbir satir SECILI GELMESIN: kendiliginden
        // odaklanan satir genel tasarima ters duruyordu.
        table.allowsEmptySelection = true
        // Shift ile coklu secim: birden fazla kaydi tek seferde silmek icin.
        table.allowsMultipleSelection = true
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        let scroll = scrollWrap(table)

        empty.translatesAutoresizingMaskIntoConstraints = false
        for v in [bar, scroll, empty] as [NSView] { root.addSubview(v) }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            empty.topAnchor.constraint(equalTo: root.topAnchor),
            empty.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            empty.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            empty.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    func didAppear() {
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
        load()
    }

    private func load() {
        // AYNI ANDA tek yukleme. Ust uste binen istekler adb'yi
        // doyuruyor, uygulama koprusunun istekleri de arkada bekleyip
        // zaman asimina ugruyordu — panel dakikalarca bos kaliyordu.
        guard !isLoading else { return }
        guard let d = data else { return }
        isLoading = true
        spinner.startAnimation(nil)
        DispatchQueue.global().async { [weak self] in
            let list = d.callLog()
            let hasApp = d.companion?.isReady == true
            DispatchQueue.main.async {
                guard let self else { return }
                // Bayragi HER DURUMDA once sifirla. Erteleme dalindan
                // once sifirlanmazsa, ertelenen yukleme "zaten
                // yukleniyor" sanip donuyor ve panel kalici olarak bos
                // kaliyor — kilitlenme.
                self.isLoading = false
                // Kullanici bir hareketin ortasindaysa yenilemeyi ertele.
                guard !UserBusy.isBusy else {
                    UserBusy.run { [weak self] in self?.load() }
                    return
                }
                self.spinner.stopAnimation(nil)
                // Secili satirin KIMLIGINI sakla: yenileme sonrasi geri
                // kur, yoksa her tazelemede secim kayboluyordu.
                let keep = self.table.selectedRow >= 0
                    && self.table.selectedRow < self.shown.count
                    ? self.shown[self.table.selectedRow].id : nil
                self.calls = list
                self.applyFilter(appReady: hasApp)
                if let keep, let i = self.shown.firstIndex(where: { $0.id == keep }) {
                    self.table.selectRowIndexes([i], byExtendingSelection: false)
                }
            }
        }
    }

    private func applyFilter(appReady: Bool? = nil) {
        let q = search.text.trimmingCharacters(in: .whitespaces).lowercased()
        let oldIDs = shown.map(\.id)
        shown = calls.filter { SearchMatch.matchesAny(q, [$0.name, $0.number]) }
        reloadKeepingState(table, oldIDs: oldIDs, newIDs: shown.map(\.id))
        if shown.isEmpty {
            let ready = appReady ?? (data?.companion?.isReady == true)
            if !ready {
                // Bu modul YALNIZ uygulama ile mumkun: Android arama kaydi
                // saglayicisini adb kabuguna kapatiyor (SecurityException).
                empty.show(L("AndrOS mobil uygulaması gerekli",
                             "AndrOS mobile app required"),
                           L("Android, arama kaydını adb üzerinden kapatıyor. "
                           + "Cihazlar’dan telefonu eşleştirince arama geçmişi burada görünür.",
                             "Android blocks the call log over adb. Pair the phone "
                           + "in Devices and the call history appears here."),
                           symbol: "phone.badge.waveform")
            } else {
                empty.show(calls.isEmpty ? L("Arama yok", "No calls")
                                         : L("Eşleşen arama yok", "No matching call"),
                           calls.isEmpty ? L("Telefonda kayıtlı arama bulunamadı.",
                                             "No calls found on the phone.")
                                         : L("Aramayı değiştir ya da temizle.",
                                             "Change or clear the search."),
                           symbol: "phone")
            }
        } else { empty.isHidden = true }
    }

    func numberOfRows(in t: NSTableView) -> Int { shown.count }

    /// Yuvarlak kose vurgu — cihaz listesiyle ayni dil.
    func tableView(_ t: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        DeviceRowView()
    }

    func tableView(_ t: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        // SINIR KONTROLU: AppKit, `reloadData()` islenmeden once eski
        // indeksle satir isteyebiliyor; dizi kuculduyse cokerdi.
        guard row < shown.count else { return nil }
        let c = shown[row]
        let symbol: String
        let tint: NSColor
        switch c.kind {
        case "incoming": symbol = "phone.arrow.down.left"; tint = .systemGreen
        case "outgoing": symbol = "phone.arrow.up.right";  tint = .systemBlue
        case "missed":   symbol = "phone.down";            tint = .systemRed
        case "rejected", "blocked": symbol = "phone.down.circle"; tint = .systemOrange
        default:         symbol = "phone";                 tint = .secondaryLabelColor
        }
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = tint
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true

        let title = NSTextField(labelWithString: c.name.isEmpty ? c.number : c.name)
        title.font = .systemFont(ofSize: 13, weight: .medium)

        let fmt = DateFormatter(); fmt.dateFormat = "d MMM HH:mm"
        var detail = fmt.string(from: c.date)
        if c.duration > 0 {
            detail += " · " + String(format: "%d:%02d", c.duration / 60, c.duration % 60)
        }
        if !c.name.isEmpty { detail += " · " + c.number }
        let sub = NSTextField(labelWithString: detail)
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = .secondaryLabelColor

        let texts = NSStackView(views: [title, sub])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1

        let r = SwipeRow(views: [icon, texts])
        r.orientation = .horizontal
        r.spacing = 10
        r.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        // Samsung'un telefon yoneticisindeki gibi: SAGA cek = ara,
        // SOLA cek = mesaj yaz.
        r.onSwipeRight = { [weak self] in self?.call(c.number, name: c.name) }
        r.onSwipeLeft = { [weak self] in self?.message(c.number) }
        return r
    }

    /// Telefonda aramayi baslatir.
    ///
    /// Ses Mac'e TASINMIYOR — Android buna izin vermiyor (bkz. mobil
    /// taraftaki CallModule aciklamasi). Mac aramayi baslatiyor,
    /// konusma telefondan yapiliyor. Bildirim iki tarafta da cikiyor.
    func call(_ number: String, name: String = "") {
        guard let d = data, !number.isEmpty else { return }
        DispatchQueue.global().async { [weak self] in
            let err: String?
            if d.companion?.isReady == true {
                err = d.dial(number, immediate: true)
            } else {
                _ = try? d.adb.run(["shell", "am", "start", "-a",
                                    "android.intent.action.CALL", "-d", "tel:\(number)"])
                err = nil
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if let err {
                    self.warn(L("Aranamadı", "Could not call"),
                              err == "notpaired"
                                ? L("Önce AndrOS mobil uygulamasını eşleştir.",
                                    "Pair the AndrOS mobile app first.")
                                : L("Telefon aramayı başlatamadı.",
                                    "The phone could not start the call."))
                } else {
                    Notify.post(title: L("Aranıyor", "Calling"),
                                body: (name.isEmpty ? number : "\(name) · \(number)")
                                    + "\n" + L("Konuşma telefondan yapılır.",
                                                "The conversation happens on the phone."))
                }
            }
        }
    }

    private func warn(_ t: String, _ b: String) {
        let a = NSAlert(); a.messageText = t; a.informativeText = b; a.runModal()
    }

    /// Mesajlar kategorisine gecip o kisiyle sohbeti acar.
    private func message(_ number: String) {
        guard !number.isEmpty else { return }
        NotificationCenter.default.post(name: .androsOpenConversation, object: number)
    }

    // MARK: - Sag tik menusu

    /// Sag tiklanan satir secili degilse ONU hedef al (Finder davranisi).
    private var actionCalls: [AndroidData.CallEntry] {
        // `clickedRow` satirin ustundeki SwipeRow olayi yuttugunda -1
        // kalabiliyor; o durumda fare konumundan buluyoruz.
        var r = table.clickedRow
        if r < 0, let w = table.window {
            r = table.row(at: table.convert(w.mouseLocationOutsideOfEventStream, from: nil))
        }
        if r >= 0, r < shown.count, !table.selectedRowIndexes.contains(r) {
            return [shown[r]]
        }
        return table.selectedRowIndexes.compactMap { $0 < shown.count ? shown[$0] : nil }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ t: String, _ sel: Selector) {
            let i = NSMenuItem(title: t, action: sel, keyEquivalent: "")
            i.target = self
            menu.addItem(i)
        }
        let picked = actionCalls
        if picked.count == 1 {
            add(L("Ara", "Call"), #selector(callClicked))
            add(L("Mesaj yaz", "Message"), #selector(messageClicked))
            menu.addItem(.separator())
            add(L("Numarayı kopyala", "Copy number"), #selector(copyNumber))
        }
        if !picked.isEmpty {
            menu.addItem(.separator())
            add(picked.count == 1 ? L("Kaydı sil", "Delete entry")
                                  : L("\(picked.count) kaydı sil", "Delete \(picked.count) entries"),
                #selector(deleteClicked))
        }
        menu.addItem(.separator())
        add(L("Yenile", "Refresh"), #selector(refreshNow))
    }

    @objc private func callClicked() {
        guard let c = actionCalls.first else { return }
        call(c.number, name: c.name)
    }

    @objc private func messageClicked() {
        guard let c = actionCalls.first else { return }
        message(c.number)
    }

    @objc private func copyNumber() {
        let nums = actionCalls.map(\.number).joined(separator: "\n")
        guard !nums.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(nums, forType: .string)
    }

    @objc private func refreshNow() { isLoading = false; load() }

    /// ⌫ ile de silinsin — listede beklenen davranis bu.
    override func keyDown(with e: NSEvent) {
        if e.keyCode == 51 || e.keyCode == 117 { deleteClicked(); return }
        super.keyDown(with: e)
    }

    @objc private func deleteClicked() {
        guard let d = data else { return }
        let picked = actionCalls
        guard !picked.isEmpty else { return }
        let a = NSAlert()
        a.messageText = picked.count == 1
            ? L("Bu arama kaydı silinsin mi?", "Delete this call entry?")
            : L("\(picked.count) arama kaydı silinsin mi?", "Delete \(picked.count) call entries?")
        a.informativeText = L("Kayıt telefondan da silinir.", "It is deleted from the phone too.")
        a.alertStyle = .warning
        a.addButton(withTitle: L("Sil", "Delete"))
        a.addButton(withTitle: L("Vazgeç", "Cancel"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        spinner.startAnimation(nil)
        DispatchQueue.global().async { [weak self] in
            var failed = 0
            for c in picked where d.deleteCall(number: c.number, date: c.date) != nil {
                failed += 1
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.spinner.stopAnimation(nil)
                if failed > 0 {
                    self.warn(L("Bazı kayıtlar silinemedi", "Some entries could not be deleted"),
                              L("\(failed)/\(picked.count) kayıt telefonda silinemedi.",
                                "\(failed)/\(picked.count) entries could not be deleted on the phone."))
                }
                // Yerel listeden de dus: telefon listesi gecikmeli gelebiliyor.
                let gone = Set(picked.map(\.id))
                self.calls.removeAll { gone.contains($0.id) }
                self.applyFilter()
                self.refreshNow()
            }
        }
    }
}
