import AppKit
import AndrOSCore

/// Yan panelin EN ALTINDA sabit duran serit:
///  - ustte devam eden aktarimlar (ilerleme, duraklat/devam, iptal, +n kuyruk)
///  - altta mini oynatici (kapak, isim, geri/oynat/ileri)
///
/// Muzik/video panelden cikilinca susmuyor; buradan kontrol ediliyor.
/// Isme ya da kapaga tiklayinca Muzik paneline donuluyor.
final class BottomDock: NSView {

    var onExpand: (() -> Void)?
    var onPrev: (() -> Void)?
    var onNext: (() -> Void)?
    var onPlayPause: (() -> Void)?
    var onSeek: ((Double) -> Void)?
    /// Serit uzerindeki kapatma dugmesi.
    var onStop: (() -> Void)?

    private let transfersBox = NSStackView()
    private let playerBox = NSStackView()
    private let art = NSImageView()
    private let title = MarqueeLabel()
    private let subtitle = MarqueeLabel()
    private let playButton = NSButton()
    private let prevButton = NSButton()
    private let nextButton = NSButton()
    /// Caliani birak. Video artik panelden bagimsiz calmaya devam ettigi
    /// icin onu KAPATACAK bir yer gerekiyor; muzikte de ise yariyor.
    private let stopButton = NSButton()
    private let progress = NSSlider()
    /// Kullanici kaydiraci tutuyorsa disaridan gelen guncelleme onu ITMESIN.
    private var scrubbing = false

    private var collapsed = false
    private var historyPopover: NSPopover?
    /// Dugme olculeri kisitla tutuluyor: daraltilmis seritte (62 px is
    /// gorur alan) dort dugme sigmiyor, tasan dugmeler EBEVEYN SINIRININ
    /// disinda kaldigi icin TIKLANAMIYORDU. "Daraltinca dugmeler
    /// calismiyor" bunun sonucuydu.
    private var buttonSize: [NSLayoutConstraint] = []
    /// Kapatma dugmesi yalniz videoda anlamli (muzigin kendi paneli var).
    private var showStop = false
    /// Serit icerigi: daraltip genisletince kaybolmasin diye saklaniyor.
    private var last: (title: String?, subtitle: String, art: NSImage?,
                       playing: Bool, progress: Double)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        // --- Aktarimlar
        transfersBox.orientation = .vertical
        transfersBox.alignment = .leading
        transfersBox.spacing = 4
        transfersBox.translatesAutoresizingMaskIntoConstraints = false
        transfersBox.isHidden = true

