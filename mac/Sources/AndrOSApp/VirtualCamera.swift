import AppKit
import CoreVideo
import CoreImage
import SystemExtensions
import AndrOSCore
import AndrOSCameraShim

/// Sanal kamera kaynagi.
///
/// Telefondan cozulen kareler buradan gecerek sistem uzantisina
/// (CMIOExtension) gidiyor; boylece FaceTime, Zoom, Photo Booth gibi
/// KAMERA KULLANAN HER UYGULAMA telefonu bir webcam olarak goruyor.
///
/// Uzanti ayri bir surecte calisiyor ve kareleri paylasimli bellekten
/// aliyor — ses tarafindaki halka tamponun ayni fikri. Uzanti kurulu
/// degilse burasi sessizce hicbir sey yapmiyor: uygulama ici onizleme
/// ve menu cubugu yine calisiyor.
final class VirtualCamera: NSObject {

    static let shared = VirtualCamera()
    private override init() { super.init() }

    /// Efekt zinciri — kareler uzantiya gitmeden ONCE burada isleniyor,
    /// yani efekt kamerayi kullanan HER uygulamada gorunuyor.
    var effect: CameraEffect = {
        CameraEffect(rawValue: UserDefaults.standard.string(forKey: "cameraEffect") ?? "")
            ?? .none
    }() {
        didSet { UserDefaults.standard.set(effect.rawValue, forKey: "cameraEffect") }
    }

    /// Goruntu donusu (0/90/180/270).
    ///
    /// Telefon yan tutuldugunda goruntu yatiyor ve karsi taraf egik
    /// goruyor. Efektlerden ayri tutuldu: efekt bir "gorunum" secimi,
    /// donus ise duzeltme.
    var rotation: Int = UserDefaults.standard.integer(forKey: "cameraRotation") {
        didSet {
            rotation = ((rotation % 360) + 360) % 360
            UserDefaults.standard.set(rotation, forKey: "cameraRotation")
        }
    }

    /// Aynalama AYRI bir anahtar.
    ///
    /// Efekt listesinde bir secenek olarak durunca "siyah beyaz + ayna"
    /// yapilamiyordu — biri otekini kapatiyordu. Aynalama bir gorunum
    /// tercihi degil, yon duzeltmesi; donus gibi bagimsiz.
    var mirrored: Bool = UserDefaults.standard.bool(forKey: "cameraMirror") {
        didSet { UserDefaults.standard.set(mirrored, forKey: "cameraMirror") }
    }

    /// Islenmis kare (donus + ayna + efekt sonrasi). Onizleme bunu
    /// gostermeli ki kullanici ayarin etkisini GORSUN.
    var onProcessed: ((CVPixelBuffer) -> Void)?

    private var shared_: UnsafeMutablePointer<AndrOSCameraShared>?
    private let ci = CIContext(options: [.useSoftwareRenderer: false])
    private(set) var isPublishing = false

    private func attach() -> UnsafeMutablePointer<AndrOSCameraShared>? {
        if shared_ == nil { shared_ = androsCameraAttach(1) }
        return shared_
    }

    /// Yeni kare: efekti uygula ve uzantiya ver.
    private var logged = 0

    func publish(_ pixels: CVPixelBuffer) {
        guard let sh = attach() else {
            if logged == 0 { logged = 1; Log.write("sanal kamera: paylaşımlı bellek açılamadı") }
            return
        }
        let out = transform(pixels) ?? pixels
        // Onizleme de ISLENMIS kareyi gorsun.
        onProcessed?(out)
        // ASIL YOL: CMIO sink akisi (kum havuzunu gecen tek yol).
        VirtualCameraSink.shared.send(out)
        guard write(out, to: sh) else {
            if logged < 2 {
                logged = 2
                Log.write("sanal kamera: kare yazılamadı — biçim "
                          + "\(CVPixelBufferGetPixelFormatType(out)) "
                          + "\(CVPixelBufferGetWidth(out))x\(CVPixelBufferGetHeight(out))")
            }
            return
        }
        if logged < 3 { logged = 3; Log.write("sanal kamera: kareler akıyor") }
        sh.pointee.running = 1
        sh.pointee.heartbeat = UInt64(Date().timeIntervalSince1970)
        isPublishing = true
    }

