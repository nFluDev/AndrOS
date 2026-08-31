import AVFoundation
import CoreAudio
import AudioToolbox
import AndrOSCore

/// Telefondan gelen ham PCM sesi Mac'te calar.
///
/// Neden ham PCM (raw): Opus/AAC cozmek ekstra gecikme ve bagimlilik demek.
/// 48 kHz stereo 16-bit = ~1.5 Mbps; USB'de sorun degil ve cozucu gerekmiyor.
///
/// Telefonun hoparloru: sunucu `audio_source=output` (REMOTE_SUBMIX) ile
/// calisiyor, bu ses cikisini YONLENDIRIYOR — yani telefondan ses gelmiyor.
final class AudioPlayer {

    /// scrcpy varsayilanlari: 48 kHz, stereo, 16-bit signed little-endian.
    static let sampleRate: Double = 48000
    static let channels: AVAudioChannelCount = 2

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private(set) var isRunning = false

    /// Kuyrukta bekleyen tampon sayisi — gecikme takibi icin.
    private var queued = 0
    private let lock = NSLock()

    /// Hangi Mac cikis aygitindan calinsin (nil = sistem varsayilani).
    /// Geri besleme dongusunu onlemek icin `AudioRouting` belirliyor.
    var preferredDevice: AudioDeviceID?

    var volume: Float = 1.0 {
        didSet { player.volume = max(0, min(1, volume)) }
    }

    func start() {
        guard !isRunning else { return }
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: AudioPlayer.sampleRate,
                                      channels: AudioPlayer.channels,
                                      interleaved: false) else {
            Log.write("ses: format olusturulamadi")
            return
        }
        format = fmt
        // CIKIS AYGITINI SEC.
        //
        // Telefonun sesi bizim SANAL aygitimizdan calarsa telefona geri
        // doner ve geri besleme dongusu olusur:
        //   telefon sesi -> Mac -> "AndrOS Hoparlör" -> telefon -> ...
        // `preferredDevice` bu yuzden sanal olmayan bir cikis veriyor.
        if var dev = preferredDevice {
            let unit = engine.outputNode.audioUnit
            if let unit {
                let err = AudioUnitSetProperty(
                    unit, kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global, 0, &dev,
                    UInt32(MemoryLayout<AudioDeviceID>.size))
                if err != noErr { Log.write("ses: çıkış aygıtı seçilemedi (\(err))") }
            }
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: fmt)
        do {
            try engine.start()
            player.volume = volume
            player.play()
            isRunning = true
            Log.write("ses motoru basladi (48kHz stereo)")
        } catch {
            Log.write("ses motoru baslatilamadi: \(error)")
        }
    }

    func stop() {
        guard isRunning else { return }
        player.stop()
        engine.stop()
        engine.detach(player)
        isRunning = false
        lock.lock(); queued = 0; lock.unlock()
        Log.write("ses motoru durdu")
    }

    /// Ham 16-bit LE stereo PCM parcasini kuyruga alir.
    func enqueue(_ pcm: [UInt8]) {
        guard isRunning, let fmt = format, pcm.count >= 4 else { return }

        // Asiri birikme = gecikme. 12 tampondan fazlasini atiyoruz;
        // ses gecikmesi goruntuyle uyumsuz olmaktansa kisa bir kopukluk yeg.
        lock.lock(); let q = queued; lock.unlock()
        if q > 12 { return }

        let frameCount = pcm.count / 4          // 2 kanal * 2 bayt
        guard frameCount > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: fmt,
                                         frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        buf.frameLength = AVAudioFrameCount(frameCount)
        guard let ch = buf.floatChannelData else { return }

        // Interleaved int16 -> planar float32
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<frameCount {
                let l = Int16(littleEndian: samples[i * 2])
                let r = Int16(littleEndian: samples[i * 2 + 1])
                ch[0][i] = Float(l) / 32768.0
                ch[1][i] = Float(r) / 32768.0
            }
        }

        lock.lock(); queued += 1; lock.unlock()
        player.scheduleBuffer(buf) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.queued -= 1; self.lock.unlock()
        }
    }
}
