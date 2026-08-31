import AppKit
import AndrOSCore

/// Ses surucusunu UYGULAMANIN ICINDEN kurar.
///
/// Surucu `/Library/Audio/Plug-Ins/HAL` altina gitmek zorunda —
/// `coreaudiod` yalnizca orayi tariyor — ve orasi root'a ait. Kullaniciyi
/// Terminal'e yollamak yerine macOS'un KENDI parola penceresini
/// gosteriyoruz.
///
/// Neden `do shell script … with administrator privileges`: imzasiz ve
/// acik kaynak bir uygulamanin kullanabilecegi tek desteklenen yol bu.
/// `SMJobBless` Developer ID imzasi istiyor, `AuthorizationExecuteWith
/// Privileges` ise kaldirildi.
///
/// Surucunun kendisi uygulama paketinin icinde geliyor
/// (`Contents/Resources/AndrOSAudio.driver`), yani kaynaktan derleme
/// gerekmiyor: uygulamayi indiren herkeste calisir.
enum AudioDriverInstaller {

    static let installedPath = "/Library/Audio/Plug-Ins/HAL/AndrOSAudio.driver"

    /// Paketle gelen surucu.
    static var bundled: URL? {
        Bundle.main.url(forResource: "AndrOSAudio", withExtension: "driver")
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: installedPath)
    }

    /// Kurulu surum paketle gelenden eski mi?
    static var needsUpdate: Bool {
        guard isInstalled, let b = bundled else { return false }
        let f = FileManager.default
        func mtime(_ p: String) -> Date {
            (try? f.attributesOfItem(atPath: p)[.modificationDate] as? Date) as? Date ?? .distantPast
        }
        let src = b.appendingPathComponent("Contents/MacOS/AndrOSAudio").path
        let dst = installedPath + "/Contents/MacOS/AndrOSAudio"
        guard f.fileExists(atPath: src), f.fileExists(atPath: dst) else { return false }
        let a = (try? Data(contentsOf: URL(fileURLWithPath: src)))?.count ?? 0
        let c = (try? Data(contentsOf: URL(fileURLWithPath: dst)))?.count ?? 0
        return a != c || mtime(src) > mtime(dst)
    }

    /// Kurar. Kullaniciya macOS'un parola penceresi cikar.
    ///
    /// `done` ana is parcaciginda cagriliyor: `nil` = basarili.
    static func install(_ done: @escaping (String?) -> Void) {
        guard let src = bundled else {
            done(L("Sürücü uygulama paketinde bulunamadı",
                   "The driver is missing from the app bundle"))
            return
        }
        // Tirnak sorunlarindan kacinmak icin once gecici bir yere
        // kopyalayip oradan tasiyoruz; kullanicinin klasor adinda bosluk
        // ya da tirnak olabilir.
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("AndrOSAudio.driver")
        try? FileManager.default.removeItem(at: staging)
        do { try FileManager.default.copyItem(at: src, to: staging) }
        catch { done(error.localizedDescription); return }

        let script = """
        rm -rf '\(installedPath)' && \
        mkdir -p '/Library/Audio/Plug-Ins/HAL' && \
        cp -R '\(staging.path)' '\(installedPath)' && \
        chown -R root:wheel '\(installedPath)' && \
        killall coreaudiod
        """
        run(script, done)
    }

    /// Kaldirir.
    static func uninstall(_ done: @escaping (String?) -> Void) {
        run("rm -rf '\(installedPath)' && killall coreaudiod", done)
    }

    private static func run(_ shell: String, _ done: @escaping (String?) -> Void) {
        DispatchQueue.global().async {
            // AppleScript icinde tirnak kacisi: cift tirnak ve ters bolu.
            let escaped = shell
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let osa = "do shell script \"\(escaped)\" with administrator privileges"
            var err: NSDictionary?
            let script = NSAppleScript(source: osa)
            _ = script?.executeAndReturnError(&err)
            let message: String?
            if let err {
                // -128 = kullanici vazgecti; hata gibi gostermeyelim.
                let code = (err[NSAppleScript.errorNumber] as? Int) ?? 0
                message = code == -128
                    ? L("Kurulum iptal edildi", "Installation cancelled")
                    : (err[NSAppleScript.errorMessage] as? String
                       ?? L("Kurulum başarısız", "Installation failed"))
            } else {
                message = nil
                Log.write("ses sürücüsü kuruldu/güncellendi")
            }
            DispatchQueue.main.async { done(message) }
        }
    }
}
