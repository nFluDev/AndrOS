package dev.naer.andros.feature

import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import dev.naer.andros.net.Reply
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream

/**
 * Yuklu uygulamalar.
 *
 * adb ile yalniz PAKET ADI aliniyordu ("com.ark.mzxqteq.gp"); gercek ad
 * ve simge icin APK'yi cozmek gerekiyordu. PackageManager ikisini de
 * dogrudan veriyor — bu yuzden Mac'teki Uygulamalar kategorisindeki
 * "isimler duzgun degil, resimleri gozukmuyor" sorunu kokten cozuluyor.
 */
class AppsModule(private val ctx: Context) {

    fun list(id: Int, includeSystem: Boolean): JSONObject {
        val pm = ctx.packageManager
        val out = JSONArray()
        val apps = pm.getInstalledApplications(PackageManager.GET_META_DATA)
        for (a in apps) {
            val isSystem = (a.flags and ApplicationInfo.FLAG_SYSTEM) != 0
            if (isSystem && !includeSystem) continue
            out.put(JSONObject()
                .put("package", a.packageName)
                .put("label", pm.getApplicationLabel(a).toString())
                .put("system", isSystem)
                .put("enabled", a.enabled)
                .put("launchable", pm.getLaunchIntentForPackage(a.packageName) != null))
        }
        return Reply.ok(id, JSONObject().put("apps", out))
    }

    /** Simgeyi PNG olarak base64 doner — 96x96 yeterli, APK indirmeye gerek yok. */
    fun icon(id: Int, pkg: String): JSONObject {
        return try {
            val d: Drawable = ctx.packageManager.getApplicationIcon(pkg)
            val size = 96
            val bmp = if (d is BitmapDrawable && d.bitmap != null) {
                Bitmap.createScaledBitmap(d.bitmap, size, size, true)
            } else {
                Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888).also {
                    val c = Canvas(it)
                    d.setBounds(0, 0, size, size)
                    d.draw(c)
                }
            }
            val bos = ByteArrayOutputStream()
            bmp.compress(Bitmap.CompressFormat.PNG, 100, bos)
            Reply.ok(id, JSONObject()
                .put("png", android.util.Base64.encodeToString(
                    bos.toByteArray(), android.util.Base64.NO_WRAP)))
        } catch (e: Exception) {
            Reply.err(id, "notfound", e.message ?: "simge yok")
        }
    }

    fun launch(id: Int, pkg: String): JSONObject {
        val i = ctx.packageManager.getLaunchIntentForPackage(pkg)
            ?: return Reply.err(id, "notlaunchable", "Bu uygulama başlatılamıyor")
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        ctx.startActivity(i)
        return Reply.ok(id)
    }
}
