import AppKit
import AndrOSCore

/// Solda sohbetler, sagda mesajlar. Okuma adb ile calisiyor;
/// GONDERME icin shell'in SEND_SMS izni yok, o yuzden mesaj telefonun
/// mesaj uygulamasinda hazir aciliyor (companion app gelince dogrudan gidecek).
final class MessagesPanel: NSViewController, AndrOSPanel,
                           NSTableViewDataSource, NSTableViewDelegate {
    var data: AndroidData?

    private var conversations: [AndroidData.Conversation] = []
    private var filtered: [AndroidData.Conversation] = []
    private let list = NSTableView()
    private let search = SearchToggle()
    private let thread = NSStackView()
    private let threadScroll: NSScrollView
    private let composeField = NSTextField()
    private let sendButton = NSButton()
    private let threadTitle = NSTextField(labelWithString: L("Bir sohbet seç", "Select a conversation"))
    private var selected: AndroidData.Conversation?
    private let spinner = NSProgressIndicator()

    override init(nibName: NSNib.Name?, bundle: Bundle?) {
        thread.orientation = .vertical
        thread.alignment = .leading
        thread.spacing = 6
        thread.translatesAutoresizingMaskIntoConstraints = false
        threadScroll = scrollWrap(thread)
        super.init(nibName: nibName, bundle: bundle)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()

        // Aramalar panelinden "mesaj yaz" gelince o kisiyle sohbeti ac;
        // sohbet yoksa numarayi yaz kutusuna hazirla.
        NotificationCenter.default.addObserver(
            forName: .androsOpenConversation, object: nil, queue: .main) { [weak self] n in
            guard let self, let number = n.object as? String else { return }
            self.openConversation(with: number)
        }

        // Sol sutun
        search.placeholder = L("Sohbet, mesaj ara", "Search conversations and messages")
        search.onChange = { [weak self] _ in self?.filterChanged() }
        let col = NSTableColumn(identifier: .init("c"))
        col.width = 260
        list.addTableColumn(col)
        list.headerView = nil
        list.style = .fullWidth
        list.intercellSpacing = NSSize(width: 0, height: 4)
        list.backgroundColor = .clear
        list.allowsEmptySelection = true
        list.rowHeight = 56
        list.dataSource = self
        list.delegate = self
        let listScroll = scrollWrap(list)

        let searchRow = NSStackView(views: [flexSpacer(), search])
        searchRow.orientation = .horizontal
        let left = NSStackView(views: [searchRow, listScroll])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 8
        searchRow.translatesAutoresizingMaskIntoConstraints = false
        searchRow.widthAnchor.constraint(equalTo: left.widthAnchor).isActive = true
        left.translatesAutoresizingMaskIntoConstraints = false
        listScroll.widthAnchor.constraint(equalTo: left.widthAnchor).isActive = true

        // Sag sutun
        threadTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        composeField.placeholderString = L("Mesaj yaz…", "Write a message…")
        composeField.font = .systemFont(ofSize: 12)
        sendButton.title = L("Gönder", "Send")
        sendButton.bezelStyle = .rounded
        sendButton.target = self
        sendButton.action = #selector(send)
        sendButton.toolTip = L("Mesaj telefonun mesaj uygulamasında hazır açılır", "The message opens prefilled in the phone's messaging app")

        let compose = NSStackView(views: [composeField, sendButton])
        compose.orientation = .horizontal
        compose.spacing = 8
        compose.translatesAutoresizingMaskIntoConstraints = false
        composeField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let head = NSStackView(views: [threadTitle, spinner])
        head.orientation = .horizontal
        head.spacing = 8

        let right = NSStackView(views: [head, threadScroll, compose])
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 8
        right.translatesAutoresizingMaskIntoConstraints = false
        threadScroll.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
        compose.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true

        root.addSubview(left)
        root.addSubview(right)
        NSLayoutConstraint.activate([
            left.topAnchor.constraint(equalTo: root.topAnchor),
            left.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            left.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            left.widthAnchor.constraint(equalToConstant: 260),

            right.topAnchor.constraint(equalTo: root.topAnchor),
            right.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: 16),
            right.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            right.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            thread.widthAnchor.constraint(equalTo: threadScroll.widthAnchor, constant: -20),
        ])
        view = root
    }

    func didAppear() {
        guard let d = data, conversations.isEmpty else { return }
        spinner.startAnimation(nil)
        DispatchQueue.global().async { [weak self] in
            let contacts = d.contactsPreferringApp()
            let convs = d.conversationsPreferringApp(contacts: contacts)
            DispatchQueue.main.async {
                guard let self else { return }
                self.spinner.stopAnimation(nil)
                self.conversations = convs
                self.filterChanged()
                if !convs.isEmpty {
                    self.list.selectRowIndexes([0], byExtendingSelection: false)
                }
            }
        }
    }

    /// Numaraya ait sohbeti secer; yoksa yeni sohbet olarak hazirlar.
    private func openConversation(with number: String) {
        let key = number.filter(\.isNumber).suffix(9)
        if let i = filtered.firstIndex(where: {
            $0.address.filter(\.isNumber).suffix(9) == key
        }) {
            list.selectRowIndexes([i], byExtendingSelection: false)
            list.scrollRowToVisible(i)
            selected = filtered[i]
            showThread(filtered[i])
        } else {
            // Sifirdan sohbet: baslik numarayla, gonderime hazir.
            selected = AndroidData.Conversation(threadID: "new:\(number)",
                                                address: number,
                                                displayName: nil, messages: [])
            threadTitle.stringValue = number
            thread.arrangedSubviews.forEach { $0.removeFromSuperview() }
        }
        view.window?.makeFirstResponder(composeField)
    }

    @objc private func filterChanged() {
        let q = search.text.trimmingCharacters(in: .whitespaces).lowercased()
        filtered = conversations.filter {
            SearchMatch.matchesAny(q, [$0.title, $0.last?.body ?? ""])
        }
        list.reloadData()
        if filtered.isEmpty {
            emptyState().show(
                conversations.isEmpty ? L("Sohbet yok", "No conversations")
                                      : L("Eşleşen sohbet yok", "No matching conversation"),
                conversations.isEmpty
                    ? L("Telefon bağlandığında SMS sohbetleri burada listelenir.",
                        "SMS conversations appear here once a phone is connected.")
                    : L("Aramayı değiştir ya da temizle.", "Change or clear the search."),
                symbol: "message")
        } else { emptyState().isHidden = true }
    }

    @objc private func send() {
        let text = composeField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let c = selected, let d = data else { return }
        composeField.isEnabled = false
        DispatchQueue.global().async { [weak self] in
            // Uygulama eslesmisse GERCEKTEN gonderiyoruz. adb kabugunun
            // SEND_SMS izni yok; o yolda mesaj yalniz telefonun kendi
            // uygulamasinda hazir aciliyor.
            var err: String?
            if d.companion?.isReady == true {
                err = d.sendSMS(to: c.address, body: text)
            } else {
                let escaped = text.replacingOccurrences(of: "'", with: "'\\''")
                _ = try? d.adb.run(["shell", "am", "start", "-a",
                                    "android.intent.action.SENDTO",
                                    "-d", "sms:\(c.address)",
                                    "--es", "sms_body", "'\(escaped)'"])
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.composeField.isEnabled = true
                if let err {
                    // Cekirdek katman dil bilmiyor: ANAHTAR yolluyor.
                    let a = NSAlert()
                    a.messageText = L("Mesaj gönderilemedi", "Could not send")
                    a.informativeText = err == "notpaired"
                        ? L("Önce AndrOS mobil uygulamasını eşleştir.",
                            "Pair the AndrOS mobile app first.")
                        : L("Telefon mesajı gönderemedi. Numara ve sinyali kontrol et.",
                            "The phone could not send it. Check the number and signal.")
                    a.runModal()
                } else {
                    self.composeField.stringValue = ""
                    self.reloadThread()
                }
            }
        }
    }

    /// Gonderimden sonra sohbeti tazele.
    private func reloadThread() {
        guard let c = selected else { return }
        DispatchQueue.global().async { [weak self] in
            guard let d = self?.data else { return }
            let convs = d.conversationsPreferringApp()
            DispatchQueue.main.async {
                guard let self else { return }
                if let fresh = convs.first(where: { $0.threadID == c.threadID }) {
                    self.selected = fresh
                    self.showThread(fresh)
                }
            }
        }
    }

    // MARK: - Tablolar

    /// Yuvarlak kose vurgu — tum listelerde ayni dil.
    func tableView(_ t: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        DeviceRowView()
    }

    func numberOfRows(in t: NSTableView) -> Int { filtered.count }

    func tableView(_ t: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let c = filtered[row]
        let title = NSTextField(labelWithString: c.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail

        let preview = NSTextField(labelWithString:
            (c.last?.body ?? "").replacingOccurrences(of: "\n", with: " "))
        preview.font = .systemFont(ofSize: 11)
        preview.textColor = .secondaryLabelColor
        preview.lineBreakMode = .byTruncatingTail
        preview.maximumNumberOfLines = 2

        let s = NSStackView(views: [title, preview])
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 2
        s.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        return s
    }

    func tableViewSelectionDidChange(_ n: Notification) {
        let r = list.selectedRow
        guard r >= 0, r < filtered.count else { return }
        selected = filtered[r]
        showThread(filtered[r])
    }

    private func showThread(_ c: AndroidData.Conversation) {
        threadTitle.stringValue = c.title + "  ·  " + c.address
        thread.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let fmt = DateFormatter()
        fmt.dateFormat = "d MMM HH:mm"

        for m in c.messages.suffix(200) {
            let bubble = NSTextField(wrappingLabelWithString: m.body)
            bubble.font = .systemFont(ofSize: 12)
            bubble.textColor = m.incoming ? .labelColor : .white
            bubble.drawsBackground = false
            bubble.preferredMaxLayoutWidth = 420

            let box = NSView()
            box.wantsLayer = true
            box.layer?.cornerRadius = 12
            if #available(macOS 10.15, *) { box.layer?.cornerCurve = .continuous }
            box.layer?.backgroundColor = m.incoming
                ? NSColor.labelColor.withAlphaComponent(0.08).cgColor
                : NSColor.controlAccentColor.cgColor
            bubble.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(bubble)
            NSLayoutConstraint.activate([
                bubble.topAnchor.constraint(equalTo: box.topAnchor, constant: 8),
                bubble.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -8),
                bubble.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
                bubble.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
                box.widthAnchor.constraint(lessThanOrEqualToConstant: 450),
            ])

            let time = NSTextField(labelWithString: fmt.string(from: m.date))
            time.font = .systemFont(ofSize: 9)
            time.textColor = .tertiaryLabelColor

            let cell = NSStackView(views: m.incoming ? [box, time] : [time, box])
            cell.orientation = .vertical
            cell.alignment = m.incoming ? .leading : .trailing
            cell.spacing = 2
            cell.translatesAutoresizingMaskIntoConstraints = false

            let holder = NSStackView(views: m.incoming ? [cell, NSView()] : [NSView(), cell])
            holder.orientation = .horizontal
            holder.translatesAutoresizingMaskIntoConstraints = false
            // SIRALAMA: once hiyerarsiye ekle, SONRA kisiti etkinlestir.
            // Tersi olursa ortak ust view bulunamiyor ve Auto Layout
            // istisna atip uygulamayi dusuruyor.
            thread.addArrangedSubview(holder)
            holder.widthAnchor.constraint(equalTo: thread.widthAnchor).isActive = true
        }
        // Sohbet EN SON mesajda acilsin — mesajlasma uygulamalarinin
        // beklenen davranisi bu. Yerlesim bir tur sonra oturdugu icin
        // hem simdi hem de bir sonraki dongude kaydiriyoruz; ilkinde
        // yukseklik henuz kesin degil.
        scrollThreadToBottom()
        DispatchQueue.main.async { [weak self] in self?.scrollThreadToBottom() }
    }

    private func scrollThreadToBottom() {
        threadScroll.layoutSubtreeIfNeeded()
        let docH = max(thread.fittingSize.height, thread.bounds.height)
        let visH = threadScroll.contentView.bounds.height
        threadScroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, docH - visH)))
        threadScroll.reflectScrolledClipView(threadScroll.contentView)
    }
}
