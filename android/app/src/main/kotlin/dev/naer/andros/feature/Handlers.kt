package dev.naer.andros.feature

import android.content.Context
import dev.naer.andros.net.Reply
import org.json.JSONObject
import java.io.DataInputStream
import java.io.DataOutputStream

/**
 * Yetkili isteklerin dagitimi. Burasi yalniz yonlendirme yapiyor.
 *
 * Bir modul izin isteyip alamazsa `permission` hatasi ve EKSIK IZNIN adi
 * donuyor; Mac tarafi kullaniciyi telefonda izin vermeye yonlendirebilsin
 * diye. Sessizce bos liste donmek en kotusu olurdu.
 */
class Handlers(private val ctx: Context) {

    companion object {
        /// Akis sunucusu — hizmet baslarken atanir.
        @Volatile var mediaServer: dev.naer.andros.net.MediaServer? = null
    }


    private val clipboard by lazy { ClipboardModule(ctx) }
    private val device by lazy { DeviceModule(ctx) }
    private val sms by lazy { SmsModule(ctx) }
    private val contacts by lazy { ContactsModule(ctx) }
    private val calls by lazy { CallsModule(ctx) }
    private val apps by lazy { AppsModule(ctx) }
    private val media by lazy { MediaModule(ctx) }
    private val files by lazy { FilesModule(ctx) }
    private val phone by lazy { CallModule(ctx) }

    fun handle(id: Int, op: String, a: JSONObject, out: DataOutputStream,
               input: DataInputStream): JSONObject? =
        when (op) {
            "ping"               -> Reply.ok(id, JSONObject().put("pong", true))
            // Hiz olcumu: istenen kadar veriyi ikili cerceveler halinde
            // akitir. Hangi yolun (Wi-Fi / USB) gercekten hizli oldugunu
            // TAHMIN etmek yerine olcuyoruz.
            "bench"              -> bench(id, a.optInt("bytes", 8 * 1024 * 1024), out)
            "device.info"        -> Reply.ok(id, device.info())
            "device.battery"     -> Reply.ok(id, device.battery())
            "device.capabilities" -> Reply.ok(id, capabilities())

            "clipboard.get"      -> clipboard.get(id)
            "clipboard.set"      -> clipboard.set(id, a.optString("text"))

            "sms.conversations"  -> sms.conversations(id, a.optInt("limit", 200))
            "sms.thread"         -> sms.thread(id, a.optLong("threadId"), a.optInt("limit", 500))
            "sms.send"           -> sms.send(id, a.optString("address"), a.optString("body"))

            "contacts.list"      -> contacts.list(id, a.optInt("limit", 2000))
            "calls.list"         -> calls.list(id, a.optInt("limit", 500))
            // Arama TELEFONDA baslatilir; ses Mac'e tasinmiyor (bkz.
            // CallModule aciklamasi — Android buna izin vermiyor).
            "calls.dial"         -> phone.dial(id, a.optString("number"),
                                               a.optBoolean("immediate", false))
            "calls.delete"       -> phone.delete(id, a.optString("number"),
                                                 a.optLong("date"))
            "phone.number"       -> phone.ownNumber(id)

            "apps.list"          -> apps.list(id, a.optBoolean("system", false))
            "apps.icon"          -> apps.icon(id, a.optString("package"))
            "apps.launch"        -> apps.launch(id, a.optString("package"))

            "media.images"       -> media.images(id, a.optInt("limit", 500))
            "media.videos"       -> media.videos(id, a.optInt("limit", 500))
            "media.thumbnail"    -> media.thumbnail(id, a.optLong("mediaId"),
                                                    a.optBoolean("video"), a.optInt("px", 256))
            "music.tracks"       -> media.tracks(id, a.optInt("limit", 2000))
            "music.artwork"      -> media.albumArt(id, a.optLong("albumId"),
                                                   a.optInt("px", 512))
            // Dosyayi INDIRMEDEN oynatmak icin gecici bir HTTP adresi.
            "media.stream"       -> stream(id, a.optString("path"))

            "files.list"         -> files.list(id, a.optString("path"))
            "files.read"         -> files.read(id, a.optString("path"), out)
            "files.write"        -> files.write(id, a.optString("path"), input)
            "files.mkdir"        -> files.mkdir(id, a.optString("path"))
            "files.delete"       -> files.delete(id, a.optString("path"))
            "files.move"         -> files.move(id, a.optString("from"), a.optString("to"))

            "notifications.list" ->
                if (NotificationListener.isEnabled(ctx))
                    Reply.ok(id, JSONObject()
                        .put("notifications", NotificationListener.snapshot(ctx))
                        .put("history", NotificationListener.historySnapshot()))
                else Reply.err(id, "permission", "notification_access")
            "notifications.dismiss" ->
                if (NotificationListener.dismiss(a.optString("key"))) Reply.ok(id)
                else Reply.err(id, "failed", "Bildirim kapatılamadı")
            "notifications.dismissAll" ->
                if (NotificationListener.dismissAll()) Reply.ok(id)
                else Reply.err(id, "failed", "Kapatılamadı")
            // Bildirimin kendi eylemi — metin verilirse YANIT olarak gider
            // (WhatsApp/SMS gibi uygulamalarda dogrudan cevap).
            "notifications.act" ->
                if (NotificationListener.act(a.optString("key"), a.optInt("index"),
                                             a.optString("text").ifEmpty { null }))
                    Reply.ok(id)
                else Reply.err(id, "failed", "Eylem çalıştırılamadı")

            else -> Reply.err(id, "unknown_op", "Bilinmeyen istek: $op")
        }

    private fun bench(id: Int, bytes: Int, out: DataOutputStream): JSONObject? {
        val total = bytes.coerceIn(1 shl 20, 64 shl 20)
        dev.naer.andros.net.Frame.writeJson(out,
            Reply.ok(id, JSONObject().put("streaming", true).put("size", total)))
        val chunk = ByteArray(256 * 1024)
        var sent = 0
        while (sent < total) {
            val n = minOf(chunk.size, total - sent)
            dev.naer.andros.net.Frame.writeBlob(out, id, chunk, 0, n)
            sent += n
        }
        dev.naer.andros.net.Frame.writeBlob(out, id, ByteArray(0), 0, 0)
        return null
    }

    private fun stream(id: Int, path: String): JSONObject {
        val srv = mediaServer ?: return Reply.err(id, "nostream", "Akış sunucusu kapalı")
        if (path.isEmpty() || !java.io.File(path).isFile) {
            return Reply.err(id, "notfound", "Dosya yok")
        }
        return Reply.ok(id, JSONObject()
            .put("path", srv.publish(path))
            .put("port", srv.port))
    }

    /**
     * Hangi modul GERCEKTEN kullanilabilir?
     *
     * Mac tarafi kategorileri buna gore aciyor/soluklastiriyor; olmayan
     * bir veriyi bos gostermek yerine nedenini soyleyebiliyor.
     */
    private fun capabilities(): JSONObject = JSONObject()
        .put("sms", Permissions.has(ctx, android.Manifest.permission.READ_SMS))
        .put("smsSend", Permissions.has(ctx, android.Manifest.permission.SEND_SMS))
        .put("contacts", Permissions.has(ctx, android.Manifest.permission.READ_CONTACTS))
        .put("callLog", Permissions.has(ctx, android.Manifest.permission.READ_CALL_LOG))
        .put("dial", true)
        .put("callDelete", Permissions.has(ctx, android.Manifest.permission.WRITE_CALL_LOG))
        .put("notifications", NotificationListener.isEnabled(ctx))
        .put("files", true)
        .put("media", true)
        .put("clipboard", true)
}
