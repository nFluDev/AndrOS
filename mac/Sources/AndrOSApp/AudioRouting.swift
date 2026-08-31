import AppKit
import CoreAudio
import AVFoundation
import AndrOSCore

/// Ses yollarinin CAKISMASINI onler.
///
/// Uc ayri yol ayni telefonun sesine dokunuyor:
///   1. Yansitma (scrcpy) — telefonun cikisini Mac'te calar
///   2. Ses koprusu       — telefonun cikisini Mac'te calar (yansitmasiz)
///   3. Sanal aygit       — Mac'in cikisini telefona gonderir
///
/// Ikisi ayni anda calisirsa ses cift duyuluyor; 2 ile 3 ayni anda
/// acikken ise GERI BESLEME DONGUSU olusuyor:
///
///     telefon sesi -> Mac -> "AndrOS Hoparlör" -> telefon -> ...
///
/// Burasi tek karar noktasi: telefonun sesini AYNI ANDA yalniz bir yol
/// tasiyor ve telefon sesi hicbir kosulda bizim sanal aygitimiza
/// calinmiyor.
enum AudioRouting {

    /// Sanal cikis aygitimizin kimligi (surucudeki UID ile ayni).
    static let virtualOutputUID = "dev.naer.andros.audio.output"

    /// Yansitma sesi su an acik mi? Acikken koprii telefon sesini
    /// yakalamiyor — ayni ses iki yoldan gelirdi.
    static var mirroringAudioActive = false {
        didSet {
            guard mirroringAudioActive != oldValue else { return }
            AudioBridge.shared.phoneCaptureAllowed = !mirroringAudioActive
            Log.write("ses yolu: yansıtma sesi \(mirroringAudioActive ? "açık" : "kapalı")")
        }
    }

    // MARK: - Cikis aygiti secimi

    /// Sistemin varsayilan cikis aygiti BIZIM sanal aygitimiz mi?
    static var defaultOutputIsOurs: Bool {
        guard let id = defaultOutputDevice() else { return false }
        return uid(of: id) == virtualOutputUID
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                             &addr, 0, nil, &size, &dev)
        return err == noErr ? dev : nil
    }

    private static func uid(of device: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var s: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let err = withUnsafeMutablePointer(to: &s) {
            AudioObjectGetPropertyData(device, &addr, 0, nil, &size, $0)
        }
        guard err == noErr, let s else { return nil }
        return s as String
    }

    /// Telefonun sesi HANGI Mac aygitindan calmali?
    ///
    /// Varsayilan cikis bizim sanal aygitimizsa onu KULLANMIYORUZ:
    /// telefon sesi oradan gecerse telefona geri doner ve dongu olur.
    /// O durumda ilk fiziksel cikisa (dahili hoparlor / kulaklik)
    /// duserek sesi yine de duyuruyoruz.
    static func deviceForPhoneAudio() -> AudioDeviceID? {
        guard let def = defaultOutputDevice() else { return nil }
        guard uid(of: def) == virtualOutputUID else { return def }
        return firstPhysicalOutput()
    }

    private static func firstPhysicalOutput() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &addr, 0, nil, &size) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &ids) == noErr else { return nil }
        for d in ids {
            guard let u = uid(of: d), u != virtualOutputUID else { continue }
            guard outputChannelCount(d) > 0 else { continue }
            return d
        }
        return nil
    }

    private static func outputChannelCount(_ device: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr,
              size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = raw.assumingMemoryBound(to: AudioBufferList.self)
        var n = 0
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        for b in buffers { n += Int(b.mNumberChannels) }
        return n
    }
}
