package dev.naer.andros

import android.app.Activity
import android.app.AlertDialog
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import android.provider.Settings
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.Switch
import android.widget.TextView
import android.widget.Toast
import dev.naer.andros.net.Identity

/**
 * Ayarlar.
 *
 * Her satirin ALTINDA ne yaptigi yaziyor. Bir anahtarin ne anlama
 * geldigini tahmin ettirmek, kullaniciyi ya korkutup hic dokundurmuyor
 * ya da yanlislikla actiriyor.
 */
class SettingsActivity : Activity() {

    private val prefs by lazy { getSharedPreferences("andros.settings", Context.MODE_PRIVATE) }

    override fun onCreate(saved: Bundle?) {
        super.onCreate(saved)
        setTheme(R.style.Theme_AndrOS)
        setContentView(R.layout.activity_settings)
        findViewById<TextView>(R.id.backButton).setOnClickListener { finish() }
        findViewById<TextView>(R.id.versionText).text = versionLine()
        build()
    }

    override fun onResume() { super.onResume(); build() }

    private fun versionLine(): String {
        val p = packageManager.getPackageInfo(packageName, 0)
        return "AndrOS ${p.versionName} · Android ${android.os.Build.VERSION.RELEASE}"
    }

    private fun build() {
        buildBackground()
        buildUpdate()
        buildReset()
    }

    // MARK: - Baslangic ve arka plan

    private fun buildBackground() {
        val box = findViewById<LinearLayout>(R.id.backgroundBox)
        box.removeAllViews()

        toggleRow(box, "Açılışta başlat",
            "Telefon yeniden başladığında AndrOS kendiliğinden çalışır.",
            prefs.getBoolean(KEY_RUN_AT_BOOT, true)) { on ->
            prefs.edit().putBoolean(KEY_RUN_AT_BOOT, on).apply()
        }

        toggleRow(box, "Her zaman arka planda",
            "Uygulamayı kapatsan da bağlantı sürer. Kapatırsan Mac ancak "
          + "uygulama açıkken bağlanabilir.",
            prefs.getBoolean(KEY_ALWAYS_ON, true)) { on ->
            prefs.edit().putBoolean(KEY_ALWAYS_ON, on).apply()
            if (on) AndrOSService.start(this, fromForeground = true)
            else AndrOSService.stop(this)
        }

        toggleRow(box, "Sessiz bildirim",
            "Kalıcı bildirimi en alta iter: sesi ve rozeti olmaz, bildirim "
          + "gölgesinin dibinde durur. Android bu bildirimi tamamen "
          + "kaldırmaya izin vermiyor — arka planda kalmanın şartı.",
            prefs.getBoolean(KEY_QUIET_NOTIF, false)) { on ->
            prefs.edit().putBoolean(KEY_QUIET_NOTIF, on).apply()
            AndrOSService.start(this, fromForeground = true)
        }

        actionRow(box, "Uygulama listesinden gizle",
            "Simge çekmecede görünmez; yalnızca Mac’ten ve bildirimden "
          + "erişilir. Geri almak için Mac’teki Cihazlar ekranından "
          + "“Telefon uygulamasını göster” de.",
            if (launcherHidden()) "Göster" else "Gizle") {
            confirmHideLauncher(!launcherHidden())
        }

        actionRow(box, "Pil kısıtlamasından muaf",
            "Bu açık değilken sistem uygulamayı arka planda öldürüyor ve "
          + "bağlantı kopuyor.",
            if (isBatteryExempt()) "✓" else "Aç") {
            if (!isBatteryExempt()) startActivity(Intent(
                Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                Uri.parse("package:$packageName")))
        }
    }

    // MARK: - Guncelleme

    private fun buildUpdate() {
        val box = findViewById<LinearLayout>(R.id.updateBox)
        box.removeAllViews()

        toggleRow(box, "Otomatik güncelleme",
            "Yeni sürüm çıktığında haber verir ve indirir. Kurulumu her "
          + "zaman sen onaylarsın — Android sessiz kuruluma izin vermiyor.",
            prefs.getBoolean(KEY_AUTO_UPDATE, true)) { on ->
            prefs.edit().putBoolean(KEY_AUTO_UPDATE, on).apply()
        }

        actionRow(box, "Şimdi kontrol et",
            "Yayımlanmış son sürümü sorar.", "Kontrol et") {
            Updates.check(this) { result ->
                runOnUiThread {
                    when (result) {
                        is Updates.Result.UpToDate ->
                            toast("En güncel sürümdesin.")
                        is Updates.Result.Available ->
                            promptUpdate(result.version, result.url, result.notes)
                        is Updates.Result.Failed ->
                            toast("Kontrol edilemedi: ${result.reason}")
                    }
                }
            }
        }
    }

    private fun promptUpdate(version: String, url: String, notes: String) {
        AlertDialog.Builder(this)
            .setTitle("Yeni sürüm: $version")
            .setMessage(notes.ifBlank { "Değişiklik notu yok." })
            .setPositiveButton("İndir") { _, _ ->
                startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
            }
            .setNegativeButton("Şimdi değil", null)
            .show()
    }

