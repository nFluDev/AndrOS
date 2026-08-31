package dev.naer.andros.net

import java.security.SecureRandom

/**
 * Eslestirme durumu: telefonda gosterilen 6 haneli kod.
 *
 * Neden kod: Mac'in sertifikayi sabitlemesi tek basina yetmiyor — ilk
 * baglantida karsidaki Mac'in GERCEKTEN kullanicinin Mac'i oldugunu
 * dogrulamak gerekiyor. Kod ekranda gorunur, kullanici Mac'e yazar;
 * boylece ayni agdaki baska biri sessizce eslesemez.
 *
 * Kod tek kullanimlik ve kisa omurlu.
 */
object Pairing {
    /// Kod 15 saniyede bir yenileniyor. Uzun omurlu bir kod, ekran acik
    /// unutulunca guvenlik acigi; cok kisa olani ise yazmaya vakit
    /// birakmiyor. Mac tarafindaki geri sayim cubugu ayni periyotta.
    const val TTL_MS = 15_000L

    @Volatile private var code: String? = null
    @Volatile private var expiresAt = 0L
    @Volatile var pendingClient: String? = null
        private set

    private var refresher: java.util.Timer? = null

    /// Eslestirme ekrani acikken kodu periyodik yeniler.
    private fun scheduleRefresh() {
        refresher?.cancel()
        val t = java.util.Timer(true)
        t.schedule(object : java.util.TimerTask() {
            override fun run() {
                val who = pendingClient ?: return
                if (code == null) { refresher?.cancel(); return }
                begin(who)
            }
        }, TTL_MS, TTL_MS)
        refresher = t
    }

    /** Yeni kod uretir ve dondurur. */
    fun begin(clientName: String): String {
        val rnd = SecureRandom()
        val c = (0 until 6).map { rnd.nextInt(10) }.joinToString("")
        code = c
        pendingClient = clientName
        expiresAt = System.currentTimeMillis() + TTL_MS
        listener?.invoke(c, clientName)
        scheduleRefresh()
        return c
    }

    fun currentCode(): String? =
        if (System.currentTimeMillis() < expiresAt) code else null

    /// Mac'in ekranindaki QR ile gelen kodu ON ONAYLAR.
    ///
    /// Neden bu yon: Mac'te kamera yok, telefonda var. Telefonun kodu
    /// gosterip Mac'in okumasi mumkun degil; tersi mumkun. Kullanici
    /// Mac'teki QR'i TELEFONUN KENDI kamera uygulamasiyla okuyor, o da
    /// `andros://pair?c=…` baglantisini aciyor. Boylece uygulamaya
    /// kamera kodu eklemeye gerek kalmiyor.
    fun preauthorize(candidate: String, clientName: String) {
        if (candidate.length != 6 || candidate.any { !it.isDigit() }) return
        code = candidate
        pendingClient = clientName
        expiresAt = System.currentTimeMillis() + TTL_MS
        listener?.invoke(candidate, clientName)
    }

    /** Kod dogruysa TEK SEFERLIK tuketir. */
    fun consume(candidate: String): Boolean {
        val c = currentCode() ?: return false
        // Sabit sureli karsilastirma: zamanlama uzerinden kod sizmasin.
        var diff = c.length xor candidate.length
        for (i in c.indices) {
            diff = diff or (c[i].code xor (candidate.getOrNull(i)?.code ?: 0))
        }
        if (diff != 0) return false
        code = null
        expiresAt = 0
        refresher?.cancel(); refresher = null
        listener?.invoke(null, null)
        return true
    }

    fun cancel() {
        code = null; expiresAt = 0; pendingClient = null
        refresher?.cancel(); refresher = null
        listener?.invoke(null, null)
    }

    /** Arayuz kodu gostersin diye. */
    var listener: ((String?, String?) -> Unit)? = null
}
