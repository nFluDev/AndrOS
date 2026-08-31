import AppKit
import AndrOSCore

/// Klavye -> dokunma haritalama. Emulatorlerin asil avantaji bu.
///
/// Iki bagimsiz parmak kullanilir:
///  - joystickID: WASD ile surulen sanal analog cubuk
///  - mappedKeyID: tek seferlik yetenek tuslari
/// Fare kendi parmagini (fingerID) kullandigi icin ucu ayni anda calisir.
final class KeyMapper {

    /// Bir tusun nasil davranacagi.
    enum Mode: String, Codable, CaseIterable {
        case hold      // basili tuttugun surece parmak ekranda
        case tap       // tek dokunus, birakma beklenmez
        case repeatFire // basili tuttugun surece tekrar tekrar dokunur

        var title: String {
            switch self {
            case .hold: return L("Basılı tut", "Hold")
            case .tap: return L("Tek dokunuş", "Single tap")
            case .repeatFire: return "Otomatik tekrar"
            }
        }
    }

    struct Binding: Codable {
        var key: UInt16          // macOS sanal tus kodu
        var label: String
        var nx: Double           // ekranda oransal konum (0..1)
        var ny: Double
        var mode: Mode = .hold

        enum CodingKeys: String, CodingKey { case key, label, nx, ny, mode }
        init(key: UInt16, label: String, nx: Double, ny: Double, mode: Mode = .hold) {
            self.key = key; self.label = label; self.nx = nx; self.ny = ny; self.mode = mode
        }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            key = try c.decode(UInt16.self, forKey: .key)
            label = try c.decode(String.self, forKey: .label)
            nx = try c.decode(Double.self, forKey: .nx)
            ny = try c.decode(Double.self, forKey: .ny)
            mode = (try? c.decode(Mode.self, forKey: .mode)) ?? .hold
        }
    }

    /// Otomatik tekrar araligi (saniye).
    var repeatInterval: Double = 0.12
    /// Cok kucuk yonlendirmeleri yok say (0..0.5).
    var deadZone: Double = 0.0

    /// Diske yazilan profil.
    private struct Profile: Codable {
        var stickX: Double, stickY: Double, stickR: Double
        var bindings: [Binding]
        var deadZone: Double?
        var repeatInterval: Double?
    }

    func save() {
        let p = Profile(stickX: stickCenter.x, stickY: stickCenter.y,
                        stickR: stickRadius, bindings: bindings,
                        deadZone: deadZone, repeatInterval: repeatInterval)
        if let d = try? JSONEncoder().encode(p) {
            UserDefaults.standard.set(d, forKey: "keymapProfile")
        }
    }

    func load() {
        guard let d = UserDefaults.standard.data(forKey: "keymapProfile"),
              let p = try? JSONDecoder().decode(Profile.self, from: d),
              !p.bindings.isEmpty else { return }
        stickCenter = (p.stickX, p.stickY)
        stickRadius = p.stickR
        bindings = p.bindings
        deadZone = p.deadZone ?? 0
        repeatInterval = p.repeatInterval ?? 0.12
    }

    var send: (([UInt8]) -> Void)?
    var streamSize: (w: Int, h: Int) = (0, 0)
    var enabled = false { didSet { if !enabled { releaseAll() } } }

    /// Sanal cubugun merkezi ve yaricapi (oransal).
    /// Era Online'in 1600x720 yatay duzeninden OLCULDU (tahmin degil):
    /// pad merkezi ~ (340, 545) piksel.
    var stickCenter = (x: 0.213, y: 0.757)
    var stickRadius = 0.13

    /// Yetenek tuslari — Era Online'in sag alt yetenek cemberinden olculdu.
    var bindings: [Binding] = [
        Binding(key: 49, label: L("Boşluk", "Space"), nx: 0.889, ny: 0.847), // ana saldiri (buyuk)
        Binding(key: 18, label: "1", nx: 0.866, ny: 0.708),
        Binding(key: 19, label: "2", nx: 0.925, ny: 0.708),
        Binding(key: 20, label: "3", nx: 0.826, ny: 0.792),
        Binding(key: 21, label: "4", nx: 0.931, ny: 0.799),
        Binding(key: 23, label: "5", nx: 0.826, ny: 0.924),
        Binding(key: 22, label: "6", nx: 0.866, ny: 0.944),
        Binding(key: 26, label: "7", nx: 0.931, ny: 0.938),
    ]

    private var held = Set<UInt16>()     // basili WASD tuslari
    private var stickDown = false
    private var keyDownAt: [UInt16: (Int, Int)] = [:]
    private var repeaters: [UInt16: DispatchSourceTimer] = [:]

    private static let up: UInt16 = 13, left: UInt16 = 0, down: UInt16 = 1, right: UInt16 = 2 // W A S D

    /// true donerse olay tuketildi, oyuna ayrica gonderilmemeli.
    func handle(keyCode: UInt16, isDown: Bool) -> Bool {
        guard enabled, streamSize.w > 0 else { return false }

        if [KeyMapper.up, KeyMapper.left, KeyMapper.down, KeyMapper.right].contains(keyCode) {
            if isDown { held.insert(keyCode) } else { held.remove(keyCode) }
            updateStick()
            return true
        }
        if let b = bindings.first(where: { $0.key == keyCode }) {
            let x = Int(b.nx * Double(streamSize.w))
            let y = Int(b.ny * Double(streamSize.h))
            switch b.mode {
            case .tap:
                if isDown {
                    guard keyDownAt[keyCode] == nil else { return true }
                    keyDownAt[keyCode] = (x, y)
                    emit(.down, x, y, ControlMessage.mappedKeyID)
                    // Kisa ama gercek bir dokunus: hemen birakmak bazi
                    // oyunlarda kaydedilmiyor.
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.04) { [weak self] in
                        self?.emit(.up, x, y, ControlMessage.mappedKeyID)
                    }
                } else {
                    keyDownAt.removeValue(forKey: keyCode)
                }
            case .repeatFire:
                if isDown {
                    guard repeaters[keyCode] == nil else { return true }
                    let t = DispatchSource.makeTimerSource(queue: .global())
                    t.schedule(deadline: .now(), repeating: repeatInterval)
                    t.setEventHandler { [weak self] in
                        guard let self else { return }
                        self.emit(.down, x, y, ControlMessage.mappedKeyID)
                        usleep(30_000)
                        self.emit(.up, x, y, ControlMessage.mappedKeyID)
                    }
                    t.resume()
                    repeaters[keyCode] = t
                } else {
                    repeaters.removeValue(forKey: keyCode)?.cancel()
                }
            case .hold:
                if isDown {
                    guard keyDownAt[keyCode] == nil else { return true }
                    keyDownAt[keyCode] = (x, y)
                    emit(.down, x, y, ControlMessage.mappedKeyID)
                } else if let p = keyDownAt.removeValue(forKey: keyCode) {
                    emit(.up, p.0, p.1, ControlMessage.mappedKeyID)
                }
            }
            return true
        }
        return false
    }

    private func updateStick() {
        var dx = 0.0, dy = 0.0
        if held.contains(KeyMapper.left)  { dx -= 1 }
        if held.contains(KeyMapper.right) { dx += 1 }
        if held.contains(KeyMapper.up)    { dy -= 1 }
        if held.contains(KeyMapper.down)  { dy += 1 }

        let cx = stickCenter.x * Double(streamSize.w)
        let cy = stickCenter.y * Double(streamSize.h)

        if dx == 0 && dy == 0 {
            if stickDown { emit(.up, Int(cx), Int(cy), ControlMessage.joystickID); stickDown = false }
            return
        }
        // Caprazda da tam yaricap olsun diye normalize
        let len = (dx*dx + dy*dy).squareRoot()
        let effective = stickRadius * (1.0 - deadZone) + stickRadius * deadZone
        let r = effective * Double(min(streamSize.w, streamSize.h))
        let px = Int(cx + dx / len * r)
        let py = Int(cy + dy / len * r)

        if !stickDown {
            // Yuzen (floating) cubuklu oyunlarda cubuk, ILK dokunulan noktada
            // olusuyor. Once merkeze bas, oyunun cubugu oraya yerlestirmesi
            // icin bir kare bekle, SONRA yonlendir. Aksi halde down ve move
            // ayni anda gidince oyun merkezi kaciriyor.
            emit(.down, Int(cx), Int(cy), ControlMessage.joystickID)
            stickDown = true
            let sx = px, sy = py
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.035) { [weak self] in
                guard let self, self.stickDown else { return }
                self.emit(.move, sx, sy, ControlMessage.joystickID)
            }
            return
        }
        emit(.move, px, py, ControlMessage.joystickID)
    }

    func releaseAll() {
        if stickDown {
            let cx = Int(stickCenter.x * Double(streamSize.w))
            let cy = Int(stickCenter.y * Double(streamSize.h))
            emit(.up, cx, cy, ControlMessage.joystickID)
            stickDown = false
        }
        for (_, t) in repeaters { t.cancel() }
        repeaters.removeAll()
        for (_, p) in keyDownAt { emit(.up, p.0, p.1, ControlMessage.mappedKeyID) }
        keyDownAt.removeAll()
        held.removeAll()
    }

    private func emit(_ a: ControlMessage.TouchAction, _ x: Int, _ y: Int, _ pid: UInt64) {
        send?(ControlMessage.touch(a, x: x, y: y, w: streamSize.w, h: streamSize.h,
                                   pointerID: pid))
    }
}
