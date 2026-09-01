import AppKit
import AndrOSCore

/// Menu cubugunda MINI OYNATICI.
///
/// Muzik ya da video calarken menu cubugunda kucuk bir simge ve parca
/// adi duruyor; tiklayinca kontroller aciliyor. Uygulama penceresi
/// kapaliyken de calani gormek ve durdurmak gerekiyor — pencereyi
/// acmak icin bir sebep olmamali.
final class PlayerStatusItem {

    static let shared = PlayerStatusItem()
    private init() {}

    private var item: NSStatusItem?
    private let host = PopoverHost()

    /// Menu cubugunda gorunen en fazla karakter.
    ///
    /// Tam ad menu cubugunun ucte birini yiyordu. Kisa bir pencere
    /// gosterip metni KAYDIRIYORUZ: yer kaplamadan tam ad okunuyor.
    private let visibleChars = 6
    private var scrollOffset = 0
    private var scrollTimer: Timer?
    private var fullTitle = ""


    var onOpenApp: (() -> Void)?

    /// Ayara ve calma durumuna gore goster/gizle.
    func sync() {
        let wanted = UserDefaults.standard.object(forKey: "mbPlayer") as? Bool ?? true
        let playing = (NowPlaying.shared.title?.isEmpty == false)
        if wanted && playing { show() } else { hide() }
        refreshTitle()
    }

    private func show() {
        guard item == nil else { return }
        let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        it.button?.imagePosition = .imageLeading
        // ESIT GENISLIKLI yazi tipi: orantili yazida her kaydirmada
        // pencere genisligi degisiyor ve simge saga sola ziplıyordu.
        // Monospace ile 12 karakter her zaman ayni yeri kapliyor.
        it.button?.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        it.button?.target = self
        it.button?.action = #selector(toggle)
        item = it
    }

    private func hide() {
        scrollTimer?.invalidate(); scrollTimer = nil
        fullTitle = ""
        guard let it = item else { return }
        NSStatusBar.system.removeStatusItem(it)
        item = nil
    }

    private func refreshTitle() {
        guard let b = item?.button else { return }
        let np = NowPlaying.shared
        b.image = NSImage(systemSymbolName: np.isPlaying ? "play.circle.fill"
                                                         : "pause.circle.fill",
                          accessibilityDescription: L("Oynatıcı", "Player"))
        b.image?.isTemplate = true

        let t = np.title ?? ""
        if t != fullTitle {
            fullTitle = t
            scrollOffset = 0
            b.toolTip = t
        }
        startScrollIfNeeded()
        drawTitle()
        if host.isShown { PlayerPanel.shared.refresh() }
    }

    /// Ad kisaysa oldugu gibi; uzunsa dongusel kayar.
    ///
    /// Kayma AYARA bagli: hareket eden bir menu cubugu herkesin isine
    /// gelmiyor. Kapaliyken ad kirpilip "…" ile bitiyor.
    private func startScrollIfNeeded() {
        let animate = UserDefaults.standard.object(forKey: "mbAnimate") as? Bool ?? true
        let needs = animate && fullTitle.count > visibleChars
        if !needs {
            scrollTimer?.invalidate(); scrollTimer = nil
            scrollOffset = 0
            return
        }
        guard scrollTimer == nil else { return }
        let t = Timer(timeInterval: 0.28, repeats: true) { [weak self] _ in
            guard let self, self.item != nil else { return }
            self.scrollOffset += 1
            self.drawTitle()
        }
        RunLoop.main.add(t, forMode: .common)
        scrollTimer = t
    }

    private func drawTitle() {
        guard let b = item?.button else { return }
        let animate = UserDefaults.standard.object(forKey: "mbAnimate") as? Bool ?? true
        if !animate, fullTitle.count > visibleChars {
            b.title = " " + String(fullTitle.prefix(visibleChars - 1)) + "…"
            return
        }
        guard fullTitle.count > visibleChars else {
            // Kisa adlarda da SABIT genislik: sonu bosluklarla dolduruyoruz.
            let padded = fullTitle.padding(toLength: visibleChars,
                                           withPad: " ", startingAt: 0)
            b.title = fullTitle.isEmpty ? "" : " " + padded
            return
        }
        // Ucundan basa donerken bir bosluk birakiyoruz ki kelimeler
        // birbirine yapismasin.
        let loop = Array(fullTitle + "   ")
        let start = scrollOffset % loop.count
        var window = ""
        for i in 0..<visibleChars { window.append(loop[(start + i) % loop.count]) }
        b.title = " " + window
    }

    @objc private func toggle() {
        guard let b = item?.button else { return }
        let p = PlayerPanel.shared
        p.onOpenApp = { [weak self] in self?.host.close(); self?.onOpenApp?() }
        p.refresh()
        host.toggle(p, from: b)
    }
}

/// Menu cubugu oynaticisinin acilir paneli.
final class PlayerPanel: NSViewController {

