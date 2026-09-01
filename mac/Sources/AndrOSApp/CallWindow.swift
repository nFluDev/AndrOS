import AppKit
import AndrOSCore

/// Arama penceresi: gelen arama, giden arama ve gorusme.
///
/// Tek pencere uc durumu birden gosteriyor. Ayri pencereler yapmak
/// durum degisiminde pencere kapanip acilmasi demekti — arama kabul
/// edilirken ekranin yanip sonmesi kotu durur.
final class CallWindowController: NSWindowController {

    static let shared = CallWindowController()

    private let avatar = AvatarView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let stateLabel = NSTextField(labelWithString: "")
    private let noteLabel = NSTextField(wrappingLabelWithString: "")
    private let buttons = NSStackView()
    private let quickBox = NSPopUpButton()

    private var peer = ""

    convenience init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 380),
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = L("Arama", "Call")
        w.isReleasedWhenClosed = false
        w.level = .floating          // arama her seyin ustunde durmali
        w.center()
        self.init(window: w)

        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.widthAnchor.constraint(equalToConstant: 86).isActive = true
        avatar.heightAnchor.constraint(equalToConstant: 86).isActive = true

        nameLabel.font = .systemFont(ofSize: 19, weight: .semibold)
        nameLabel.alignment = .center
        stateLabel.font = .systemFont(ofSize: 12)
        stateLabel.textColor = .secondaryLabelColor
        stateLabel.alignment = .center
        noteLabel.font = .systemFont(ofSize: 12)
        noteLabel.alignment = .center
        noteLabel.textColor = .systemOrange
        noteLabel.isHidden = true
        noteLabel.preferredMaxLayoutWidth = 260

        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.alignment = .centerY

        quickBox.isHidden = true
        quickBox.target = self
        quickBox.action = #selector(quickPicked)

        let stack = NSStackView(views: [avatar, nameLabel, stateLabel, noteLabel,
                                        buttons, quickBox])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let host = NSView()
        host.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: host.topAnchor),
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            stack.bottomAnchor.constraint(greaterThanOrEqualTo: host.bottomAnchor,
                                          constant: -8),
        ])
        w.contentView = host
    }

    /// Durum degisince pencereyi tazeler; gerekiyorsa acar ya da kapatir.
    func apply(_ state: CallEngine.State, name: (String) -> String) {
        switch state {
        case .idle:
            close()
            return

        case .ringing(let p, let video):
            peer = p
            show(name(p), video ? L("Görüntülü arama", "Video call")
                                : L("Arıyor…", "Calling…"))
            setButtons([
                ("phone.down.fill", L("Reddet", "Decline"), #selector(decline), NSColor.systemRed),
                ("phone.fill", L("Kabul et", "Accept"), #selector(accept), NSColor.systemGreen),
            ])
            // HIZLI CEVAP: reddederken tek dokunusla not birakmak.
            // Not mesaj olarak GITMIYOR — karsi tarafin arama ekraninda
            // gorunuyor, cunku istenen buydu.
            quickBox.removeAllItems()
            quickBox.addItem(withTitle: L("Mesajla reddet…", "Decline with a note…"))
            quickBox.addItems(withTitles: QuickReplies.all)
            quickBox.addItem(withTitle: L("Kendi metnim…", "My own text…"))
            quickBox.isHidden = false

        case .calling(let p):
            peer = p
            show(name(p), L("Aranıyor…", "Ringing…"))
            setButtons([("phone.down.fill", L("Kapat", "Hang up"),
                         #selector(hangUp), NSColor.systemRed)])
            quickBox.isHidden = true

        case .connecting(let p):
            show(name(p), L("Bağlanılıyor…", "Connecting…"))
            setButtons([("phone.down.fill", L("Kapat", "Hang up"),
                         #selector(hangUp), NSColor.systemRed)])
            quickBox.isHidden = true

        case .active(let p, _):
            show(name(p), L("Görüşme sürüyor", "In call"))
            setButtons([("phone.down.fill", L("Kapat", "Hang up"),
                         #selector(hangUp), NSColor.systemRed)])
            quickBox.isHidden = true

        case .ended(let reason, let note):
            stateLabel.stringValue = text(for: reason)
            // Karsi tarafin biraktigi not BURADA gorunuyor: kapanma
            // ekrani birkac saniye duruyor ve okunacak yer orasi.
            noteLabel.stringValue = note ?? ""
            noteLabel.isHidden = (note ?? "").isEmpty
            setButtons([])
            quickBox.isHidden = true
        }
    }

    private func text(for r: CallEngine.EndReason) -> String {
        switch r {
        case .hangup:      return L("Arama bitti", "Call ended")
        case .declined:    return L("Reddedildi", "Declined")
        case .busy:        return L("Meşgul", "Busy")
        case .unreachable: return L("Ulaşılamıyor", "Unreachable")
        case .failed(let why):
            return why == "nopath"
                ? L("Doğrudan bağlantı kurulamadı (ağ engelliyor)",
                    "Could not connect directly (the network blocks it)")
                : L("Bağlanılamadı", "Could not connect")
        }
    }

    private func show(_ who: String, _ state: String) {
        avatar.initial = String(who.prefix(1)).uppercased()
        avatar.seed = who.hashValue
        nameLabel.stringValue = who
        stateLabel.stringValue = state
        noteLabel.isHidden = true
        if window?.isVisible != true {
            showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func setButtons(_ items: [(String, String, Selector, NSColor)]) {
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (symbol, title, sel, color) in items {
            let b = NSButton(title: " " + title, target: self, action: sel)
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            b.imagePosition = .imageLeading
            b.bezelStyle = .rounded
            b.contentTintColor = color
            buttons.addArrangedSubview(b)
        }
        buttons.isHidden = items.isEmpty
    }

    @objc private func accept() { CallEngine.shared.accept() }
    @objc private func hangUp() { CallEngine.shared.hangUp() }
    @objc private func decline() { CallEngine.shared.decline() }

    @objc private func quickPicked() {
        let i = quickBox.indexOfSelectedItem
        guard i > 0 else { return }
        let replies = QuickReplies.all
        if i <= replies.count {
            CallEngine.shared.decline(note: replies[i - 1])
            return
        }
        // "Kendi metnim…"
        let a = NSAlert()
        a.messageText = L("Reddederken not bırak", "Decline with a note")
        a.informativeText = L("Karşı tarafın arama ekranında görünür.",
                              "It appears on the caller's call screen.")
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        a.accessoryView = f
        a.addButton(withTitle: L("Reddet", "Decline"))
        a.addButton(withTitle: L("Vazgeç", "Cancel"))
        if a.runModal() == .alertFirstButtonReturn {
            let text = f.stringValue.trimmingCharacters(in: .whitespaces)
            CallEngine.shared.decline(note: text.isEmpty ? nil : text)
            // Kullanicinin yazdigi metni listeye EKLE: ikinci kez
            // yazmak zorunda kalmasin.
            if !text.isEmpty, !QuickReplies.all.contains(text) {
                QuickReplies.all = (QuickReplies.all + [text]).suffix(8).map { $0 }
            }
        } else {
            quickBox.selectItem(at: 0)
        }
    }
}
