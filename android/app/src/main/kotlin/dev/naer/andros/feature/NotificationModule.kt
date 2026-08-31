package dev.naer.andros.feature

import android.app.Notification
import android.app.RemoteInput
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import org.json.JSONArray
import org.json.JSONObject

/**
 * Telefon bildirimlerini Mac'e tasir.
 *
 * `NotificationListenerService` ozel bir izin istiyor (Ayarlar >
 * Bildirim erisimi); normal izin diyaloguyla verilemiyor.
 *
 * Bildirim GELIR GELMEZ yollaniyor (olay), ayrica ekranda duranlarin
 * tamami istenebiliyor. Gecmis ayrica tutuluyor: kullanici telefonda
 * kapatsa bile Mac'te "gecmis" bolumunde kaliyor — bilgisayar basindan
 * kalkmadan neyi kacirdigini gorebilsin.
 */
class NotificationListener : NotificationListenerService() {

    override fun onListenerConnected() {
        super.onListenerConnected()
        instance = this
        // Hizmeti BURADAN da baslat.
        //
        // Sistem uygulama surecini bildirim dinleyicisini baglamak icin
        // ayaga kaldirabiliyor; o yolda `MainActivity` hic calismiyor ve
        // sunucular kurulmuyordu. Olculdu: surec ayakta, bildirimler
        // geliyor ama `onChange` null ve portlar kapali.
        if (!dev.naer.andros.AndrOSService.running) {
            runCatching { dev.naer.andros.AndrOSService.start(this) }
        }
        // Baglaninca ekranda duranlari tazele: uygulama sonradan
        // baslamis olabilir.
        activeNotifications?.forEach { live[it.key] = it }
        onChange?.invoke(null)
    }

    override fun onListenerDisconnected() {
        instance = null
        super.onListenerDisconnected()
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        live[sbn.key] = sbn
        remember(sbn)
        val cb = onChange
        android.util.Log.i("AndrOS.Notif",
            "bildirim: ${sbn.packageName} dinleyici=${cb != null}")
        cb?.invoke(describe(sbn, this))
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        live.remove(sbn.key)
        onChange?.invoke(null)
    }

    companion object {
        @Volatile private var instance: NotificationListener? = null
        private val live = LinkedHashMap<String, StatusBarNotification>()
        /// Ekrandan silinse bile duran gecmis.
        private val history = ArrayList<JSONObject>()
        private const val HISTORY_MAX = 300

        /// Yeni bildirim gelince cagrilir (`null` = yalniz liste degisti).
        var onChange: ((JSONObject?) -> Unit)? = null

        private fun remember(sbn: StatusBarNotification) {
            val ctx = instance ?: return
            val o = describe(sbn, ctx)
            synchronized(history) {
                history.removeAll { it.optString("key") == sbn.key }
                history.add(o)
                while (history.size > HISTORY_MAX) history.removeAt(0)
            }
        }

        /// Bir bildirimi JSON'a cevirir; eylemleri de tasir.
        fun describe(sbn: StatusBarNotification, ctx: Context): JSONObject {
            val n = sbn.notification
            val e = n.extras
            val actions = JSONArray()
            n.actions?.forEachIndexed { i, a ->
                val hasInput = a.remoteInputs?.isNotEmpty() == true
                actions.put(JSONObject()
                    .put("index", i)
                    .put("title", a.title?.toString() ?: "")
                    .put("reply", hasInput))
            }
            val appName = runCatching {
                val pm = ctx.packageManager
                pm.getApplicationLabel(pm.getApplicationInfo(sbn.packageName, 0)).toString()
            }.getOrDefault(sbn.packageName)
            return JSONObject()
                .put("key", sbn.key)
                .put("package", sbn.packageName)
                .put("app", appName)
                .put("time", sbn.postTime)
                .put("title", e.getCharSequence(Notification.EXTRA_TITLE)?.toString() ?: "")
                .put("text", e.getCharSequence(Notification.EXTRA_TEXT)?.toString() ?: "")
                .put("sub", e.getCharSequence(Notification.EXTRA_SUB_TEXT)?.toString() ?: "")
                .put("ongoing", (n.flags and Notification.FLAG_ONGOING_EVENT) != 0)
                .put("clearable", sbn.isClearable)
                .put("actions", actions)
        }

        /// Ekranda duranlar.
        fun snapshot(ctx: Context): JSONArray {
            val out = JSONArray()
            for (sbn in live.values.toList()) out.put(describe(sbn, ctx))
            return out
        }

        /// Ekrandan silinmis olanlar dahil gecmis.
        fun historySnapshot(): JSONArray {
            val out = JSONArray()
            synchronized(history) { for (o in history.reversed()) out.put(o) }
            return out
        }

        /// Bildirimi kapatir (telefonda da kaybolur).
        fun dismiss(key: String): Boolean {
            val s = instance ?: return false
            return runCatching { s.cancelNotification(key); true }.getOrDefault(false)
        }

        fun dismissAll(): Boolean {
            val s = instance ?: return false
            return runCatching { s.cancelAllNotifications(); true }.getOrDefault(false)
        }

        /// Bildirimin bir eylemini calistirir; `text` varsa yanit olarak
        /// gonderir (WhatsApp/SMS gibi uygulamalarda dogrudan cevap).
        fun act(key: String, index: Int, text: String?): Boolean {
            val sbn = live[key] ?: return false
            val a = sbn.notification.actions?.getOrNull(index) ?: return false
            return runCatching {
                if (text != null && a.remoteInputs?.isNotEmpty() == true) {
                    val intent = Intent()
                    val bundle = Bundle()
                    for (ri in a.remoteInputs!!) bundle.putCharSequence(ri.resultKey, text)
                    RemoteInput.addResultsToIntent(a.remoteInputs!!, intent, bundle)
                    a.actionIntent.send(instance, 0, intent)
                } else {
                    a.actionIntent.send()
                }
                true
            }.getOrDefault(false)
        }

        fun isEnabled(ctx: Context): Boolean {
            val flat = Settings.Secure.getString(
                ctx.contentResolver, "enabled_notification_listeners") ?: return false
            val me = ComponentName(ctx, NotificationListener::class.java).flattenToString()
            return flat.split(":").any { it == me }
        }
    }
}
