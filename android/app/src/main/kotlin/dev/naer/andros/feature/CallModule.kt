package dev.naer.andros.feature

import android.Manifest
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.CallLog
import dev.naer.andros.net.Reply
import org.json.JSONObject

/**
 * Aramayi TELEFONDA baslatir ve arama kaydini yonetir.
 *
 * Ses Mac'e TASINMIYOR — tasinamiyor da: Android 10'dan beri
 * `VOICE_CALL` ses kaynagi normal uygulamalara kapali (sistem izni
 * `CAPTURE_AUDIO_OUTPUT` gerekiyor) ve telefonun giden ses akisina
 * disaridan ses enjekte etmenin API'si hic yok. Yani Mac'ten
 * konusmak root'suz bir cihazda mumkun degil.
 *
 * Yapilabilen: aramayi Mac'ten BASLATMAK ve gecmisi yonetmek.
 * Kullanici konusmayi telefondan yapiyor.
 */
class CallModule(private val ctx: Context) {

    /** Numarayi cevirir. CALL_PHONE izni varsa dogrudan arar. */
    fun dial(id: Int, number: String, immediate: Boolean): JSONObject {
        if (number.isBlank()) return Reply.err(id, "badargs", "Numara gerekli")
        val direct = immediate && Permissions.has(ctx, Manifest.permission.CALL_PHONE)
        val action = if (direct) Intent.ACTION_CALL else Intent.ACTION_DIAL
        val i = Intent(action, Uri.fromParts("tel", number, null))
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return try {
            ctx.startActivity(i)
            Reply.ok(id, JSONObject().put("direct", direct))
        } catch (e: Exception) {
            Reply.err(id, "dialfailed", e.message ?: "aranamadi")
        }
    }

    /** Arama kaydindan tek bir girdiyi siler. */
    fun delete(id: Int, number: String, date: Long): JSONObject {
        Permissions.missing(ctx, Manifest.permission.WRITE_CALL_LOG)?.let {
            return Reply.err(id, "permission", it)
        }
        return try {
            val n = ctx.contentResolver.delete(
                CallLog.Calls.CONTENT_URI,
                "${CallLog.Calls.NUMBER}=? AND ${CallLog.Calls.DATE}=?",
                arrayOf(number, date.toString()))
            Reply.ok(id, JSONObject().put("deleted", n))
        } catch (e: Exception) {
            Reply.err(id, "deletefailed", e.message ?: "silinemedi")
        }
    }

    /** Telefonun kendi numarasi (SIM'de kayitliysa). */
    fun ownNumber(id: Int): JSONObject {
        val tm = ctx.getSystemService(Context.TELEPHONY_SERVICE)
            as? android.telephony.TelephonyManager
        val n = try {
            if (Permissions.has(ctx, Manifest.permission.READ_PHONE_NUMBERS))
                @Suppress("DEPRECATION") tm?.line1Number else null
        } catch (e: Exception) { null }
        return Reply.ok(id, JSONObject()
            .put("number", n ?: JSONObject.NULL)
            .put("carrier", tm?.networkOperatorName ?: JSONObject.NULL))
    }
}
