package dev.naer.andros.call

import android.content.Context
import android.util.Log
import org.bouncycastle.crypto.params.X25519PublicKeyParameters
import org.json.JSONObject
import java.io.File
import java.util.UUID

/**
 * AndrOS agi: kimlik, baglanti, tanisma ve mesajlar tek yerde.
 *
 * Arayuzun `SignalClient`, `Envelope` ve anahtarlarla tek tek
 * ugrasmasi gerekmiyor — burada "kime yaz" ve "mesaj geldi" var.
 * Mac tarafindaki `SignalHub` ile AYNI davranis; ikisi ayni protokolu
 * konusuyor.
 */
class Hub private constructor(private val ctx: Context) {

    val keys = Keys(ctx)
    val store = MessageStore(ctx)
    val id: String get() = keys.id

    @Volatile var client: SignalClient? = null
        private set

    var onState: ((SignalClient.State) -> Unit)? = null
    var onMessage: ((String, String, Long) -> Unit)? = null
    var onCall: ((String, JSONObject) -> Unit)? = null
    var onPresence: (() -> Unit)? = null

    /// Numara ozeti -> kimlik (su an ulasilabilir olanlar).
    @Volatile var reachable: Map<String, String> = emptyMap()
        private set

    private val peers = HashMap<String, X25519PublicKeyParameters>()
    private val sharedKeys = HashMap<String, ByteArray>()
    /// Karsi tarafin anahtari daha gelmedigi icin bekleyen iletiler.
    private val pending = HashMap<String, MutableList<JSONObject>>()
    /// Ozet -> sorulan numara. Yanit yalniz ozeti tasiyor.
    private val pendingLookups = HashMap<String, String>()
    private val peerFile = File(ctx.filesDir, "peers.json")

    init { loadPeers() }

    // MARK: - Baglanti

    fun start() {
        val prefs = ctx.getSharedPreferences("andros", Context.MODE_PRIVATE)
        if (!prefs.getBoolean("signalEnabled", true)) {
            Log.i(TAG, "ag kapali"); return
        }
        client?.disconnect()
        val c = SignalClient(keys, SignalClient.urlFor(ctx))
        c.onState = { st -> onState?.invoke(st) }
        c.onEnvelope = { from, env -> receive(from, env) }
        c.onPresence = { found, _ ->
            reachable = found
            // Ag kimlik konusuyor, arayuz numara: eslemeyi sakli tut.
            for ((digest, peer) in found) {
                pendingLookups[digest]?.let { store.remember(peer, it) }
            }
            onPresence?.invoke()
        }
        c.onUndeliverable = { to -> Log.i(TAG, "$to bagli degil") }
        client = c
        c.connect()
    }

    fun stop() { client?.disconnect(); client = null }

    /// Bu telefon hangi numaradan bulunabilir.
    fun announce(numbers: List<String>) { client?.myNumbers = numbers }

    fun checkReachable(numbers: List<String>) {
        val c = client ?: return
        val digests = ArrayList<String>()
        for (n in numbers) {
            val d = c.digest(n)
            if (d.isEmpty()) continue
            pendingLookups[d] = n
            digests.add(d)
        }
        if (digests.isNotEmpty()) c.lookup(digests)
    }

    fun peerFor(number: String): String? {
        val c = client ?: return store.peerFor(number)
        return reachable[c.digest(number)] ?: store.peerFor(number)
    }

    // MARK: - Gonderme

    fun sendMessage(to: String, text: String): MessageStore.Message {
        val m = MessageStore.Message(UUID.randomUUID().toString(), true,
                                     text, System.currentTimeMillis())
        store.add(to, m)
        send(to, JSONObject().put("t", "msg").put("text", text)
            .put("ts", m.at / 1000.0))
        return m
    }

    fun sendCall(to: String, payload: JSONObject) = send(to, payload)

    private fun send(to: String, payload: JSONObject) {
        val c = client ?: return
        val key = keyFor(to)
        if (key == null) {
            // Anahtari yok: once TANISMA. Ileti kuyruga giriyor ve
            // karsi tarafin tanismasi gelince yollaniyor.
            pending.getOrPut(to) { ArrayList() }.add(payload)
            c.send(to, Envelope.intro(keys))
            return
        }
        c.send(to, Envelope.seal(key, payload))
    }

    private fun keyFor(peer: String): ByteArray? {
        sharedKeys[peer]?.let { return it }
        val x = peers[peer] ?: return null
        val k = Keys.sharedKey(keys.xPrivate, x, id, peer)
        sharedKeys[peer] = k
        return k
    }

    // MARK: - Alma

    private fun receive(from: String, env: ByteArray) {
        when (Envelope.typeOf(env)) {
            Envelope.TYPE_INTRO -> {
                val p = Envelope.openIntro(env, from)
                if (p == null) { Log.w(TAG, "gecersiz tanisma paketi ($from)"); return }
                val known = peers.containsKey(from)
                peers[from] = p.xPublic
                sharedKeys.remove(from)
                savePeers()
                // Karsilikli tanisma: bizi taniyan taraf bizim
                // anahtarimizi da bilmeli, yoksa cevap yazamaz.
                if (!known) client?.send(from, Envelope.intro(keys))
                pending.remove(from)?.forEach { send(from, it) }
            }
            Envelope.TYPE_SEALED -> {
                val k = keyFor(from)
                val m = if (k == null) null else Envelope.open(k, env)
                if (m == null) {
                    // Anahtarimiz yok ya da eskimis: yeniden taniselim.
                    Log.i(TAG, "cozulemeyen zarf ($from) — yeniden tanisiliyor")
                    client?.send(from, Envelope.intro(keys))
                    return
                }
                if (m.optString("t") == "msg") {
                    val at = (m.optDouble("ts", 0.0) * 1000).toLong()
                        .takeIf { it > 0 } ?: System.currentTimeMillis()
                    val text = m.optString("text")
                    // SUNUCU SAKLAMIYOR: kayit bizde degilse hicbir
                    // yerde yok. Once yaz, sonra haber ver.
                    store.add(from, MessageStore.Message(
                        UUID.randomUUID().toString(), false, text, at))
                    onMessage?.invoke(from, text, at)
                } else {
                    onCall?.invoke(from, m)
                }
            }
            else -> Log.w(TAG, "bilinmeyen zarf turu")
        }
    }

    private fun loadPeers() = runCatching {
        if (!peerFile.exists()) return@runCatching
        val o = JSONObject(peerFile.readText())
        for (k in o.keys()) {
            val raw = android.util.Base64.decode(o.optString(k), android.util.Base64.NO_WRAP)
            if (raw.size == 32) peers[k] = X25519PublicKeyParameters(raw, 0)
        }
    }.let { Unit }

    private fun savePeers() = runCatching {
        val o = JSONObject()
        for ((k, v) in peers) {
            o.put(k, android.util.Base64.encodeToString(v.encoded, android.util.Base64.NO_WRAP))
        }
        peerFile.writeText(o.toString())
    }.let { Unit }

    companion object {
        private const val TAG = "AndrOS.Hub"
        @Volatile private var instance: Hub? = null

        fun get(ctx: Context): Hub = instance ?: synchronized(this) {
            instance ?: Hub(ctx.applicationContext).also { instance = it }
        }
    }
}
