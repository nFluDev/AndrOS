import AppKit

/// Makro yoneticisi: kaydet, oynat, hiz sec, adimlari duzenle.
final class MacroWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {

    private let engine: MacroEngine
    private var onRecordToggle: (Bool) -> Void
    private var onPlay: (Macro, Double, Int) -> Void
    private var onStop: () -> Void

    private let macroTable = NSTableView()
    private let stepTable = NSTableView()
    private let speedPopup = NSPopUpButton()
    private let loopField = NSTextField()
    private let recordButton = NSButton()
    private let playButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: L("Hazır", "Ready"))

    private var selected: Int? {
        macroTable.selectedRow >= 0 && macroTable.selectedRow < engine.macros.count
            ? macroTable.selectedRow : nil
    }

    init(engine: MacroEngine,
         onRecordToggle: @escaping (Bool) -> Void,
         onPlay: @escaping (Macro, Double, Int) -> Void,
         onStop: @escaping () -> Void) {
        self.engine = engine
        self.onRecordToggle = onRecordToggle
        self.onPlay = onPlay
        self.onStop = onStop

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 380),
                         styleMask: [.titled, .closable, .resizable, .utilityWindow],
                         backing: .buffered, defer: false)
        w.title = "Makrolar"
        super.init(window: w)
        buildUI()
        engine.load()
        macroTable.reloadData()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        guard let w = window else { return }
        let root = NSView()

        // --- Ust satir: kayit / oynat / hiz / dongu
        recordButton.title = L("● Kaydet", "● Record")
        recordButton.bezelStyle = .rounded
        recordButton.target = self; recordButton.action = #selector(toggleRecord)

        playButton.title = "▶ Oynat"
        playButton.bezelStyle = .rounded
        playButton.target = self; playButton.action = #selector(togglePlay)

        for (label, _) in MacroEngine.speedOptions { speedPopup.addItem(withTitle: label) }
        speedPopup.selectItem(at: 3)                 // 1x
        speedPopup.target = self; speedPopup.action = #selector(speedChanged)

        loopField.stringValue = "1"
        loopField.placeholderString = L("döngü", "loops")
        loopField.widthAnchor.constraint(equalToConstant: 46).isActive = true

        let top = NSStackView(views: [
            recordButton, playButton,
            NSTextField(labelWithString: L("Hız:", "Speed:")), speedPopup,
            NSTextField(labelWithString: L("Döngü:", "Loops:")), loopField,
            statusLabel,
        ])
        top.orientation = .horizontal
        top.spacing = 8
        statusLabel.textColor = .secondaryLabelColor

        // --- Makro listesi
        macroTable.addTableColumn({
            let c = NSTableColumn(identifier: .init("name")); c.title = "Makro"; c.width = 150; return c }())
        macroTable.addTableColumn({
            let c = NSTableColumn(identifier: .init("len")); c.title = L("Süre", "Duration"); c.width = 70; return c }())
        macroTable.dataSource = self; macroTable.delegate = self
        macroTable.rowHeight = 20
        let macroScroll = NSScrollView()
        macroScroll.documentView = macroTable
        macroScroll.hasVerticalScroller = true
        macroScroll.borderType = .bezelBorder

        // --- Adim listesi (duzenlenebilir)
        for (id, title, wd) in [("t","ms",60), ("act","olay",70), ("pos","konum",110)] {
            let c = NSTableColumn(identifier: .init(id)); c.title = title
            c.width = CGFloat(wd); stepTable.addTableColumn(c)
        }
        stepTable.dataSource = self; stepTable.delegate = self
        stepTable.rowHeight = 18
        let stepScroll = NSScrollView()
        stepScroll.documentView = stepTable
        stepScroll.hasVerticalScroller = true
        stepScroll.borderType = .bezelBorder

        let delMacro = NSButton(title: L("Makroyu sil", "Delete Macro"), target: self, action: #selector(deleteMacro))
        delMacro.bezelStyle = .rounded
        let renameMacro = NSButton(title: L("Yeniden adlandır", "Rename"), target: self, action: #selector(renameMacro))
        renameMacro.bezelStyle = .rounded
        let delStep = NSButton(title: L("Adımı sil", "Delete Step"), target: self, action: #selector(deleteStep))
        delStep.bezelStyle = .rounded

        let leftCol = NSStackView(views: [macroScroll,
                                          NSStackView(views: [renameMacro, delMacro])])
        leftCol.orientation = .vertical; leftCol.spacing = 6
        (leftCol.views[1] as? NSStackView)?.orientation = .horizontal

        let rightCol = NSStackView(views: [stepScroll, delStep])
        rightCol.orientation = .vertical; rightCol.spacing = 6
        rightCol.alignment = .leading

        let cols = NSStackView(views: [leftCol, rightCol])
        cols.orientation = .horizontal
        cols.distribution = .fillEqually
        cols.spacing = 10

        let hint = NSTextField(labelWithString:
            L("Kaydet'e bas, aynada fareyle oyna, tekrar bas. Hız −10x (10 kat yavaş) ile 50x arası. Döngü 0 = sonsuz.", "Hit Record, play with the mouse in the mirror, hit it again. Speed ranges from -10x (10x slower) to 50x. Loops 0 = forever."))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor

        let main = NSStackView(views: [top, cols, hint])
        main.orientation = .vertical
        main.alignment = .leading
        main.spacing = 10
        main.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        main.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(main)
        NSLayoutConstraint.activate([
            main.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            main.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            main.topAnchor.constraint(equalTo: root.topAnchor),
            main.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            cols.widthAnchor.constraint(equalTo: main.widthAnchor, constant: -24),
            cols.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),
        ])
        w.contentView = root
    }

    // MARK: - Eylemler

    @objc private func toggleRecord() {
        if engine.state == .recording {
            let name = "Makro \(engine.macros.count + 1)"
            _ = engine.stopRecording(name: name)
            recordButton.title = L("● Kaydet", "● Record")
            statusLabel.stringValue = L("Kaydedildi", "Recorded")
            onRecordToggle(false)
            macroTable.reloadData()
        } else {
            engine.startRecording()
            recordButton.title = L("■ Durdur", "■ Stop")
            statusLabel.stringValue = L("Kaydediliyor — aynada fareyle oyna", "Recording — play with the mouse in the mirror")
            onRecordToggle(true)
        }
    }

    @objc private func togglePlay() {
        if engine.state == .playing { onStop(); playButton.title = "▶ Oynat"; return }
        guard let i = selected else {
            statusLabel.stringValue = L("Önce bir makro seç", "Select a macro first")
            return
        }
        let factor = MacroEngine.speedOptions[speedPopup.indexOfSelectedItem].factor
        let loops = max(Int(loopField.stringValue) ?? 1, 0)
        engine.macros[i].speed = factor
        engine.macros[i].loops = loops
        engine.save()
        playButton.title = L("■ Durdur", "■ Stop")
        statusLabel.stringValue = L("Oynatılıyor ", "Playing ") + MacroEngine.speedOptions[speedPopup.indexOfSelectedItem].label
        onPlay(engine.macros[i], factor, loops)
    }

    func playbackFinished() {
        playButton.title = "▶ Oynat"
        statusLabel.stringValue = L("Bitti", "Done")
    }

    @objc private func speedChanged() {
        guard let i = selected else { return }
        engine.macros[i].speed = MacroEngine.speedOptions[speedPopup.indexOfSelectedItem].factor
        engine.save()
    }

    @objc private func deleteMacro() {
        guard let i = selected else { return }
        engine.macros.remove(at: i); engine.save()
        macroTable.reloadData(); stepTable.reloadData()
    }

    @objc private func renameMacro() {
        guard let i = selected else { return }
        let a = NSAlert()
        a.messageText = L("Makro adı", "Macro name")
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        f.stringValue = engine.macros[i].name
        a.accessoryView = f
        a.addButton(withTitle: L("Tamam", "OK")); a.addButton(withTitle: L("Vazgeç", "Cancel"))
        if a.runModal() == .alertFirstButtonReturn, !f.stringValue.isEmpty {
            engine.macros[i].name = f.stringValue
            engine.save(); macroTable.reloadData()
        }
    }

    @objc private func deleteStep() {
        guard let i = selected, stepTable.selectedRow >= 0,
              stepTable.selectedRow < engine.macros[i].steps.count else { return }
        engine.macros[i].steps.remove(at: stepTable.selectedRow)
        engine.save(); stepTable.reloadData()
    }

    // MARK: - Tablo

    func numberOfRows(in t: NSTableView) -> Int {
        if t === macroTable { return engine.macros.count }
        guard let i = selected else { return 0 }
        return engine.macros[i].steps.count
    }

    func tableView(_ t: NSTableView, objectValueFor col: NSTableColumn?, row: Int) -> Any? {
        if t === macroTable {
            let m = engine.macros[row]
            return col?.identifier.rawValue == "name"
                ? m.name : String(format: "%.1f sn", m.durationMs / 1000)
        }
        guard let i = selected, row < engine.macros[i].steps.count else { return nil }
        let s = engine.macros[i].steps[row]
        switch col?.identifier.rawValue {
        case "t":   return String(format: "%.0f", s.t)
        case "act": return s.actionName
        default:    return String(format: "%.3f, %.3f", s.nx, s.ny)
        }
    }

    func tableViewSelectionDidChange(_ n: Notification) {
        guard let t = n.object as? NSTableView, t === macroTable else { return }
        stepTable.reloadData()
        if let i = selected,
           let idx = MacroEngine.speedOptions.firstIndex(where: {
               abs($0.factor - engine.macros[i].speed) < 0.001 }) {
            speedPopup.selectItem(at: idx)
            loopField.stringValue = "\(engine.macros[i].loops)"
        }
    }
}
