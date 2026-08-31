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
    private const val API = "https://api.github.com/repos/nFluDev/AndrOS/releases/latest"

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
                val json = org.json.JSONObject(c.inputStream.bufferedReader().readText())
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

    /// "1.10" > "1.9" olmali: metin karsilastirmasi bunu yanlis yapiyor.
    private fun isNewer(remote: String, local: String): Boolean {
        val a = remote.split(".", "-").mapNotNull { it.toIntOrNull() }
        val b = local.split(".", "-").mapNotNull { it.toIntOrNull() }
        for (i in 0 until maxOf(a.size, b.size)) {
            val x = a.getOrElse(i) { 0 }
            val y = b.getOrElse(i) { 0 }
            if (x != y) return x > y
        }
        return false
    }
}
