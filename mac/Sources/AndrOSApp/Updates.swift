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

    /// TUM surumler — `/releases/latest` DEGIL.
    ///
    /// GitHub'in "latest" ucu on surumleri (prerelease) ATLIYOR; beta
    /// yayinlarken hicbir sey donmuyor ve 404 aliniyordu. Listeyi
    /// cekip en yenisini kendimiz seciyoruz.
    private static let api =
        URL(string: "https://api.github.com/repos/nFluDev/AndrOS/releases?per_page=20")!

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
            guard let all = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            else { finish(.failed("yanıt okunamadı")); return }
            // Taslaklar haric; on surumler DAHIL (beta kullaniyoruz).
            let usable = all.filter { ($0["draft"] as? Bool ?? false) == false }

            // LISTENIN SIRASINA GUVENME.
            //
            // Olculdu: GitHub bu ucu tarihe gore DEGIL etiket adina gore
            // siraliyor. "v0.1.0-beta.10" metin olarak "v0.1.0-beta.1"in
            // hemen ardina dusuyor, yani en yeni surum listenin
            // SONLARINDA kaliyor. Ilk kaydi "en yeni" saymak beta.9'u
            // gosteriyor ve yeni betalar hic gorunmuyordu.
            let newest = usable.max { a, b in
                let x = ((a["tag_name"] as? String) ?? "").hasPrefix("v")
                    ? String(((a["tag_name"] as? String) ?? "").dropFirst())
                    : ((a["tag_name"] as? String) ?? "")
                let y = ((b["tag_name"] as? String) ?? "").hasPrefix("v")
                    ? String(((b["tag_name"] as? String) ?? "").dropFirst())
                    : ((b["tag_name"] as? String) ?? "")
                return isNewer(y, than: x)
            }
            guard let j = newest, let tag = j["tag_name"] as? String else {
                finish(.noReleases); return
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
            let newer = isNewer(remote, than: local)
            Log.write("güncelleme: uzak \(remote) · yerel \(local) · yeni mi: \(newer)")
            finish(newer ? .available(version: remote, url: url, notes: notes)
                         : .upToDate)
        }.resume()
    }

    /// Surum karsilastirmasi.
    ///
    /// Iki tuzak var:
    ///  • "1.10" > "1.9" olmali — metin karsilastirmasi yanlis yapiyor.
    ///  • "0.1.0" (kesin surum) > "0.1.0-beta.2" olmali — on surum
    ///    ekini yok saymak kesin surumu ESKI gosteriyordu.
    static func isNewer(_ remote: String, than local: String) -> Bool {
        func parts(_ v: String) -> (core: [Int], pre: [Int]) {
            let split = v.split(separator: "-", maxSplits: 1)
            let core = (split.first ?? "").split(separator: ".").compactMap { Int($0) }
            let pre = split.count > 1
                ? split[1].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
                : []
            return (core, pre)
        }
        let a = parts(remote), b = parts(local)
        for i in 0..<max(a.core.count, b.core.count) {
            let x = i < a.core.count ? a.core[i] : 0
            let y = i < b.core.count ? b.core[i] : 0
            if x != y { return x > y }
        }
        // Cekirdek esit: on surum eki OLMAYAN daha yeni.
        if a.pre.isEmpty != b.pre.isEmpty { return a.pre.isEmpty }
        for i in 0..<max(a.pre.count, b.pre.count) {
            let x = i < a.pre.count ? a.pre[i] : 0
            let y = i < b.pre.count ? b.pre[i] : 0
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
