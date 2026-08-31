import AppKit
import CoreVideo
import CoreImage
import AndrOSCore

/// Kamera acikken menu cubugunda duran SIMGE.
///
/// Amac: kamera akiyorken bunun her zaman gorunur olmasi. Simgenin
/// icine kucuk canli goruntu koymayi denedik; 20 px'te ne oldugu
/// anlasilmiyor ve menu cubugunda huzursuz duruyor. Simge sabit,
/// goruntu tiklayinca acilan MINI OYNATICIDA.
final class CameraStatusItem {

    static let shared = CameraStatusItem()
    private init() {}

    private var item: NSStatusItem?
    private let ci = CIContext(options: [.useSoftwareRenderer: false])
    private var lastDraw = Date.distantPast
    /// Menu cubugu yuksekligi.
    private let height: CGFloat = 20

    var onToggleFacing: (() -> Void)?
    var onStop: (() -> Void)?
    var onOpen: (() -> Void)?

    func show() {
        guard item == nil else { return }
        let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        it.button?.image = NSImage(systemSymbolName: "camera.fill",
                                   accessibilityDescription: L("Kamera", "Camera"))
        it.button?.image?.isTemplate = true
        it.button?.imageScaling = .scaleProportionallyDown
        it.button?.toolTip = L("Telefon kamerası açık", "Phone camera is live")

        // MENU DEGIL POPOVER: kucuk simge "acik mi?" sorusunu
        // yanitliyor; tiklayinca gercek onizleme ve denetimler aciliyor.
        it.button?.target = self
        it.button?.action = #selector(togglePopover)
        item = it
    }

    func hide() {
        guard let it = item else { return }
        NSStatusBar.system.removeStatusItem(it)
        item = nil
    }

    /// Yeni kare: yalnizca ACIK mini oynatici tazelenir.
    func update(_ pixels: CVPixelBuffer) {
        guard item != nil, host.isShown else { return }
        CameraPanel.shared.update(pixels)
    }

    private let host = PopoverHost()

    @objc private func togglePopover() {
        guard let b = item?.button else { return }
        let panel = CameraPanel.shared
        panel.onToggleFacing = { [weak self] in self?.onToggleFacing?() }
        panel.onStop = { [weak self] in self?.host.close(); self?.onStop?() }
        panel.onOpenApp = { [weak self] in self?.host.close(); self?.onOpen?() }
        panel.willShow()
        host.toggle(panel, from: b)
    }

    @objc private func flip(_ s: Any?) { onToggleFacing?() }

    @objc private func pickEffect(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let e = CameraEffect(rawValue: raw) else { return }
        VirtualCamera.shared.effect = e
        for i in sender.menu?.items ?? [] {
            i.state = (i.representedObject as? String) == raw ? .on : .off
        }
    }
    @objc private func stop(_ s: Any?) { onStop?() }
    @objc private func open(_ s: Any?) { onOpen?() }
}
