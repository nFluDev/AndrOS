import AppKit

/// Yan panel eylemleri. Ham `id` UserDefaults'ta saklanir.
enum SidebarAction: String, CaseIterable {
    case back, home, recents, notifications, screenshot, rotate
    case joystick, volumeUp, volumeDown, power, screenOff, fullscreen, flipSide, settings
    case disconnect, macro

    var symbol: String {
        switch self {
        case .back:          return "chevron.backward"
        case .home:          return "circle"
        case .recents:       return "square.on.square"
        case .notifications: return "bell"
        case .screenshot:    return "camera"
        case .rotate:        return "rotate.right"
        case .joystick:      return "gamecontroller"
        case .volumeUp:      return "speaker.wave.2"
        case .volumeDown:    return "speaker.wave.1"
        case .power:         return "power"
        case .screenOff:     return "moon"
        case .fullscreen:    return "arrow.up.left.and.arrow.down.right"
        case .flipSide:      return "arrow.left.arrow.right"
        case .settings:      return "gearshape"
        case .disconnect:    return "xmark.circle"
        case .macro:         return "record.circle"
        }
    }

    var title: String {
        switch self {
        case .back:          return L("Geri", "Back")
        case .home:          return L("Ana ekran", "Home Screen")
        case .recents:       return L("Görev görünümü", "Recent Apps")
        case .notifications: return L("Bildirim paneli", "Notification Shade")
        case .screenshot:    return L("Ekran görüntüsü", "Screenshot")
        case .rotate:        return L("Döndür", "Rotate")
        case .joystick:      return L("Tuş haritalama", "Key Mapping")
        case .volumeUp:      return L("Ses +", "Volume Up")
        case .volumeDown:    return L("Ses −", "Volume Down")
        case .power:         return L("Güç tuşu", "Power Button")
        case .screenOff:     return L("Telefon ekranı", "Phone Screen")
        case .fullscreen:    return L("Tam ekran", "Full Screen")
        case .flipSide:      return L("Tarafı değiştir", "Flip Panel Side")
        case .settings:      return L("Ayarlar", "Settings")
        case .disconnect:    return L("Yayını kapat (telefonu uyandırır)",
                                      "Stop Mirroring (wakes the phone)")
        case .macro:         return L("Makrolar", "Macros")
        }
    }

    /// Acik/kapali durumu olan dugmeler (isaretli gosterilir).
    var isToggle: Bool { self == .joystick || self == .screenOff || self == .macro }

    /// Panelin EN USTUNE sabitlenenler (ortadaki yigindan bagimsiz).
    static let topPinned: [SidebarAction] = [.flipSide]
    /// Panelin EN ALTINA sabitlenenler.
    static let bottomPinned: [SidebarAction] = [.settings, .disconnect]

    /// Sabitlenmis dugmeler de bu listede OLMALI, yoksa
    /// topPinnedVisible/bottomPinnedVisible filtreleri onlari bulamaz
    /// ve dugme hic gorunmez.
    static let defaultOrder: [SidebarAction] = [
        .flipSide,
        .joystick, .macro, .screenshot, .rotate, .notifications,
        .recents, .home, .back, .volumeUp, .volumeDown,
        .screenOff, .fullscreen,
        .settings, .disconnect,
    ]
}

/// BlueStacks tarzi dikey arac cubugu.
/// Yuzen panel: kendi yuvarlak koseleri, bulanik zemin, kenarlarda bosluk.
final class SidebarView: NSView {

    /// Panelin kapladigi toplam genislik (bosluklar dahil).
    static let width: CGFloat = 54
    static let inset: CGFloat = 6

    var onAction: ((SidebarAction) -> Void)?
    var onRightClick: ((SidebarAction) -> Void)?
    var visibleActions: [SidebarAction] = SidebarAction.defaultOrder { didSet { rebuild() } }

