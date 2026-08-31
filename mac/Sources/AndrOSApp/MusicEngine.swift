import AVFoundation
import AppKit
import AndrOSCore

/// Muzik calma motoru. Panelden BAGIMSIZ yasar: kategori degistirilince
/// calma durmaz, mini oynatici uzerinden kontrol edilir.
///
/// AVAudioPlayer yerine AVAudioEngine kullaniliyor cunku ekolayzer ve
/// ses yukseltme (boost) ancak dugum zinciriyle mumkun.
final class MusicEngine {

    static let shared = MusicEngine()

    enum RepeatMode: String { case off, all, one
        var next: RepeatMode { self == .off ? .all : (self == .all ? .one : .off) }
        var symbol: String {
            switch self { case .off: return "repeat"; case .all: return "repeat"
            case .one: return "repeat.1" }
        }
        var title: String {
            switch self { case .off: return L("Tekrar yok", "No repeat")
            case .all: return "Listeyi tekrarla"; case .one: return L("Şarkıyı tekrarla", "Repeat track") }
        }
    }

    /// 10 bantli ekolayzer. Degerler dB, -12 ... +12.
    static let bands: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let eq = AVAudioUnitEQ(numberOfBands: MusicEngine.bands.count)
    private var file: AVAudioFile?
    private var started = false

    /// Calma konumu takibi (AVAudioPlayerNode dogrudan vermiyor).
    private var sampleRate: Double = 44100
    private var startFrame: AVAudioFramePosition = 0
    /// Her yeni calma/atlama icin artan sayac.
    ///
    /// KRITIK: `player.stop()` cagrildiginda ONCEKI dosyanin tamamlanma
    /// geri cagrisi da tetikleniyor. O da next() cagirinca zincirleme
    /// sonsuz "sonraki parca" dongusu olusuyordu ve durdurulamiyordu.
    /// Geri cagri artik kendi neslini kontrol ediyor.
    private var generation: Int = 0
    /// Duraklatildiginda konum: playerTime nil donuyor ve sure 0:00'a
    /// dusuyordu; son bilinen degeri sakliyoruz.
    private var pausedAt: TimeInterval = 0
    private var isPaused = false
    private(set) var duration: TimeInterval = 0
    private(set) var isPlaying = false

    private(set) var queue: [AndroidData.Track] = []
    private(set) var index: Int = -1
    private(set) var current: AndroidData.Track?
    private(set) var artwork: NSImage?

    var shuffle = UserDefaults.standard.bool(forKey: "musicShuffle") {
        didSet { UserDefaults.standard.set(shuffle, forKey: "musicShuffle") }
    }
    var repeatMode = RepeatMode(rawValue:
        UserDefaults.standard.string(forKey: "musicRepeat") ?? "off") ?? .off {
        didSet { UserDefaults.standard.set(repeatMode.rawValue, forKey: "musicRepeat") }
    }
    var volume: Float = Float(UserDefaults.standard.object(forKey: "musicVolume") as? Double ?? 0.8) {
        didSet {
            engine.mainMixerNode.outputVolume = min(volume, 1.0)
            UserDefaults.standard.set(Double(volume), forKey: "musicVolume")
        }
    }
    /// Ek kazanc: -12 ... +12 dB. Ana ses seviyesinden ayri.
    var boostDB: Float = Float(UserDefaults.standard.object(forKey: "musicBoost") as? Double ?? 0) {
        didSet {
            eq.globalGain = max(-12, min(12, boostDB))
            UserDefaults.standard.set(Double(boostDB), forKey: "musicBoost")
        }
    }

    /// COK dinleyici: tek bir `onChange` atamasi vardi ve MusicPanel,
    /// MainWindow'un koydugu dinleyiciyi EZIYORDU — bu yuzden sol alttaki
    /// mini oynatici hic guncellenmiyordu.
    private var observers: [(key: String, block: () -> Void)] = []

    func addObserver(_ key: String, _ block: @escaping () -> Void) {
        observers.removeAll { $0.key == key }
        observers.append((key, block))
    }
    func removeObserver(_ key: String) {
        observers.removeAll { $0.key == key }
    }
    private func onChange() {
        for o in observers { o.block() }
    }
    /// Parcanin dosyasini isteyen kapali fonksiyon (indirme/onbellek panelde).
    var provideFile: ((AndroidData.Track, @escaping (URL?) -> Void) -> Void)?

    private var shuffleOrder: [Int] = []
    private var ticker: Timer?

    private init() {
        engine.attach(player)
        engine.attach(eq)
        for (i, f) in MusicEngine.bands.enumerated() {
            let b = eq.bands[i]
            b.filterType = .parametric
            b.frequency = f
            b.bandwidth = 1.0
            b.bypass = false
            b.gain = Float(UserDefaults.standard.object(forKey: "eqBand\(i)") as? Double ?? 0)
        }
        eq.globalGain = boostDB
        engine.connect(player, to: eq, format: nil)
        engine.connect(eq, to: engine.mainMixerNode, format: nil)
        engine.mainMixerNode.outputVolume = min(volume, 1.0)
    }

