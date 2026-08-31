import AppKit
import AVFoundation
import AndrOSCore

/// "Su an oynayan" — muzik ya da VIDEO.
///
/// Sol alttaki serit eskiden yalniz `MusicEngine`'i dinliyordu; video
/// acilinca orada hicbir sey gorunmuyordu. Bu katman ikisinin onunde
/// duruyor: serit kimin caldigini bilmeden ayni dugmelerle kontrol
/// ediyor.
///
/// Muzik `AVAudioEngine`, video `AVPlayer` ile calisiyor — ikisini tek
/// motora indirmek yerine burada ortak bir yuz veriyoruz; boylece
/// muzik tarafi hic degismiyor.
final class NowPlaying {
    static let shared = NowPlaying()
    private init() {}

    enum Kind { case none, music, video }
    private(set) var kind: Kind = .none

    /// Oynatici GUCLU tutuluyor.
    ///
    /// Onceki surumde `weak` idi: galeri goruntuleyicisi kapaninca son
    /// gucli baglanti gidiyor, `AVPlayer` cop toplaniyor ve video
    /// duruyordu. Kullanicinin istedigi davranis bunun tersi — pencere
    /// kapansa da serit calmaya devam etsin.
    private(set) var videoPlayer: AVPlayer?
    private(set) var videoTitle = ""
    /// Halen oynayan videonun telefondaki yolu — galeriye donunce
    /// hangi ogeye yeniden baglanacagini bundan biliyoruz.
    private(set) var videoPath: String?
    private var videoSubtitle = ""
    private var videoPoster: NSImage?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    private var observers: [String: () -> Void] = [:]
    func addObserver(_ key: String, _ block: @escaping () -> Void) {
        observers[key] = block
    }
    private func notify() {
        if Thread.isMainThread { observers.values.forEach { $0() } }
        else { DispatchQueue.main.async { self.observers.values.forEach { $0() } } }
    }

    /// Muzik calmaya basladi: serit muzige donsun ve varsa video sussun.
    func beginMusic() {
        if kind == .video { stopVideo() }
        kind = .music
        notify()
    }

    // MARK: - Video

    /// Video oynamaya basladi: serit artik onu gostersin.
    func beginVideo(_ player: AVPlayer, title: String, subtitle: String,
                    poster: NSImage?, path: String? = nil) {
        detachObservers()
        videoPlayer = player
        videoTitle = title
        videoSubtitle = subtitle
        videoPoster = poster
        videoPath = path
        kind = .video
        // Muzik caliyorsa DURDUR: iki ses ust uste binmesin.
        if MusicEngine.shared.isPlaying { MusicEngine.shared.togglePlay() }
        // Serit ilerlemesi icin saniyede birkac kez haber ver.
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main) { [weak self] _ in self?.notify() }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem,
            queue: .main) { [weak self] _ in self?.stopVideo() }
        notify()
    }

    /// Videoyu KESIN olarak birak (serit de kapansin).
    func stopVideo() {
        videoPlayer?.pause()
        detachObservers()
        videoPlayer = nil
        videoPath = nil
        videoTitle = ""
        kind = MusicEngine.shared.current != nil ? .music : .none
        notify()
    }

    /// Serit uzerindeki kapatma dugmesi: ne caliyorsa onu birak.
    func stopAll() {
        if kind == .video { stopVideo(); return }
        if MusicEngine.shared.isPlaying { MusicEngine.shared.togglePlay() }
        kind = .none
        notify()
    }

    private func detachObservers() {
        if let t = timeObserver, let p = videoPlayer { p.removeTimeObserver(t) }
        timeObserver = nil
        if let o = endObserver { NotificationCenter.default.removeObserver(o) }
        endObserver = nil
    }

    // MARK: - Serit icin ortak yuz

    var title: String? {
        switch kind {
        case .video: return videoTitle
        case .music: return MusicEngine.shared.current?.title
        case .none:  return MusicEngine.shared.current?.title
        }
    }

    var subtitle: String {
        switch kind {
        case .video: return videoSubtitle
        default:     return MusicEngine.shared.current?.artist ?? ""
        }
    }

    var artwork: NSImage? {
        kind == .video ? videoPoster : MusicEngine.shared.artwork
    }

    var isPlaying: Bool {
        kind == .video ? (videoPlayer?.rate ?? 0) > 0 : MusicEngine.shared.isPlaying
    }

    var duration: TimeInterval {
        guard kind == .video else { return MusicEngine.shared.duration }
        let d = videoPlayer?.currentItem?.duration ?? .zero
        return d.isNumeric ? d.seconds : 0
    }

    var currentTime: TimeInterval {
        guard kind == .video else { return MusicEngine.shared.currentTime }
        let t = videoPlayer?.currentTime() ?? .zero
        return t.isNumeric ? t.seconds : 0
    }

    // MARK: - Denetimler

    func togglePlay() {
        guard kind == .video, let p = videoPlayer else {
            MusicEngine.shared.togglePlay(); return
        }
        if p.rate > 0 { p.pause() } else { p.play() }
        notify()
    }

    /// Videoda "onceki/sonraki" 10 saniye geri / 30 saniye ileri:
    /// tek bir video oynarken parca atlamak anlamsiz.
    func previous() {
        guard kind == .video else { MusicEngine.shared.previous(); return }
        seek(to: max(0, currentTime - 10))
    }

    func next() {
        guard kind == .video else { MusicEngine.shared.next(); return }
        seek(to: min(duration, currentTime + 30))
    }

    func seek(to time: TimeInterval) {
        guard kind == .video, let p = videoPlayer else {
            MusicEngine.shared.seek(to: time); return
        }
        p.seek(to: CMTime(seconds: time, preferredTimescale: 600))
        notify()
    }
}
