import AppKit
import AndrOSCore

/// Telefondaki bir ogeyi Mac panosuna GERCEK ICERIK olarak koyar.
///
/// Yol metnini kopyalamak ise yaramiyordu: kullanici Finder'a ya da bir
/// belgeye yapistirmak istiyor. Bu yuzden dosyayi gecici klasore indirip
/// panoya hem DOSYA URL'sini hem (resimse) NSImage'i koyuyoruz — boylece
/// hem Finder'a hem Mail/Notlar gibi uygulamalara yapistirilabiliyor.
enum CopyContent {

    private static let dir: URL = {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("AndrOS/clip", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// Birden fazla oge kopyalanabilir. `onDone` ilerleme icin.
    static func copy(_ items: [(path: String, name: String)],
                     data: AndroidData,
                     onProgress: ((String) -> Void)? = nil,
                     onDone: ((Int) -> Void)? = nil) {
        guard !items.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            var urls: [URL] = []
            for it in items {
                DispatchQueue.main.async { onProgress?(L("Kopyalanıyor: \(it.name)", "Copying: \(it.name)")) }
                let local = dir.appendingPathComponent(it.name)
                try? FileManager.default.removeItem(at: local)
                if data.pull(it.path, to: local.path) { urls.append(local) }
            }
            DispatchQueue.main.async {
                guard !urls.isEmpty else { onDone?(0); return }
                let pb = NSPasteboard.general
                pb.clearContents()
                // Dosya URL'leri: Finder ve cogu uygulama bunu anlar
                pb.writeObjects(urls as [NSURL])
                // Tek bir resimse gorseli de koy: Notlar/Mail/Onizleme'ye
                // dogrudan yapistirilabilsin.
                if urls.count == 1, let img = NSImage(contentsOf: urls[0]) {
                    pb.writeObjects([img])
                }
                onDone?(urls.count)
            }
        }
    }

    /// Metin icerigi (pano paneli gibi yerler icin).
    static func copyText(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }
}