    static let shared = PlayerPanel()

    var onOpenApp: (() -> Void)?

    private let art = NSImageView()
    private let name = MarqueeLabel()
    private let sub = MarqueeLabel()
    private let scrub = NSSlider()
    private let elapsed = NSTextField(labelWithString: "0:00")
    private let total = NSTextField(labelWithString: "0:00")
    private let playButton = NSButton()
    private let width: CGFloat = 280

    override func loadView() {
        let root = NSView()

        art.wantsLayer = true
        art.layer?.cornerRadius = 8
        art.layer?.masksToBounds = true
        art.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        art.imageScaling = .scaleProportionallyUpOrDown
        art.translatesAutoresizingMaskIntoConstraints = false
        art.widthAnchor.constraint(equalToConstant: 38).isActive = true
        art.heightAnchor.constraint(equalToConstant: 38).isActive = true

        name.font = .systemFont(ofSize: 13, weight: .semibold)
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = .secondaryLabelColor
        // Uzun adlar kesilmesin, KAYSIN — uygulamadaki seritle ayni his.
        for l in [name, sub] {
            l.translatesAutoresizingMaskIntoConstraints = false
            l.heightAnchor.constraint(equalToConstant: l === name ? 16 : 13).isActive = true
            l.widthAnchor.constraint(equalToConstant: width - 38 - 10).isActive = true
        }

        let texts = NSStackView(views: [name, sub])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1

        let top = NSStackView(views: [art, texts])
        top.orientation = .horizontal
        top.alignment = .centerY
        top.spacing = 10

        scrub.minValue = 0; scrub.maxValue = 1
        scrub.controlSize = .small
        scrub.target = self; scrub.action = #selector(seek)

        for l in [elapsed, total] {
            l.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            l.textColor = .tertiaryLabelColor
        }
        let times = NSStackView(views: [elapsed, scrub, total])
        times.orientation = .horizontal
        times.alignment = .centerY
        times.spacing = 6

        let prev = iconButton("backward.fill", #selector(previous))
        playButton.image = icon("play.fill")
        playButton.isBordered = false
        playButton.target = self; playButton.action = #selector(playPause)
        let next = iconButton("forward.fill", #selector(nextTrack))

        // Kontroller TAM GENISLIK ve esit dagilimda: sola sikismis
        // simgeler hem zor tiklaniyor hem panelin geri kalaniyla
        // hizasiz duruyordu. Carpi KALDIRILDI — bir ise yaramiyordu.
        let controls = NSStackView(views: [prev, playButton, next])
        controls.orientation = .horizontal
        controls.distribution = .fillEqually
        controls.spacing = 0

        // Ayri bir "ac" dugmesi yok: KAPAK ya da ISIM tiklanabilir.
        // Panelde yer kazandiriyor ve zaten beklenen davranis bu.
        let click = NSClickGestureRecognizer(target: self, action: #selector(openApp))
        top.addGestureRecognizer(click)
        top.toolTip = L("AndrOS'ta aç", "Open in AndrOS")

        let stack = NSStackView(views: [top, times, controls])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        let pad: CGFloat = 10
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: pad),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: pad),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -pad),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -pad),
            stack.widthAnchor.constraint(equalToConstant: width),
            times.widthAnchor.constraint(equalToConstant: width),
            top.widthAnchor.constraint(equalToConstant: width),
            controls.widthAnchor.constraint(equalToConstant: width),
        ])
        view = root
    }

    private func icon(_ n: String) -> NSImage? {
        NSImage(systemSymbolName: n, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
    }

    private func iconButton(_ n: String, _ sel: Selector) -> NSButton {
        let b = NSButton(title: "", target: self, action: sel)
        b.isBordered = false
        b.image = icon(n)
        return b
    }

    func refresh() {
        let np = NowPlaying.shared
        name.text = np.title ?? L("Bir şey çalmıyor", "Nothing playing")
        sub.text = np.subtitle
        art.image = np.artwork ?? NSImage(systemSymbolName: "music.note",
                                          accessibilityDescription: nil)
        playButton.image = icon(np.isPlaying ? "pause.fill" : "play.fill")
        let d = np.duration
        scrub.doubleValue = d > 0 ? np.currentTime / d : 0
        elapsed.stringValue = time(np.currentTime)
        total.stringValue = time(d)
    }

    private func time(_ t: TimeInterval) -> String {
        guard t.isFinite, t > 0 else { return "0:00" }
        return String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }

    @objc private func playPause() { NowPlaying.shared.togglePlay(); refresh() }
    @objc private func previous()  { NowPlaying.shared.previous(); refresh() }
    @objc private func nextTrack() { NowPlaying.shared.next(); refresh() }
    @objc private func seek() {
        NowPlaying.shared.seek(to: scrub.doubleValue * NowPlaying.shared.duration)
    }
    @objc private func openApp() { onOpenApp?() }
}
