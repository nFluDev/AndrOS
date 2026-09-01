package dev.naer.andros

import android.content.Context
import android.util.Log
import org.json.JSONArray
import java.net.HttpURLConnection
import java.net.URL
import kotlin.concurrent.thread

/**
 * Surum kontrolu.
 *
 * Kaynak GitHub Releases — web sitesi de ayni yerden okuyor. Elle
 * guncellenen bir surum numarasi er ya da gec yanlis olur.
 *
 * SESSIZ KURULUM YOK: Android bunu istemiyor ve istemeli de degil.
 * Kullaniciya haber verip APK'yi indirmesini sagliyoruz, kurulumu o
 * onayliyor.
 */
object Updates {

    private const val TAG = "AndrOS.Updates"
    /// TUM surumler — "/releases/latest" DEGIL.
    ///
    /// GitHub'in "latest" ucu ON SURUMLERI atliyor; beta yayinlarken
    /// hicbir sey donmuyor ve 404 aliniyordu.
    private const val API = "https://api.github.com/repos/nFluDev/AndrOS/releases?per_page=20"

    sealed class Result {
        object UpToDate : Result()
        /// Depoda henuz yayimlanmis surum yok.
        object NoReleases : Result()
        data class Available(val version: String, val url: String, val notes: String) : Result()
        data class Failed(val reason: String) : Result()
    }

    fun check(ctx: Context, done: (Result) -> Unit) {
        thread(isDaemon = true, name = "andros-update") {
            try {
                val c = (URL(API).openConnection() as HttpURLConnection).apply {
                    setRequestProperty("Accept", "application/vnd.github+json")
                    setRequestProperty("User-Agent", "AndrOS-Android")
                    connectTimeout = 8000
                    readTimeout = 8000
                }
                // 404 = depoda HENUZ yayimlanmis surum yok. Bu bir hata
                // degil; kullaniciya "kontrol edilemedi" demek yaniltici.
                if (c.responseCode == 404) { done(Result.NoReleases); return@thread }
                if (c.responseCode != 200) {
                    done(Result.Failed("HTTP ${c.responseCode}")); return@thread
                }
                val arr = org.json.JSONArray(c.inputStream.bufferedReader().readText())
                // LISTENIN SIRASINA GUVENME.
                //
                // Olculdu: GitHub bu ucu tarihe gore DEGIL etiket adina
                // gore siraliyor. "v0.1.0-beta.10" metin olarak
                // "v0.1.0-beta.1"in hemen ardina dusuyor, yani en yeni
                // surum listenin SONLARINDA kaliyor. Ilk kaydi "en yeni"
                // saymak beta.9'u gosteriyordu ve yeni betalar hic
                // gorunmuyordu.
                var json: org.json.JSONObject? = null
                var best = ""
                for (i in 0 until arr.length()) {
                    val o = arr.optJSONObject(i) ?: continue
                    if (o.optBoolean("draft", false)) continue
                    val tag = o.optString("tag_name").removePrefix("v")
                    if (json == null || isNewer(tag, best)) { json = o; best = tag }
                }
                if (json == null) { done(Result.NoReleases); return@thread }
                val tag = json.optString("tag_name").removePrefix("v")
                val notes = json.optString("body")
                val apk = pickApk(json.optJSONArray("assets"))
                val here = ctx.packageManager.getPackageInfo(ctx.packageName, 0).versionName ?: "0"
                if (apk == null) { done(Result.Failed("APK bulunamadı")); return@thread }
                done(if (isNewer(tag, here)) Result.Available(tag, apk, notes)
                     else Result.UpToDate)
            } catch (e: Throwable) {
                Log.w(TAG, "kontrol hatasi: ${e.message}")
                done(Result.Failed(e.message ?: "bağlantı yok"))
            }
        }
    }

    private fun pickApk(assets: JSONArray?): String? {
        if (assets == null) return null
        for (i in 0 until assets.length()) {
            val a = assets.optJSONObject(i) ?: continue
            val name = a.optString("name")
            if (name.endsWith(".apk", true)) return a.optString("browser_download_url")
        }
        return null
    }

    /**
     * Surum karsilastirmasi. Iki tuzak:
     *  - "1.10" > "1.9" olmali; metin karsilastirmasi yanlis yapiyor.
     *  - "0.1.0" > "0.1.0-beta.2" olmali; on surum ekini yok saymak
     *    kesin surumu ESKI gosteriyor.
     */
    private fun isNewer(remote: String, local: String): Boolean {
        fun parts(v: String): Pair<List<Int>, List<Int>> {
            val split = v.split("-", limit = 2)
            val core = split[0].split(".").mapNotNull { it.toIntOrNull() }
            val pre = if (split.size > 1)
                split[1].split(Regex("[^0-9]+")).mapNotNull { it.toIntOrNull() }
            else emptyList()
            return core to pre
        }
        val (ac, ap) = parts(remote)
        val (bc, bp) = parts(local)
        for (i in 0 until maxOf(ac.size, bc.size)) {
            val x = ac.getOrElse(i) { 0 }
            val y = bc.getOrElse(i) { 0 }
            if (x != y) return x > y
        }
        if (ap.isEmpty() != bp.isEmpty()) return ap.isEmpty()
        for (i in 0 until maxOf(ap.size, bp.size)) {
            val x = ap.getOrElse(i) { 0 }
            val y = bp.getOrElse(i) { 0 }
            if (x != y) return x > y
        }
        return false
    }
}
