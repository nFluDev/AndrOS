import Foundation
import AndrOSCore

/// Kaydedilmis tek bir dokunma olayi. Konum ORANSAL (0..1) tutulur ki
/// cozunurluk degisse de makro dogru yere basar.
struct MacroStep: Codable {
    var t: Double            // baslangictan itibaren milisaniye
    var action: UInt8        // 0=down 1=up 2=move
    var nx: Double
    var ny: Double

    var actionName: String {
        switch action { case 0: return "bas"; case 1: return L("bırak", "release"); default: return L("sürükle", "drag") }
    }
}

struct Macro: Codable, Identifiable {
    var id = UUID()
    var name: String
    var steps: [MacroStep]
    /// Kayitli varsayilan hiz carpani.
    var speed: Double = 1.0
    /// Dongu sayisi (0 = sonsuz).
    var loops: Int = 1

    var durationMs: Double { steps.last?.t ?? 0 }
}

/// Makro kaydi ve oynatimi.
final class MacroEngine {

    enum State { case idle, recording, playing }

    private(set) var state: State = .idle
    var macros: [Macro] = []
    var onStateChange: ((State) -> Void)?

    /// Oynatirken dokunma gonderen kapali fonksiyon.
    var emit: ((ControlMessage.TouchAction, Double, Double) -> Void)?

    /// Kullanilabilir hiz secenekleri. Negatif tarafta yavaslatma:
    /// -10x = 10 kat YAVAS (0.1 carpan). 50x = 50 kat hizli.
    static let speedOptions: [(label: String, factor: Double)] = [
        (L("-10x (çok yavaş)", "-10x (very slow)"), 0.1), ("-5x", 0.2), ("-2x", 0.5),
        ("1x (normal)", 1.0),
        ("2x", 2), ("3x", 3), ("5x", 5), ("10x", 10),
        ("20x", 20), ("35x", 35), (L("50x (çok hızlı)", "50x (very fast)"), 50),
    ]

    private var recStart = Date()
    private var recSteps: [MacroStep] = []
    private var playThread: Thread?
    private var cancelPlay = false

    // MARK: - Kayit

    func startRecording() {
        recSteps.removeAll()
        recStart = Date()
        state = .recording
        onStateChange?(state)
    }

    /// MetalView'dan gelen her dokunma buraya da dusuyor.
    func record(_ action: ControlMessage.TouchAction, nx: Double, ny: Double) {
        guard state == .recording else { return }
        let t = Date().timeIntervalSince(recStart) * 1000
        let a: UInt8 = action == .down ? 0 : (action == .up ? 1 : 2)
        recSteps.append(MacroStep(t: t, action: a, nx: nx, ny: ny))
    }

    @discardableResult
    func stopRecording(name: String) -> Macro? {
        guard state == .recording else { return nil }
        state = .idle
        onStateChange?(state)
        guard recSteps.count > 1 else { return nil }
        let m = Macro(name: name, steps: recSteps)
        macros.append(m)
        save()
        return m
    }

    // MARK: - Oynatim

    func play(_ macro: Macro, speed: Double, loops: Int) {
        stop()
        cancelPlay = false
        state = .playing
        onStateChange?(state)

        let t = Thread { [weak self] in
            guard let self else { return }
            let factor = max(speed, 0.01)
            var loop = 0
            while !self.cancelPlay && (loops == 0 || loop < max(loops, 1)) {
                var prev: Double = 0
                for s in macro.steps {
                    if self.cancelPlay { break }
                    // Adimlar arasi bekleme hiz carpanina bolunur.
                    let waitMs = (s.t - prev) / factor
                    if waitMs > 0 { usleep(UInt32(min(waitMs, 10_000) * 1000)) }
                    prev = s.t
                    let a: ControlMessage.TouchAction =
                        s.action == 0 ? .down : (s.action == 1 ? .up : .move)
                    self.emit?(a, s.nx, s.ny)
                }
                loop += 1
            }
            // Guvenlik: parmak ekranda kalmasin
            if let last = macro.steps.last { self.emit?(.up, last.nx, last.ny) }
            self.state = .idle
            DispatchQueue.main.async { self.onStateChange?(.idle) }
        }
        t.qualityOfService = .userInitiated
        playThread = t
        t.start()
    }

    func stop() {
        cancelPlay = true
        playThread = nil
        if state != .idle {
            state = .idle
            onStateChange?(state)
        }
    }

    // MARK: - Kalicilik

    func save() {
        if let d = try? JSONEncoder().encode(macros) {
            UserDefaults.standard.set(d, forKey: "macros")
        }
    }
    func load() {
        guard let d = UserDefaults.standard.data(forKey: "macros"),
              let m = try? JSONDecoder().decode([Macro].self, from: d) else { return }
        macros = m
    }
}