        // --- Mini oynatici
        art.wantsLayer = true
        art.layer?.cornerRadius = 5
        art.layer?.masksToBounds = true
        art.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.10).cgColor
        art.imageScaling = .scaleProportionallyUpOrDown
        art.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)
        art.contentTintColor = .tertiaryLabelColor
        art.translatesAutoresizingMaskIntoConstraints = false
        art.widthAnchor.constraint(equalToConstant: 34).isActive = true
        art.heightAnchor.constraint(equalToConstant: 34).isActive = true

        title.font = .systemFont(ofSize: 11, weight: .medium)
        subtitle.font = .systemFont(ofSize: 9)
        subtitle.textColor = .secondaryLabelColor
        for l in [title, subtitle] {
            l.translatesAutoresizingMaskIntoConstraints = false
            l.heightAnchor.constraint(equalToConstant: l === title ? 14 : 12).isActive = true
            // SABIT genislik: uzun isim kontrolleri ezmesin (tasma kapali).
            l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            l.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }

        // Cubuk yerine kaydirac: buradan da saniye degistirilebiliyor.
        progress.minValue = 0
        progress.maxValue = 1
        progress.controlSize = .mini
        progress.target = self
        progress.action = #selector(scrubbed)
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.heightAnchor.constraint(equalToConstant: 12).isActive = true

        let texts = NSStackView(views: [title, subtitle, progress])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1
        texts.translatesAutoresizingMaskIntoConstraints = false
        progress.widthAnchor.constraint(equalTo: texts.widthAnchor).isActive = true

        prevButton.image = icon("backward.fill")
        prevButton.isBordered = false
        prevButton.target = self; prevButton.action = #selector(prev)
        playButton.image = icon("play.fill")
        playButton.isBordered = false
        playButton.target = self; playButton.action = #selector(playPause)
        nextButton.image = icon("forward.fill")
        nextButton.isBordered = false
        nextButton.target = self; nextButton.action = #selector(next)
        stopButton.image = icon("xmark")
        stopButton.isBordered = false
        stopButton.contentTintColor = .tertiaryLabelColor
        stopButton.toolTip = L("Kapat", "Close")
        stopButton.target = self; stopButton.action = #selector(stopTapped)

        let controls = NSStackView(views: [prevButton, playButton, nextButton, stopButton])
        controls.orientation = .horizontal
        controls.spacing = 2
        for b in [prevButton, playButton, nextButton, stopButton] {
            b.translatesAutoresizingMaskIntoConstraints = false
            let w = b.widthAnchor.constraint(equalToConstant: 20)
            let h = b.heightAnchor.constraint(equalToConstant: 20)
            w.isActive = true; h.isActive = true
            buttonSize.append(w)
        }

        playerBox.orientation = .horizontal
        playerBox.alignment = .centerY
        playerBox.spacing = 8
        playerBox.translatesAutoresizingMaskIntoConstraints = false
        playerBox.addArrangedSubview(art)
        playerBox.addArrangedSubview(texts)
        playerBox.addArrangedSubview(controls)
        playerBox.isHidden = true

        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false

        addSubview(sep)
        addSubview(transfersBox)
        addSubview(playerBox)
        NSLayoutConstraint.activate([
            sep.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            sep.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            sep.topAnchor.constraint(equalTo: topAnchor),
            transfersBox.topAnchor.constraint(equalTo: sep.bottomAnchor, constant: 8),
            transfersBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            transfersBox.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            playerBox.topAnchor.constraint(equalTo: transfersBox.bottomAnchor, constant: 8),
            playerBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            playerBox.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            playerBox.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])

        // Isme/kapaga tiklayinca panele don (dugmeler haric)
        let click = NSClickGestureRecognizer(target: self, action: #selector(expand))
        texts.addGestureRecognizer(click)
        let click2 = NSClickGestureRecognizer(target: self, action: #selector(expand))
        art.addGestureRecognizer(click2)

        TransferQueue.shared.onChange = { [weak self] in self?.refreshTransfers() }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func icon(_ n: String) -> NSImage? {
        NSImage(systemSymbolName: n, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
    }

    @objc private func expand()    { onExpand?() }
    @objc private func prev()      { onPrev?() }
    @objc private func next()      { onNext?() }
    @objc private func playPause() { onPlayPause?() }
    @objc private func stopTapped() { onStop?() }

    @objc private func scrubbed() {
        scrubbing = true
        onSeek?(progress.doubleValue)
        // Kisa bir sure disaridan gelen degeri yok say: geri ziplamasin.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.scrubbing = false
        }
    }

    /// Daraltilmis panelde de geri/oynat/ileri CALISIR.
    ///
    /// Daralinca serit 62 px'e iniyor; dort dugme oraya sigmadigi icin
    /// tasip tiklanamaz hale geliyordu. Burada dugmeler kuculuyor ve
    /// kapatma dugmesi geciciyor — kalan ucu 58 px'e sigiyor.
    func setCollapsed(_ c: Bool) {
        collapsed = c
        // Daraltilinca: kapak ve alt bilgi gizlenir ama SARKI ADI
        // dugmelerin USTUNDE kalir (kaydirarak tam okunur).
        title.isHidden = false
        subtitle.isHidden = c
        progress.isHidden = c
        art.isHidden = c
        prevButton.isHidden = false
        nextButton.isHidden = false
        stopButton.isHidden = c || !showStop
        for w in buttonSize { w.constant = c ? 18 : 20 }
        playerBox.orientation = c ? .vertical : .horizontal
        playerBox.alignment = c ? .centerX : .centerY
        playerBox.spacing = c ? 4 : 8
        title.font = .systemFont(ofSize: c ? 9 : 11, weight: .medium)
        // Icerigi GERI KOY: daraltip genisletince serit bosalmasin.
        if let l = last {
            updatePlayer(title: l.title, subtitle: l.subtitle, artwork: l.art,
                         playing: l.playing, progressValue: l.progress,
                         canStop: showStop)
        }
        refreshTransfers()
    }

    // MARK: - Oynatici durumu

    func updatePlayer(title t: String?, subtitle s: String,
                      artwork: NSImage?, playing: Bool, progressValue: Double,
                      canStop: Bool = false) {
        showStop = canStop
        stopButton.isHidden = collapsed || !canStop
        last = (t, s, artwork, playing, progressValue)
        guard let t, !t.isEmpty else { playerBox.isHidden = true; return }
        playerBox.isHidden = false
        title.text = t
        subtitle.text = s
        if !scrubbing { progress.doubleValue = progressValue }
        playButton.image = icon(playing ? "pause.fill" : "play.fill")
        if let a = artwork {
            art.image = a
            art.contentTintColor = nil
        } else {
            art.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)
            art.contentTintColor = .tertiaryLabelColor
        }
    }

    func hidePlayer() { playerBox.isHidden = true }

    // MARK: - Aktarimlar

    private func refreshTransfers() {
        transfersBox.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let all = TransferQueue.shared.snapshot
        let live = all.filter { $0.state == .running || $0.state == .paused }
        let queued = all.filter { $0.state == .waiting }
        let finished = all.filter { $0.state == .done || $0.state == .cancelled
                                                     || $0.state == .failed }
        guard !live.isEmpty || !queued.isEmpty || !finished.isEmpty else {
            transfersBox.isHidden = true
            return
        }
        transfersBox.isHidden = false

        if collapsed {
            // Yalniz IKON: onay / ret / iptal ve devam eden sayisi.
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 3
            if !live.isEmpty || !queued.isEmpty {
                let s = NSProgressIndicator()
                s.style = .spinning; s.controlSize = .small
                s.startAnimation(nil)
                s.translatesAutoresizingMaskIntoConstraints = false
                s.widthAnchor.constraint(equalToConstant: 13).isActive = true
                row.addArrangedSubview(s)
                let n = NSTextField(labelWithString: "\(live.count + queued.count)")
                n.font = .systemFont(ofSize: 9); n.textColor = .secondaryLabelColor
                row.addArrangedSubview(n)
            } else if let last = finished.last {
                row.addArrangedSubview(statusIcon(last))
            }
            let b = NSButton()
            b.isBordered = false
            b.image = NSImage(systemSymbolName: "clock.arrow.circlepath",
                              accessibilityDescription: L("Geçmiş", "History"))?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
            b.target = self; b.action = #selector(showHistory)
            row.addArrangedSubview(b)
            transfersBox.addArrangedSubview(row)
            return
        }

        for it in live.prefix(2) { transfersBox.addArrangedSubview(row(for: it)) }
        if !queued.isEmpty {
            let more = NSTextField(labelWithString: L("+\(queued.count) sırada", "+\(queued.count) queued"))
            more.font = .systemFont(ofSize: 9)
            more.textColor = .tertiaryLabelColor
            transfersBox.addArrangedSubview(more)
        }
        // SON ISLEM her zaman gorunur — devam eden olmasa bile.
        if live.isEmpty, queued.isEmpty, let last = finished.last {
            let name = NSTextField(labelWithString: last.name)
            name.font = .systemFont(ofSize: 9)
            name.textColor = .tertiaryLabelColor
            name.lineBreakMode = .byTruncatingMiddle
            let hist = NSButton()
            hist.isBordered = false
            hist.image = NSImage(systemSymbolName: "clock.arrow.circlepath",
                                 accessibilityDescription: L("Geçmiş", "History"))?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
            hist.contentTintColor = .tertiaryLabelColor
            hist.target = self; hist.action = #selector(showHistory)
            let r = NSStackView(views: [statusIcon(last), name, NSView(), hist])
            r.orientation = .horizontal
            r.spacing = 5
            r.translatesAutoresizingMaskIntoConstraints = false
            transfersBox.addArrangedSubview(r)
            r.widthAnchor.constraint(equalTo: transfersBox.widthAnchor).isActive = true
        } else if !finished.isEmpty {
            let b = NSButton()
            b.isBordered = false
            b.image = NSImage(systemSymbolName: "clock.arrow.circlepath",
                              accessibilityDescription: L("Geçmiş", "History"))?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
            b.contentTintColor = .tertiaryLabelColor
            b.target = self; b.action = #selector(showHistory)
            transfersBox.addArrangedSubview(b)
        }
    }

    /// Durum ikonu: onay / ret / iptal.
    private func statusIcon(_ it: TransferQueue.Item) -> NSImageView {
        let v = NSImageView()
        let sym: String, color: NSColor
        switch it.state {
        case .done:      sym = "checkmark.circle.fill"; color = .systemGreen
        case .cancelled: sym = "minus.circle.fill";     color = .systemGray
        default:         sym = "xmark.circle.fill";     color = .systemRed
        }
        v.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        v.contentTintColor = color
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 13).isActive = true
        v.toolTip = it.name
        return v
    }

    /// Tamamlanan/iptal/basarisiz aktarimlari yan pencere gibi acar.
    @objc private func showHistory() {
        historyPopover?.close()
        let all = TransferQueue.shared.snapshot.filter {
            $0.state == .done || $0.state == .cancelled || $0.state == .failed
        }.reversed()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let t = NSTextField(labelWithString: L("Aktarım geçmişi", "Transfer history"))
        t.font = .boldSystemFont(ofSize: 12)
        stack.addArrangedSubview(t)

        for it in all.prefix(60) {
            let sym: String, color: NSColor, note: String
            switch it.state {
            case .done:      sym = "checkmark.circle.fill"; color = .systemGreen; note = L("tamamlandı", "done")
            case .cancelled: sym = "xmark.circle.fill";     color = .systemOrange; note = "iptal edildi"
            default:         sym = "exclamationmark.circle.fill"; color = .systemRed; note = L("başarısız", "failed")
            }
            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
            icon.contentTintColor = color
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.widthAnchor.constraint(equalToConstant: 17).isActive = true

            let arrow = NSImageView()
            arrow.image = NSImage(systemSymbolName:
                it.direction == .download ? "arrow.down" : "arrow.up",
                accessibilityDescription: nil)
            arrow.contentTintColor = .tertiaryLabelColor
            arrow.translatesAutoresizingMaskIntoConstraints = false
            arrow.widthAnchor.constraint(equalToConstant: 10).isActive = true

            let name = NSTextField(labelWithString: it.name)
            name.font = .systemFont(ofSize: 12)
            name.lineBreakMode = .byTruncatingMiddle
            let st = NSTextField(labelWithString: note)
            st.font = .systemFont(ofSize: 10)
            st.textColor = .tertiaryLabelColor

            let row = NSStackView(views: [icon, arrow, name, NSView(), st])
            row.orientation = .horizontal
            row.spacing = 6
            row.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        }

        let clear = NSButton(title: L("Geçmişi temizle", "Clear history"), target: self,
                             action: #selector(clearHistory))
        clear.bezelStyle = .rounded
        stack.addArrangedSubview(clear)

        let scroll = NSScrollView()
        let doc = NSView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            doc.widthAnchor.constraint(equalToConstant: 420),
        ])
        scroll.documentView = doc
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let vc = NSViewController()
        // Daha ferah: satirlar 26px, en fazla 440px yukseklik.
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 420,
                                        height: min(CGFloat(all.count) * 26 + 96, 440)))
        scroll.frame = host.bounds
        scroll.autoresizingMask = [.width, .height]
        host.addSubview(scroll)
        vc.view = host

        let pop = NSPopover()
        pop.contentViewController = vc
        pop.behavior = .transient
        pop.show(relativeTo: transfersBox.bounds, of: transfersBox, preferredEdge: .maxX)
        historyPopover = pop
    }

    @objc private func clearHistory() {
        TransferQueue.shared.clearFinished()
        historyPopover?.close()
    }

    private func row(for it: TransferQueue.Item) -> NSView {
        let arrow = NSImageView()
        arrow.image = NSImage(systemSymbolName:
            it.direction == .download ? "arrow.down.circle" : "arrow.up.circle",
            accessibilityDescription: nil)
        arrow.contentTintColor = .secondaryLabelColor
        arrow.translatesAutoresizingMaskIntoConstraints = false
        arrow.widthAnchor.constraint(equalToConstant: 13).isActive = true

        let name = NSTextField(labelWithString: it.name)
        name.font = .systemFont(ofSize: 9)
        name.lineBreakMode = .byTruncatingMiddle
        name.textColor = .secondaryLabelColor

        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = it.progress == 0
        bar.minValue = 0; bar.maxValue = 100
        bar.doubleValue = Double(it.progress)
        bar.controlSize = .small
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.heightAnchor.constraint(equalToConstant: 3).isActive = true
        if bar.isIndeterminate { bar.startAnimation(nil) }

        let pause = NSButton()
        pause.isBordered = false
        pause.image = NSImage(systemSymbolName: it.state == .paused ? "play.fill" : "pause.fill",
                              accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
        pause.target = self
        pause.action = #selector(togglePause(_:))
        pause.identifier = NSUserInterfaceItemIdentifier(it.id.uuidString)

        let stop = NSButton()
        stop.isBordered = false
        stop.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
        stop.target = self
        stop.action = #selector(cancelItem(_:))
        stop.identifier = NSUserInterfaceItemIdentifier(it.id.uuidString)

        let top = NSStackView(views: [arrow, name, pause, stop])
        top.orientation = .horizontal
        top.spacing = 4

        let col = NSStackView(views: [top, bar])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 2
        col.translatesAutoresizingMaskIntoConstraints = false
        bar.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        top.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        return col
    }

    @objc private func togglePause(_ s: NSButton) {
        guard let id = s.identifier.flatMap({ UUID(uuidString: $0.rawValue) }),
              let it = TransferQueue.shared.snapshot.first(where: { $0.id == id }) else { return }
        if it.state == .paused { TransferQueue.shared.resume(id) }
        else { TransferQueue.shared.pause(id) }
    }

    @objc private func cancelItem(_ s: NSButton) {
        guard let id = s.identifier.flatMap({ UUID(uuidString: $0.rawValue) }) else { return }
        TransferQueue.shared.cancel(id)
    }
}
