import AppKit

/// Menu cubugu popover'larinin DOGRU davranmasi icin ortak sarmalayici.
///
/// Cikartilan sorun: `.transient` popover, menu cubugu uygulamasinda
/// (LSUIElement) acilirken odagi almiyordu; disariya tiklayinca odagini
/// kaybediyor ama KAPANMIYORDU. Ekranda asili kalan, tiklamayi
/// yemeyen bir kutu kaliyordu.
///
/// Cozum uc parca:
///  1. Gostermeden once uygulamayi one getir.
///  2. Popover'in penceresini ANAHTAR pencere yap (yoksa ic denetimler
///     ilk tiklamayi yemiyor).
///  3. Disariya yapilan tiklamayi KENDIMIZ dinleyip kapat — menu
///     cubugu uygulamalarinda sistemin kendi kapatmasi guvenilir degil.
final class PopoverHost {

    private let popover = NSPopover()
    private var outsideMonitor: Any?
    private var localMonitor: Any?

    init() {
        popover.behavior = .transient
        popover.animates = true
    }

    var isShown: Bool { popover.isShown }

    func toggle(_ vc: NSViewController, from button: NSStatusBarButton) {
        if popover.isShown { close(); return }
        show(vc, from: button)
    }

    func show(_ vc: NSViewController, from button: NSStatusBarButton) {
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController = vc
        popover.contentSize = vc.view.fittingSize
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Ic denetimlerin ILK tiklamayi yemesi icin anahtar pencere olmali.
        popover.contentViewController?.view.window?.makeKey()

        outsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
        // Uygulamanin KENDI pencerelerine tiklama da kapatmali; global
        // gozlemci kendi surecimizin olaylarini gormuyor.
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
            guard let self, self.popover.isShown else { return e }
            let inPopover = e.window === self.popover.contentViewController?.view.window
            if !inPopover { self.close() }
            return e
        }
    }

    func close() {
        if let m = outsideMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        outsideMonitor = nil
        localMonitor = nil
        popover.performClose(nil)
    }
}
