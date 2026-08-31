package dev.naer.andros.feature

import android.Manifest
import android.content.Context
import android.net.Uri
import android.provider.Telephony
import android.telephony.SmsManager
import dev.naer.andros.net.Reply
import org.json.JSONArray
import org.json.JSONObject

/**
 * SMS okuma ve GONDERME.
 *
 * Gonderme adb ile hic mumkun degildi (kabugun SEND_SMS izni yok); Mac
 * tarafinda mesaj ancak telefonun kendi uygulamasinda "hazir aciliyordu".
 * Uygulama bu izne sahip oldugu icin artik gercekten gonderiliyor.
 */
class SmsModule(private val ctx: Context) {

    fun conversations(id: Int, limit: Int): JSONObject {
        Permissions.missing(ctx, Manifest.permission.READ_SMS)?.let {
            return Reply.err(id, "permission", it)
        }
        val out = JSONArray()
        val uri = Telephony.Sms.Conversations.CONTENT_URI
        ctx.contentResolver.query(uri, null, null, null,
            "${Telephony.Sms.Conversations.DEFAULT_SORT_ORDER}")?.use { c ->
            val idxThread = c.getColumnIndex(Telephony.Sms.Conversations.THREAD_ID)
            val idxSnippet = c.getColumnIndex(Telephony.Sms.Conversations.SNIPPET)
            val idxCount = c.getColumnIndex(Telephony.Sms.Conversations.MESSAGE_COUNT)
            var n = 0
            while (c.moveToNext() && n < limit) {
                val thread = if (idxThread >= 0) c.getLong(idxThread) else continue
                out.put(JSONObject()
                    .put("threadId", thread)
                    .put("snippet", if (idxSnippet >= 0) c.getString(idxSnippet) ?: "" else "")
                    .put("count", if (idxCount >= 0) c.getInt(idxCount) else 0)
                    .put("address", addressOf(thread)))
                n++
            }
        }
        return Reply.ok(id, JSONObject().put("conversations", out))
    }

    /** Konusmanin ilk mesajindan karsi tarafin numarasini bulur. */
    private fun addressOf(threadId: Long): String {
        ctx.contentResolver.query(Telephony.Sms.CONTENT_URI,
            arrayOf(Telephony.Sms.ADDRESS),
            "${Telephony.Sms.THREAD_ID}=?", arrayOf(threadId.toString()),
            "${Telephony.Sms.DATE} DESC LIMIT 1")?.use { c ->
            if (c.moveToFirst()) return c.getString(0) ?: ""
        }
        return ""
    }

    fun thread(id: Int, threadId: Long, limit: Int): JSONObject {
        Permissions.missing(ctx, Manifest.permission.READ_SMS)?.let {
            return Reply.err(id, "permission", it)
        }
        val out = JSONArray()
        ctx.contentResolver.query(Telephony.Sms.CONTENT_URI, null,
            "${Telephony.Sms.THREAD_ID}=?", arrayOf(threadId.toString()),
            "${Telephony.Sms.DATE} DESC")?.use { c ->
            val iBody = c.getColumnIndex(Telephony.Sms.BODY)
            val iDate = c.getColumnIndex(Telephony.Sms.DATE)
            val iType = c.getColumnIndex(Telephony.Sms.TYPE)
            val iAddr = c.getColumnIndex(Telephony.Sms.ADDRESS)
            var n = 0
            while (c.moveToNext() && n < limit) {
                out.put(JSONObject()
                    .put("body", c.getString(iBody) ?: "")
                    .put("date", c.getLong(iDate))
                    .put("address", c.getString(iAddr) ?: "")
                    // 1 = gelen, 2 = giden
                    .put("incoming", c.getInt(iType) == Telephony.Sms.MESSAGE_TYPE_INBOX))
                n++
            }
        }
        return Reply.ok(id, JSONObject().put("messages", out))
    }

    fun send(id: Int, address: String, body: String): JSONObject {
        Permissions.missing(ctx, Manifest.permission.SEND_SMS)?.let {
            return Reply.err(id, "permission", it)
        }
        if (address.isBlank() || body.isEmpty()) {
            return Reply.err(id, "badargs", "Numara ve metin gerekli")
        }
        return try {
            val sms = ctx.getSystemService(SmsManager::class.java)
            // Uzun mesajlar TEK parca olarak gonderilemez; 160 karakteri
            // asanlari bolerek yolluyoruz, yoksa sessizce kirpiliyor.
            val parts = sms.divideMessage(body)
            if (parts.size > 1) sms.sendMultipartTextMessage(address, null, parts, null, null)
            else sms.sendTextMessage(address, null, body, null, null)
            Reply.ok(id)
        } catch (e: Exception) {
            // Gercek nedeni Mac'e tasiyoruz: "gonderilemedi" tek basina
            // kullaniciya hicbir sey soylemiyordu.
            Reply.err(id, "sendfailed",
                      "${e.javaClass.simpleName}: ${e.message ?: "bilinmiyor"}")
        }
    }
}
