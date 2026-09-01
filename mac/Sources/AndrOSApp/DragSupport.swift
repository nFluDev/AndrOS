import AppKit
import AndrOSCore
import UniformTypeIdentifiers

/// Telefondaki bir dosyayi/klasoru Mac'in HERHANGI bir yerine surukleyebilmek
/// icin "dosya sozu" (file promise) saglayicisi.
///
/// Neden promise: `adb pull` yavas olabilir. Panoya hazir bir URL koymak
/// icin once indirmek gerekirdi ve surukleme baslarken uygulama donardi.
/// Promise ile surukleme aninda basliyor, dosya BIRAKILDIGI yerde indiriliyor.
final class RemoteFilePromise: NSFilePromiseProvider {
    var entry: AndroidData.FileEntry?
}

final class FilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate {

    var data: AndroidData?
    /// Indirme bitince haber verir (ilerleme gostermek icin).
    var onProgress: ((String, Bool) -> Void)?

    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .userInitiated
        return q
    }()

    func filePromiseProvider(_ p: NSFilePromiseProvider,
                             fileNameForType type: String) -> String {
        (p as? RemoteFilePromise)?.entry?.name ?? "dosya"
    }

    func operationQueue(for p: NSFilePromiseProvider) -> OperationQueue { queue }

    func filePromiseProvider(_ p: NSFilePromiseProvider,
                             writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        guard let e = (p as? RemoteFilePromise)?.entry, let d = data else {
            completionHandler(CocoaError(.fileNoSuchFile)); return
        }
        onProgress?(e.name, true)
        // AKTARIM GECMISINE de dussun: kullanici ne indirdigini
        // gorebilmeli. Kayit once, indirme sonra — surukleme sirasinda
        // serit hemen guncellensin.
        let record = TransferQueue.shared.track(name: e.name, remote: e.path,
                                                local: url.path, direction: .download)
        let ok = d.pull(e.path, to: url.path) { got, total in
            guard total > 0 else { return }
            TransferQueue.shared.update(record, progress: got * 100 / total)
        }
        TransferQueue.shared.finish(record, ok: ok)
        onProgress?(e.name, false)
        completionHandler(ok ? nil : CocoaError(.fileWriteUnknown))
    }
}

/// Surukleme sirasinda bir klasorun uzerinde beklenince o klasoru acan
/// zamanlayici ("spring loading" — Finder'daki davranisin aynisi).
final class SpringLoader {
    private var timer: Timer?
    private var armedPath: String?
    var delay: TimeInterval = 0.8
    var onOpen: ((String) -> Void)?

    /// Surukleme belirli bir klasorun uzerindeyken cagrilir.
    func hover(_ path: String?) {
        guard armedPath != path else { return }
        cancel()
        armedPath = path
        guard let p = path else { return }
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.onOpen?(p)
            self?.armedPath = nil
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        armedPath = nil
    }
}

/// Medya turu suzgeci — Galeri yalniz resim/video kabul ediyor.
enum MediaFilter {
    static let imageExts: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp"]
    static let videoExts: Set<String> = ["mp4", "mov", "mkv", "3gp", "webm", "avi", "m4v"]

    static func isMedia(_ url: URL) -> Bool {
        let e = url.pathExtension.lowercased()
        return imageExts.contains(e) || videoExts.contains(e)
    }

    /// Kabul edilenler ve reddedilenler.
    static func split(_ urls: [URL]) -> (accepted: [URL], rejected: [URL]) {
        var a: [URL] = [], r: [URL] = []
        for u in urls {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
            // Klasorleri de kabul et: icindeki medyayi kullanici zaten secmis olur
            if isDir.boolValue || isMedia(u) { a.append(u) } else { r.append(u) }
        }
        return (a, r)
    }
}
