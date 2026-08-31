package dev.naer.andros.feature

import android.Manifest
import android.content.Context
import android.provider.CallLog
import dev.naer.andros.net.Reply
import org.json.JSONArray
import org.json.JSONObject

/**
 * Arama gecmisi.
 *
 * Bu modul YALNIZ uygulama ile mumkun: Android, arama kaydi
 * saglayicisini adb kabuguna kapatiyor (CallLogProvider ·
 * SecurityException). Mac tarafinda "Aramalar" kategorisi bu yuzden
 * bostu; artik gercek veri geliyor.
 */
class CallsModule(private val ctx: Context) {

    fun list(id: Int, limit: Int): JSONObject {
        Permissions.missing(ctx, Manifest.permission.READ_CALL_LOG)?.let {
            return Reply.err(id, "permission", it)
        }
        val out = JSONArray()
        val proj = arrayOf(CallLog.Calls.NUMBER, CallLog.Calls.CACHED_NAME,
                           CallLog.Calls.TYPE, CallLog.Calls.DATE, CallLog.Calls.DURATION)
        ctx.contentResolver.query(CallLog.Calls.CONTENT_URI, proj, null, null,
            "${CallLog.Calls.DATE} DESC")?.use { c ->
            var n = 0
            while (c.moveToNext() && n < limit) {
                val type = when (c.getInt(2)) {
                    CallLog.Calls.INCOMING_TYPE -> "incoming"
                    CallLog.Calls.OUTGOING_TYPE -> "outgoing"
                    CallLog.Calls.MISSED_TYPE   -> "missed"
                    CallLog.Calls.REJECTED_TYPE -> "rejected"
                    CallLog.Calls.BLOCKED_TYPE  -> "blocked"
                    else -> "other"
                }
                out.put(JSONObject()
                    .put("number", c.getString(0) ?: "")
                    .put("name", c.getString(1) ?: "")
                    .put("type", type)
                    .put("date", c.getLong(3))
                    .put("duration", c.getInt(4)))
                n++
            }
        }
        return Reply.ok(id, JSONObject().put("calls", out))
    }
}
