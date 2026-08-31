import AppKit

/// Ayna goruntusu + yan paneli yerlestiren kapsayici.
/// Panel sagda ya da solda olabilir; goruntu kalan alanda en-boy korunarak durur.
final class MirrorContentView: NSView {

    let mirror: MetalView
    let sidebar = SidebarView(frame: .zero)
    let editor = KeyMapEditorView(frame: .zero)
    let guide = GuideOverlay(frame: .zero)
    let status = StatusOverlay(frame: .zero)

    var sidebarOnRight = true { didSet { needsLayout = true } }
    var sidebarVisible = true {
        didSet { sidebar.isHidden = !sidebarVisible; needsLayout = true }
    }

    init(mirror: MetalView) {
        self.mirror = mirror
        super.init(frame: .zero)
        wantsLayer = true
        // Kapsayici saydam: yuvarlak koseleri ayna ve panel KENDI ustlerinde
        // tasiyor. Kapsayici maskelerse panelin kosesini kesiyordu.
        layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(mirror)
        guide.isHidden = true
        addSubview(guide)
        editor.isHidden = true
        addSubview(editor)
        // Durum katmani aynanin ustunde, panelin ALTINDA: panel her zaman
        // erisilebilir kalsin (baglanti kurulamasa bile kapatabilelim).
        status.isHidden = true
        addSubview(status)
        addSubview(sidebar)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Yan panelin kapladigi genislik (gizliyse 0).
    var sidebarWidth: CGFloat { sidebarVisible ? SidebarView.width : 0 }

    override func layout() {
        super.layout()
        let sw = sidebarWidth
        let mirrorRect: NSRect
        let barRect: NSRect
        if sidebarOnRight {
            mirrorRect = NSRect(x: 0, y: 0, width: bounds.width - sw, height: bounds.height)
            barRect    = NSRect(x: bounds.width - sw, y: 0, width: sw, height: bounds.height)
        } else {
            barRect    = NSRect(x: 0, y: 0, width: sw, height: bounds.height)
            mirrorRect = NSRect(x: sw, y: 0, width: bounds.width - sw, height: bounds.height)
        }
        mirror.frame = mirrorRect
        sidebar.frame = barRect
        editor.frame = mirrorRect
        editor.videoRect = mirror.videoRect
        editor.needsDisplay = true
        guide.frame = mirrorRect
        guide.videoRect = mirror.videoRect
        guide.needsDisplay = true
        status.frame = mirrorRect
    }
}
