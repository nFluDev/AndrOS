package dev.naer.andros.call

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * AndrOS agindan gelen/giden metin mesajlari.
 *
 * SMS'ten AYRI durmak zorunda: SMS telefonun kendi veritabaninda,
 * bunlar ise yalnizca iki ucun elinde. Sunucu iletiyi tasiyip
 * unutuyor, saklamiyor — yani kayit BIZDE degilse hicbir yerde yok.
 */
class MessageStore(ctx: Context) {

    data class Message(val id: String, val outgoing: Boolean,
                       val text: String, val at: Long)

    private val file = File(ctx.filesDir, "messages.json")
    private val threads = HashMap<String, MutableList<Message>>()
    /// Kimlik -> telefon numarasi. Ag kimlik konusuyor, arayuz numara.
    private val numbers = HashMap<String, String>()
    private val lock = Any()

    init { load() }

    private fun load() = synchronized(lock) {
        runCatching {
            if (!file.exists()) return@runCatching
            val root = JSONObject(file.readText())
            val t = root.optJSONObject("threads") ?: JSONObject()
            for (peer in t.keys()) {
                val arr = t.optJSONArray(peer) ?: continue
                val list = ArrayList<Message>(arr.length())
                for (i in 0 until arr.length()) {
                    val o = arr.optJSONObject(i) ?: continue
                    list.add(Message(o.optString("id"), o.optBoolean("out"),
                                     o.optString("text"), o.optLong("at")))
                }
                threads[peer] = list
            }
            val n = root.optJSONObject("numbers") ?: JSONObject()
            for (k in n.keys()) numbers[k] = n.optString(k)
        }
        Unit
    }

    private fun save() = synchronized(lock) {
        runCatching {
            val t = JSONObject()
            for ((peer, list) in threads) {
                val arr = JSONArray()
                for (m in list) {
                    arr.put(JSONObject().put("id", m.id).put("out", m.outgoing)
                        .put("text", m.text).put("at", m.at))
                }
                t.put(peer, arr)
            }
            val n = JSONObject()
            for ((k, v) in numbers) n.put(k, v)
            file.writeText(JSONObject().put("threads", t).put("numbers", n).toString())
        }
        Unit
    }

    fun messages(peer: String): List<Message> =
        synchronized(lock) { threads[peer]?.toList() ?: emptyList() }

    fun peers(): List<String> = synchronized(lock) { threads.keys.toList() }

    fun add(peer: String, m: Message) {
        synchronized(lock) {
            val list = threads.getOrPut(peer) { ArrayList() }
            list.add(m)
            // Sohbet basi sinir: diskte sinirsiz buyumesin.
            while (list.size > 2000) list.removeAt(0)
        }
        save()
    }

    fun remember(peer: String, number: String) {
        synchronized(lock) { numbers[peer] = number }
        save()
    }

    fun number(peer: String): String? = synchronized(lock) { numbers[peer] }

    fun peerFor(number: String): String? {
        val want = SignalClient.normalize(number)
        return synchronized(lock) {
            numbers.entries.firstOrNull { SignalClient.normalize(it.value) == want }?.key
        }
    }
}
