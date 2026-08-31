package dev.naer.andros.feature

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Handler
import android.os.Looper
import dev.naer.andros.net.Reply
import org.json.JSONObject

/**
 * Pano.
 *
 * Bunun icin uygulama sart: Android 10'dan beri ARKA PLANDAKI bir surec
 * panoyu okuyamiyor. adb kabugu de okuyamadigi icin Mac tarafinda pano
 * ancak yansitma acikken calisiyordu. Uygulama on planda bir hizmet
 * olarak calistigi surece bu kisit kalkiyor.
 */
class ClipboardModule(private val ctx: Context) {

    private val cm by lazy { ctx.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager }
    private val main = Handler(Looper.getMainLooper())

    fun get(id: Int): JSONObject {
        // ClipboardManager ANA IS PARCACIGINDAN cagrilmali; aksi halde
        // bazi surumlerde sessizce bos donuyor.
        var text: String? = null
        val lock = Object()
        main.post {
            text = cm.primaryClip?.takeIf { it.itemCount > 0 }
                ?.getItemAt(0)?.coerceToText(ctx)?.toString()
            synchronized(lock) { lock.notifyAll() }
        }
        synchronized(lock) { lock.wait(1500) }
        return Reply.ok(id, JSONObject().put("text", text ?: ""))
    }

    fun set(id: Int, text: String): JSONObject {
        main.post { cm.setPrimaryClip(ClipData.newPlainText("AndrOS", text)) }
        return Reply.ok(id)
    }

    /** Pano degisimini dinler; degisince geri cagriyi tetikler. */
    fun watch(onChange: (String) -> Unit) {
        cm.addPrimaryClipChangedListener {
            val t = cm.primaryClip?.takeIf { it.itemCount > 0 }
                ?.getItemAt(0)?.coerceToText(ctx)?.toString()
            if (!t.isNullOrEmpty()) onChange(t)
        }
    }
}
