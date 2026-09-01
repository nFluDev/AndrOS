package dev.naer.andros

import android.app.Activity
import android.app.AlertDialog
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import androidx.core.content.FileProvider
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import kotlin.concurrent.thread

/**
 * Gomulu indirici: APK'yi UYGULAMANIN ICINDE indirip kurulumu acar.
 *
 * Neden: tarayiciya atmak guvenilmez cikti. Bazi tarayicilar indirmeyi
 * sessizce dusuruyor, bazilari "bu dosya tehlikeli olabilir" uyarisinin
 * arkasina saklaniyor, ColorOS indirilenler klasorunu bulmayi ayri bir
 * is haline getiriyor. Burada tek bir ilerleme cubugu ve tek bir sistem
 * kurulum ekrani var.
 *
 * SESSIZ KURULUM YOK: kurulumu Android'in kendi ekrani onayliyor. Bunu
 * atlatmanin yolu yok, olmasi da dogru degil.
 */
object Installer {

    private const val TAG = "AndrOS.Installer"

    /**
     * Indirip kurulum ekranini acar.
     *
     * Dosya uygulamanin KENDI klasorune iniyor: depolama izni
     * gerekmiyor ve indirilenler klasorunu kirletmiyoruz.
     */
    fun downloadAndInstall(activity: Activity, url: String, version: String) {
        // "Bilinmeyen kaynak" izni ONCE. Yoksa indirme bitiyor, kurulum
        // ekrani sessizce acilmiyor ve hicbir sey olmamis gibi duruyor.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !activity.packageManager.canRequestPackageInstalls()) {
            askInstallPermission(activity, url, version)
            return
        }

        val dir = File(activity.getExternalFilesDir(null), "updates").apply { mkdirs() }
        // Eski indirmeler birikmesin.
        dir.listFiles()?.forEach { it.delete() }
        val out = File(dir, "AndrOS-$version.apk")

        val bar = ProgressBar(activity, null, android.R.attr.progressBarStyleHorizontal).apply {
            max = 1000
            isIndeterminate = true
        }
        val label = TextView(activity).apply {
            text = "İndiriliyor…"
            setTextColor(activity.getColor(R.color.text_dim))
            textSize = 13f
        }
        val box = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(60, 40, 60, 10)
            addView(label)
            addView(bar)
        }
        val dialog = AlertDialog.Builder(activity)
            .setTitle("AndrOS $version")
            .setView(box)
            .setNegativeButton("Vazgeç", null)
            .setCancelable(false)
            .show()

        // Yerel degiskene `@Volatile` konamiyor; indirme baska bir is
        // parcaciginda oldugu icin gorunurlugu atomik kutu sagliyor.
        val cancelled = java.util.concurrent.atomic.AtomicBoolean(false)
        dialog.getButton(AlertDialog.BUTTON_NEGATIVE).setOnClickListener {
            cancelled.set(true)
            dialog.dismiss()
        }

        thread(isDaemon = true, name = "andros-download") {
            try {
                var link = url
                var conn: HttpURLConnection
                var hops = 0
                // GitHub indirme baglantisi CDN'e YONLENDIRIYOR ve
                // HttpURLConnection https->https disindaki gecislerde
                // yonlendirmeyi kendisi izlemiyor.
                while (true) {
                    conn = (URL(link).openConnection() as HttpURLConnection).apply {
                        instanceFollowRedirects = false
                        setRequestProperty("User-Agent", "AndrOS-Android")
                        connectTimeout = 15000
                        readTimeout = 30000
                    }
                    val code = conn.responseCode
                    if (code in 301..308 && hops++ < 5) {
                        link = conn.getHeaderField("Location") ?: break
                        conn.disconnect()
                        continue
                    }
                    if (code != 200) throw IllegalStateException("HTTP $code")
                    break
                }
                val total = conn.contentLength.toLong()
                activity.runOnUiThread { bar.isIndeterminate = total <= 0 }

                var done = 0L
                conn.inputStream.use { input ->
                    out.outputStream().use { file ->
                        val buf = ByteArray(64 * 1024)
                        while (true) {
                            if (cancelled.get()) { out.delete(); return@thread }
                            val n = input.read(buf)
                            if (n < 0) break
                            file.write(buf, 0, n)
                            done += n
                            if (total > 0) {
                                val pct = (done * 1000 / total).toInt()
                                activity.runOnUiThread {
                                    bar.progress = pct
                                    label.text = "İndiriliyor… %${pct / 10}"
                                }
                            }
                        }
                    }
                }
                Log.i(TAG, "indirildi: ${out.length()} bayt")
                activity.runOnUiThread {
                    dialog.dismiss()
                    openInstaller(activity, out)
                }
            } catch (e: Throwable) {
                Log.w(TAG, "indirme hatasi: ${e.message}")
                out.delete()
                activity.runOnUiThread {
                    dialog.dismiss()
                    AlertDialog.Builder(activity)
                        .setTitle("İndirilemedi")
                        .setMessage(e.message ?: "Bağlantı kurulamadı.")
                        .setPositiveButton("Tamam", null)
                        .show()
                }
            }
        }
    }

    /// Sistem kurulum ekrani. Dosyayi `content://` olarak veriyoruz —
    /// Android 7'den beri `file://` paylasmak yasak.
    private fun openInstaller(ctx: Context, apk: File) {
        val uri = FileProvider.getUriForFile(ctx, "${ctx.packageName}.files", apk)
        val i = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        ctx.startActivity(i)
    }

    private fun askInstallPermission(activity: Activity, url: String, version: String) {
        AlertDialog.Builder(activity)
            .setTitle("Kurulum izni gerekiyor")
            .setMessage("AndrOS güncellemeyi kendisi indirip kurabilmek için "
                      + "“bu kaynaktan uygulama yükleme” iznine ihtiyaç duyuyor. "
                      + "Açtıktan sonra buraya dön ve tekrar dene.")
            .setPositiveButton("Ayarı aç") { _, _ ->
                activity.startActivity(Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:${activity.packageName}")))
            }
            .setNegativeButton("Vazgeç", null)
            .show()
    }
}
