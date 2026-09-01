package dev.naer.andros.call

import android.util.Base64
import android.util.Log
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * Sinyal sunucusuna baglanti.
 *
 * Sunucu yalnizca TANISTIRIYOR: kimin bagli oldugunu biliyor ve
 * sifreli zarflari iletiyor. Icerigi goremiyor.
 *
 * `wss://` ZORUNLU. Duz `ws://` kabul etmiyoruz: sunucu icerigi
 * goremese de kimin kime yazdigini aradaki herkes gorebilirdi.
 */
class SignalClient(
    private val keys: Keys,
    private val url: String,
    private val salt: String,
) {
    enum class State { OFFLINE, CONNECTING, READY }

    @Volatile var state = State.OFFLINE
        private set
    @Volatile private var ws: WebSocket? = null
    @Volatile private var closedByUs = false
    private var attempt = 0

    /// Bu cihazin bulunabilecegi numaralarin ozetleri.
    var myNumbers: List<String> = emptyList()

    var onState: ((State) -> Unit)? = null
    /// Zarf geldi: (gonderen kimlik, ham zarf).
    var onEnvelope: ((String, ByteArray) -> Unit)? = null
    /// Ulasilabilirlik yaniti: (numara ozeti -> kimlik), bulunamayanlar.
    var onPresence: ((Map<String, String>, List<String>) -> Unit)? = null
    /// Karsi taraf bagli degil.
    var onUndeliverable: ((String) -> Unit)? = null

    private val http = OkHttpClient.Builder()
        .pingInterval(20, TimeUnit.SECONDS)      // NAT eslemesi dusmesin
        .retryOnConnectionFailure(true)
        .build()

    fun connect() {
        if (!url.startsWith("wss://")) {
            Log.w(TAG, "wss:// disinda adres kabul edilmiyor: $url"); return
        }
        closedByUs = false
        set(State.CONNECTING)
        val req = Request.Builder().url(url).build()
        ws = http.newWebSocket(req, object : WebSocketListener() {
            override fun onMessage(webSocket: WebSocket, text: String) {
                runCatching { handle(webSocket, JSONObject(text)) }
                    .onFailure { Log.w(TAG, "cozumlenemedi: ${it.message}") }
            }
            override fun onFailure(webSocket: WebSocket, t: Throwable, r: Response?) {
                Log.w(TAG, "baglanti hatasi: ${t.message}")
                set(State.OFFLINE); retry()
            }
            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                set(State.OFFLINE); retry()
            }
        })
    }

    fun disconnect() {
        closedByUs = true
        ws?.close(1000, null)
        ws = null
        set(State.OFFLINE)
    }

    private fun handle(sock: WebSocket, m: JSONObject) {
        when (m.optString("t")) {
            "hello" -> {
                // Kimligi ISPATLA: sunucunun verdigi rastgele meydan
                // okumayi imzaliyoruz. Hesap ve parola yok.
                val challenge = Base64.decode(m.optString("challenge"), Base64.DEFAULT)
                val numbers = JSONArray().also { a -> myNumbers.forEach { a.put(it) } }
                sock.send(JSONObject()
                    .put("t", "auth")
                    .put("key", b64(keys.edPublic.encoded))
                    .put("sig", b64(keys.sign(challenge)))
                    .put("numbers", numbers).toString())
            }
            "ready" -> {
                attempt = 0
                Log.i(TAG, "sinyal hazir: ${m.optString("id")}")
                set(State.READY)
            }
            "recv" -> {
                val env = Base64.decode(m.optString("env"), Base64.DEFAULT)
                onEnvelope?.invoke(m.optString("from"), env)
            }
            "presence" -> {
                val found = HashMap<String, String>()
                m.optJSONObject("found")?.let { o ->
                    for (k in o.keys()) found[k] = o.optString(k)
                }
                val missing = ArrayList<String>()
                m.optJSONArray("missing")?.let { a ->
                    for (i in 0 until a.length()) missing.add(a.optString(i))
                }
                onPresence?.invoke(found, missing)
            }
            "undeliverable" -> onUndeliverable?.invoke(m.optString("to"))
            "error" -> Log.w(TAG, "sunucu hatasi: ${m.optString("why")}")
        }
    }

    /** Sifreli zarfi kime gidecekse ona iletir. */
    fun send(to: String, envelope: ByteArray): Boolean {
        val s = ws ?: return false
        if (state != State.READY) return false
        return s.send(JSONObject().put("t", "send").put("to", to)
            .put("env", b64(envelope)).toString())
    }

    /** Bu numaralardan hangileri su an ulasilabilir? */
    fun lookup(numberDigests: List<String>) {
        val s = ws ?: return
        val a = JSONArray().also { arr -> numberDigests.forEach { arr.put(it) } }
        s.send(JSONObject().put("t", "lookup").put("of", a).toString())
    }

    /// Yeniden baglanma geri cekilmeli: sunucu kapaliyken saniyede bir
    /// denemek ne baglantiyi getirir ne pili birakir.
    private fun retry() {
        if (closedByUs) return
        attempt++
        val wait = minOf(30_000L, (1500L * (1 shl minOf(attempt - 1, 4))))
        android.os.Handler(android.os.Looper.getMainLooper())
            .postDelayed({ if (!closedByUs && state == State.OFFLINE) connect() }, wait)
    }

    private fun set(s: State) {
        if (state == s) return
        state = s
        onState?.invoke(s)
    }

    private fun b64(b: ByteArray) = Base64.encodeToString(b, Base64.NO_WRAP)

    /**
     * Numaranin sunucuya gidecek OZETI.
     *
     * Numaranin kendisi hicbir zaman gonderilmiyor. Sunucu numaralari
     * listeleyemiyor; yalnizca elinde bir ozet varken karsiligini
     * arayabiliyor. Tuz sunucuyla PAYLASILAN bir sir — istemci ve
     * sunucu ayni ozeti uretmezse esleme tutmaz.
     */
    fun digest(number: String): String {
        val e164 = normalize(number)
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(salt.toByteArray(), "HmacSHA256"))
        return Base64.encodeToString(mac.doFinal(e164.toByteArray()).copyOf(16),
                                     Base64.NO_WRAP)
    }

    companion object {
        private const val TAG = "AndrOS.Signal"

        /**
         * Numarayi E.164'e yaklastirir.
         *
         * Ayni kisi rehberde "0532 …", "+90 532 …", "90532…" diye
         * yaziliyor ve ozetleri farkli cikarsa hic bulusamiyorlar.
         * Turkiye varsayilani: bastaki 0 atilir, +90 eklenir.
         */
        fun normalize(raw: String, defaultCountry: String = "90"): String {
            var d = raw.filter { it.isDigit() || it == '+' }
            if (d.startsWith("+")) return d
            d = d.filter(Char::isDigit)
            if (d.startsWith("00")) return "+" + d.drop(2)
            if (d.startsWith("0")) return "+$defaultCountry" + d.drop(1)
            if (d.startsWith(defaultCountry) && d.length > 10) return "+$d"
            return "+$defaultCountry$d"
        }
    }
}
