import AppKit
import CoreVideo
import CoreImage
import AndrOSCore

/// Menu cubugundaki kamera simgesine tiklayinca acilan MINI OYNATICI.
///
/// Menu cubugundaki gomulu kucuk goruntu 20 px: "acik mi?" sorusunu
/// yanitliyor ama bakilacak bir sey degil. Burasi ona tiklayinca acilan
/// gercek onizleme — altinda kamera denetimleri ve efekt listesi ayri
/// bir bolum olarak duruyor.
final class CameraPanel: NSViewController {

    static let shared = CameraPanel()

    var onToggleFacing: (() -> Void)?
    var onStop: (() -> Void)?
    var onOpenApp: (() -> Void)?

    private let preview = PreviewView()
    private let headline = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let facingButton = NSButton()
    private let rotateButton = NSButton()
    private let mirrorButton = NSButton()
    private let effectsStack = NSStackView()
    private let ci = CIContext(options: [.useSoftwareRenderer: false])
    private var lastDraw = Date.distantPast

    private let width: CGFloat = 320
    private let previewHeight: CGFloat = 180

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        headline.font = .systemFont(ofSize: 13, weight: .semibold)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor

        preview.wantsLayer = true
        preview.layer?.backgroundColor = NSColor.black.cgColor
        preview.layer?.cornerRadius = 10
        preview.layer?.masksToBounds = true
        preview.translatesAutoresizingMaskIntoConstraints = false

