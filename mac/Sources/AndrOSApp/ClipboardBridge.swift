import AppKit
import AndrOSCore

/// Mac <-> Android pano senkronizasyonu.
///
/// Cihaz -> Mac: kontrol soketinden gelen DEVICE_MSG_TYPE_CLIPBOARD.
/// Mac -> cihaz: NSPasteboard.changeCount izlenerek SET_CLIPBOARD.
/// Dongu olusmasin diye son senkronlanan metin hatirlaniyor.
final class ClipboardBridge {

    var send: (([UInt8]) -> Void)?
    /// Her yeni pano icerigi (iki yonden de) buraya dusuyor — gecmis icin.
    var onRecord: ((String) -> Void)?
    var enabled = true

    private var lastChangeCount = NSPasteboard.general.changeCount
    private var lastSynced: String?
    private var timer: Timer?
    private var sequence: UInt64 = 1

    func start() {
        stop()
        lastChangeCount = NSPasteboard.general.changeCount
        // NSPasteboard'un degisiklik bildirimi yok; yoklamak tek yol.
        let t = Timer(timeInterval: 0.7, repeats: true) { [weak self] _ in
            self?.pollMacPasteboard()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func pollMacPasteboard() {
        guard enabled else { return }
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        guard let text = pb.string(forType: .string), !text.isEmpty else { return }
        guard text != lastSynced else { return }
        lastSynced = text
        sequence &+= 1
        send?(ControlMessage.setClipboard(text, sequence: sequence))
        onRecord?(text)
        Log.write("pano Mac -> telefon (\(text.count) karakter)")
    }

    /// Cihazdan pano geldi.
    func receivedFromDevice(_ text: String) {
        guard enabled, !text.isEmpty, text != lastSynced else { return }
        lastSynced = text
        DispatchQueue.main.async {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            self.lastChangeCount = pb.changeCount
            self.onRecord?(text)
            Log.write("pano telefon -> Mac (\(text.count) karakter)")
        }
    }
}
