import AppKit
import CoreVideo
import AndrOSCore

/// Uygulama yoluyla (adb'siz) gelen kareleri AYNI ayna penceresine cizer.
///
/// Ayri, sade bir pencere yazmayi denedik ve yanlisti: yuvarlak koseler,
/// kenarliksiz govde, yuzen yan panel, goruntu kaydiraclari — hepsi
/// `MirrorContentView` + `MetalView` + `MetalRenderer` uclusunde zaten
/// vardi. Bu surucu yalnizca KAYNAK degistiriyor: kareler scrcpy
/// soketinden degil `ScreenBridge`'ten geliyor, gerisi ayni.
final class AppMirrorDriver {

    weak var view: MetalView?
    /// Metal cihazi ya da gorunturu kurulamazsa cizim yapamayiz;
    /// `MirrorSession` de ayni bicimde iyimser degil.
    private let renderer = MetalRenderer()

    private let lock = NSLock()
    private var queue: [CVPixelBuffer] = []
    /// Son cizilen kare — ekran goruntusu buradan aliniyor.
    private(set) var lastFrame: CVPixelBuffer?

    private(set) var streamWidth = 0
    private(set) var streamHeight = 0
    /// Olcu degisti (telefon dondu): pencere yeniden boyutlanmali.
    var onSize: ((Int, Int) -> Void)?

    var params: MetalRenderer.Params {
        get { renderer?.params ?? .init() }
        set { renderer?.params = newValue }
    }

    var stretchToFill: Bool {
        get { renderer?.stretchToFill ?? false }
        set { renderer?.stretchToFill = newValue }
    }

    /// Pencereye baglan. `attach` olmadan `CAMetalLayer.nextDrawable()`
    /// daima nil doner ve ekran simsiyah kalir.
    func attach(to v: MetalView) {
        view = v
        guard let dev = renderer?.mtlDevice else {
            Log.write("yansıtma: Metal cihazı yok, çizilemez")
            return
        }
        v.attach(device: dev)
        v.onDisplayTick = { [weak self] in self?.drawTick() }
    }

    func stop() {
        lock.lock(); queue.removeAll(); lastFrame = nil; lock.unlock()
        streamWidth = 0; streamHeight = 0
        renderer?.resetRangeDetection()
        DispatchQueue.main.async { [weak self] in self?.view?.stopDisplayLink() }
    }

    /// Cozulmus kare. Ana is parcaciginda DEGIL.
    func push(_ px: CVPixelBuffer) {
        let w = CVPixelBufferGetWidth(px), h = CVPixelBufferGetHeight(px)
        lock.lock()
        // KUYRUK BIRIKMESIN. Ekran yenilemesi kare hizindan yavassa
        // kuyruk uzuyor ve gecikme kartopu gibi buyuyordu; en fazla iki
        // kare tutuyoruz, eskisi dusuyor.
        queue.append(px)
        if queue.count > 2 { queue.removeFirst(queue.count - 2) }
        lock.unlock()

        if w != streamWidth || h != streamHeight {
            streamWidth = w; streamHeight = h
            DispatchQueue.main.async { [weak self] in
                self?.view?.videoSize = CGSize(width: w, height: h)
                self?.onSize?(w, h)
            }
        }
    }

    private func drawTick() {
        lock.lock()
        let pb = queue.isEmpty ? nil : queue.removeFirst()
        lock.unlock()
        guard let pb, let v = view, let r = renderer,
              v.metalLayer.device != nil, v.metalLayer.drawableSize.width >= 1 else { return }
        r.render(pb, to: v.metalLayer)
        lastFrame = pb
    }

    /// Su anki kareyi PNG olarak verir (panoya kopyalamak icin).
    func snapshot() -> NSImage? {
        guard let pb = lastFrame, let r = renderer,
              let tex = r.renderToTexture(pb, width: CVPixelBufferGetWidth(pb),
                                          height: CVPixelBufferGetHeight(pb)),
              let png = MetalRenderer.pngData(tex) else { return nil }
        return NSImage(data: png)
    }
}

/// Fare olaylarini TELEFON JESTLERINE cevirir.
///
/// Erisilebilirlik hizmeti "bas/birak" degil "sundan buraya sur" diyor;
/// bu yuzden bas-surukle-birak dizisini toplayip tek bir jeste
/// ceviriyoruz. adb yolunda bu gerekmiyordu, orada olaylar dogrudan
/// enjekte ediliyor.
final class TouchGesturizer {

    var onTap: ((Double, Double) -> Void)?
    var onLongPress: ((Double, Double) -> Void)?
    var onSwipe: (([(Double, Double)], Int) -> Void)?

    private var path: [(Double, Double)] = []
    private var down: (Double, Double) = (0, 0)
    private var downAt = Date()

    func begin(_ x: Double, _ y: Double) {
        down = (x, y)
        downAt = Date()
        path = [(x, y)]
    }

    func move(_ x: Double, _ y: Double) { path.append((x, y)) }

    func end(_ x: Double, _ y: Double) {
        defer { path.removeAll() }
        guard let start = path.first else { return }
        let held = Date().timeIntervalSince(downAt)
        let moved = hypot(x - down.0, y - down.1)
        // Esik ORANLI: 0.012 ~ 1080 piksel genislikte 13 piksel.
        if moved < 0.012 {
            held > 0.45 ? onLongPress?(x, y) : onTap?(x, y)
            return
        }
        var pts = [start]
        let step = max(1, path.count / 12)
        for i in stride(from: step, to: path.count, by: step) { pts.append(path[i]) }
        pts.append((x, y))
        onSwipe?(pts, Int(max(60, min(600, held * 1000))))
    }
}