    func bandGain(_ i: Int) -> Float { eq.bands[i].gain }
    func setBandGain(_ i: Int, _ db: Float) {
        let v = max(-12, min(12, db))
        eq.bands[i].gain = v
        UserDefaults.standard.set(Double(v), forKey: "eqBand\(i)")
    }
    func resetEQ() {
        for i in eq.bands.indices { setBandGain(i, 0) }
        boostDB = 0
    }

    // MARK: - Kuyruk

    func setQueue(_ tracks: [AndroidData.Track], startAt: Int) {
        queue = tracks
        rebuildShuffle(around: startAt)
        play(at: startAt)
    }

    private func rebuildShuffle(around i: Int) {
        shuffleOrder = Array(queue.indices).shuffled()
        if let pos = shuffleOrder.firstIndex(of: i), pos != 0 {
            shuffleOrder.swapAt(0, pos)
        }
    }

    /// UST USTE kac parca acilamadi.
    ///
    /// Bir parca acilamayinca siradakine geciyoruz — tek bozuk dosya
    /// butun listeyi durdurmasin diye. Ama telefon erisilemezken HER
    /// parca basarisiz oluyor ve bu zincir hic bitmiyordu: liste
    /// boyunca donup duruyor, her adimda yeni bir indirme baslatiyordu
    /// (olculdu: kullanici "tonlarca indirme" gordu). Ust uste birkac
    /// basarisizlikta duruyoruz.
    private var consecutiveFailures = 0
    private let maxConsecutiveFailures = 3

    /// Calma durdu ve sebebi soylenecek.
    var onPlaybackFailed: ((String) -> Void)?

    func play(at i: Int) {
        // Serit muzige donsun; video oynuyorsa sussun.
        NowPlaying.shared.beginMusic()
        guard i >= 0, i < queue.count else { return }
        generation += 1
        let gen = generation
        index = i
        let t = queue[i]
        current = t
        artwork = nil
        onChange()

        provideFile?(t) { [weak self] url in
            // Bu arada baska parcaya gecildiyse bu indirmeyi YOK SAY:
            // eskiden "actigini gosterip oncekini caliyordu".
            guard let self, self.generation == gen, self.index == i else { return }
            guard let url else {
                // Dosya gelmediyse siradakine gec: tek bir bozuk parca
                // butun listeyi durdurmasin. Ama ust uste olursa DUR.
                self.consecutiveFailures += 1
                if self.consecutiveFailures >= self.maxConsecutiveFailures {
                    self.stopAfterFailures()
                    return
                }
                self.onChange()
                self.next()
                return
            }
            self.consecutiveFailures = 0
            self.start(url)
        }
    }

    private func start(_ url: URL) {
        do {
            let f = try AVAudioFile(forReading: url)
            file = f
            sampleRate = f.processingFormat.sampleRate
            duration = Double(f.length) / sampleRate

            generation += 1
            let gen = generation
            player.stop()
            if !started { try engine.start(); started = true }
            player.scheduleFile(f, at: nil) { [weak self] in
                DispatchQueue.main.async {
                    guard let self, self.generation == gen else { return }
                    self.trackFinished()
                }
            }
            startFrame = 0
            pausedAt = 0
            isPaused = false
            player.play()
            isPlaying = true
            artwork = MusicEngine.artwork(of: url)
            startTicker()
            onChange()
        } catch {
            Log.write("muzik acilamadi: \(error)")
            // Zincirleme atlamayi onlemek icin: sonrakine gecerken de
            // nesil artar, boylece eski geri cagrilar yok sayilir.
            generation += 1
            consecutiveFailures += 1
            if consecutiveFailures >= maxConsecutiveFailures {
                stopAfterFailures()
                return
            }
            next()
        }
    }

    static func artwork(of url: URL) -> NSImage? {
        let asset = AVURLAsset(url: url)
        for m in asset.commonMetadata where m.commonKey == .commonKeyArtwork {
            if let d = m.dataValue, let img = NSImage(data: d) { return img }
        }
        return nil
    }

    /// Ust uste basarisizlik: calmayi birak ve SEBEBINI soyle.
    private func stopAfterFailures() {
        consecutiveFailures = 0
        generation += 1
        player.stop()
        isPlaying = false
        current = nil
        onChange()
        Log.write("muzik: üst üste \(maxConsecutiveFailures) parça açılamadı, durduruldu")
        onPlaybackFailed?(L("Parçalar telefondan alınamadı. Bağlantıyı kontrol et.",
                            "Could not fetch tracks from the phone. Check the connection."))
    }

