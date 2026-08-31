import Foundation
import ServiceManagement
import AndrOSCore

/// macOS tarafinda surum kontrolu.
///
/// Kaynak GitHub Releases — site ve Android uygulamasi da ayni yerden
/// okuyor. Elle guncellenen bir surum numarasi er ya da gec yanlis olur.
enum Updates {

    enum Result {
        case upToDate
        /// Depoda henuz yayimlanmis surum yok — hata degil.
        case noReleases
        case available(version: String, url: String, notes: String)
        case failed(String)
    }

    private static let api =
        URL(string: "https://api.github.com/repos/nFluDev/AndrOS/releases/latest")!

    static func check(_ done: @escaping (Result) -> Void) {
        var req = URLRequest(url: api)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("AndrOS-Mac", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10
        URLSession.shared.dataTask(with: req) { data, resp, err in
            func finish(_ r: Result) { DispatchQueue.main.async { done(r) } }
            if let err { finish(.failed(err.localizedDescription)); return }
            if (resp as? HTTPURLResponse)?.statusCode == 404 { finish(.noReleases); return }
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200, let data else {
                finish(.failed("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)")); return
            }
            guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = j["tag_name"] as? String else {
                finish(.failed("yanıt okunamadı")); return
            }
            let remote = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let notes = j["body"] as? String ?? ""
            let assets = j["assets"] as? [[String: Any]] ?? []
            // Mac paketi: .dmg ya da .zip
            let mac = assets.first {
                let n = ($0["name"] as? String ?? "").lowercased()
                return n.hasSuffix(".dmg") || n.hasSuffix(".zip")
            }
            let url = mac?["browser_download_url"] as? String
                ?? (j["html_url"] as? String ?? "")
            let local = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
            finish(isNewer(remote, than: local)
                   ? .available(version: remote, url: url, notes: notes)
                   : .upToDate)
        }.resume()
    }

    /// "1.10" > "1.9" olmali; metin karsilastirmasi bunu yanlis yapiyor.
    static func isNewer(_ remote: String, than local: String) -> Bool {
        let a = remote.split(whereSeparator: { ".-".contains($0) }).compactMap { Int($0) }
        let b = local.split(whereSeparator: { ".-".contains($0) }).compactMap { Int($0) }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

/// Giriste baslatma.
///
/// macOS 13'ten beri `SMAppService` var ve kullanicidan izin
/// istemiyor; eski yol (LaunchAgent plist yazmak) artik gereksiz.
enum LoginItem {
    static func setEnabled(_ on: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            Log.write("girişte başlat: \(on ? "açık" : "kapalı")")
        } catch {
            Log.write("girişte başlat ayarlanamadı: \(error.localizedDescription)")
        }
    }

    static var isEnabled: Bool {
        guard #available(macOS 13.0, *) else { return false }
        return SMAppService.mainApp.status == .enabled
    }
}