    // MARK: - Sifirlama

    private fun buildReset() {
        val box = findViewById<LinearLayout>(R.id.resetBox)
        box.removeAllViews()

        actionRow(box, "Eşleşmeleri kaldır",
            "Eşleşmiş bütün Mac’ler unutulur; bir dahaki bağlanmada kod "
          + "sorulur.", "Kaldır") {
            confirm("Eşleşmeler kaldırılsın mı?",
                    "Eşleşmiş Mac’ler unutulur. Verilerin silinmez.") {
                Identity(this).forgetAll()
                toast("Eşleşmeler kaldırıldı.")
            }
        }

        actionRow(box, "İzinleri sıfırla",
            "Verdiğin izinler geri alınır ve uygulama yeniden başlar. "
          + "Android bunu ancak ayarlardan yapabiliyor.", "Sıfırla") {
            confirm("İzinler sıfırlansın mı?",
                    "Uygulama ayarları açılacak. Oradan “İzinler”e girip "
                  + "hepsini kaldırabilirsin.") {
                startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                     Uri.parse("package:$packageName")))
            }
        }

        actionRow(box, "Her şeyi sıfırla",
            "Eşleşmeler, ayarlar ve önbellek silinir. Uygulama ilk günkü "
          + "haline döner.", "Sıfırla") {
            confirm("Her şey sıfırlansın mı?",
                    "Eşleşmeler ve ayarlar silinir. Bu işlem geri alınamaz.") {
                Identity(this).forgetAll()
                prefs.edit().clear().apply()
                cacheDir.deleteRecursively()
                AndrOSService.stop(this)
                toast("Sıfırlandı.")
                finish()
            }
        }
    }

    // MARK: - Baslatici simgesi

    private fun launcherComponent() = ComponentName(this, "dev.naer.andros.MainActivity")

    private fun launcherHidden(): Boolean =
        packageManager.getComponentEnabledSetting(launcherComponent()) ==
            PackageManager.COMPONENT_ENABLED_STATE_DISABLED

    private fun confirmHideLauncher(hide: Boolean) {
        if (!hide) { setLauncherHidden(false); toast("Simge geri geldi."); build(); return }
        confirm("Simge gizlensin mi?",
                "Uygulama çekmecede görünmeyecek. Geri getirmek için Mac’teki "
              + "Cihazlar ekranını kullanman gerekir.") {
            setLauncherHidden(true)
            toast("Simge gizlendi.")
            build()
        }
    }

    private fun setLauncherHidden(hidden: Boolean) {
        packageManager.setComponentEnabledSetting(
            launcherComponent(),
            if (hidden) PackageManager.COMPONENT_ENABLED_STATE_DISABLED
            else PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
            PackageManager.DONT_KILL_APP)
    }

    private fun isBatteryExempt(): Boolean {
        val pm = getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
        return pm.isIgnoringBatteryOptimizations(packageName)
    }

    // MARK: - Satirlar

    private fun toggleRow(box: LinearLayout, title: String, note: String,
                          state: Boolean, onChange: (Boolean) -> Unit) {
        val v = row(box, title, note)
        val sw = v.findViewById<Switch>(R.id.toggle)
        sw.visibility = View.VISIBLE
        sw.isChecked = state
        sw.setOnCheckedChangeListener { _, on -> onChange(on) }
        v.setOnClickListener { sw.isChecked = !sw.isChecked }
    }

    private fun actionRow(box: LinearLayout, title: String, note: String,
                          action: String, onTap: () -> Unit) {
        val v = row(box, title, note)
        val a = v.findViewById<TextView>(R.id.action)
        a.visibility = View.VISIBLE
        a.text = action
        v.setOnClickListener { onTap() }
    }

    private fun row(box: LinearLayout, title: String, note: String): View {
        val v = LayoutInflater.from(this).inflate(R.layout.setting_row, box, false)
        v.findViewById<TextView>(R.id.title).text = title
        v.findViewById<TextView>(R.id.note).text = note
        box.addView(v, ViewGroup.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        return v
    }

    private fun confirm(title: String, message: String, onYes: () -> Unit) {
        AlertDialog.Builder(this)
            .setTitle(title).setMessage(message)
            .setPositiveButton("Evet") { _, _ -> onYes() }
            .setNegativeButton("Vazgeç", null)
            .show()
    }

    private fun toast(s: String) = Toast.makeText(this, s, Toast.LENGTH_SHORT).show()

    companion object {
        const val KEY_RUN_AT_BOOT = "runAtBoot"
        const val KEY_ALWAYS_ON = "alwaysOn"
        const val KEY_QUIET_NOTIF = "quietNotification"
        const val KEY_AUTO_UPDATE = "autoUpdate"

        fun prefs(ctx: Context) =
            ctx.getSharedPreferences("andros.settings", Context.MODE_PRIVATE)
    }
}