    private func startTicker() {
        ticker?.invalidate()
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.onChange() }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    var currentTime: TimeInterval {
        // Duraklatildiginda playerTime nil donuyor; son konumu veriyoruz.
        if isPaused { return pausedAt }
        guard let node = player.lastRenderTime,
              let p = player.playerTime(forNodeTime: node) else { return pausedAt }
        // Dugumun KENDI ornekleme hizini kullan: dosyaninkiyle farkli olabilir
        // ve bu fark yuzunden ilerleme cubugu parca bitmeden dolmuyordu.
        let rate = p.sampleRate > 0 ? p.sampleRate : sampleRate
        return min(Double(startFrame) / sampleRate + Double(p.sampleTime) / rate, duration)
    }

    private func trackFinished() {
        if repeatMode == .one, index >= 0 {
            play(at: index)
            return
        }
        next()
    }

    // MARK: - Denetimler

    func togglePlay() {
        guard file != nil else { return }
        if isPlaying {
            pausedAt = currentTime     // once oku, SONRA duraklat
            isPaused = true
            player.pause()
            isPlaying = false
        } else {
            isPaused = false
            player.play()
            isPlaying = true
        }
        onChange()
    }

    func next() {
        guard !queue.isEmpty else { return }
        if shuffle {
            guard let pos = shuffleOrder.firstIndex(of: index) else { play(at: 0); return }
            if pos + 1 < shuffleOrder.count { play(at: shuffleOrder[pos + 1]) }
            else if repeatMode != .off { rebuildShuffle(around: 0); play(at: shuffleOrder[0]) }
            else { stop() }
            return
        }
        if index + 1 < queue.count { play(at: index + 1) }
        else if repeatMode == .all { play(at: 0) }
        else { stop() }
    }

    /// 3 saniyeden fazla calindiysa BASA SAR, degilse onceki parcaya gec.
    func previous() {
        guard !queue.isEmpty else { return }
        if currentTime > 3.0 {
            seek(to: 0)
            return
        }
        if shuffle {
            guard let pos = shuffleOrder.firstIndex(of: index), pos > 0 else { seek(to: 0); return }
            play(at: shuffleOrder[pos - 1])
            return
        }
        if index > 0 { play(at: index - 1) } else { seek(to: 0) }
    }

    func seek(to time: TimeInterval) {
        guard let f = file else { return }
        let frame = AVAudioFramePosition(max(0, min(time, duration)) * sampleRate)
        let remaining = f.length - frame
        guard remaining > 0 else { next(); return }
        generation += 1
        let gen = generation
        player.stop()
        startFrame = frame
        pausedAt = time
        isPaused = false
        player.scheduleSegment(f, startingFrame: frame,
                               frameCount: AVAudioFrameCount(remaining), at: nil) { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                self.trackFinished()
            }
        }
        player.play()
        isPlaying = true
        onChange()
    }

    func stop() {
        generation += 1        // bekleyen geri cagrilar yok sayilsin
        player.stop()
        isPlaying = false
        isPaused = false
        pausedAt = 0
        current = nil
        file = nil
        index = -1
        ticker?.invalidate(); ticker = nil
        onChange()
    }
}

// MARK: - Calma listeleri

/// Basit, diskte saklanan calma listeleri. Parcalari YOL ile tutuyoruz;
/// cihaz degisse bile ayni yol varsa liste calisir.
struct Playlist: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var paths: [String]
}

enum PlaylistStore {
    /// Calma listeleri CIHAZA BAGLI tutuluyor.
    ///
    /// Neden: liste telefondaki dosya YOLLARINI sakliyor. Baska bir
    /// cihazda o yollar yok, dolayisiyla liste ya bos ya da yaniltici
    /// gorunurdu. Anahtar cihaz kimligiyle ayriliyor; cihaz degisince
    /// kendi listeleri geliyor.
    static var deviceKey: String = "default" {
        didSet { NotificationCenter.default.post(name: .androsRefresh, object: nil) }
    }
    private static var key: String { "musicPlaylists." + deviceKey }

    static func load() -> [Playlist] {
        guard let d = UserDefaults.standard.data(forKey: key),
              let p = try? JSONDecoder().decode([Playlist].self, from: d) else { return [] }
        return p
    }
    static func save(_ p: [Playlist]) {
        if let d = try? JSONEncoder().encode(p) { UserDefaults.standard.set(d, forKey: key) }
    }
    static func add(_ name: String) -> Playlist {
        var all = load()
        let p = Playlist(name: name, paths: [])
        all.append(p); save(all)
        return p
    }
    static func remove(_ id: UUID) {
        save(load().filter { $0.id != id })
    }
    static func add(paths: [String], to id: UUID) {
        var all = load()
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        for p in paths where !all[i].paths.contains(p) { all[i].paths.append(p) }
        save(all)
    }
    static func remove(paths: [String], from id: UUID) {
        var all = load()
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        all[i].paths.removeAll { paths.contains($0) }
        save(all)
    }
    static func rename(_ id: UUID, to name: String) {
        var all = load()
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        all[i].name = name
        save(all)
    }
}