        facingButton.bezelStyle = .rounded
        facingButton.title = L("Ön/arka", "Front/back")
        facingButton.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath.camera",
                                     accessibilityDescription: nil)
        facingButton.imagePosition = .imageLeading
        facingButton.target = self
        facingButton.action = #selector(flip)

        rotateButton.bezelStyle = .rounded
        rotateButton.title = L("90° döndür", "Rotate 90°")
        rotateButton.image = NSImage(systemSymbolName: "rotate.right",
                                     accessibilityDescription: nil)
        rotateButton.imagePosition = .imageLeading
        rotateButton.target = self
        rotateButton.action = #selector(rotateTapped)
        rotateButton.toolTip = L("Görüntü yan duruyorsa çevirir; dört adımda tam tur.",
                                 "Turns a sideways image upright; four steps make a full turn.")

        mirrorButton.setButtonType(.switch)
        mirrorButton.title = L("Aynala", "Mirror")
        mirrorButton.state = VirtualCamera.shared.mirrored ? .on : .off
        mirrorButton.target = self
        mirrorButton.action = #selector(mirrorChanged)
        mirrorButton.toolTip = L("Efektten bağımsız: efektle birlikte kullanılabilir.",
                                 "Independent of the effect — both can be on at once.")

        let controls = NSStackView(views: [facingButton, rotateButton])
        controls.orientation = .horizontal
        controls.distribution = .fillEqually
        controls.spacing = 8

        let fxHead = NSTextField(labelWithString: L("EFEKTLER", "EFFECTS"))
        fxHead.font = .systemFont(ofSize: 10, weight: .semibold)
        fxHead.textColor = .tertiaryLabelColor

        effectsStack.orientation = .vertical
        effectsStack.alignment = .leading
        effectsStack.spacing = 4
        buildEffects()

        let stop = NSButton(title: L("Kamerayı kapat", "Turn camera off"),
                            target: self, action: #selector(stopTapped))
        stop.bezelStyle = .rounded
        let openApp = NSButton(title: L("AndrOS'u aç", "Open AndrOS"),
                               target: self, action: #selector(openTapped))
        openApp.bezelStyle = .rounded
        let footer = NSStackView(views: [openApp, NSView(), stop])
        footer.orientation = .horizontal

        let sep = NSBox(); sep.boxType = .separator

        // Baslik iki satir; onizlemeden once kucuk bir ayirici bosluk.
        let heads = NSStackView(views: [headline, subtitle])
        heads.orientation = .vertical
        heads.alignment = .leading
        heads.spacing = 2

        let stack = NSStackView(views: [heads, preview, controls,
                                        mirrorButton, sep, fxHead, effectsStack, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        // BOSLUK KISITLARLA veriliyor, yiginin `edgeInsets`i ile degil:
        // `fittingSize` insets'i her zaman saymiyor ve panel kenara
        // yapisik cikiyordu.
        let pad: CGFloat = 14
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: pad),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: pad),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -pad),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -pad),
            preview.widthAnchor.constraint(equalToConstant: width),
            preview.heightAnchor.constraint(equalToConstant: previewHeight),
            controls.widthAnchor.constraint(equalTo: preview.widthAnchor),
            footer.widthAnchor.constraint(equalTo: preview.widthAnchor),
            effectsStack.widthAnchor.constraint(equalTo: preview.widthAnchor),
        ])
        view = root
        refreshLabels()
    }

    private func buildEffects() {
        effectsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for e in CameraEffect.allCases {
            let b = NSButton(radioButtonWithTitle: e.title, target: self,
                             action: #selector(pickEffect(_:)))
            b.identifier = NSUserInterfaceItemIdentifier(e.rawValue)
            b.state = VirtualCamera.shared.effect == e ? .on : .off
            b.font = .systemFont(ofSize: 12)
            effectsStack.addArrangedSubview(b)
        }
    }

    private func refreshLabels() {
        let b = CameraBridge.shared
        headline.stringValue = L("Telefon Kamerası", "Phone Camera")
        let facing = b.facing == .front ? L("ön kamera", "front camera")
                                       : L("arka kamera", "back camera")
        let size = b.size == .zero ? "—" : "\(Int(b.size.width))×\(Int(b.size.height))"
        let rot = VirtualCamera.shared.rotation
        subtitle.stringValue = "\(facing) · \(size)"
            + (rot != 0 ? " · \(rot)°" : "")
            + (VirtualCamera.shared.mirrored ? L(" · aynalı", " · mirrored") : "")
            + (VirtualCamera.extensionInstalled
               ? L(" · tüm uygulamalarda", " · in every app")
               : L(" · yalnızca burada", " · here only"))
    }

    // MARK: - Kare

    func update(_ pixels: CVPixelBuffer) {
        let now = Date()
        guard now.timeIntervalSince(lastDraw) > 1.0 / 20 else { return }
        lastDraw = now
        let img = CIImage(cvPixelBuffer: pixels)
        let scale = previewHeight / img.extent.height
        let small = img.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = ci.createCGImage(small, from: small.extent) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.preview.layer?.contents = cg
            self?.preview.layer?.contentsGravity = .resizeAspect
        }
    }

    // MARK: - Eylemler

    @objc private func flip() {
        onToggleFacing?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.refreshLabels()
        }
    }

    @objc private func rotateTapped() {
        VirtualCamera.shared.rotation = (VirtualCamera.shared.rotation + 90) % 360
        refreshLabels()
    }

    @objc private func pickEffect(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let e = CameraEffect(rawValue: raw) else { return }
        VirtualCamera.shared.effect = e
        for v in effectsStack.arrangedSubviews {
            (v as? NSButton)?.state = (v.identifier?.rawValue == raw) ? .on : .off
        }
    }

    @objc private func mirrorChanged() {
        VirtualCamera.shared.mirrored = mirrorButton.state == .on
        refreshLabels()
    }

    @objc private func stopTapped() { onStop?() }
    @objc private func openTapped() { onOpenApp?() }

    /// Panel her acildiginda guncel bilgiyle gelsin.
    func willShow() {
        refreshLabels()
        buildEffects()
        mirrorButton.state = VirtualCamera.shared.mirrored ? .on : .off
    }
}

/// Katman icerigi olarak kare gosteren basit gorunum.
final class PreviewView: NSView {
    override var isFlipped: Bool { true }
}
