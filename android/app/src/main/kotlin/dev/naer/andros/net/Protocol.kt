package dev.naer.andros.net

import org.json.JSONObject
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.EOFException

/**
 * Mac ile telefon arasindaki cerceve bicimi.
 *
 * Her cerceve: [4 bayt uzunluk (big-endian)][1 bayt tur][govde]
 *
 * Neden uzunluk onekli: TCP akis tabanli, mesaj siniri yok. JSON'u
 * satir sonuyla ayirmak ikili veri (dosya, resim, ses) tasirken
 * kaciş kurallari gerektiriyordu; uzunluk oneki ikisini de tasiyor.
 */
object Frame {
    const val JSON: Byte = 0
    /** Buyuk ikili govde — istek kimligi govdenin ilk 4 baytinda. */
    const val BLOB: Byte = 1

    /** Tek cerceve icin ust sinir: bozuk/kotu niyetli uzunluk bellegi patlatmasin. */
    const val MAX_FRAME = 16 * 1024 * 1024

    fun writeJson(out: DataOutputStream, obj: JSONObject) {
        val body = obj.toString().toByteArray(Charsets.UTF_8)
        synchronized(out) {
            out.writeInt(body.size + 1)
            out.writeByte(JSON.toInt())
            out.write(body)
            out.flush()
        }
    }

    fun writeBlob(out: DataOutputStream, id: Int, data: ByteArray, offset: Int, length: Int) {
        synchronized(out) {
            out.writeInt(length + 5)
            out.writeByte(BLOB.toInt())
            out.writeInt(id)
            out.write(data, offset, length)
            out.flush()
        }
    }

    class Message(val type: Byte, val body: ByteArray)

    fun read(input: DataInputStream): Message {
        val len = input.readInt()
        if (len < 1 || len > MAX_FRAME) throw EOFException("gecersiz cerceve uzunlugu: $len")
        val type = input.readByte()
        val body = ByteArray(len - 1)
        input.readFully(body)
        return Message(type, body)
    }
}

/** Istek/yanit yardimcilari. */
object Reply {
    fun ok(id: Int, data: JSONObject = JSONObject()): JSONObject =
        JSONObject().put("id", id).put("ok", true).put("data", data)

    fun err(id: Int, code: String, message: String): JSONObject =
        JSONObject().put("id", id).put("ok", false)
            .put("error", JSONObject().put("code", code).put("message", message))

    /** Istemcinin sormadan gonderilen olaylar (bildirim, pano degisimi…). */
    fun event(name: String, data: JSONObject): JSONObject =
        JSONObject().put("event", name).put("data", data)
}
