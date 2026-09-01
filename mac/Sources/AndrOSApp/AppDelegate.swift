import AppKit
import Carbon.HIToolbox
import AndrOSCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem?
    private let session = MirrorSession()
    private var window: NSWindow?
    private var view: MetalView?
    private var content: MirrorContentView?

    // Yan panel tercihleri
    private var sidebarOnRight = UserDefaults.standard.object(forKey: "sidebarRight") as? Bool ?? true
    private var sidebarVisible = UserDefaults.standard.object(forKey: "sidebarVisible") as? Bool ?? true
    private var enabledActions: [SidebarAction] = {
        if let raw = UserDefaults.standard.array(forKey: "sidebarActions") as? [String] {
            let parsed = raw.compactMap { SidebarAction(rawValue: $0) }
            if !parsed.isEmpty { return parsed }
        }
        return SidebarAction.defaultOrder
    }()
    private var settingsPopover: NSPopover?
    private var editorToolbar: NSPanel?
    private var showGuide = UserDefaults.standard.bool(forKey: "showGuide")
    private let macroEngine = MacroEngine()
    private var macroWC: MacroWindowController?
    private var main: MainWindowController?
    private var deviceTimer: Timer?
    /// Eslestirilmis telefona kalici baglanti — paneller bunun uzerinden
    /// calisiyor (arama gecmisi, SMS gonderme, uygulama adlari…).
    private let companionBrowser = CompanionBrowser.shared
    /// "Cihaz" menusu — acilirken guncel listeyle dolduruluyor.
    private weak var deviceMenu: NSMenu?
    /// Menuyu doldurmak icin son bilinen birlesik cihaz listesi.
    private var unifiedDevices: [UnifiedDevice] = []
    private let companionStore = CompanionStore()
    private var companionLinks: [String: CompanionLink] = [:]
    private var companionDevices: [CompanionDevice] = []
    /// Goruntu ana pencereye gomulu mu? Gomuluyken ayri ayna penceresi
    /// gosterilmemeli — yoksa bos bir pencere daha ortaya cikiyor.
    private var mirrorEmbedded = false
    private var statusMenuItem: NSMenuItem?
    private var connectItem: NSMenuItem?
    private var autoItem: NSMenuItem?
    private var screenItem: NSMenuItem?
    private var topItem: NSMenuItem?

    // Ayarlar (UserDefaults'ta kalici)
    private var bitRate = UserDefaults.standard.object(forKey: "bitRate") as? Int ?? 24_000_000
    private var maxFPS  = UserDefaults.standard.object(forKey: "maxFPS")  as? Int ?? 60
    // Artik varsayilan GORUNUR: kullanici dock'tan/Cmd+Tab'den odaklanabilsin.
    /// Dock'ta ve ⌘Tab'de GORUNMESIN (varsayilan).
    ///
    /// AndrOS bir menu cubugu uygulamasi: pencereyi kapatinca arka
    /// planda calismaya devam ediyor. Dock'ta durursa "kapattim ama hala
    /// aciik" hissi veriyor ve ⌘Tab'i sisiriyor. Isteyen ayarlardan
    /// geri acabiliyor.
    /// Dock ve ⌘Tab, PENCERE DURUMUNU izliyor.
    ///
    /// Windows'taki gibi: ana pencere aciksa uygulama Dock'ta ve
    /// ⌘Tab'de — oraya gecebilmek gerekiyor. Kirmizi dugmeyle pencereyi
    /// kapatinca ikisinden de kalkiyor, cunku artik gecilecek bir sey
    /// yok; uygulama menu cubugunda yasamaya devam ediyor.
    ///
    /// Bunu bir AYAR yapmak yanlisti: kullanicinin istedigi sey durum
    /// degil davranis.
    func syncActivationPolicy() {
        let visible = NSApp.windows.contains { w in
            guard w.isVisible, !w.isMiniaturized else { return false }
            // Popover ve durum penceresi sayilmaz; yalnizca gercek
            // pencereler Dock'a girmeyi hak ediyor.
            return w.styleMask.contains(.titled) && w.canBecomeMain
        }
        let want: NSApplication.ActivationPolicy = visible ? .regular : .accessory
        guard NSApp.activationPolicy() != want else { return }
        // Politika degisince AppKit acik pencereleri arka plana atiyor;
        // gorunur olanlari not alip sonra geri getiriyoruz.
        let wasVisible = NSApp.windows.filter { $0.isVisible && !$0.isMiniaturized }
        NSApp.setActivationPolicy(want)
        if want == .regular {
            DispatchQueue.main.async {
                for w in wasVisible { w.orderFront(nil) }
                wasVisible.last?.makeKey()
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    private var autoConnect = UserDefaults.standard.object(forKey: "autoConnect") as? Bool ?? true
    private var screenOff = UserDefaults.standard.object(forKey: "screenOff") as? Bool ?? true
    // Varsayilan KAPALI: acik oldugunda diger pencereleri kapatiyor ve
    // arka plandakiler one getirilemiyor. Yerine global kisayol var.
    private var alwaysOnTop = UserDefaults.standard.object(forKey: "alwaysOnTop") as? Bool ?? false
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyRef2: EventHotKeyRef?
    private var signalSources: [DispatchSourceSignal] = []
    private var smoothItem: NSMenuItem?
    private var clipItem: NSMenuItem?
    private var audioItem: NSMenuItem?
    private var audioOn = UserDefaults.standard.object(forKey: "audioOn") as? Bool ?? true
    private var clipboardSync = UserDefaults.standard.object(forKey: "clipboardSync") as? Bool ?? true
    private var smoothing = UserDefaults.standard.object(forKey: "smoothing") as? Bool ?? true

    /// Kullanici Finder/Launchpad'den zaten calisan uygulamayi tekrar acinca
    /// cagrilir. Dock ikonu olmadigi icin bu olmadan "hicbir sey olmuyor".
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool {
        focusWindow()
        return true
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        // Ayni bundle id'den baska bir ornek varsa onu one getir, kendini kapat.
        // Aksi halde iki ornek ayni porta/sunucuya yarisir ve ikisi de sessizce coker.
        let me = NSRunningApplication.current
        let others = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? "dev.naer.andros")
            .filter { $0.processIdentifier != me.processIdentifier }
        if let other = others.first {
            Log.write("zaten calisan ornek var (pid \(other.processIdentifier)), one getirilip cikiliyor")
            other.activate(options: [.activateAllWindows])
            NSApp.terminate(nil)
            return
        }
        // Varsayilan: dock'ta HIC gorunme, yalniz menu cubugunda tek simge.
        // Baslangicta pencere yok: menu cubugu kipi.
        NSApp.setActivationPolicy(.accessory)
        buildMainMenu()
        buildStatusItem()
        registerHotKey()
        installSignalHandlers()
        refreshTogglesSoon()
        restoreParams()
        session.turnScreenOff = screenOff
        session.smoothing = smoothing
        session.clipboard.enabled = clipboardSync
        session.clipboard.onRecord = { text in ClipboardPanel.record(text) }
        NotificationCenter.default.addObserver(
            forName: .androsRequestPhoneClipboard, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if case .running = self.session.state {
                self.session.sendRaw(ControlMessage.getClipboard())
            } else {
                self.alert(title: L("Yansıtma kapalı", "Mirroring is off"),
                           body: L("Telefonun panosunu okumak için önce yansıtmayı başlat. "
                             + "Android 10+ arka planda pano okumaya izin vermiyor.",
                               "Start mirroring first to read the phone's clipboard. "
                             + "Android 10+ does not allow background clipboard reads."))
            }
        }
        session.audioEnabled = audioOn

        session.onStateChange = { [weak self] s in self?.updateUI(s) }
        session.onSize = { [weak self] w, h in
            self?.resizeWindow(w, h)

        }
        session.onWarning = { [weak self] title, body in
            self?.alert(title: title, body: body)
        }
        session.onNeedsRestartForAudio = { [weak self] in
            guard let self else { return }
            // Kisa bir yeniden baglanma: ses soketi ancak sunucu baslarken kurulur.
            self.session.stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self else { return }
                self.session.start(bitRate: self.bitRate, maxFPS: self.maxFPS,
                                   forceFullRange: false)
            }
        }
        session.onStatus = { [weak self] text in
            guard let self else { return }
            self.statusMenuItem?.title = text
            let waitingUnlock = text.contains("kilid")
            self.statusItem?.button?.contentTintColor = waitingUnlock ? .systemOrange : nil
            if waitingUnlock {
                self.content?.status.show(
                    title: L("Kilit açılıyor", "Unlocking"),
                    detail: L("PIN'ini bu pencereden girebilirsin.", "You can type your PIN in this window."),
                    symbol: "lock.open.iphone", busy: true)
                self.showWindowNow()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .androsDevicesListed, object: nil, queue: .main) { [weak self] n in
            self?.unifiedDevices = n.object as? [UnifiedDevice] ?? []
        }
        // Elle "yeniden baglan": kullanici uygulamayi kapatip acmak
        // zorunda kalmasin.
        NotificationCenter.default.addObserver(
            forName: .androsReconnectRequested, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Log.write("elle yeniden bağlanma istendi")
            // Once bulmayi tazele, sonra kopmus baglantilari kur.
            self.companionBrowser.stop()
            self.companionBrowser.start()
            for (id, l) in self.companionLinks where l.state != .ready {
                l.disconnect()
                self.companionLinks.removeValue(forKey: id)
            }
            self.connectPairedCompanions()
            self.refreshDevices()
        }

        // Ayar degisince menu cubugu ogeleri hemen uysun.
        NotificationCenter.default.addObserver(
            forName: .androsSettingsChanged, object: nil, queue: .main) { _ in
            let wantCam = UserDefaults.standard.object(forKey: "mbCamera") as? Bool ?? true
            if !wantCam { CameraStatusItem.shared.hide() }
            else if CameraBridge.shared.state == .on { CameraStatusItem.shared.show() }
            PlayerStatusItem.shared.sync()
        }

        // Menu cubugu oynaticisi: calan degisince gorunsun/gizlensin.
        PlayerStatusItem.shared.onOpenApp = { [weak self] in
            self?.main?.showWindow(nil)
            self?.main?.select(NowPlaying.shared.kind == .video ? .gallery : .music)
        }
        NowPlaying.shared.addObserver("menubar") {
            PlayerStatusItem.shared.sync()
        }
        MusicEngine.shared.addObserver("menubar") {
            PlayerStatusItem.shared.sync()
        }

        scheduleUpdateCheck()
        Notify.shared.setup()
        // macOS bildirim merkezindeki dugmeler GERCEKTEN calissin:
        // banner uzerinden yazilan yanit telefona gidiyor, "okundu"
        // bildirimi telefonda da kapatiyor.
        Notify.shared.onReply = { [weak self] key, index, text in
            guard let d = self?.currentData else { return }
            DispatchQueue.global().async { d.runNotificationAction(key, index: index, text: text) }
        }
        Notify.shared.onAction = { [weak self] key, index in
            guard let d = self?.currentData else { return }
            DispatchQueue.global().async { d.runNotificationAction(key, index: index) }
        }
        Notify.shared.onMarkRead = { [weak self] key in
            guard let d = self?.currentData else { return }
            DispatchQueue.global().async { d.dismissNotification(key) }
            Notify.withdraw(key)
        }
        Notify.shared.onOpen = { [weak self] key in
            // Guncelleme bildirimi: gomulu indiriciyi baslatir.
            if key.hasPrefix("andros.update."),
               let u = UserDefaults.standard.string(forKey: "pendingUpdateURL") {
                let v = String(key.dropFirst("andros.update.".count))
                SelfUpdate.run(from: u, version: v)
                return
            }
            self?.main?.showWindow(nil)
            self?.main?.select(.notifications)
        }
        startCompanionWatch()

        // AndrOS artik bir KABUK: acilista hub gosteriliyor, aynalama
        // oradan bir modul olarak baslatiliyor.
        showHub()
    }

    /// AndrOS ana penceresi (kategoriler + icerik).
    @objc func showHub() {
        defer {
            // Pencere acildi: Dock ve ⌘Tab'e gir.
            DispatchQueue.main.async { [weak self] in self?.syncActivationPolicy() }
        }
        if main == nil {
            let m = MainWindowController()
            m.session = session
            m.onStartMirroring = { [weak self] d in self?.launchMirroring(d) }
            m.onStopMirroring = { [weak self] in self?.stopMirroring() }
            m.onSelectDevice = { [weak self] serial, companionId in
                // ETKIN CIHAZ iki anahtarla saklaniyor: adb seri numarasi
                // ve uygulama kimligi. Yalniz uygulamayla bagli telefonun
                // seri numarasi yok; eskiden boyle bir cihaz secilemiyordu.
                UserDefaults.standard.set(serial ?? "", forKey: "activeSerial")
                UserDefaults.standard.set(companionId ?? "", forKey: "activeCompanion")
                // Yeni cihazin yetenekleri sifirdan olculsun.
                self?.cachedProbe = nil
                self?.refreshDevices()
                // Acik panel yeni cihazin verisini istesin.
                NotificationCenter.default.post(name: .androsRefresh, object: nil)
            }
            m.onMirrorSetting = { [weak self] key, value in
                guard let self else { return }
                switch key {
                case "audioOn":       self.audioOn = value as? Bool ?? true
                                      self.session.audioEnabled = self.audioOn
                                      self.audioItem?.state = self.audioOn ? .on : .off
                case "screenOff":     self.screenOff = value as? Bool ?? true
                                      self.session.turnScreenOff = self.screenOff
                                      self.screenItem?.state = self.screenOff ? .on : .off
                case "smoothing":     self.smoothing = value as? Bool ?? true
                                      self.session.smoothing = self.smoothing
                case "clipboardSync": self.clipboardSync = value as? Bool ?? true
                                      self.session.clipboard.enabled = self.clipboardSync
                case "autoConnect":   self.autoConnect = value as? Bool ?? true
                case "bitRate":       self.bitRate = value as? Int ?? 24_000_000
                case "maxFPS":        self.maxFPS = value as? Int ?? 60
                case "saturation", "sharpen", "contrast", "gamma":
                    var p = self.session.params
                    let f = Float(value as? Double ?? 1)
                    switch key {
                    case "saturation": p.saturation = f
                    case "sharpen":    p.sharpen = f
                    case "contrast":   p.contrast = f
                    default:           p.gamma = f
                    }
                    self.session.params = p
                default: break
                }
                Log.write("ayar degisti: \(key) = \(value)")
            }
            main = m
            refreshDevices()
            startDeviceWatch()
        }
        main?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshDevices()
    }

    /// Eslestirilmis telefonlara baglaniyor ve baglantiyi ayakta tutuyor.
    private func startCompanionWatch() {
        companionBrowser.onChange = { [weak self] list in
            guard let self else { return }
            self.companionDevices = list
            // Kopmus baglantiyi yeniden kur; zaten calisan varsa dokunma.
            self.connectPairedCompanions()
            self.refreshDevices()
        }
        companionBrowser.start()

        // CANLI TUTMA: baglanti kopunca kendiliginden geri gelsin.
        // Telefon uygulamasi arka planda oldurulup yeniden baslayabiliyor
        // ve Bonjour listesi degismedigi icin yeniden baglanma hic
        // tetiklenmiyordu; moduller de "uygulama gerekli" diyordu.
        // Uygulamayi kapatip acmak GEREKMEMELI: kopan baglanti kendi
        // kendine geri gelsin. Bulucu da bayatlayinca alt agi yeniden
        // tariyor (bkz. UdpProbe.staleAfter).
        let keepAlive = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
            guard let self else { return }
            let before = self.readyCompanion != nil
            self.connectPairedCompanions()
            // Baglanti yeni kurulduysa veri katmanini tazele.
            if !before, self.readyCompanion != nil {
                self.refreshDevices()
                NotificationCenter.default.post(name: .androsRefresh, object: nil)
            }
            // Eslesmis ama HIC bulunamayan cihaz varsa bulmayi durtukle.
            let pairedIDs = Set(self.companionStore.paired().map(\.id))
            let seen = Set(self.companionDevices.map(\.id))
            if !pairedIDs.isSubset(of: seen) { self.companionBrowser.poke() }
        }
        RunLoop.main.add(keepAlive, forMode: .common)

        NotificationCenter.default.addObserver(
            forName: .androsPaired, object: nil, queue: .main) { [weak self] _ in
            self?.connectPairedCompanions()
        }
    }

    /// Eslesmis ama baglanmamis telefonlara baglanir.
    private func connectPairedCompanions() {
        for d in companionDevices where companionStore.isPaired(d.id) {
            let existing = companionLinks[d.id]
            // TAKILI KALMIS baglantiyi da yenile.
            //
            // Olculdu: telefon bulundugu halde baglanti kurulmuyordu.
            // Sebep, `connecting` durumunda takili kalan bir nesnenin
            // ne `idle` ne `failed` sayilmasi — kosul hicbir zaman
            // saglanmadigi icin yeniden deneme HIC yapilmiyordu.
            var stale = false
            if existing?.state == .connecting || existing?.state == .awaitingCode,
               let since = existing?.stateChangedAt,
               Date().timeIntervalSince(since) > 12 { stale = true }
            if existing == nil || existing?.state == .idle
                || existing?.state.isFailed == true || stale {
                existing?.disconnect()
                let l = CompanionLink(device: d, store: companionStore)
                l.onState = { [weak self] st in
                    guard let self else { return }
                    CompanionStatus.set(d.id, st)
                    if case .ready = st {
                        self.refreshDevices()
                        // Acik panel veriyi yeniden istesin.
                        NotificationCenter.default.post(name: .androsRefresh, object: nil)
                        self.startAudioBridgeIfWanted(d.id)
                        // Kamera acik birakildiysa geri gelsin.
                        if UserDefaults.standard.bool(forKey: "cameraOn"),
                           CameraBridge.shared.state == .off {
                            self.setCamera(true)
                        }
                    }
                }
                // Telefondan gelen olaylar: bildirim, pano degisimi…
                l.onEvent = { [weak self] name, data in
                    self?.handlePhoneEvent(name, data)
                }
                companionLinks[d.id] = l
                l.connect()
            }
        }
    }

    // MARK: - "Cihaz" menusu

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === deviceMenu else { return }
        menu.removeAllItems()
        let activeSerial = UserDefaults.standard.string(forKey: "activeSerial") ?? ""
        let activeCompanion = UserDefaults.standard.string(forKey: "activeCompanion") ?? ""

        let online = unifiedDevices.filter(\.isOnline)
        if online.isEmpty {
            let it = menu.addItem(withTitle: L("Cihaz yok", "No device"),
                                  action: nil, keyEquivalent: "")
            it.isEnabled = false
        }
        for (i, d) in online.enumerated() {
            let it = NSMenuItem(title: d.displayName,
                                action: #selector(pickDevice(_:)),
                                keyEquivalent: i < 9 ? String(i + 1) : "")
            it.keyEquivalentModifierMask = [.command, .control]
            it.target = self
            // Anahtar iki parcali: "seri|uygulamaKimligi".
            it.representedObject = (d.adbSerial ?? "") + "|" + (d.companionId ?? "")
            let isActive = (!activeCompanion.isEmpty && d.companionId == activeCompanion)
                || (activeCompanion.isEmpty && !activeSerial.isEmpty
                    && (d.usbSerial == activeSerial || d.wifiSerial == activeSerial))
            it.state = isActive ? .on : .off
            it.image = NSImage(systemSymbolName: "iphone.gen3", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
            let paths = d.transportLabel(appName: "AndrOS")
            it.toolTip = paths
            menu.addItem(it)
        }
        menu.addItem(.separator())
        // Sanal kamera uzantisi: kamerayi kullanan HER uygulamada
        // telefonun gorunmesi icin gerekli. Menude durmasi, kurulumun
        // Cihazlar panelini acmadan da yapilabilmesini sagliyor.
        if VirtualCamera.extensionInstalled {
            let upd = NSMenuItem(title: L("Sanal kamerayı yeniden kur…",
                                         "Reinstall virtual camera…"),
                                 action: #selector(installVirtualCamera), keyEquivalent: "")
            upd.target = self
            menu.addItem(upd)
            let rm = NSMenuItem(title: L("Sanal kamerayı kaldır…",
                                         "Remove virtual camera…"),
                                action: #selector(removeVirtualCamera), keyEquivalent: "")
            rm.target = self
            menu.addItem(rm)
        } else {
            let cam = NSMenuItem(title: L("Sanal kamerayı kur…",
                                          "Install virtual camera…"),
                                 action: #selector(installVirtualCamera), keyEquivalent: "")
            cam.target = self
            menu.addItem(cam)
        }
        let manage = NSMenuItem(title: L("Cihazları Yönet…", "Manage Devices…"),
                                action: #selector(openDevices), keyEquivalent: "")
        manage.target = self
        menu.addItem(manage)
    }

    @objc private func pickDevice(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        let parts = raw.split(separator: "|", omittingEmptySubsequences: false)
        let serial = parts.count > 0 ? String(parts[0]) : ""
        let cid = parts.count > 1 ? String(parts[1]) : ""
        UserDefaults.standard.set(serial, forKey: "activeSerial")
        UserDefaults.standard.set(cid, forKey: "activeCompanion")
        cachedProbe = nil
        refreshDevices()
        NotificationCenter.default.post(name: .androsRefresh, object: nil)
    }

    @objc private func installVirtualCamera() {
        VirtualCamera.shared.installExtension { err in
            let a = NSAlert()
            if let err {
                a.messageText = L("Sanal kamera kurulamadı",
                                  "Could not install the virtual camera")
                a.informativeText = err
            } else {
                a.messageText = L("Sanal kamera hazır", "Virtual camera ready")
                a.informativeText = L(
                    "Telefon artık FaceTime, Zoom gibi kamera kullanan "
                  + "uygulamalarda “AndrOS · Telefon Kamerası” olarak görünüyor.",
                    "The phone now appears as “AndrOS · Phone Camera” in apps "
                  + "that use a camera, such as FaceTime and Zoom.")
            }
            a.runModal()
        }
    }

    @objc private func removeVirtualCamera() {
        VirtualCamera.shared.removeExtension { err in
            let a = NSAlert()
            if let err {
                a.messageText = L("Kaldırılamadı", "Could not remove")
                a.informativeText = err
            } else {
                a.messageText = L("Sanal kamera kaldırıldı", "Virtual camera removed")
                a.informativeText = L("Yeniden başlattıktan sonra tamamen gider.",
                                      "It is fully gone after a restart.")
            }
            a.runModal()
        }
    }

    @objc private func openDevices() {
        main?.showWindow(nil)
        main?.select(.device)
    }

    // MARK: - Ses koprusu

    /// Kullanici acmissa telefonu Mac'in ses aygiti olarak baglar.
    ///
    /// Surucu kurulu degilse hicbir sey yapmiyoruz — ses paneli zaten
    /// cihazlari gormez. Kurulum root gerektirdigi icin tek seferlik ve
    /// kullanicinin onayiyla yapiliyor (`tools/audio-driver.sh install`).
    private func startAudioBridgeIfWanted(_ deviceId: String) {
        guard UserDefaults.standard.bool(forKey: "audioBridgeOn") else { return }
        guard AudioBridge.driverInstalled else {
            Log.write("ses köprüsü: sürücü kurulu değil")
            return
        }
        guard let link = companionLinks[deviceId], link.state == .ready,
              let host = link.remoteHost,
              let token = companionStore.token(for: deviceId) else { return }
        AudioBridge.shared.microphoneEnabled =
            UserDefaults.standard.object(forKey: "audioBridgeMic") as? Bool ?? true
        // Telefonun KENDI sesi (bildirim, muzik) Mac'in SU ANKI cikisindan
        // calsin — sanal aygittan degil. Amac "kulaga iki cihaz bagliymis
        // gibi": kullanici Mac kulakligiyla telefon bildirimini de duysun.
        AudioBridge.shared.onPhoneAudio = { [weak self] pcm in
            guard let self else { return }
            if !self.phoneAudioPlayer.isRunning {
                DispatchQueue.main.sync {
                    // Sanal aygittan CALMA: telefona geri doner (dongu).
                    self.phoneAudioPlayer.preferredDevice = AudioRouting.deviceForPhoneAudio()
                    self.phoneAudioPlayer.start()
                }
            }
            self.phoneAudioPlayer.enqueue([UInt8](pcm))
        }
        AudioBridge.shared.onState = { [weak self] st in
            // Ses koprusu de kopunca kendiliginden geri gelsin.
            guard st == .off || st.isFailed else { return }
            guard UserDefaults.standard.bool(forKey: "audioBridgeOn") else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard UserDefaults.standard.bool(forKey: "audioBridgeOn"),
                      AudioBridge.shared.state != .on,
                      let id = self?.companionLinks.first(where: { $0.value.state == .ready })?.key
                else { return }
                self?.startAudioBridgeIfWanted(id)
            }
        }
        AudioBridge.shared.start(host: host, token: token)
    }

    // MARK: - Kamera

    /// Telefonun kamerasini ac/kapa.
    ///
    /// Acikken menu cubugunda CANLI kucuk onizleme duruyor: kamera
    /// akiyorken bunun her zaman gorunur olmasi gerekiyor.
    func setCamera(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "cameraOn")
        guard on else {
            CameraBridge.shared.stop()
            CameraStatusItem.shared.hide()
            VirtualCamera.shared.stopPublishing()
            return
        }
        guard let id = companionLinks.first(where: { $0.value.state == .ready })?.key,
              let link = companionLinks[id], let host = link.remoteHost,
              let token = companionStore.token(for: id) else { return }

        CameraStatusItem.shared.onToggleFacing = { CameraBridge.shared.toggleFacing() }
        CameraStatusItem.shared.onStop = { [weak self] in self?.setCamera(false) }
        CameraStatusItem.shared.onOpen = { [weak self] in
            self?.main?.showWindow(nil)
            self?.main?.select(.device)
        }
        // Onizleme ISLENMIS kareyi gorsun: efekt/donus/ayna ayarinin
        // etkisi menu cubugu panelinde de gorunsun.
        VirtualCamera.shared.onProcessed = { px in
            CameraStatusItem.shared.update(px)
        }
        CameraBridge.shared.onFrame = { px in
            VirtualCamera.shared.publish(px)
        }
        CameraBridge.shared.onState = { [weak self] st in
            DispatchQueue.main.async {
                guard let self else { return }
                // Menu cubugu simgesi AYARA bagli.
                let wantIcon = UserDefaults.standard.object(forKey: "mbCamera") as? Bool ?? true
                if case .on = st, wantIcon { CameraStatusItem.shared.show() }
                else { CameraStatusItem.shared.hide() }

                // KENDILIGINDEN GERI GEL. Baglanti kopmasi olagan:
                // telefon uykuya gecer, ag degisir, karsi taraf soketi
                // kapatir ("Connection reset by peer"). Kullaniciya hata
                // gostermek yerine sessizce yeniden deniyoruz.
                let stillWanted = UserDefaults.standard.bool(forKey: "cameraOn")
                if st == .off, stillWanted {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                        guard UserDefaults.standard.bool(forKey: "cameraOn"),
                              CameraBridge.shared.state == .off else { return }
                        self?.setCamera(true)
                    }
                    return
                }
                // Telefonun ACIKCA soyledigi sebepler kullaniciya gosterilir
                // (izin yok, baska uygulama kullaniyor…); ag hatalari degil.
                guard case .failed(let why) = st else { return }
                let networky = why.contains("54") || why.lowercased().contains("reset")
                    || why.lowercased().contains("posix")
                if networky {
                    Log.write("kamera bağlantısı koptu, yeniden denenecek: \(why)")
                    if stillWanted {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                            guard UserDefaults.standard.bool(forKey: "cameraOn") else { return }
                            self?.setCamera(true)
                        }
                    }
                    return
                }
                self.explainCameraFailure(why)
            }
        }
        CameraBridge.shared.start(host: host, token: token)
    }

    /// Kamera acilamadi: sebebi ve cozumu.
    private func explainCameraFailure(_ why: String) {
        let a = NSAlert()
        a.messageText = L("Telefon kamerası açılamadı", "Could not open the phone camera")
        switch why {
        case "policy":
            a.informativeText = L(
                "Android, arka planda başlatılan servise kamera izni vermiyor. "
              + "Telefonda AndrOS uygulamasını bir kez aç — servis yeniden "
              + "kurulup kamerayı açabilir hale gelir.",
                "Android does not grant camera access to a service started in the "
              + "background. Open the AndrOS app on the phone once; the service "
              + "restarts and can then use the camera.")
        case "inuse":
            a.informativeText = L("Kamerayı telefonda başka bir uygulama kullanıyor.",
                                  "Another app on the phone is using the camera.")
        case "permission":
            a.informativeText = L("Telefondaki AndrOS uygulamasında kamera iznini ver.",
                                  "Grant the camera permission in the AndrOS app on the phone.")
        default:
            a.informativeText = why
        }
        a.runModal()
    }

    /// Cihazlar panelindeki anahtardan cagriliyor.
    func setAudioBridge(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "audioBridgeOn")
        guard on else {
            AudioBridge.shared.stop()
            phoneAudioPlayer.stop()
            return
        }
        if let id = companionLinks.first(where: { $0.value.state == .ready })?.key {
            startAudioBridgeIfWanted(id)
        }
    }

    /// Telefondan gelen olaylari isler.
    ///
    /// Bildirim geldiginde macOS'un KENDI bildirim merkezinde
    /// gosteriyoruz — kullanicinin AndrOS penceresine bakmasi
    /// gerekmesin. Panel aciksa o da tazeleniyor.
    private func handlePhoneEvent(_ name: String, _ data: [String: Any]) {
        switch name {
        case "notification":
            guard let n = AndroidData.notification(from: data) else { return }
            // Surekli duran bildirimler (muzik calar, indirme) macOS'ta
            // tekrar tekrar gosterilmemeli; yalniz panelde gorunsunler.
            guard !n.ongoing else { break }
            let head = n.title.isEmpty ? n.app : "\(n.app) · \(n.title)"
            // Bildirimin KENDI dugmeleri Mac'e oldugu gibi tasiniyor:
            // "Bağlantıyı kes", "Duraklat", "Ertele"… Metin kabul eden
            // eylem banner'da yazma kutusu olarak aciliyor.
            let acts = n.actions.map {
                Notify.PhoneAction(index: $0.index, title: $0.title, reply: $0.reply)
            }
            Log.write("telefon bildirimi: \(n.package) '\(head)' "
                      + "(\(acts.count) düğme)")
            Notify.shared.show(title: head, body: n.text, id: n.key,
                               key: n.key, package: n.package, app: n.app,
                               actions: acts)
        case "notifications.changed":
            break
        case "remote.input":
            // TELEFON = Mac'in dokunmatik yuzeyi. Bu yon yansitmanin
            // TERSI: goruntu gitmiyor, yalnizca girdi geliyor.
            guard UserDefaults.standard.object(forKey: "remoteControl") as? Bool ?? true
            else { break }
            guard RemoteControl.isTrusted else { askForAccessibility(); break }
            RemoteControl.shared.handle(data)
            return                      // bildirim paneli tazelemeye gerek yok
        default:
            break
        }
        NotificationCenter.default.post(name: .androsNotificationsChanged, object: nil)
    }

    /// Erisilebilirlik izni yoksa BIR KEZ sor.
    ///
    /// macOS sentetik fare/klavye olaylarini bu izin olmadan yutuyor —
    /// hicbir hata vermeden. Sessiz kalmak "telefondan kontrol
    /// calismiyor" demek olurdu.
    private var askedForAX = false
    private func askForAccessibility() {
        guard !askedForAX else { return }
        askedForAX = true
        RemoteControl.requestTrust()
        let a = NSAlert()
        a.messageText = L("Mac'i telefondan yönetmek için izin gerekiyor",
                          "Controlling the Mac from the phone needs permission")
        a.informativeText = L(
            "Sistem Ayarları › Gizlilik ve Güvenlik › Erişilebilirlik listesinde "
          + "AndrOS'u aç. macOS, bu izin olmadan uygulamaların fare ve klavye "
          + "olayı üretmesine izin vermiyor.",
            "Open System Settings › Privacy & Security › Accessibility and enable "
          + "AndrOS. macOS does not let an app synthesise mouse and keyboard "
          + "events without it.")
        a.addButton(withTitle: L("Ayarları aç", "Open Settings"))
        a.addButton(withTitle: L("Sonra", "Later"))
        if a.runModal() == .alertFirstButtonReturn,
           let u = URL(string: "x-apple.systempreferences:com.apple.preference."
                             + "security?Privacy_Accessibility") {
            NSWorkspace.shared.open(u)
        }
    }

    /// Su an hazir olan ilk baglanti.
    private var readyCompanion: CompanionLink? {
        companionLinks.values.first { $0.state == .ready }
    }

    /// Otomatik guncelleme denetimi.
    ///
    /// Gunde BIR kez ve sessizce: yeni surum varsa bildirim cikiyor,
    /// yoksa hicbir sey olmuyor. Acilista hemen sormuyoruz — uygulama
    /// yeni acilmisken ag beklemek acilisi geciktirir.
    ///
    /// OTOMATIK KURULUM YOK. macOS'ta imzasiz bir uygulamanin kendini
    /// yerine koymasi Gatekeeper'a takilir; Android da sessiz kuruluma
    /// izin vermiyor. Indirmeyi aciyoruz, kurulumu kullanici onayliyor.
    private func scheduleUpdateCheck() {
        guard UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true
        else { return }
        let last = UserDefaults.standard.double(forKey: "lastUpdateCheck")
        let now = Date().timeIntervalSince1970
        guard now - last > 24 * 3600 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            UserDefaults.standard.set(now, forKey: "lastUpdateCheck")
            Updates.check { r in
                guard case .available(let v, let url, _) = r else { return }
                Log.write("yeni sürüm var: \(v)")
                Notify.post(title: L("AndrOS \(v) çıktı", "AndrOS \(v) is out"),
                            body: L("İndirmek için tıkla.", "Click to download."),
                            id: "andros.update.\(v)")
                UserDefaults.standard.set(url, forKey: "pendingUpdateURL")
            }
        }
    }

    /// Bildirim eylemleri icin veri katmani.
    ///
    /// Panel acik olmayabilir (bildirime Mac'in bildirim merkezinden
    /// cevap veriliyor), bu yuzden koprüyu burada kuruyoruz.
    private var currentData: AndroidData? {
        guard let adb = try? ADB() else { return nil }
        var ad = AndroidData(adb: adb)
        ad.companion = linkForData.map { CompanionBridge($0) }
        return ad
    }

    /// Veri katmanina verilecek baglanti.
    ///
    /// Hazir olani varsa onu, yoksa mevcut baglantiyi (yeniden kuruluyor
    /// olabilir) doner. Kopruyu tamamen dusurmek yerine elde tutuyoruz:
    /// `CompanionBridge.isReady` gercegi zaten soyluyor, ama nesnenin
    /// kaybolmasi paneli adb'ye dusurup listeyi bosaltiyordu.
    private var linkForData: CompanionLink? {
        // ETKIN CIHAZ once. Birden fazla telefon eslesmis olabilir;
        // panellerin hangisini gosterdigi rastgele olmamali.
        let wanted = UserDefaults.standard.string(forKey: "activeCompanion") ?? ""
        if !wanted.isEmpty, let l = companionLinks[wanted],
           l.state == .ready || companionLinks.count == 1 {
            return l
        }
        return readyCompanion ?? companionLinks.values.first
    }

    /// Denetim panelinde gosterilecek cihaz adi.
    private var lastDeviceLabel = ""

    /// Telefonun kendi sesini calan oynatici (yansitmadan bagimsiz).
    private let phoneAudioPlayer = AudioPlayer()

    /// Son yetenek olcumu (serial, yetenekler, ne zaman).
    private var cachedProbe: (serial: String, caps: AndroidData.Capabilities, at: Date)?

    /// Cihaz listesini ve modul yeteneklerini tazeler.
    private func refreshDevices() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var list: [HubDevice] = []
            var probe = AndroidData.Capabilities()
            var dataLayer: AndroidData?
            var label = L("Cihaz yok", "No device")

            if let adb = try? ADB(), let found = try? adb.devices() {
                for d in found {
                    let one = (try? ADB(serial: d.serial)) ?? adb
                    list.append(HubDevice(serial: d.serial, model: d.model,
                                          manufacturer: one.getProp("ro.product.manufacturer"),
                                          android: one.getProp("ro.build.version.release"),
                                          overWifi: d.transport == "tcp"))
                }
                // Kullanicinin Cihazlar panelinde sectigi cihaz varsa ONU
                // kullan; yoksa listedeki ilki. Boylece birden fazla cihaz
                // bagliyken panellerin hangisini gosterdigi belirsiz kalmiyor.
                let wanted = UserDefaults.standard.string(forKey: "activeSerial")
                let chosen = (wanted?.isEmpty == false
                              ? found.first { $0.serial == wanted } : nil) ?? found.first
                if let first = chosen, let one = try? ADB(serial: first.serial) {
                    TransferQueue.shared.configure(adbPath: one.path, serial: first.serial)
                    var ad = AndroidData(adb: one)
                    // Eslestirilmis uygulama varsa moduller onu tercih etsin.
                    let bridge = self?.linkForData.map { CompanionBridge($0) }
                    ad.companion = bridge
                    dataLayer = ad
                    // Kuyruk da uygulama yolunu kullanabilsin.
                    TransferQueue.shared.data = ad
                    // YOKLAMA SEYREK. Her 3 saniyede birkac adb kabuk
                    // cagrisi demekti; galeri/muzik ayni anda calisirken
                    // adb doyuyor ve panellerin istekleri zaman asimina
                    // ugruyordu. Yetenekler zaten yapiskan (bkz.
                    // MainWindowController.stickyCaps), sik olcmenin
                    // faydasi yok.
                    let now = Date()
                    if let cached = self?.cachedProbe,
                       now.timeIntervalSince(cached.at) < 60,
                       cached.serial == first.serial {
                        probe = cached.caps
                    } else {
                        probe = ad.probe()
                        self?.cachedProbe = (first.serial, probe, now)
                    }
                    // Yetenekler adb'ye gore olculuyor; uygulama varsa onun
                    // acabildiklerini EKLIYORUZ. Arama gecmisi adb'de her
                    // zaman kapali cikiyor, bu yuzden kategori uygulama
                    // eslesmisken bile gri kaliyordu.
                    // Yetenekler ESLESTIRME durumuna bakiyor, baglantinin
                    // O ANDAKI hazir olusuna degil.
                    //
                    // Neden: baglanti arada bir yeniden kuruluyor ve
                    // `isReady` kisa sureligine false oluyordu; kategoriler
                    // (ozellikle Aramalar) gri olup geri geliyordu. Modul
                    // veriyi alamazsa zaten kendi bos durumunu gosteriyor;
                    // kategoriyi kapatip acmak kullaniciyi sasirtiyordu.
                    if self?.companionStore.paired().isEmpty == false {
                        probe.callLog = true
                        probe.sms = true
                        probe.contacts = true
                        probe.media = true
                        probe.files = true
                    }
                    label = "\(one.getProp("ro.product.manufacturer")) "
                          + "\(one.getProp("ro.product.model")) · Android "
                          + one.getProp("ro.build.version.release")
                }
            }
            // UYGULAMA yoluyla bagli telefonlar da yansitma listesinde.
            //
            // Onceden liste yalniz adb cihazlarindan geliyordu: telefon
            // eslesip her sey calisirken "Screen Mirroring"de hicbir sey
            // gorunmuyordu. Artik goruntu de uygulama uzerinden geldigi
            // icin (MediaProjection + erisilebilirlik) burada olmasi
            // gerekiyor.
            for (id, link) in (self?.companionLinks ?? [:]) where link.state == .ready {
                if list.contains(where: { $0.serial == id }) { continue }
                let nm = self?.companionStore.paired().first { $0.id == id }?.name ?? "Android"
                list.append(HubDevice(serial: id, model: nm, manufacturer: "",
                                      android: "", overWifi: true, viaApp: true))
            }

            // adb HIC yoksa ama uygulama eslesmisse veri katmani yine
            // kurulmali: hedef zaten hata ayiklamasiz calismak. adb'ye
            // dusen moduller bos doner, uygulamayi tercih edenler calisir.
            if dataLayer == nil, self?.companionStore.paired().isEmpty == false,
               let adb = try? ADB() {
                var ad = AndroidData(adb: adb)
                ad.companion = self?.linkForData.map { CompanionBridge($0) }
                dataLayer = ad
                TransferQueue.shared.data = ad
                var caps = AndroidData.Capabilities()
                caps.sms = true; caps.contacts = true; caps.callLog = true
                caps.media = true; caps.files = true
                probe = caps
                label = L("AndrOS mobil uygulaması", "AndrOS mobile app")
            }
            let finalList = list, finalProbe = probe, finalData = dataLayer, finalLabel = label
            DispatchQueue.main.async {
                guard let self else { return }
                var mirroring = false
                if case .running = self.session.state { mirroring = true }
                self.main?.setDevices(finalList, mirroring: mirroring)
                self.main?.setMirroring(mirroring)
                self.lastDeviceLabel = finalLabel
                self.main?.setDevice(finalData, label: finalLabel, caps: finalProbe)
            }
        }
    }

    private func startDeviceWatch() {
        deviceTimer?.invalidate()
        let t = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            guard self?.main?.window?.isVisible == true else { return }
            UserBusy.run { [weak self] in self?.refreshDevices() }
        }
        RunLoop.main.add(t, forMode: .common)
        deviceTimer = t
    }

    private func stopMirroring() {
        stopAppMirroring()
        session.stop()
        mirrorEmbedded = false
        window?.orderOut(nil)
        refreshDevices()
    }

    /// Secilen cihazla aynalamayi baslatir.
    private func launchMirroring(_ device: HubDevice) {
        Log.write("ana pencere: aynalama baslatiliyor -> \(device.serial)")
        if device.viaApp { startAppMirroring(device); return }
        UserDefaults.standard.set(device.serial, forKey: "lastSerial")
        if case .running = session.state { return }
        // Aynalama KENDI penceresinde acilir; ana pencere bagimsiz kalir,
        // yansitirken Mesajlar/Dosyalar/Galeri'yi rahatca kullanabilirsin.
        mirrorEmbedded = false
        ensureWindow()
        session.start(bitRate: bitRate, maxFPS: maxFPS, forceFullRange: false)
    }

    // MARK: - Yansitma: UYGULAMA yolu (hata ayiklamasiz)

    private var appMirror: AppMirrorWindowController?

    /// Telefondaki uygulama uzerinden yansitma.
    ///
    /// adb'li yoldan farki: goruntuyu `MediaProjection` uretiyor, dokunma
    /// da erisilebilirlik hizmetine JEST olarak gidiyor. Hicbiri hata
    /// ayiklama istemiyor.
    private func startAppMirroring(_ device: HubDevice) {
        guard let link = companionLinks[device.serial], let host = link.remoteHost,
              let token = companionStore.token(for: device.serial) else {
            Log.write("yansıtma: uygulama bağlantısı yok")
            return
        }
        let wc = appMirror ?? AppMirrorWindowController()
        appMirror = wc
        let bridge = ScreenBridge.shared

        wc.mirror.onTap       = { bridge.tap($0, $1) }
        wc.mirror.onLongPress = { bridge.longPress($0, $1) }
        wc.mirror.onSwipe     = { bridge.swipe($0, ms: $1) }
        wc.mirror.onBack      = { bridge.back() }
        wc.mirror.onText      = { bridge.type($0) }
        wc.mirror.onBackspace = { bridge.backspace() }
        wc.onAction = { a in
            switch a {
            case .back:       bridge.back()
            case .home:       bridge.home()
            case .recents:    bridge.recents()
            case .shade:      bridge.shade()
            case .quick:      bridge.quickSettings()
            case .screenshot: bridge.screenshot()
            case .volumeUp:   bridge.volume(up: true)
            case .volumeDown: bridge.volume(up: false)
            case .rotate:     bridge.toggleAutoRotate()
            case .lock:       bridge.lockScreen()
            case .power:      bridge.powerDialog()
            }
        }
        wc.onClose   = { [weak self] in self?.stopAppMirroring() }

        bridge.onFrame = { [weak wc] px in wc?.mirror.show(px) }
        bridge.onInputReady = { [weak wc] ok in wc?.setInputReady(ok) }
        bridge.onNotice = { [weak wc] code in
            let text: String
            switch code {
            case "nowritesettings":
                text = L("Otomatik döndürmeyi değiştirmek için telefonda AndrOS'a "
                       + "“sistem ayarlarını değiştir” izni ver.",
                         "To toggle auto-rotate, grant AndrOS the “modify system "
                       + "settings” permission on the phone.")
            default: text = code
            }
            wc?.notice(text)
        }
        bridge.onState = { [weak self] st in
            guard let self else { return }
            self.appMirror?.setInputReady(ScreenBridge.shared.inputReady)
            self.main?.setMirroring(st == .on)
            if case .failed(let why) = st { self.explainMirrorFailure(why) }
        }
        // Kalite: yansitma panelindeki ayarlar. Cozunurlugu de
        // buradan veriyoruz — gecikmeyi en cok o belirliyor.
        let q = ScreenBridge.Quality(
            maxSize: UserDefaults.standard.object(forKey: "mirrorMaxSize") as? Int ?? 1920,
            fps: maxFPS,
            mbps: max(1, bitRate / 1_000_000))
        bridge.start(host: host, token: token, quality: q)
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        main?.setMirroring(true)
    }

    private func stopAppMirroring() {
        guard appMirror != nil else { return }
        ScreenBridge.shared.stop()
        appMirror?.onClose = nil
        appMirror?.close()
        appMirror = nil
        main?.setMirroring(false)
    }

    /// Yansitma acilamadi: SEBEBI ve cozumu.
    private func explainMirrorFailure(_ why: String) {
        let a = NSAlert()
        a.messageText = L("Telefon ekranı alınamadı", "Could not capture the phone screen")
        switch why {
        case "noprojection":
            a.informativeText = L(
                "Telefon ekran kaydı iznini vermemiş. Telefonda AndrOS uygulamasını "
              + "aç ve çıkan \"Kaydetmeye başla\" onayını ver — aynı izin ses için de "
              + "kullanılıyor, bir kez yeterli.",
                "The phone has not granted screen capture. Open the AndrOS app on the "
              + "phone and accept the \"Start recording\" prompt — the same permission "
              + "covers audio, so once is enough.")
        default:
            a.informativeText = why
        }
        a.addButton(withTitle: "Tamam")
        a.runModal()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }

    // MARK: - Menu cubugu (uygulamanin ust menusu)

    /// Ust menu TAMAMEN iki dilli ve olabildigince dolu.
    ///
    /// "Yansitma" menusu burada KURULMAZ: o menu yalniz yansitma penceresi
    /// odaktayken menu cubuguna giriyor (bkz. `syncMirrorMenu`), cunku
    /// icindeki her sey — ana ekran, ses, guc tusu — yalniz o pencere icin
    /// anlamli. Ana uygulama odaktayken orada durmasi kafa karistirir.
    private func buildMainMenu() {
        let main = NSMenu()

        // ---- AndrOS
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        add(appMenu, L("AndrOS Hakkında", "About AndrOS"), #selector(about))
        appMenu.addItem(.separator())

        let langItem = NSMenuItem(title: L("Dil", "Language"), action: nil, keyEquivalent: "")
        let langMenu = NSMenu()
        for (key, name) in [("auto", L("Otomatik (sistem)", "Automatic (System)")),
                            ("tr", "Türkçe"), ("en", "English")] {
            let it = add(langMenu, name, #selector(pickLanguage(_:)))
            it.representedObject = key
            it.state = (L10n.override == key) ? .on : .off
        }
        langItem.submenu = langMenu
        appMenu.addItem(langItem)

        appMenu.addItem(.separator())

        let services = NSMenuItem(title: L("Servisler", "Services"), action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu()
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(services)
        appMenu.addItem(.separator())

        appMenu.addItem(withTitle: L("AndrOS'u Gizle", "Hide AndrOS"),
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = appMenu.addItem(withTitle: L("Diğerlerini Gizle", "Hide Others"),
                                     action: #selector(NSApplication.hideOtherApplications(_:)),
                                     keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: L("Tümünü Göster", "Show All"),
                        action: #selector(NSApplication.unhideAllApplications(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        add(appMenu, L("AndrOS'tan Çık", "Quit AndrOS"), #selector(quit), "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        // ---- Duzen: metin alanlari icin ⌘C/⌘V'nin CALISMASI gerekiyor.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: L("Düzen", "Edit"))
        editMenu.addItem(withTitle: L("Geri Al", "Undo"),
                         action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: L("Yinele", "Redo"),
                                    action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L("Kes", "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L("Kopyala", "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L("Yapıştır", "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L("Tümünü Seç", "Select All"),
                         action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        add(editMenu, L("Ara", "Find"), #selector(focusSearch), "f")
        editItem.submenu = editMenu
        main.addItem(editItem)

        // ---- Gorunum: kategoriler ⌘1…⌘9 ile
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: L("Görünüm", "View"))
        for (i, c) in MainWindowController.Category.allCases.enumerated() {
            let it = add(viewMenu, c.title, #selector(pickCategory(_:)),
                         i < 9 ? String(i + 1) : "")
            it.representedObject = c.rawValue
            it.image = NSImage(systemSymbolName: c.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        }
        viewMenu.addItem(.separator())
        let sb = add(viewMenu, L("Kenar Çubuğunu Daralt/Genişlet", "Toggle Sidebar"),
                     #selector(toggleHubSidebar), "s")
        sb.keyEquivalentModifierMask = [.command, .control]
        add(viewMenu, L("Yenile", "Refresh"), #selector(refreshCurrent), "r")
        viewMenu.addItem(.separator())
        let full = viewMenu.addItem(withTitle: L("Tam Ekran", "Enter Full Screen"),
                                    action: #selector(NSWindow.toggleFullScreen(_:)),
                                    keyEquivalent: "f")
        full.keyEquivalentModifierMask = [.command, .control]
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        // ---- Cihaz: birden fazla telefon varken hizli gecis
        let devItem = NSMenuItem()
        let devMenu = NSMenu(title: L("Cihaz", "Device"))
        devMenu.delegate = self
        deviceMenu = devMenu
        devItem.submenu = devMenu
        main.addItem(devItem)

        // ---- Pencere
        let winItem = NSMenuItem()
        let winMenu = NSMenu(title: L("Pencere", "Window"))
        winMenu.addItem(withTitle: L("Simge Durumuna Küçült", "Minimize"),
                        action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        winMenu.addItem(withTitle: L("Yakınlaştır", "Zoom"),
                        action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        winMenu.addItem(.separator())
        add(winMenu, L("AndrOS Penceresi", "AndrOS Window"), #selector(showHub), "0")
        let mw = add(winMenu, L("Yansıtma Penceresi", "Mirroring Window"), #selector(focusWindow), "a")
        mw.keyEquivalentModifierMask = [.command, .option]
        winMenu.addItem(.separator())
        add(winMenu, L("Kapat", "Close"), #selector(closeWindow), "w")
        winMenu.addItem(.separator())
        winMenu.addItem(withTitle: L("Tümünü Öne Getir", "Bring All to Front"),
                        action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        winItem.submenu = winMenu
        main.addItem(winItem)
        NSApp.windowsMenu = winMenu

        // ---- Yardim
        let helpItem = NSMenuItem()
        let helpMenu = NSMenu(title: L("Yardım", "Help"))
        add(helpMenu, L("Klavye Kısayolları", "Keyboard Shortcuts"), #selector(showShortcuts), "/")
        helpItem.submenu = helpMenu
        main.addItem(helpItem)
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = main
        watchKeyWindow()
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ sel: Selector,
                     _ key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        it.target = self
        menu.addItem(it)
        return it
    }

    // MARK: - Yansitma menusu (yalniz o pencere odaktayken)

    /// Yansitma penceresi odagi alip verdikce menuyu takiyoruz.
    private func watchKeyWindow() {
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main) { [weak self] _ in
                // Odak bir pencereden digerine gecerken once "resign", sonra
                // "becomeKey" geliyor; arada bir tur bekleyip SON durumu
                // okuyoruz, yoksa menu bir anligina kaybolup geri geliyor.
                DispatchQueue.main.async { self?.syncMirrorMenu() }
            }
        }
    }

    private func syncMirrorMenu() {
        guard let main = NSApp.mainMenu else { return }
        let key = NSApp.keyWindow
        let shouldShow = key != nil && key === window
        let existing = main.items.first { $0.identifier?.rawValue == "mirror" }

        if shouldShow, existing == nil {
            let it = buildMirrorMenuItem()
            // "Pencere"nin soluna: sirasi Gorunum ile Pencere arasi olsun.
            let idx = main.items.firstIndex { $0.submenu?.title == L("Pencere", "Window") }
            main.insertItem(it, at: idx ?? main.items.count)
        } else if !shouldShow, let e = existing {
            main.removeItem(e)
        }
    }

    private func buildMirrorMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        item.identifier = NSUserInterfaceItemIdentifier("mirror")
        let m = NSMenu(title: L("Yansıtma", "Mirroring"))
        m.autoenablesItems = false

        // Gezinme
        for (a, key, mods) in [
            (SidebarAction.home, "H", NSEvent.ModifierFlags([.command, .shift])),
            (.back, "[", [.command]),
            (.recents, "]", [.command]),
            (.notifications, "N", [.command, .shift]),
        ] as [(SidebarAction, String, NSEvent.ModifierFlags)] {
            mirrorRow(m, a, key, mods)
        }
        m.addItem(.separator())

        // Donanim tuslari
        mirrorRow(m, .volumeUp, "+", [.command])
        mirrorRow(m, .volumeDown, "-", [.command])
        mirrorRow(m, .power, "P", [.command, .shift])
        m.addItem(.separator())

        mirrorRow(m, .screenshot, "S", [.command, .shift])
        mirrorRow(m, .rotate, "R", [.command, .shift])
        m.addItem(.separator())

        mirrorRow(m, .joystick, "J", [.command, .shift])
        mirrorRow(m, .macro, "M", [.command, .shift])
        m.addItem(.separator())

        mirrorRow(m, .fullscreen, "F", [.command])
        mirrorRow(m, .flipSide, "", [])
        let panelItem = add(m, sidebarVisible ? L("Paneli Gizle", "Hide Panel")
                                              : L("Paneli Göster", "Show Panel"),
                            #selector(toggleSidebarShortcut), "\\")
        panelItem.identifier = NSUserInterfaceItemIdentifier("panelToggle")
        m.addItem(.separator())

        // Acip kapananlar
        audioItem = add(m, L("Telefon Sesini Mac'e Al", "Route Phone Audio to Mac"),
                        #selector(toggleAudio))
        audioItem?.state = audioOn ? .on : .off
        screenItem = add(m, L("Telefon Ekranını Kapalı Tut", "Keep Phone Screen Off"),
                         #selector(toggleScreenOff))
        screenItem?.state = screenOff ? .on : .off
        clipItem = add(m, L("Panoyu Eşitle", "Sync Clipboard"), #selector(toggleClipboard))
        clipItem?.state = clipboardSync ? .on : .off
        smoothItem = add(m, L("Görüntü Yumuşatma", "Image Smoothing"), #selector(toggleSmoothing))
        smoothItem?.state = smoothing ? .on : .off
        topItem = add(m, L("Her Zaman Üstte", "Always on Top"), #selector(toggleOnTop))
        topItem?.state = alwaysOnTop ? .on : .off
        m.addItem(.separator())

        mirrorRow(m, .disconnect, "K", [.command])

        item.submenu = m
        return item
    }

    private func mirrorRow(_ m: NSMenu, _ a: SidebarAction,
                           _ key: String, _ mods: NSEvent.ModifierFlags) {
        let it = NSMenuItem(title: a.title, action: #selector(mirrorAction(_:)),
                            keyEquivalent: key.lowercased())
        it.keyEquivalentModifierMask = mods
        it.target = self
        it.representedObject = a.rawValue
        it.image = NSImage(systemSymbolName: a.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        m.addItem(it)
    }

    @objc private func mirrorAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let a = SidebarAction(rawValue: raw) else { return }
        handleSidebar(a)
    }

    @objc private func pickCategory(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let c = MainWindowController.Category(rawValue: raw) else { return }
        showHub()
        main?.select(c)
    }

    @objc private func pickLanguage(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        L10n.override = key
        buildMainMenu()
        buildStatusItem()
        alert(title: L("Dil değiştirildi", "Language changed"),
              body: L("Menüler hemen güncellendi. Panellerin tamamının yeni dile "
                    + "geçmesi için AndrOS'u yeniden başlat.",
                      "Menus updated right away. Restart AndrOS so every panel "
                    + "picks up the new language."))
    }

    @objc private func focusSearch() {
        NotificationCenter.default.post(name: .androsFocusSearch, object: nil)
    }

    @objc private func refreshCurrent() {
        NotificationCenter.default.post(name: .androsRefresh, object: nil)
    }

    @objc private func toggleHubSidebar() { main?.toggleSidebar() }

    @objc private func showShortcuts() {
        alert(title: L("Klavye Kısayolları", "Keyboard Shortcuts"),
              body: L("""
                ⌘0        AndrOS penceresi
                ⌘1…⌘9     Kategoriler
                ⌘F        Ara
                ⌘R        Yenile
                ⌃⌘S       Kenar çubuğu

                Yansıtma penceresinde
                ⌘⌥A       Pencereyi öne getir
                ⇧⌘H       Ana ekran        ⌘[ Geri     ⌘] Görev görünümü
                ⇧⌘N       Bildirim paneli  ⌘+ Ses +    ⌘− Ses −
                ⇧⌘P       Güç tuşu         ⇧⌘S Ekran görüntüsü
                ⇧⌘R       Döndür           ⇧⌘J Tuş haritalama
                ⇧⌘M       Makrolar         ⌘F  Tam ekran
                ⌘\\        Paneli göster/gizle
                ⌘K        Yayını kapat
                ⌘ + sürükle   Pencereyi taşı
                """,
                """
                ⌘0        AndrOS window
                ⌘1…⌘9     Categories
                ⌘F        Find
                ⌘R        Refresh
                ⌃⌘S       Sidebar

                In the mirroring window
                ⌘⌥A       Bring window to front
                ⇧⌘H       Home             ⌘[ Back     ⌘] Recents
                ⇧⌘N       Notifications    ⌘+ Vol up   ⌘− Vol down
                ⇧⌘P       Power            ⇧⌘S Screenshot
                ⇧⌘R       Rotate           ⇧⌘J Key mapping
                ⇧⌘M       Macros           ⌘F  Full screen
                ⌘\\        Show/hide panel
                ⌘K        Stop mirroring
                ⌘ + drag  Move the window
                """))
    }

    @objc private func about() {
        alert(title: "AndrOS 0.1.0",
              body: L("Android ekranını yansıtır ve kontrol eder.\n\n⌘⌥A  pencereyi öne getir\n⌘ + sürükle  pencereyi taşı\nsol tık  dokunma",
                "Mirrors and controls an Android screen.\n\n⌘⌥A  bring window to front\n⌘ + drag  move the window\nleft click  tap"))
    }

    @objc private func closeWindow() { window?.orderOut(nil) }

    // MARK: - Menu cubugu

    private func buildStatusItem() {
        // Dil degisiminde bu yeniden cagriliyor; eskisi kalirsa menu
        // cubugunda IKI simge olurdu.
        if let old = statusItem { NSStatusBar.system.removeStatusItem(old) }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem?.button {
            b.image = NSImage(systemSymbolName: "iphone.gen3",
                              accessibilityDescription: "AndrOS")
            b.image?.isTemplate = true
        }

        // MENU DEGIL DENETIM PANELI.
        //
        // Gunluk kullanilan seyler (telefonu ses aygiti yapmak, kamerayi
        // acmak) ana pencerede kucuk kutucuklar halindeydi: bulunmasi
        // zordu ve dar pencerede sigmiyordu. Hepsi artik burada, her
        // birinin ne yaptigi tek satirda yazili.
        statusItem?.button?.target = self
        statusItem?.button?.action = #selector(toggleStatusPanel)
    }

    private let statusHost = PopoverHost()

    @objc private func toggleStatusPanel() {
        Log.write("menü çubuğu paneli açılıyor")
        guard let b = statusItem?.button else { return }

        let panel = StatusPanel.shared
        panel.onOpenApp = { [weak self] in
            self?.statusHost.close(); self?.showHub()
        }
        panel.onToggleMirroring = { [weak self] in
            self?.statusHost.close(); self?.toggleConnect()
        }
        panel.onWakePhone = { [weak self] in self?.wakePhone() }
        panel.onQuit = { [weak self] in self?.quit() }
        panel.onAudio = { [weak self] on in self?.setAudioBridge(on) }
        panel.onCamera = { [weak self] on in self?.setCamera(on) }
        panel.onMicrophone = { on in
            UserDefaults.standard.set(on, forKey: "audioBridgeMic")
            AudioBridge.shared.microphoneEnabled = on
        }
        panel.onOpenCategory = { [weak self] c in
            self?.statusHost.close()
            self?.main?.showWindow(nil)
            self?.main?.select(c)
        }
        // Ayarlar menu cubugundan da acilsin: pencereyi acip sag alt
        // kosedeki disliyi aramak gereksiz.
        panel.onOpenSettings = { [weak self] in
            self?.statusHost.close()
            self?.main?.showWindow(nil)
            self?.main?.openSettings()
        }
        var mirroring = false
        if case .running = session.state { mirroring = true }
        panel.refresh(deviceLabel: lastDeviceLabel,
                      connected: readyCompanion != nil,
                      mirroring: mirroring)
        statusHost.toggle(panel, from: b)
    }

    /// Menu icine gomulu kaydiraci olan satir — ayri pencere acmadan ayar.
    private func sliderItem(_ title: String, key: String,
                            min: Double, max: Double, value: Float) -> NSMenuItem {
        let item = NSMenuItem()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 40))

        let label = NSTextField(labelWithString: "\(title)  \(String(format: "%.2f", value))")
        label.frame = NSRect(x: 14, y: 21, width: 190, height: 16)
        label.font = .menuFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        container.addSubview(label)

        let slider = NSSlider(value: Double(value), minValue: min, maxValue: max,
                              target: self, action: #selector(sliderChanged(_:)))
        slider.frame = NSRect(x: 14, y: 2, width: 192, height: 18)
        slider.identifier = NSUserInterfaceItemIdentifier(key)
        slider.controlSize = .small
        container.addSubview(slider)

        item.view = container
        sliderLabels[key] = (label, title)
        return item
    }
    private var sliderLabels: [String: (NSTextField, String)] = [:]

    @objc private func sliderChanged(_ s: NSSlider) {
        guard let key = s.identifier?.rawValue else { return }
        var p = session.params
        switch key {
        case "saturation": p.saturation = Float(s.doubleValue)
        case "sharpen":    p.sharpen = Float(s.doubleValue)
        case "contrast":   p.contrast = Float(s.doubleValue)
        default: break
        }
        session.params = p
        UserDefaults.standard.set(s.doubleValue, forKey: key)
        if let (label, title) = sliderLabels[key] {
            label.stringValue = "\(title)  \(String(format: "%.2f", s.doubleValue))"
        }
    }

    private func restoreParams() {
        var p = session.params
        let d = UserDefaults.standard
        if d.object(forKey: "saturation") != nil { p.saturation = Float(d.double(forKey: "saturation")) }
        if d.object(forKey: "sharpen") != nil    { p.sharpen = Float(d.double(forKey: "sharpen")) }
        if d.object(forKey: "contrast") != nil   { p.contrast = Float(d.double(forKey: "contrast")) }
        if d.object(forKey: "gamma") != nil      { p.gamma = Float(d.double(forKey: "gamma")) }
        session.params = p
    }

    /// SIGTERM/SIGINT'te telefon ekranini geri ac. Aksi halde uygulama
    /// disaridan oldurulunce telefon sonuk kalir ve kullanicinin elinde
    /// acmanin bariz bir yolu olmaz.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                Log.write("sinyal \(sig) alindi -> temizlik")
                self?.session.stop()
                NSApp.terminate(nil)
            }
            src.resume()
            signalSources.append(src)
        }
    }

    /// Global kisayol: ⌘⌥A ile pencereyi one getir.
    /// Carbon RegisterEventHotKey erisilebilirlik izni GEREKTIRMEZ —
    /// NSEvent global monitor'un aksine. LSUIElement uygulamasi Cmd+Tab'de
    /// gorunmedigi icin bu kisayol tek guvenilir geri donus yolu.
    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, evt, userData -> OSStatus in
            guard let userData, let evt else { return noErr }
            var hkID = EventHotKeyID()
            GetEventParameter(evt, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let me = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async {
                switch hkID.id {
                case 1: me.focusWindow()
                case 2: me.toggleSidebarShortcut()
                default: break
                }
            }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)

        let sig = OSType(0x414E4452)   // 'ANDR'
        var st = RegisterEventHotKey(UInt32(kVK_ANSI_A), UInt32(cmdKey | optionKey),
                                     EventHotKeyID(signature: sig, id: 1),
                                     GetApplicationEventTarget(), 0, &hotKeyRef)
        Log.write(st == noErr ? "global kisayol: ⌘⌥A (pencereyi one getir)"
                              : "⌘⌥A KAYDEDILEMEDI (\(st))")
        st = RegisterEventHotKey(UInt32(kVK_ANSI_S), UInt32(cmdKey | optionKey),
                                 EventHotKeyID(signature: sig, id: 2),
                                 GetApplicationEventTarget(), 0, &hotKeyRef2)
        Log.write(st == noErr ? "global kisayol: ⌘⌥S (paneli ac/kapa)"
                              : "⌘⌥S KAYDEDILEMEDI (\(st))")
    }

    // MARK: - Eylemler

    @objc private func toggleConnect() {
        switch session.state {
        case .idle, .failed:
            ensureWindow()
            // color-range zorlamasi KAPALI: MediaTek encoder'i etiketi
            // degistiriyor ama veriyi degistirmiyor -> yanlis cozumleme -> soluk.
            session.start(bitRate: bitRate, maxFPS: maxFPS, forceFullRange: false)
        default:
            session.stop()
            window?.orderOut(nil)
        }
    }

    /// Yansitma penceresini yikar.
    private func teardownMirrorWindow() {
        window?.orderOut(nil)
        window?.contentView = nil
        window?.close()
        window = nil
        view = nil
        content = nil
        session.view = nil
    }

    @objc private func focusWindow() {
        // Oturum yoksa yansitma penceresi de olmamali; kullaniciyi
        // donuk bir kareyle bas basa birakmak yerine ana pencereye al.
        guard case .running = session.state, let w = window else {
            showHub()
            return
        }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        w.makeFirstResponder(view)
    }

    @objc private func toggleOnTop() {
        alwaysOnTop.toggle()
        UserDefaults.standard.set(alwaysOnTop, forKey: "alwaysOnTop")
        topItem?.state = alwaysOnTop ? .on : .off
        window?.level = alwaysOnTop ? .floating : .normal
        focusWindow()
    }

    @objc private func toggleScreenOff() {
        screenOff.toggle()
        UserDefaults.standard.set(screenOff, forKey: "screenOff")
        screenItem?.state = screenOff ? .on : .off
        session.turnScreenOff = screenOff
        session.smoothing = smoothing
        session.clipboard.enabled = clipboardSync
        session.clipboard.onRecord = { text in ClipboardPanel.record(text) }
        NotificationCenter.default.addObserver(
            forName: .androsRequestPhoneClipboard, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if case .running = self.session.state {
                self.session.sendRaw(ControlMessage.getClipboard())
            } else {
                self.alert(title: L("Yansıtma kapalı", "Mirroring is off"),
                           body: L("Telefonun panosunu okumak için önce yansıtmayı başlat. "
                             + "Android 10+ arka planda pano okumaya izin vermiyor.",
                               "Start mirroring first to read the phone's clipboard. "
                             + "Android 10+ does not allow background clipboard reads."))
            }
        }
        session.audioEnabled = audioOn
        // Yayin surerken aninda uygula
        if case .running = session.state { session.setPhoneScreen(on: !screenOff) }
    }

    @objc private func toggleAudio() {
        audioOn.toggle()
        UserDefaults.standard.set(audioOn, forKey: "audioOn")
        audioItem?.state = audioOn ? .on : .off
        session.audioEnabled = audioOn
        alert(title: audioOn ? L("Ses açıldı", "Audio on") : L("Ses kapatıldı", "Audio off"),
              body: L("Değişikliğin etkili olması için yeniden bağlanman gerekiyor "
                      + "(ses kanalı oturum başında kuruluyor).",
                        "You need to reconnect for this to take effect "
                      + "(the audio channel is set up when the session starts)."))
    }

    @objc private func toggleClipboard() {
        clipboardSync.toggle()
        UserDefaults.standard.set(clipboardSync, forKey: "clipboardSync")
        clipItem?.state = clipboardSync ? .on : .off
        session.clipboard.enabled = clipboardSync
        session.clipboard.onRecord = { text in ClipboardPanel.record(text) }
        NotificationCenter.default.addObserver(
            forName: .androsRequestPhoneClipboard, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if case .running = self.session.state {
                self.session.sendRaw(ControlMessage.getClipboard())
            } else {
                self.alert(title: L("Yansıtma kapalı", "Mirroring is off"),
                           body: L("Telefonun panosunu okumak için önce yansıtmayı başlat. "
                             + "Android 10+ arka planda pano okumaya izin vermiyor.",
                               "Start mirroring first to read the phone's clipboard. "
                             + "Android 10+ does not allow background clipboard reads."))
            }
        }
        session.audioEnabled = audioOn
    }

    @objc private func toggleSmoothing() {
        smoothing.toggle()
        UserDefaults.standard.set(smoothing, forKey: "smoothing")
        smoothItem?.state = smoothing ? .on : .off
        session.smoothing = smoothing
        session.clipboard.enabled = clipboardSync
        session.clipboard.onRecord = { text in ClipboardPanel.record(text) }
        NotificationCenter.default.addObserver(
            forName: .androsRequestPhoneClipboard, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if case .running = self.session.state {
                self.session.sendRaw(ControlMessage.getClipboard())
            } else {
                self.alert(title: L("Yansıtma kapalı", "Mirroring is off"),
                           body: L("Telefonun panosunu okumak için önce yansıtmayı başlat. "
                             + "Android 10+ arka planda pano okumaya izin vermiyor.",
                               "Start mirroring first to read the phone's clipboard. "
                             + "Android 10+ does not allow background clipboard reads."))
            }
        }
        session.audioEnabled = audioOn
    }

    @objc private func wakePhone() {
        if case .running = session.state {
            session.setPhoneScreen(on: true)
        } else {
            alert(title: L("Bağlı değil", "Not connected"),
                  body: L("Ekranı açmak için önce bağlan, ya da Terminal'de:\n\nandrosctl screen on",
                "Connect first to wake the screen, or run in Terminal:\n\nandrosctl screen on"))
        }
    }

    @objc private func toggleAuto() {
        autoConnect.toggle()
        UserDefaults.standard.set(autoConnect, forKey: "autoConnect")
        autoItem?.state = autoConnect ? .on : .off
    }

    @objc private func quit() {
        session.stop()
        NSApp.terminate(nil)
    }

    /// LSUIElement uygulamasinda uyari gostermek icin once etkinlesmek gerekir.
    private func alert(title: String, body: String) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = title
            a.informativeText = body
            a.alertStyle = .warning
            a.addButton(withTitle: L("Tamam", "OK"))
            a.runModal()
        }
    }

    // MARK: - Yan panel

    private func handleSidebar(_ a: SidebarAction) {
        switch a {
        case .back:          session.tapKey(AKeycode.back)
        case .home:          session.tapKey(AKeycode.home)
        case .recents:       session.tapKey(AKeycode.appSwitch)
        case .volumeUp:      session.tapKey(AKeycode.volumeUp)
        case .volumeDown:    session.tapKey(AKeycode.volumeDown)
        case .power:         session.tapKey(AKeycode.power)
        case .notifications: session.sendRaw(ControlMessage.expandNotifications)
        case .rotate:        session.sendRaw(ControlMessage.rotateDevice)
        case .screenshot:    takeScreenshot()
        case .joystick:
            toggleKeyMapEditor()
        case .screenOff:
            screenOff.toggle()
            UserDefaults.standard.set(screenOff, forKey: "screenOff")
            screenItem?.state = screenOff ? .on : .off
            session.turnScreenOff = screenOff
            if case .running = session.state { session.setPhoneScreen(on: !screenOff) }
            refreshToggles()
        case .fullscreen:
            // ALT basiliysa: sanal masaustu ACMADAN ekrani kapla.
            // Normal tik: macOS'un kendi tam ekrani (ayri masaustu).
            if NSEvent.modifierFlags.contains(.option) { toggleCoverScreen() }
            else { toggleNativeFullscreen() }
        case .disconnect:    disconnectAndWake()
        case .macro:         showMacroWindow()
        case .flipSide:
            sidebarOnRight.toggle()
            UserDefaults.standard.set(sidebarOnRight, forKey: "sidebarRight")
            content?.sidebarOnRight = sidebarOnRight
        case .settings:      showSidebarSettings()
        }
    }

    /// Kenarliksiz pencerede AppKit'in toggleFullScreen'i calismiyordu
    /// (.titled olmayan pencere fullscreen'e girmiyor). Elle buyutuyoruz:
    /// onceki cerceveyi saklayip ekrani tamamen kaplayacak sekilde ayarliyoruz.
    private var preFullscreenFrame: NSRect?

    /// ALT + tam ekran: sanal masaustu acmadan ekrani kaplar.
    private func toggleCoverScreen() {
        guard let w = window, let scr = w.screen ?? NSScreen.main else { return }
        if let prev = preFullscreenFrame {
            w.setFrame(prev, display: true, animate: true)
            preFullscreenFrame = nil
            NSApp.presentationOptions = []
        } else {
            preFullscreenFrame = w.frame
            // Menu cubugu GIZLENMIYOR: bu gercek tam ekran degil, pencereyi
            // ekrana sigdiran bir buyutme. Menu cubugunu saklamak kullaniciyi
            // "tam ekrandayim" sanip Esc aramaya itiyordu; ayrica AndrOS'un
            // kendi menuleri erisilemez oluyordu.
            NSApp.presentationOptions = []

            // Pencereyi, EN-BOY ORANINI koruyarak ekrana sigan EN BUYUK
            // boyuta getir. Ekrani siyahla kaplamiyoruz; pencere tam
            // goruntunun sekli oluyor, dolayisiyla siyah kenarlik olusmuyor.
            // Yan panel de yerinde kaliyor, genisligi hesaba katiliyor.
            let vw = CGFloat(max(session.streamWidth, 1))
            let vh = CGFloat(max(session.streamHeight, 1))
            let bar = content?.sidebarWidth ?? 0
            let avail = scr.visibleFrame
            let scale = Swift.min((avail.width - bar) / vw, avail.height / vh)
            let size = NSSize(width: vw * scale + bar, height: vh * scale)
            let origin = NSPoint(x: avail.midX - size.width / 2,
                                 y: avail.midY - size.height / 2)
            w.setFrame(NSRect(origin: origin, size: size), display: true, animate: true)
        }
        w.makeKeyAndOrderFront(nil)
        content?.needsLayout = true
    }

    /// Normal tik: macOS'un kendi tam ekrani (ayri sanal masaustu).
    /// Kenarliksiz pencere bunu ancak .fullScreenPrimary davranisiyla yapar.
    private func toggleNativeFullscreen() {
        guard let w = window else { return }
        if !w.collectionBehavior.contains(.fullScreenPrimary) {
            w.collectionBehavior.insert(.fullScreenPrimary)
        }
        w.toggleFullScreen(nil)
    }

    /// Yayini kapatir ve telefonu KISA SURELIGINE uyandirir; boylece kablo
    /// takiliyken telefonu elle kullanabilirsin. Uygulama acik kalir.
    private func disconnectAndWake() {
        session.setPhoneScreen(on: true)
        session.tapKey(AKeycode.back)   // ekrani uyanik tutan dokunma benzeri
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.session.stop()
            if let prev = self.preFullscreenFrame {
                self.window?.setFrame(prev, display: false)
                self.preFullscreenFrame = nil
                NSApp.presentationOptions = []
            }
            // Pencereyi GIZLEMEK yetmiyor: nesne ayakta kaldigi icin
            // ⌘⌥A ya da uygulamaya odaklanmak onu geri getiriyordu —
            // oturum kapali oldugundan donuk bir kare gorunuyor, panelde
            // "Baslat" yaziyor ama hicbir sey hareket etmiyordu.
            // Tamamen yikip bir sonraki baslatmada yeniden kuruyoruz.
            self.teardownMirrorWindow()
            Log.write("yayin kapatildi, telefon uyandirildi")
            self.showHub()          // kabuga geri don
        }
    }

    /// Duzenleyiciyi ac/kapa. Acikken oyuna girdi GITMEZ; isaretciler
    /// surukle-birak ile tasinir, tiklayinca tus atanir.
    private func toggleKeyMapEditor() {
        guard let c = content else { return }
        if c.editor.isHidden {
            c.editor.videoRect = c.mirror.videoRect
            c.editor.isHidden = false
            c.editor.needsDisplay = true
            window?.makeFirstResponder(c.editor)
            // Duzenleme sirasinda basili kalan parmaklar birakilsin
            session.keyMapper.releaseAll()
            showEditorToolbar()
        } else {
            closeKeyMapEditor()
        }
    }

    private func closeKeyMapEditor() {
        guard let c = content else { return }
        c.editor.isHidden = true
        session.keyMapper.save()
        editorToolbar?.close()
        editorToolbar = nil
        window?.makeFirstResponder(c.mirror)
    }

    /// Duzenleyici acikken ustte duran kucuk arac cubugu: ac/kapa + varsayilana don.
    private func showEditorToolbar() {
        editorToolbar?.close()
        guard let w = window, let c = content else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 44),
                            styleMask: [.titled, .utilityWindow, .hudWindow],
                            backing: .buffered, defer: false)
        panel.title = L("Tuş haritalama", "Key mapping")
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false

        let sw = NSSwitch()
        sw.state = session.keyMapper.enabled ? .on : .off
        sw.target = self
        sw.action = #selector(editorToggleEnabled(_:))
        row.addArrangedSubview(NSTextField(labelWithString: L("Etkin", "Enabled")))
        row.addArrangedSubview(sw)

        row.addArrangedSubview(NSBox.vSeparator())

        // Olu bolge: cok kucuk yonlendirmeleri yok say
        row.addArrangedSubview(NSTextField(labelWithString: L("Ölü bölge", "Dead zone")))
        let dz = NSSlider(value: session.keyMapper.deadZone, minValue: 0, maxValue: 0.5,
                          target: self, action: #selector(editorDeadZone(_:)))
        dz.controlSize = .small
        dz.widthAnchor.constraint(equalToConstant: 70).isActive = true
        row.addArrangedSubview(dz)

        // Oynarken isaretcileri saydam olarak goster
        let ov = NSButton(checkboxWithTitle: L("Kılavuz", "Guide"), target: self,
                          action: #selector(editorShowOverlay(_:)))
        ov.state = showGuide ? .on : .off
        row.addArrangedSubview(ov)

        // Sag tik ile kamera surukleme (MMO'larda etrafa bakinmak icin)
        let cam = NSButton(checkboxWithTitle: L("Sağ tık = kamera", "Right click = camera"), target: self,
                           action: #selector(editorCameraDrag(_:)))
        cam.state = session.cameraDrag ? .on : .off
        row.addArrangedSubview(cam)

        row.addArrangedSubview(NSBox.vSeparator())

        let reset = NSButton(title: L("Sıfırla", "Reset"), target: self,
                             action: #selector(editorReset))
        reset.bezelStyle = .rounded
        row.addArrangedSubview(reset)

        let done = NSButton(title: L("Bitti", "Done"), target: self, action: #selector(editorDone))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        row.addArrangedSubview(done)

        let host = NSView()
        host.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            row.topAnchor.constraint(equalTo: host.topAnchor),
            row.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        panel.contentView = host
        let f = w.frame
        panel.setFrameOrigin(NSPoint(x: f.midX - 320, y: f.maxY - 70))
        panel.orderFront(nil)
        editorToolbar = panel
        _ = c
    }

    @objc private func editorToggleEnabled(_ s: NSSwitch) {
        session.keyMapper.enabled = (s.state == .on)
        refreshToggles()
    }

    @objc private func editorDeadZone(_ s: NSSlider) {
        session.keyMapper.deadZone = s.doubleValue
        session.keyMapper.save()
    }

    @objc private func editorShowOverlay(_ b: NSButton) {
        showGuide = b.state == .on
        UserDefaults.standard.set(showGuide, forKey: "showGuide")
        content?.guide.isHidden = !showGuide
        content?.guide.needsDisplay = true
    }

    @objc private func editorCameraDrag(_ b: NSButton) {
        session.cameraDrag = b.state == .on
        UserDefaults.standard.set(session.cameraDrag, forKey: "cameraDrag")
        view?.cameraDragEnabled = session.cameraDrag
    }

    @objc private func editorReset() {
        UserDefaults.standard.removeObject(forKey: "keymapProfile")
        let fresh = KeyMapper()
        session.keyMapper.stickCenter = fresh.stickCenter
        session.keyMapper.stickRadius = fresh.stickRadius
        session.keyMapper.bindings = fresh.bindings
        session.keyMapper.save()
        content?.editor.needsDisplay = true
    }

    @objc private func editorDone() { closeKeyMapEditor() }

    private func refreshTogglesSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refreshToggles()
        }
    }

    private func refreshToggles() {
        content?.sidebar.toggleStates = [
            .joystick: session.keyMapper.enabled,
            .screenOff: screenOff,
            .macro: macroEngine.state != .idle,
        ]
    }

    private func showMacroWindow() {
        if macroWC == nil {
            macroWC = MacroWindowController(
                engine: macroEngine,
                onRecordToggle: { [weak self] rec in
                    self?.refreshToggles()
                    if rec { self?.focusWindow() }   // kayit icin ayna one gelsin
                },
                onPlay: { [weak self] m, speed, loops in
                    self?.macroEngine.play(m, speed: speed, loops: loops)
                },
                onStop: { [weak self] in self?.macroEngine.stop() })
        }
        macroWC?.showWindow(nil)
        macroWC?.window?.makeKeyAndOrderFront(nil)
    }

    /// Son kareyi panoya ve ~/Pictures altina kaydeder.
    private func takeScreenshot() {
        guard let png = session.screenshotPNG() else {
            alert(title: L("Ekran görüntüsü alınamadı", "Screenshot failed"), body: L("Henüz çizilmiş kare yok.", "No frame has been drawn yet."))
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(png, forType: .png)

        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let dir = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AndrOS", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("AndrOS_\(fmt.string(from: Date())).png")
        try? png.write(to: url)
        Log.write("ekran goruntusu: pano + \(url.path)")

        // Kisa gorsel geri bildirim
        NSSound(named: "Grab")?.play()
    }

    /// Panel ayarlari: hangi dugmeler gorunsun, taraf, paneli gizle.
    private func showSidebarSettings() {
        settingsPopover?.close()
        guard let content else { return }

        let vc = NSViewController()
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 0))
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // --- DINAMIK yansitma ayarlari: yayin sururken degistirilebilenler
        // burada. Baslatmadan once secilenler (bit hizi, FPS) ana uygulamada.
        let live = NSTextField(labelWithString: L("Yansıtma", "Mirroring"))
        live.font = .boldSystemFont(ofSize: 12)
        stack.addArrangedSubview(live)

        for (title, key, fallback) in [
            (L("Telefon ekranını kapat", "Turn the phone screen off"), "screenOff", true),
            ("Sesi Mac'e aktar", "audioOn", true),
            (L("Akıcılık önceliği", "Prefer smoothness"), "smoothing", true),
            ("Pano senkronizasyonu", "clipboardSync", true),
            (L("Her zaman üstte", "Always on top"), "alwaysOnTop", false),
            (L("Kılavuzu göster", "Show guide"), "showGuide", false),
            (L("Sağ tık = kamera", "Right click = camera"), "cameraDrag", true),
        ] {
            let cb = NSButton(checkboxWithTitle: title, target: self,
                              action: #selector(panelToggle(_:)))
            cb.state = (UserDefaults.standard.object(forKey: key) as? Bool ?? fallback)
                ? .on : .off
            cb.identifier = NSUserInterfaceItemIdentifier(key)
            cb.font = .systemFont(ofSize: 12)
            stack.addArrangedSubview(cb)
        }

        let img = NSTextField(labelWithString: L("Görüntü", "Image"))
        img.font = .boldSystemFont(ofSize: 12)
        stack.addArrangedSubview(img)
        for (t, key, lo, hi, def) in [
            ("Doygunluk", "saturation", 0.5, 2.0, 1.15),
            ("Keskinlik", "sharpen",    0.0, 1.5, 0.45),
            ("Kontrast",  "contrast",   0.7, 1.6, 1.05),
            ("Gama",      "gamma",      0.7, 1.5, 1.00),
        ] {
            stack.addArrangedSubview(panelSlider(t, key, lo, hi, def))
        }
        let resetImg = NSButton(title: L("Görüntüyü sıfırla", "Reset image"), target: self,
                                action: #selector(panelResetImage))
        resetImg.bezelStyle = .rounded
        stack.addArrangedSubview(resetImg)

        let sep0 = NSBox(); sep0.boxType = .separator
        sep0.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(sep0)
        sep0.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true

        let title = NSTextField(labelWithString: L("Panel düğmeleri", "Panel buttons"))
        title.font = .boldSystemFont(ofSize: 12)
        stack.addArrangedSubview(title)

        for a in SidebarAction.allCases where a != .settings {
            let cb = NSButton(checkboxWithTitle: a.title, target: self,
                              action: #selector(toggleSidebarAction(_:)))
            cb.state = enabledActions.contains(a) ? .on : .off
            cb.identifier = NSUserInterfaceItemIdentifier(a.rawValue)
            cb.font = .systemFont(ofSize: 12)
            stack.addArrangedSubview(cb)
        }

        let sep = NSBox(); sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(sep)
        sep.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true

        let side = NSButton(checkboxWithTitle: L("Panel sağda", "Panel on the right"), target: self,
                            action: #selector(toggleSidebarSide))
        side.state = sidebarOnRight ? .on : .off
        side.font = .systemFont(ofSize: 12)
        stack.addArrangedSubview(side)

        let vis = NSButton(checkboxWithTitle: L("Paneli göster", "Show panel"), target: self,
                           action: #selector(toggleSidebarVisible))
        vis.state = sidebarVisible ? .on : .off
        vis.font = .systemFont(ofSize: 12)
        stack.addArrangedSubview(vis)

        let hint = NSTextField(labelWithString: L("Panel gizliyken ⌘⌥S ile geri getir", "Bring the panel back with ⌘⌥S"))
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(hint)

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: 280),
        ])
        vc.view = root

        let pop = NSPopover()
        pop.contentViewController = vc
        pop.behavior = .transient
        if let btn = content.sidebar.subviews.first {
            pop.show(relativeTo: content.sidebar.bounds, of: content.sidebar,
                     preferredEdge: sidebarOnRight ? .minX : .maxX)
            _ = btn
        }
        settingsPopover = pop
    }

    /// Paneldeki dinamik ayar anahtarlari.
    @objc private func panelToggle(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        let on = sender.state == .on
        UserDefaults.standard.set(on, forKey: key)
        switch key {
        case "screenOff":
            screenOff = on
            session.turnScreenOff = on
            screenItem?.state = on ? .on : .off
            if case .running = session.state { session.setPhoneScreen(on: !on) }
            refreshToggles()
        case "audioOn":
            audioOn = on
            session.audioEnabled = on
            audioItem?.state = on ? .on : .off
        case "smoothing":
            smoothing = on
            session.smoothing = on
        case "clipboardSync":
            clipboardSync = on
            session.clipboard.enabled = on
        case "alwaysOnTop":
            alwaysOnTop = on
            window?.level = on ? .floating : .normal
        case "showGuide":
            showGuide = on
            content?.guide.isHidden = !on
            content?.guide.needsDisplay = true
        case "cameraDrag":
            session.cameraDrag = on
            view?.cameraDragEnabled = on
        default: break
        }
        Log.write("panel ayari: \(key) = \(on)")
    }

    private var panelSliderLabels: [String: (NSTextField, String)] = [:]
    private var panelSliders: [String: NSSlider] = [:]

    private func panelSlider(_ title: String, _ key: String,
                             _ lo: Double, _ hi: Double, _ def: Double) -> NSView {
        let v = UserDefaults.standard.object(forKey: key) as? Double ?? def
        let label = NSTextField(labelWithString: String(format: "%@  %.2f", title, v))
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 104).isActive = true

        let sl = NSSlider(value: v, minValue: lo, maxValue: hi,
                          target: self, action: #selector(panelSliderMoved(_:)))
        sl.controlSize = .small
        sl.identifier = NSUserInterfaceItemIdentifier(key)
        sl.translatesAutoresizingMaskIntoConstraints = false
        sl.widthAnchor.constraint(equalToConstant: 130).isActive = true

        panelSliderLabels[key] = (label, title)
        panelSliders[key] = sl
        let row = NSStackView(views: [label, sl])
        row.orientation = .horizontal
        row.spacing = 6
        return row
    }

    @objc private func panelSliderMoved(_ sender: NSSlider) {
        guard let key = sender.identifier?.rawValue else { return }
        let v = sender.doubleValue
        UserDefaults.standard.set(v, forKey: key)
        if let (l, t) = panelSliderLabels[key] {
            l.stringValue = String(format: "%@  %.2f", t, v)
        }
        var p = session.params
        switch key {
        case "saturation": p.saturation = Float(v)
        case "sharpen":    p.sharpen = Float(v)
        case "contrast":   p.contrast = Float(v)
        default:           p.gamma = Float(v)
        }
        session.params = p
    }

    @objc private func panelResetImage() {
        for (k, v) in ["saturation": 1.15, "sharpen": 0.45, "contrast": 1.05, "gamma": 1.0] {
            UserDefaults.standard.set(v, forKey: k)
            panelSliders[k]?.doubleValue = v
            if let (l, t) = panelSliderLabels[k] { l.stringValue = String(format: "%@  %.2f", t, v) }
        }
        var p = session.params
        p.saturation = 1.15; p.sharpen = 0.45; p.contrast = 1.05; p.gamma = 1.0
        session.params = p
    }

    @objc private func toggleSidebarAction(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let a = SidebarAction(rawValue: id) else { return }
        if sender.state == .on {
            if !enabledActions.contains(a) {
                // Varsayilan sirayi koru
                enabledActions = SidebarAction.defaultOrder.filter {
                    enabledActions.contains($0) || $0 == a
                }
            }
        } else {
            enabledActions.removeAll { $0 == a }
        }
        if !enabledActions.contains(.settings) { enabledActions.append(.settings) }
        UserDefaults.standard.set(enabledActions.map(\.rawValue), forKey: "sidebarActions")
        content?.sidebar.visibleActions = enabledActions
        refreshToggles()
    }

    @objc private func toggleSidebarSide(_ sender: NSButton) {
        sidebarOnRight = sender.state == .on
        UserDefaults.standard.set(sidebarOnRight, forKey: "sidebarRight")
        content?.sidebarOnRight = sidebarOnRight
    }

    @objc private func toggleSidebarVisible(_ sender: NSButton) {
        sidebarVisible = sender.state == .on
        UserDefaults.standard.set(sidebarVisible, forKey: "sidebarVisible")
        content?.sidebarVisible = sidebarVisible
        syncPanelMenuTitle()
    }

    @objc func toggleSidebarShortcut() {
        sidebarVisible.toggle()
        UserDefaults.standard.set(sidebarVisible, forKey: "sidebarVisible")
        content?.sidebarVisible = sidebarVisible
        syncPanelMenuTitle()
    }

    /// Menudeki "Paneli Gizle/Goster" basligini durumla ayni tutar.
    private func syncPanelMenuTitle() {
        guard let mirror = NSApp.mainMenu?.items
                .first(where: { $0.identifier?.rawValue == "mirror" })?.submenu,
              let it = mirror.items
                .first(where: { $0.identifier?.rawValue == "panelToggle" }) else { return }
        it.title = sidebarVisible ? L("Paneli Gizle", "Hide Panel")
                                  : L("Paneli Göster", "Show Panel")
    }

    // MARK: - Pencere

    private func ensureWindow() {
        guard window == nil else { return }
        let v = MetalView(frame: NSRect(x: 0, y: 0, width: 960, height: 432))
        view = v
        session.view = v
        let container = MirrorContentView(mirror: v)
        container.sidebarOnRight = sidebarOnRight
        container.sidebarVisible = sidebarVisible
        container.sidebar.visibleActions = enabledActions
        container.sidebar.onAction = { [weak self] a in self?.handleSidebar(a) }
        container.sidebar.onRightClick = { [weak self] a in
            // Gamepad'e SAG tik: duzenleyiciyi acmadan dogrudan ac/kapa.
            guard a == .joystick, let self else { return }
            self.session.keyMapper.enabled.toggle()
            self.refreshToggles()
        }
        container.editor.mapper = session.keyMapper
        container.editor.onChange = { [weak self] in self?.session.keyMapper.save() }
        container.editor.onClose = { [weak self] in self?.closeKeyMapEditor() }
        session.keyMapper.load()
        macroEngine.load()
        // Oynatim: oransal konumu akis pikseline cevirip dokunma gonder.
        macroEngine.emit = { [weak self] action, nx, ny in
            guard let self else { return }
            let w = self.session.streamWidth, h = self.session.streamHeight
            guard w > 0 else { return }
            self.session.sendMacroTouch(action, x: Int(nx * Double(w)), y: Int(ny * Double(h)))
        }
        macroEngine.onStateChange = { [weak self] st in
            DispatchQueue.main.async {
                self?.refreshToggles()
                if st == .idle { self?.macroWC?.playbackFinished() }
            }
        }
        // Aynadaki her dokunma kayda da dussun.
        v.onTouchNormalized = { [weak self] a, nx, ny in
            self?.macroEngine.record(a, nx: nx, ny: ny)
        }
        session.cameraDrag = UserDefaults.standard.object(forKey: "cameraDrag") as? Bool ?? true
        v.cameraDragEnabled = session.cameraDrag
        container.guide.mapper = session.keyMapper
        container.guide.isHidden = !showGuide
        content = container

        v.onTouch  = { [weak self] a, x, y in self?.session.sendTouch(a, x: x, y: y) }
        v.onScroll = { [weak self] x, y, h, vv in self?.session.sendScroll(x: x, y: y, h: h, v: vv) }
        v.onCamera = { [weak self] a, x, y in self?.session.sendCamera(a, x: x, y: y) }
        v.onKey    = { [weak self] k, down in self?.session.sendKey(k, down: down) }
        v.onRawKey = { [weak self] code, down in
            self?.session.keyMapper.handle(keyCode: code, isDown: down) ?? false
        }

        let w = MirrorWindow(contentRect: v.frame,
                             styleMask: [.borderless, .resizable],
                             backing: .buffered, defer: false)
        w.title = "AndrOS"
        // Dock ikonu olmadigi icin pencere arkaya duserse geri getirilemiyordu.
        // Her zaman ustte tutmak bunu yapisal olarak cozuyor.
        w.level = alwaysOnTop ? .floating : .normal
        w.collectionBehavior = [.managed, .fullScreenAuxiliary]
        // KAPALI: acik olsaydi surukleme pencereyi tasirdi ve oyunda
        // kaydirma/bildirim paneli cekme yapilamazdi.
        w.isMovableByWindowBackground = false
        w.isMovable = false          // sistemin kendi tasima yollarini da kapat
        w.hasShadow = true
        // Kose yuvarlaklarinin disi seffaf kalsin, golge duzgun otursun.
        w.backgroundColor = .clear
        w.isOpaque = false
        w.contentView = container
        w.delegate = self
        w.center()
        w.isReleasedWhenClosed = false
        window = w
    }

    /// Pencereyi kare gelmeden de gosterir. Aksi halde baglanti/kilit
    /// bekleme sirasinda hicbir sey gorunmuyor ve uygulama bozuk saniliyor.
    private func showWindowNow() {
        guard !mirrorEmbedded else { return }   // gomuluyken ayri pencere yok
        ensureWindow()
        guard let w = window else { return }
        if !w.isVisible {
            if w.frame.width < 200 {
                w.setContentSize(NSSize(width: 720, height: 380))
                w.center()
            }
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func resizeWindow(_ vw: Int, _ vh: Int) {
        guard !mirrorEmbedded else { return }   // boyutu ana pencere yonetiyor
        guard let w = window, vw > 0, vh > 0 else { return }
        let bar = content?.sidebarWidth ?? 0
        // contentAspectRatio KULLANMIYORUZ: panel sabit genislikte oldugu icin
        // pencere buyudukce oran kayiyor ve ust/alt siyah bar olusuyordu.
        // Bunun yerine windowWillResize'da yuksekligi tam hesapliyoruz.
        w.contentAspectRatio = .zero
        // Yukseklik alt siniri panele DEGIL, makul bir asgariye bagli:
        // panel sigmazsa kendi icinde kayiyor. Aksi halde yatay goruntude
        // pencere zorla yukseliyor ve yanlarda siyah bosluk kaliyor.
        w.contentMinSize = NSSize(width: 240 + bar, height: 200)
        // Ekrana sigan en buyuk tam sayi olcegi sec (yumusak olmayan buyutme icin)
        let vis = w.screen?.visibleFrame.size ?? NSSize(width: 1920, height: 1080)
        let scale = Swift.min((vis.width * 0.9 - bar) / CGFloat(vw), (vis.height * 0.9) / CGFloat(vh))
        let size = NSSize(width: CGFloat(vw) * scale + bar, height: CGFloat(vh) * scale)
        w.setContentSize(size)
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Klavye olaylari MetalView'a gitsin
        w.makeFirstResponder(view)
    }

    /// Kullanici pencereyi yeniden boyutlandirirken yuksekligi, goruntunun
    /// oranina TAM oturacak sekilde hesapliyoruz. Boylece hicbir boyutta
    /// ust/alt siyah bar olusmuyor — pencere daima goruntunun sekli oluyor.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let vw = CGFloat(session.streamWidth), vh = CGFloat(session.streamHeight)
        guard vw > 0, vh > 0 else { return frameSize }

        let bar = content?.sidebarWidth ?? 0
        // Cerceve -> icerik farki (kenarliksiz pencerede ~0, yine de dogru olsun)
        let chrome = sender.frame.height - sender.contentLayoutRect.height
        var contentW = frameSize.width - (sender.frame.width - sender.contentLayoutRect.width)
        let minW = 240 + bar
        contentW = Swift.max(contentW, minW)

        var contentH = (contentW - bar) * vh / vw
        let minH: CGFloat = 200
        if contentH < minH {
            contentH = minH
            contentW = contentH * vw / vh + bar
        }
        return NSSize(width: contentW + (sender.frame.width - sender.contentLayoutRect.width),
                      height: contentH + chrome)
    }

    private func updateUI(_ s: MirrorSession.State) {
        switch s {
        case .idle:
            statusMenuItem?.title = L("Bağlı değil", "Not connected")
            connectItem?.title = L("Bağlan", "Connect")
            statusItem?.button?.contentTintColor = nil
            content?.status.hide()
        case .connecting:
            statusMenuItem?.title = L("Bağlanıyor…", "Connecting…")
            connectItem?.title = L("İptal", "Cancel")
            content?.status.show(title: L("Bağlanıyor…", "Connecting…"),
                                 detail: L("Telefona bağlanılıyor.", "Connecting to the phone."),
                                 symbol: "cable.connector", busy: true)
            showWindowNow()
        case .running:
            statusMenuItem?.title = L("Yayında — \(session.streamWidth)x\(session.streamHeight)", "Streaming — \(session.streamWidth)x\(session.streamHeight)")
            connectItem?.title = L("Bağlantıyı kes", "Disconnect")
            statusItem?.button?.contentTintColor = nil
            content?.status.hide()
        case .failed(let e):
            statusMenuItem?.title = L("Hata: ", "Error: ") + e.prefix(48)
            connectItem?.title = L("Yeniden dene", "Try again")
            statusItem?.button?.contentTintColor = nil
            // Pencereyi KAPATMIYORUZ: kapatmak windowWillClose -> stop()
            // zincirini tetikleyip durumu daha da karistiriyordu.
            // Bunun yerine ne oldugunu pencerede gosteriyoruz.
            content?.status.show(title: L("Bağlanılamadı", "Could not connect"), detail: e,
                                 symbol: "exclamationmark.triangle", busy: false)
            showWindowNow()
        }
    }

    func windowWillClose(_ n: Notification) {
        Log.write("pencere kapaniyor -> oturum durduruluyor")
        session.stop()
    }
}