    /// Uygulama yolu (adb'siz) etkin mi? Uc dugme orada BASKA is
    /// yapiyor ve ipucu metni yaniltmasin diye burada degisiyor.
    var appMode = false { didSet { if appMode != oldValue { rebuild() } } }

    static func appTitle(_ a: SidebarAction) -> String {
        switch a {
        case .power:
            return L("Hızlı ayarlar", "Quick settings")
        case .screenOff:
            return L("Telefon ekranını karart (yansıtma sürer)",
                     "Dim the phone screen (mirroring continues)")
        case .screenshot:
            return L("Ekran görüntüsünü panoya kopyala",
                     "Copy screenshot to the clipboard")
        case .disconnect:
            return L("Yansıtmayı kapat", "Stop mirroring")
        case .rotate:
            return L("Otomatik döndürmeyi aç/kapa", "Toggle auto-rotate")
        default:
            return a.title
        }
    }
    var toggleStates: [SidebarAction: Bool] = [:] { didSet { refreshStates() } }

    private var buttons: [SidebarAction: HoverButton] = [:]
    private let stack = NSStackView()
    private let topStack = NSStackView()
    private let bottomStack = NSStackView()
    private let panel = NSVisualEffectView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        // Zemin: koyu, hafif saydam, kendi yuvarlak koseleri.
        panel.material = .hudWindow
        panel.blendingMode = .withinWindow
        panel.state = .active
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 14
        if #available(macOS 10.15, *) { panel.layer?.cornerCurve = .continuous }
        panel.layer?.masksToBounds = true
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.10).cgColor
        // Semboller acik renk kalsin diye panel her zaman koyu temada.
        panel.appearance = NSAppearance(named: .darkAqua)
        addSubview(panel)

        for st in [topStack, stack, bottomStack] {
            st.orientation = .vertical
            st.alignment = .centerX
            st.spacing = 8            // 5'ten 8'e: dugmeler artik hic degmiyor
            st.translatesAutoresizingMaskIntoConstraints = false
            panel.addSubview(st)
            NSLayoutConstraint.activate([
                st.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
                st.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            ])
        }
        // Ortadaki yigin ortalanir AMA sabitlenmis bolgelerin uzerine BINEMEZ.
        // Pencere kucuklunce eskiden ic ice giriyorlardi; asagidaki >= / <=
        // kisitlari ortalamadan daha yuksek oncelikli oldugu icin engelliyor.
        let centerY = stack.centerYAnchor.constraint(equalTo: panel.centerYAnchor)
        centerY.priority = .defaultLow
        NSLayoutConstraint.activate([
            // "Tarafi degistir" panelin GERCEK ustunde, ortadaki yigindan bagimsiz
            topStack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 8),
            bottomStack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -8),
            centerY,
            stack.topAnchor.constraint(greaterThanOrEqualTo: topStack.bottomAnchor, constant: 8),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomStack.topAnchor, constant: -8),
        ])
        rebuild()
    }

    /// Panel artik yer yetmezse KAYDIRILIYOR, bu yuzden pencereye yukseklik
    /// dayatmiyor. Eskiden dayatiyordu ve yatay goruntude pencere gereginden
    /// yuksek olup yanlarda siyah bosluk birakiyordu.
    var requiredHeight: CGFloat { 120 }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        panel.frame = bounds.insetBy(dx: SidebarView.inset, dy: SidebarView.inset)
    }

    private func makeButton(_ a: SidebarAction,
                            _ cfg: NSImage.SymbolConfiguration) -> HoverButton {
        let b = HoverButton()
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.imagePosition = .imageOnly
        b.image = NSImage(systemSymbolName: a.symbol, accessibilityDescription: a.title)?
            .withSymbolConfiguration(cfg)
        b.toolTip = appMode ? SidebarView.appTitle(a) : a.title
        b.target = self
        b.action = #selector(tapped(_:))
        b.onRightClick = { [weak self] in self?.onRightClick?(a) }
        b.identifier = NSUserInterfaceItemIdentifier(a.rawValue)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 36).isActive = true
        b.heightAnchor.constraint(equalToConstant: 34).isActive = true
        buttons[a] = b
        return b
    }

    private func rebuild() {
        [topStack, stack, bottomStack].forEach { st in
            st.arrangedSubviews.forEach { $0.removeFromSuperview() }
        }
        buttons.removeAll()
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        // Uygulama yolunda KARSILIGI OLMAYANLARI gostermiyoruz: tus
        // haritalama ve makrolar scrcpy denetim kanalinin olay bicimine
        // bagli, orada calismiyor. Calismayan dugme gostermek, dugmeyi
        // hic gostermemekten kotu.
        let list = appMode
            ? visibleActions.filter { $0 != .joystick && $0 != .macro }
            : visibleActions

        for a in SidebarView.topPinnedVisible(list) {
            topStack.addArrangedSubview(makeButton(a, cfg))
        }
        for a in SidebarView.bottomPinnedVisible(list) {
            bottomStack.addArrangedSubview(makeButton(a, cfg))
        }
        for a in list where !SidebarAction.topPinned.contains(a)
                         && !SidebarAction.bottomPinned.contains(a) {
            stack.addArrangedSubview(makeButton(a, cfg))
        }
        refreshStates()
    }

    static func topPinnedVisible(_ v: [SidebarAction]) -> [SidebarAction] {
        SidebarAction.topPinned.filter { v.contains($0) }
    }
    static func bottomPinnedVisible(_ v: [SidebarAction]) -> [SidebarAction] {
        SidebarAction.bottomPinned.filter { v.contains($0) }
    }

    private func refreshStates() {
        for (a, b) in buttons {
            let on = a.isToggle && (toggleStates[a] ?? false)
            // ACIK RENK: koyu zeminde secilebilsin. secondaryLabelColor
            // acik temada koyu griye donusup kayboluyordu.
            b.baseTint = on ? NSColor.systemGreen
                            : NSColor(calibratedWhite: 0.92, alpha: 1)
            b.isActive = on
            b.refresh()
        }
    }

    @objc private func tapped(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let a = SidebarAction(rawValue: id) else { return }
        onAction?(a)
    }
}