    /// Donus + efekt tek gecipte uygulaniyor: iki ayri kopya cikarmak
    /// 30 fps'te gereksiz is.
    private func transform(_ input: CVPixelBuffer) -> CVPixelBuffer? {
        guard rotation != 0 || mirrored || effect != .none else { return nil }
        var img = CIImage(cvPixelBuffer: input)
        if mirrored {
            img = img.transformed(by: CGAffineTransform(scaleX: -1, y: 1)
                .translatedBy(x: -img.extent.width, y: 0))
        }
        if rotation != 0 {
            let rad = CGFloat(rotation) * .pi / 180
            img = img.transformed(by: CGAffineTransform(rotationAngle: rad))
            // Donusten sonra kare eksi koordinatlara kayiyor; basa cek.
            img = img.transformed(by: CGAffineTransform(translationX: -img.extent.origin.x,
                                                        y: -img.extent.origin.y))
        }
        img = effect.filter(img)
        var out: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: CVPixelBufferGetPixelFormatType(input),
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, Int(img.extent.width), Int(img.extent.height),
                            CVPixelBufferGetPixelFormatType(input), attrs as CFDictionary, &out)
        guard let out else { return nil }
        ci.render(img, to: out)
        return out
    }

    /// Kamera kapandi: uzanti yer tutucuya donsun.
    func stopPublishing() {
        isPublishing = false
        shared_?.pointee.running = 0
        VirtualCameraSink.shared.close()
    }

    /// NV12 duzlemlerini paylasimli slota SIKI paketleyerek yazar.
    private func write(_ px: CVPixelBuffer,
                       to sh: UnsafeMutablePointer<AndrOSCameraShared>) -> Bool {
        guard CVPixelBufferGetPixelFormatType(px)
                == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
              || CVPixelBufferGetPixelFormatType(px)
                == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else { return false }
        let w = CVPixelBufferGetWidth(px), h = CVPixelBufferGetHeight(px)
        guard w > 0, h > 0, w <= Int(ANDROS_CAM_MAXW), h <= Int(ANDROS_CAM_MAXH) else { return false }

        CVPixelBufferLockBaseAddress(px, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }
        guard let ySrc = CVPixelBufferGetBaseAddressOfPlane(px, 0),
              let cSrc = CVPixelBufferGetBaseAddressOfPlane(px, 1) else { return false }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(px, 0)
        let cStride = CVPixelBufferGetBytesPerRowOfPlane(px, 1)

        let slot = UInt32(sh.pointee.sequence % UInt64(ANDROS_CAM_SLOTS))
        guard let dst = androsCameraSlot(sh, slot) else { return false }

        for row in 0..<h {
            memcpy(dst.advanced(by: row * w), ySrc.advanced(by: row * yStride), w)
        }
        let cDst = dst.advanced(by: w * h)
        for row in 0..<(h / 2) {
            memcpy(cDst.advanced(by: row * w), cSrc.advanced(by: row * cStride), w)
        }
        sh.pointee.width = UInt32(w)
        sh.pointee.height = UInt32(h)
        // Sirayi EN SON artir: uzanti yarim yazilmis slotu okumasin.
        sh.pointee.sequence &+= 1
        return true
    }

    // MARK: - Uzanti kurulumu

    private var activationDone: ((String?) -> Void)?

    /// Sanal kamera uzantisi kurulu mu?
    static var extensionInstalled: Bool {
        // `systemextensionsctl list` tek guvenilir kaynak; cikti kisa.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/systemextensionsctl")
        p.arguments = ["list"]
        let pipe = Pipe(); p.standardOutput = pipe
        try? p.run(); p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return out.contains("dev.naer.andros.camera") && out.contains("activated enabled")
    }

    /// Uzantiyi kurar/etkinlestirir. Sistem kullanicidan onay isteyebilir.
    func installExtension(_ done: @escaping (String?) -> Void) {
        activationDone = done
        let req = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: "dev.naer.andros.camera", queue: .main)
        req.delegate = self
        OSSystemExtensionManager.shared.submitRequest(req)
    }

    /// Uzantiyi kaldirir. Kullanici istemedigi bir sistem uzantisiyla
    /// bas basa kalmamali — kurmak kadar KALDIRMAK da tek tik.
    func removeExtension(_ done: @escaping (String?) -> Void) {
        activationDone = done
        let req = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: "dev.naer.andros.camera", queue: .main)
        req.delegate = self
        OSSystemExtensionManager.shared.submitRequest(req)
    }
}

extension VirtualCamera: OSSystemExtensionRequestDelegate {

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties)
        -> OSSystemExtensionRequest.ReplacementAction { .replace }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Log.write("kamera uzantısı: kullanıcı onayı bekleniyor")
    }

    func request(_ request: OSSystemExtensionRequest,
                 didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Log.write("kamera uzantısı sonucu: \(result.rawValue)")
        activationDone?(nil); activationDone = nil
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let ns = error as NSError
        Log.write("kamera uzantısı hatası: \(ns.domain) kod=\(ns.code) "
                  + "\(error.localizedDescription)")
        activationDone?("\(error.localizedDescription) (kod \(ns.code))")
        activationDone = nil
    }
}

/// Kamera efektleri.
///
/// Efekt SANAL KAMERAYA uygulaniyor, yalnizca uygulama ici onizlemeye
/// degil: amac kamerayi kullanan her programda ayni goruntunun cikmasi.
enum CameraEffect: String, CaseIterable {
    case none, grayscale, warm, cool, blur

    var title: String {
        switch self {
        case .none:      return L("Efekt yok", "No effect")
        case .grayscale: return L("Siyah beyaz", "Black & white")
        case .warm:      return L("Sıcak", "Warm")
        case .cool:      return L("Soğuk", "Cool")
        case .blur:      return L("Arka planı yumuşat", "Soften")
        }
    }

    /// Goruntu uzerine efekt. Piksel tamponu donusumu cagiran tarafta.
    func filter(_ input: CIImage) -> CIImage {
        switch self {
        case .none: return input
        case .grayscale:
            return input.applyingFilter("CIPhotoEffectMono")
        case .warm:
            return input.applyingFilter("CITemperatureAndTint",
                                        parameters: ["inputTargetNeutral": CIVector(x: 5500, y: 0)])
        case .cool:
            return input.applyingFilter("CITemperatureAndTint",
                                        parameters: ["inputTargetNeutral": CIVector(x: 7500, y: 0)])
        case .blur:
            return input.applyingFilter("CIGaussianBlur", parameters: ["inputRadius": 3])
                .cropped(to: input.extent)
        }
    }
}
