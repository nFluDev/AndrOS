package dev.naer.andros.net

import android.content.Context
import android.util.Log
import dev.naer.andros.feature.Handlers
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.ServerSocket
import java.net.Socket
import javax.net.ssl.SSLServerSocket

/**
 * TLS sunucusu. Her Mac ayri bir baglantida.
 *
 * Baglanti akisi:
 *   1. TLS el sikismasi (telefonun kendinden imzali sertifikasiyla)
 *   2. `hello`      — istemci kendini tanitir, sunucu cihaz bilgisini doner
 *   3. `auth`       — belirtec varsa dogrudan; yoksa `pair.begin` + `pair.confirm`
 *   4. Yetkili istekler
 *
 * Yetki alinmadan `hello`, `pair.begin`, `pair.confirm` disinda hicbir
 * istek islenmiyor — SMS/kisi gibi veriler eslestirilmemis istemciye
 * hicbir kosulda gitmemeli.
 */
class Server(
    private val ctx: Context,
    private val identity: Identity,
    private val onClients: (Int) -> Unit,
) {
    @Volatile private var socket: ServerSocket? = null
    private var job: Job? = null
    /**
     * TEK BIR SOKET UYGULAMAYI OLDURMESIN.
     *
     * Olculen cokme: bir istemci TLS el sikismasini yarida birakinca
     * (baglanti denemesi, port taramasi, aglar arasi gecis)
     * `SSLHandshakeException` yakalanmadan yukari cikiyor ve TUM surec
     * oluyordu; ColorOS de yeniden baslatmayi once 1,5 sn, sonra 30
     * dakikaya erteliyordu — telefon "kapali" gorunuyordu. Ust duzey
     * isleyici, hangi hata olursa olsun sureci ayakta tutuyor.
     */
    private val guard = CoroutineExceptionHandler { _, e ->
        Log.w(TAG, "baglanti hatasi yutuldu: ${e.javaClass.simpleName}: ${e.message}")
    }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO + guard)
    private val clients = mutableListOf<ClientLink>()
    /// Ayni anda islenecek en fazla istek sayisi.
    private val gate = Semaphore(4)

    val port: Int get() = socket?.localPort ?: 0

    fun start(): Int {
        stop()
        val ctxTls = identity.sslContext()
        // SABIT port: rastgele port her yeniden baslamada degisiyordu ve
        // mDNS kaydi bayatlayinca Mac eski porta baglanmaya calisip
        // "connection refused" aliyordu. Port doluysa rastgeleye dusuyoruz.
        val ss = try {
            ctxTls.serverSocketFactory.createServerSocket(DEFAULT_PORT) as SSLServerSocket
        } catch (e: Exception) {
            Log.w(TAG, "sabit port alinamadi, rastgele: ${e.message}")
            ctxTls.serverSocketFactory.createServerSocket(0) as SSLServerSocket
        }
        // Yalniz modern sifre paketleri; eski TLS'e dusme yok.
        ss.enabledProtocols = arrayOf("TLSv1.3", "TLSv1.2")
        socket = ss
        job = scope.launch {
            while (isActive) {
                val s = try { ss.accept() } catch (e: Exception) { break }
                // Denetim baglantisi GECIKMEYE duyarli: kucuk JSON
                // cerceveleri. Nagle kapali ve dusuk gecikme isareti
                // konuyor ki dosya aktarimi/video akisi bu kanali
                // bekletmesin.
                runCatching {
                    s.tcpNoDelay = true
                    s.trafficClass = 0x10        // IPTOS_LOWDELAY
                }
                launch(guard) { serve(s) }
            }
        }
        Log.i(TAG, "sunucu dinliyor: ${ss.localPort}")
        return ss.localPort
    }

    fun stop() {
        job?.cancel()
        try { socket?.close() } catch (_: Exception) {}
        socket = null
        synchronized(clients) { clients.forEach { it.close() }; clients.clear() }
        onClients(0)
    }

    /// Acik oturumlari kapatir; sunucu dinlemeye DEVAM eder ve
    /// eslesmeler korunur.
    fun disconnectAll() {
        synchronized(clients) { clients.forEach { it.close() }; clients.clear() }
        onClients(0)
    }

    /**
     * Tum istemcilere olay yollar (bildirim, pano…).
     *
     * ARKA PLANDA. Bildirim dinleyicisinin geri cagrisi ANA IS
     * PARCACIGINDA calisiyor; oradan sokete yazmak Android'de yasak
     * (`NetworkOnMainThreadException`). Istisna eskiden bos bir
     * `catch` icinde yutuluyordu, bu yuzden bildirimler Mac'e HIC
     * ulasmiyor ama hicbir hata da gorunmuyordu — olculdu.
     */
    /**
     * Bagli Mac'lere olay yollar.
     *
     * TEK IS PARCACIGI: her olay icin ayri coroutine baslatmak SIRAYI
     * bozuyordu. Bildirimde onemsizdi, ama kumandada imlec farklari
     * sirasiz gidince imlec titriyor. Ayrica yalniz YETKILI istemcilere:
     * eslesmemis bir baglantiya olay gitmemeli.
     */
    fun broadcast(event: JSONObject) {
        val list = synchronized(clients) { clients.filter { it.authorized } }
        if (list.isEmpty()) return
        scope.launch(events + guard) { list.forEach { it.send(event) } }
    }

    /// Olay sirasini koruyan tek is parcacigi.
    @OptIn(ExperimentalCoroutinesApi::class)
    private val events = Dispatchers.IO.limitedParallelism(1)

    private inner class ClientLink(val out: DataOutputStream) {
        var authorized = false
        var name = "?"
        fun send(obj: JSONObject) {
            try { Frame.writeJson(out, obj) }
            catch (e: Throwable) {
                Log.w(TAG, "olay yazilamadi: ${e.javaClass.simpleName}: ${e.message}")
            }
        }
        fun close() { try { out.close() } catch (_: Exception) {} }
    }

    private suspend fun serve(raw: Socket) = withContext(Dispatchers.IO) {
        // AKISLARI ALMAK EL SIKISMASINI TETIKLIYOR. Bu yuzden burasi da
        // try icinde olmali: karsi taraf el sikismasi bitmeden koparsa
        // atilan istisna disari cikip sureci olduruyordu.
        val input: DataInputStream
        val out: DataOutputStream
        try {
            // EL SIKISMASINA SURE SINIRI.
            //
            // `getInputStream()` el sikismasini tetikliyor ve karsi taraf
            // yarida birakirsa SONSUZA KADAR bekliyor. Her yarim kalan
            // baglanti bir `Dispatchers.IO` is parcacigini tutuyordu;
            // varsayilan 64'luk havuz zamanla doluyor ve sunucu YENI
            // baglantilari da kabul edemez hale geliyordu (olculdu:
            // portlar dinliyor, iki soket "established", ama el sikismasi
            // hicbir zaman bitmiyor). Sure dolunca soket kapaniyor ve is
            // parcacigi geri veriliyor.
            raw.soTimeout = 15_000
            input = DataInputStream(BufferedInputStream(raw.getInputStream()))
            out = DataOutputStream(BufferedOutputStream(raw.getOutputStream()))
            // El sikismasi bitti: okuma dongusunde sure siniri OLMAMALI,
            // yoksa bosta bekleyen saglam baglanti da dusurdu.
            raw.soTimeout = 0
        } catch (e: Exception) {
            Log.d(TAG, "el sikismasi tamamlanmadi: ${e.message}")
            try { raw.close() } catch (_: Exception) {}
            return@withContext
        }
        val link = ClientLink(out)
        synchronized(clients) { clients.add(link) }
        onClients(synchronized(clients) { clients.count { it.authorized } })
        val handlers = Handlers(ctx)

        try {
            while (true) {
                val msg = Frame.read(input)
                if (msg.type != Frame.JSON) continue
                val req = JSONObject(String(msg.body, Charsets.UTF_8))
                val id = req.optInt("id", 0)
                val op = req.optString("op")
                val args = req.optJSONObject("args") ?: JSONObject()

                val reply = when {
                    op == "hello" -> {
                        link.name = args.optString("client", "Mac")
                        Reply.ok(id, JSONObject()
                            .put("name", android.os.Build.MODEL)
                            .put("manufacturer", android.os.Build.MANUFACTURER)
                            .put("android", android.os.Build.VERSION.RELEASE)
                            .put("sdk", android.os.Build.VERSION.SDK_INT)
                            .put("deviceId", identity.deviceId)
                            // ANDROID_ID ortak anahtar: ayni cihaz hem adb
                            // hem uygulama uzerinden gorunurse Mac ikisini
                            // TEK satirda birlestirebilsin diye. adb'den de
                            // `settings get secure android_id` ile okunuyor.
                            .put("androidId", android.provider.Settings.Secure.getString(
                                ctx.contentResolver,
                                android.provider.Settings.Secure.ANDROID_ID) ?: "")
                            .put("paired", identity.pairedClients().isNotEmpty()))
                    }
                    op == "auth" -> {
                        val token = args.optString("token")
                        if (identity.isKnown(token)) {
                            link.authorized = true
                            onClients(synchronized(clients) { clients.count { it.authorized } })
                            Reply.ok(id)
                        } else Reply.err(id, "unauthorized", "Belirtec gecersiz")
                    }
                    op == "pair.begin" -> {
                        Pairing.begin(link.name)
                        Reply.ok(id, JSONObject().put("shown", true))
                    }
                    op == "pair.confirm" -> {
                        if (Pairing.consume(args.optString("code"))) {
                            val token = identity.addClient(link.name)
                            link.authorized = true
                            onClients(synchronized(clients) { clients.count { it.authorized } })
                            Reply.ok(id, JSONObject().put("token", token))
                        } else Reply.err(id, "badcode", "Kod yanlis ya da suresi doldu")
                    }
                    !link.authorized ->
                        Reply.err(id, "unauthorized", "Once eslestirme gerekiyor")
                    // AKAN istekler SIRAYLA: govdeyi bloklar halinde
                    // dogrudan sokete yaziyorlar ve Mac tarafinda tek bir
                    // blok alicisi var — ust uste binerlerse veri karisir.
                    op in STREAMING -> handlers.handle(id, op, args, out, input)
                    else -> {
                        // OTEKI ISTEKLER PARALEL.
                        //
                        // Olculen sorun: her sey tek sirada islendigi icin
                        // agir bir istek (500 kucuk resim, 2000 parca)
                        // arkasindakileri bekletiyordu; Mac tarafinda 20
                        // saniyelik sure dolunca Aramalar/Mesajlar bos
                        // donuyor, kategori "uygulama gerekli" diyordu.
                        // "Muzigi actim, arama kayitlari kayboldu" buydu.
                        // Esik: ayni anda en fazla 4 is — telefonu de
                        // bogmayalim.
                        launch(guard) {
                            gate.withPermit {
                                val r = try { handlers.handle(id, op, args, out, input) }
                                        catch (e: Throwable) {
                                            Log.w(TAG, "$op hata: ${e.message}")
                                            Reply.err(id, "failed", e.message ?: "hata")
                                        }
                                if (r != null) Frame.writeJson(out, r)
                            }
                        }
                        null
                    }
                }
                if (reply != null) Frame.writeJson(out, reply)
            }
        } catch (e: Throwable) {
            // `Throwable`: yalniz `Exception` yakalamak yetmiyordu; bazi
            // TLS hatalari `Error` olarak geliyor ve sureci alip goturuyor.
            Log.d(TAG, "baglanti kapandi: ${e.message}")
        } finally {
            synchronized(clients) { clients.remove(link) }
            onClients(synchronized(clients) { clients.count { it.authorized } })
            try { raw.close() } catch (_: Exception) {}
        }
    }

    companion object {
        private const val TAG = "AndrOS.Server"
        /// Govdesini dogrudan sokete akitan istekler — SIRAYLA islenmeli.
        // Govdesini dogrudan sokete akitan ya da soketten OKUYAN
        // istekler: sirali islenmeli, araya baska cerceve giremez.
        private val STREAMING = setOf("files.read", "files.write", "bench")
        /** Kayitli olmayan aralikta sabit port. */
        const val DEFAULT_PORT = 47821
    }
}