/// Uzerine gelince belirginlesen, basilinca geri bildirim veren dugme.
final class HoverButton: NSButton {
    var baseTint: NSColor = .white
    var isActive = false
    var onRightClick: (() -> Void)?
    private var hovering = false
    private var pressed = false
    private var trackingAreaRef: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingAreaRef { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeInKeyWindow],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingAreaRef = t
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; refresh() }
    override func mouseExited(with event: NSEvent)  { hovering = false; refresh() }

    /// Sadece durum degisince cagrilir. Onceki surumde draw() icinde
    /// cagriliyordu; her yeniden cizimde katman ozelligi set edilince
    /// gereksiz is birikiyor ve dugmeler gec tepki veriyordu.
    func refresh() {
        wantsLayer = true
        contentTintColor = (hovering || pressed) ? .white : baseTint
        layer?.cornerRadius = 8
        if #available(macOS 10.15, *) { layer?.cornerCurve = .continuous }
        let bg: NSColor
        if pressed       { bg = NSColor(calibratedWhite: 1, alpha: 0.26) }
        else if isActive { bg = NSColor.systemGreen.withAlphaComponent(0.22) }
        else if hovering { bg = NSColor(calibratedWhite: 1, alpha: 0.14) }
        else             { bg = .clear }
        layer?.backgroundColor = bg.cgColor
    }

    /// Eylemi mouseDown'da tetikle: mouseUp'i beklemek gecikme hissi veriyordu.
    override func mouseDown(with event: NSEvent) {
        pressed = true; refresh()
        if let t = target, let a = action { _ = t.perform(a, with: self) }
    }
    override func mouseUp(with event: NSEvent) {
        pressed = false; refresh()
    }
    override func rightMouseDown(with event: NSEvent) { onRightClick?() }
}
