import AppKit
import AndrOSCore

/// Telefon bildirimleri: ustte ekranda DURANLAR, altta GECMIS.
///
/// Gecmis ayri tutuluyor cunku telefonda kapatilan bir bildirim
/// sistemden siliniyor; kullanici bilgisayar basindayken neyi
/// kacirdigini yine de gorebilmeli.
final class NotificationsPanel: NSViewController, AndrOSPanel,
                                NSTableViewDataSource, NSTableViewDelegate {
    var data: AndroidData?

    private enum Row {
        case header(String)
        case item(AndroidData.PhoneNotification, historic: Bool)
    }

    private var rows: [Row] = []
    private var live: [AndroidData.PhoneNotification] = []
    private var history: [AndroidData.PhoneNotification] = []
    private let table = NSTableView()
    private let search = SearchToggle()
    private let spinner = NSProgressIndicator()
    private lazy var empty = EmptyStateView(frame: .zero)
    private var refreshObserverInstalled = false
    private var isLoading = false
    /// "Uyari bicimine gec" onerisi (bir kez).
    private let styleHint = NSStackView()
    /// Yanit kutusu ACIK olan bildirim. Acilir pencere yok — kutu
    /// satirin icinde beliriyor (Mesajlar'daki yazma alani gibi).
    private var replyingKey: String?

    override func loadView() {
        let root = NSView()

        search.placeholder = L("Bildirim ara", "Search notifications")
        search.onChange = { [weak self] _ in self?.rebuild() }
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let clear = NSButton(title: L("Tümünü kapat", "Clear all"), target: self,
                             action: #selector(clearAll))
        clear.bezelStyle = .rounded

        let bar = NSStackView(views: [clear, spinner, flexSpacer(), search])
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.spacing = 8
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let col = NSTableColumn(identifier: .init("n"))
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 56
        table.style = .fullWidth
        table.intercellSpacing = NSSize(width: 0, height: 4)
        table.backgroundColor = .clear
        table.allowsEmptySelection = true
        table.dataSource = self
        table.delegate = self
        let scroll = scrollWrap(table)

        buildStyleHint()

        empty.translatesAutoresizingMaskIntoConstraints = false
        for v in [bar, styleHint, scroll, empty] as [NSView] { root.addSubview(v) }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            styleHint.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),
            styleHint.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            styleHint.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: styleHint.bottomAnchor, constant: 8),
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

    /// macOS'ta dugmeler yalniz UYARI biciminde dogrudan gorunur.
    ///
    /// Serit biciminde kullanicinin bildirimin uzerine gelip genisletme
    /// okuna basmasi gerekiyor — "Yanıtla"yi bulmak zor. Bunu uygulama
    /// degistiremez (kullanici ayari), ama tek tikla dogru sayfaya
    /// goturebiliriz.
    private func buildStyleHint() {
        styleHint.orientation = .horizontal
        styleHint.alignment = .centerY
        styleHint.spacing = 8
        styleHint.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        styleHint.translatesAutoresizingMaskIntoConstraints = false
        styleHint.wantsLayer = true
        styleHint.layer?.cornerRadius = 8
        styleHint.layer?.backgroundColor = NSColor.controlAccentColor
            .withAlphaComponent(0.10).cgColor
        styleHint.isHidden = true

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "rectangle.badge.checkmark",
                             accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        icon.contentTintColor = .controlAccentColor

        let text = NSTextField(labelWithString: L(
            "Yanıtla ve diğer düğmeler doğrudan görünsün mü? macOS’ta AndrOS bildirim biçimini “Uyarılar” yap.",
            "Want Reply and the other buttons visible right away? Set AndrOS’s notification style to “Alerts” in macOS."))
        text.font = .systemFont(ofSize: 11)
        text.lineBreakMode = .byTruncatingTail

        let open = NSButton(title: L("Ayarları aç", "Open Settings"), target: self,
                            action: #selector(openNotificationSettings))
        open.bezelStyle = .rounded
        open.font = .systemFont(ofSize: 11)

        let hide = NSButton(title: "", target: self, action: #selector(dismissStyleHint))
        hide.bezelStyle = .inline
        hide.isBordered = false
        hide.image = NSImage(systemSymbolName: "xmark", accessibilityDescription:
                                L("Gizle", "Hide"))?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
        hide.contentTintColor = .secondaryLabelColor

        for v in [icon, text, flexSpacer(), open, hide] { styleHint.addArrangedSubview(v) }
    }

    @objc private func openNotificationSettings() { Notify.openSystemSettings() }

    @objc private func dismissStyleHint() {
        UserDefaults.standard.set(true, forKey: "hideAlertStyleHint")
        styleHint.isHidden = true
    }

    private func refreshStyleHint() {
        guard !UserDefaults.standard.bool(forKey: "hideAlertStyleHint") else {
            styleHint.isHidden = true; return
        }
        Notify.isAlertStyle { [weak self] isAlert in
            self?.styleHint.isHidden = isAlert
        }
    }

    func didAppear() {
        refreshStyleHint()
        if !refreshObserverInstalled {
            refreshObserverInstalled = true
            for name in [Notification.Name.androsRefresh, .androsNotificationsChanged] {
                NotificationCenter.default.addObserver(
                    forName: name, object: nil, queue: .main) { [weak self] _ in
                    guard let self, !self.view.isHiddenOrHasHiddenAncestor else { return }
                    UserBusy.run { [weak self] in self?.load() }
                }
            }
        }
        load()
    }

    private func load() {
        guard !isLoading else { return }
        guard let d = data else { return }
        isLoading = true
        spinner.startAnimation(nil)
        DispatchQueue.global().async { [weak self] in
            let (l, h) = d.notifications()
            let ready = d.companion?.isReady == true
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLoading = false
                self.spinner.stopAnimation(nil)
                // EN YENI EN USTTE. Android'in verdigi sira ekrandaki
                // yerlesim sirasi; zaman sirasi degil.
                // Telefonda kapatilan bildirim Mac'te asili kalmasin.
                let stillLive = Set(l.map(\.key))
                for old in self.live where !stillLive.contains(old.key) {
                    Notify.withdraw(old.key)
                }
                self.live = l.sorted { $0.date > $1.date }
                // Gecmiste, hala ekranda duranlari tekrar gosterme.
                let liveKeys = Set(l.map(\.key))
                self.history = h.filter { !liveKeys.contains($0.key) }
                    .sorted { $0.date > $1.date }
                self.rebuild(appReady: ready)
            }
        }
    }

    private func rebuild(appReady: Bool? = nil) {
        let q = search.text.trimmingCharacters(in: .whitespaces).lowercased()
        func match(_ n: AndroidData.PhoneNotification) -> Bool {
            SearchMatch.matchesAny(q, [n.app, n.title, n.text])
        }
        let l = live.filter(match), h = history.filter(match)
        rows = []
        if !l.isEmpty {
            rows.append(.header(L("Şimdi", "Now")))
            rows += l.map { .item($0, historic: false) }
        }
        if !h.isEmpty {
            rows.append(.header(L("Geçmiş", "Earlier")))
            rows += h.map { .item($0, historic: true) }
        }
        table.reloadData()

        if rows.isEmpty {
            let ready = appReady ?? (data?.companion?.isReady == true)
            if !ready {
                empty.show(L("AndrOS mobil uygulaması gerekli", "AndrOS mobile app required"),
                           L("Bildirimler yalnız uygulama üzerinden gelir. "
                           + "Cihazlar’dan telefonu eşleştir.",
                             "Notifications only arrive through the app. "
                           + "Pair the phone in Devices."),
                           symbol: "bell.slash")
            } else {
                empty.show(L("Bildirim yok", "No notifications"),
                           L("Telefona bildirim geldiğinde burada ve macOS "
                           + "bildirim merkezinde görünür.",
                             "When the phone gets a notification it shows up here "
                           + "and in macOS Notification Center."),
                           symbol: "bell")
            }
        } else { empty.isHidden = true }
    }

    @objc private func clearAll() {
        guard let d = data else { return }
        // Mac'teki banner'lar da kalksin: telefonda kapatilan bir sey
        // bildirim merkezinde asili kalmasin.
        for n in live { Notify.withdraw(n.key) }
        DispatchQueue.global().async { [weak self] in
            d.dismissAllNotifications()
            DispatchQueue.main.async { self?.load() }
        }
    }

    // MARK: - Tablo

    func numberOfRows(in t: NSTableView) -> Int { rows.count }

    func tableView(_ t: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        DeviceRowView()
    }

    func tableView(_ t: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < rows.count else { return 56 }
        if case .header = rows[row] { return 26 }
        if case .item(let n, _) = rows[row], n.key == replyingKey { return 92 }
        return 56
    }

    func tableView(_ t: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let l = NSTextField(labelWithString: title.uppercased())
            l.font = .systemFont(ofSize: 10, weight: .semibold)
            l.textColor = .tertiaryLabelColor
            let s = NSStackView(views: [l])
            s.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 2, right: 10)
            return s

        case .item(let n, let historic):
            let av = AvatarView()
            av.initial = String(n.app.prefix(1)).uppercased()
            av.seed = n.package.hashValue
            av.translatesAutoresizingMaskIntoConstraints = false
            av.widthAnchor.constraint(equalToConstant: 30).isActive = true
            av.heightAnchor.constraint(equalToConstant: 30).isActive = true

            let fmt = DateFormatter(); fmt.dateFormat = "d MMM HH:mm"
            let head = NSTextField(labelWithString:
                n.app + "  ·  " + fmt.string(from: n.date))
            head.font = .systemFont(ofSize: 10)
            head.textColor = .tertiaryLabelColor

            let title = NSTextField(labelWithString: n.title.isEmpty ? n.text : n.title)
            title.font = .systemFont(ofSize: 13, weight: .medium)
            title.lineBreakMode = .byTruncatingTail

            let body = NSTextField(labelWithString: n.title.isEmpty ? "" : n.text)
            body.font = .systemFont(ofSize: 11)
            body.textColor = .secondaryLabelColor
            body.lineBreakMode = .byTruncatingTail

            let texts = NSStackView(views: [head, title, body])
            texts.orientation = .vertical
            texts.alignment = .leading
            texts.spacing = 0
            texts.setContentHuggingPriority(.init(250), for: .horizontal)
            if historic { texts.alphaValue = 0.6 }

            let spacer = NSView()
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)

            if let until = Notify.mutedUntil(n.package) {
                let f = DateFormatter()
                f.dateFormat = until.timeIntervalSinceNow > 86_400 * 365 ? "" : "HH:mm"
                let when = f.dateFormat.isEmpty ? L("süresiz", "indefinitely")
                                                : L("\(f.string(from: until))'e kadar",
                                                    "until \(f.string(from: until))")
                let tag = NSTextField(labelWithString: "🔕 " + when)
                tag.font = .systemFont(ofSize: 9)
                tag.textColor = .tertiaryLabelColor
                tag.toolTip = L("Mac'te susturuldu; telefonda bildirim gelmeye devam eder",
                                "Muted on this Mac; the phone still receives it")
                texts.addArrangedSubview(tag)
            }

            var views: [NSView] = [av, texts, spacer]
            // Yalniz EKRANDA duranlarin eylemleri calisir; gecmistekiler
            // sistemden silindigi icin eylem gonderilemez.
            if !historic {
                // TUM dugmeler: bildirim kac eylem tasiyorsa hepsi.
                // Panelde yer var, kirpmaya gerek yok.
                for a in n.actions {
                    let b = NSButton(title: a.title, target: self,
                                     action: a.reply ? #selector(beginReply(_:))
                                                     : #selector(runAction(_:)))
                    b.bezelStyle = .rounded
                    b.font = .systemFont(ofSize: 11)
                    b.identifier = NSUserInterfaceItemIdentifier("\(n.key)|\(a.index)")
                    views.append(b)
                }
                if n.clearable {
                    let x = iconButton("checkmark", L("Okundu işaretle", "Mark as read"),
                                       #selector(dismissOne(_:)), n.key)
                    views.append(x)
                }
                let muted = Notify.mutedUntil(n.package) != nil
                let mute = iconButton(
                    muted ? "bell.slash.fill" : "bell",
                    muted ? L("Susturmayı kaldır", "Unmute")
                          : L("\(n.app) bildirimlerini sustur…", "Mute \(n.app)…"),
                    #selector(toggleMute(_:)), n.package)
                views.append(mute)
            }

            let top = NSStackView(views: views)
            top.orientation = .horizontal
            top.spacing = 6
            top.distribution = .fill

            // Yanit kutusu ACIKKEN satirin altinda yazma alani.
            guard n.key == replyingKey,
                  let a = n.actions.first(where: { $0.reply }) else {
                top.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 10)
                return top
            }
            let field = NSTextField()
            field.placeholderString = L("Yanıt yaz…", "Write a reply…")
            field.font = .systemFont(ofSize: 12)
            field.target = self
            field.action = #selector(sendReply(_:))
            field.identifier = NSUserInterfaceItemIdentifier("\(n.key)|\(a.index)")
            let send = NSButton(title: L("Gönder", "Send"), target: self,
                                action: #selector(sendReply(_:)))
            send.bezelStyle = .rounded
            send.keyEquivalent = "\r"
            send.identifier = field.identifier
            let cancel = iconButton("xmark", L("Vazgeç", "Cancel"),
                                    #selector(cancelReply), "")
            let replyRow = NSStackView(views: [field, send, cancel])
            replyRow.orientation = .horizontal
            replyRow.spacing = 6

            let stack = NSStackView(views: [top, replyRow])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 6
            stack.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 6, right: 10)
            field.widthAnchor.constraint(equalToConstant: 320).isActive = true
            DispatchQueue.main.async { [weak self] in
                self?.view.window?.makeFirstResponder(field)
            }
            return stack
        }
    }

    func tableView(_ t: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .header = rows[row] { return false }
        return true
    }

    // MARK: - Eylemler

    /// "Okundu isaretle" = telefonda da kapat. Android'de ayri bir
    /// "okundu" kavrami yok; bildirimi dusurmek tam karsiligi.
    @objc private func dismissOne(_ s: NSButton) {
        guard let key = s.identifier?.rawValue, let d = data else { return }
        Notify.shared.markActed(key)
        Notify.withdraw(key)          // Mac'teki banner da kalksin
        DispatchQueue.global().async { [weak self] in
            d.dismissNotification(key)
            DispatchQueue.main.async { self?.load() }
        }
    }

    @objc private func runAction(_ s: NSButton) {
        guard let p = parse(s.identifier?.rawValue), let d = data else { return }
        Notify.shared.markActed(p.key)
        DispatchQueue.global().async { [weak self] in
            let ok = d.runNotificationAction(p.key, index: p.index)
            DispatchQueue.main.async {
                if !ok {
                    self?.showToast(L("Eylem çalıştırılamadı — bildirim telefonda kapanmış olabilir.",
                                      "Could not run the action — it may be gone on the phone."))
                }
                self?.load()
            }
        }
    }

    /// Kisa bilgi satiri (acilir pencere degil).
    private func showToast(_ text: String) {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .systemOrange
        l.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(l)
        NSLayoutConstraint.activate([
            l.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            l.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
        ])
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { l.removeFromSuperview() }
    }

    /// Dugme kimliginden (anahtar, eylem sirasi) cikarir.
    ///
    /// ANAHTARIN ICINDE "|" VAR: Android bildirim anahtarlari
    /// "0|com.whatsapp|1|null|10123" bicimde. Bastan bolunce parca
    /// sayisi ikiyi asiyor ve dugmeler SESSIZCE hicbir sey yapmiyordu.
    /// Son ayiricidan boluyoruz.
    private func parse(_ id: String?) -> (key: String, index: Int)? {
        guard let id, let cut = id.lastIndex(of: "|") else { return nil }
        guard let idx = Int(id[id.index(after: cut)...]) else { return nil }
        return (String(id[id.startIndex..<cut]), idx)
    }

    /// Kucuk ikon dugmesi (okundu, sustur, vazgec).
    private func iconButton(_ symbol: String, _ tip: String,
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
        return b
    }

    /// Yanit kutusunu SATIR ICINDE acar — acilir pencere yok.
    @objc private func beginReply(_ s: NSButton) {
        guard let p = parse(s.identifier?.rawValue) else { return }
        replyingKey = p.key
        table.reloadData()
    }

    @objc private func cancelReply() {
        replyingKey = nil
        table.reloadData()
    }

    @objc private func sendReply(_ s: NSControl) {
        guard let p = parse(s.identifier?.rawValue), let d = data else { return }
        let key = p.key, idx = p.index
        // Metin ya kutunun kendisinden ya da yanindaki dugmeden geliyor.
        let text: String
        if let f = s as? NSTextField { text = f.stringValue }
        else if let f = s.superview?.subviews.compactMap({ $0 as? NSTextField }).first {
            text = f.stringValue
        } else { text = "" }
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        replyingKey = nil
        table.reloadData()
        // Yanit sonrasi uygulama kendi bildirimini guncelliyor; bu
        // ayni bildirimin Mac'te geri gelmesi demek. Kisa sessizlik.
        Notify.shared.markActed(key)
        Notify.withdraw(key)
        DispatchQueue.global().async { [weak self] in
            let ok = d.runNotificationAction(key, index: idx, text: text)
            DispatchQueue.main.async {
                if !ok {
                    let a = NSAlert()
                    a.messageText = L("Yanıt gönderilemedi", "Could not send the reply")
                    a.informativeText = L("Bildirim telefonda kapanmış olabilir.",
                                          "The notification may have been dismissed on the phone.")
                    a.runModal()
                }
                self?.load()
            }
        }
    }

    /// Susturma SURELI. "Sustur" deyip kalici susturmak kullaniciyi
    /// sasirtiyor; secenekleri acikca veriyoruz. Telefon etkilenmiyor —
    /// bildirim gelmeye devam eder, yalniz Mac'te banner cikmaz.
    @objc private func toggleMute(_ s: NSButton) {
        guard let pkg = s.identifier?.rawValue, !pkg.isEmpty else { return }
        let m = NSMenu()
        if Notify.mutedUntil(pkg) != nil {
            let i = NSMenuItem(title: L("Susturmayı kaldır", "Unmute"),
                               action: #selector(unmute(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = pkg
            m.addItem(i)
        } else {
            for (title, hours) in [(L("1 saat sustur", "Mute for 1 hour"), 1.0),
                                   (L("8 saat sustur", "Mute for 8 hours"), 8.0),
                                   (L("Yarına kadar sustur", "Mute until tomorrow"), 24.0)] {
                let i = NSMenuItem(title: title, action: #selector(muteFor(_:)),
                                   keyEquivalent: "")
                i.target = self
                i.representedObject = "\(pkg)|\(hours)"
                m.addItem(i)
            }
            m.addItem(.separator())
            let f = NSMenuItem(title: L("Süresiz sustur", "Mute indefinitely"),
                               action: #selector(muteForever(_:)), keyEquivalent: "")
            f.target = self
            f.representedObject = pkg
            m.addItem(f)
        }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: s.bounds.height), in: s)
    }

    @objc private func muteFor(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        let parts = raw.split(separator: "|")
        guard parts.count == 2, let h = Double(parts[1]) else { return }
        Notify.mute(String(parts[0]), hours: h)
        table.reloadData()
    }

    @objc private func muteForever(_ sender: NSMenuItem) {
        guard let pkg = sender.representedObject as? String else { return }
        Notify.muteForever(pkg)
        table.reloadData()
    }

    @objc private func unmute(_ sender: NSMenuItem) {
        guard let pkg = sender.representedObject as? String else { return }
        Notify.mute(pkg, until: nil)
        table.reloadData()
    }
}
