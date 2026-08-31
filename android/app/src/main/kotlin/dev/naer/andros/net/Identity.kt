package dev.naer.andros.net

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.security.KeyStore
import java.security.MessageDigest
import java.security.cert.X509Certificate
import java.util.UUID
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext

/**
 * Telefonun kalici kimligi: TLS anahtari ve eslestirilmis Mac'lerin
 * belirtecleri.
 *
 * Anahtar AndroidKeyStore'da uretiliyor; ozel anahtar donanim destekli
 * depodan HIC cikmiyor. Kendinden imzali sertifikanin parmak izi
 * eslestirme aninda Mac tarafinda sabitleniyor (certificate pinning),
 * boylece sonraki baglantilarda araya girme mumkun olmuyor.
 */
class Identity(private val ctx: Context) {

    private val prefs = ctx.getSharedPreferences("andros.identity", Context.MODE_PRIVATE)

    val deviceId: String
        get() = prefs.getString("deviceId", null) ?: UUID.randomUUID().toString()
            .also { prefs.edit().putString("deviceId", it).apply() }

    private fun keyStore(): KeyStore =
        KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }

    /// Kimligi adb'nin okuyabilecegi bir dosyaya yazar.
    ///
    /// Neden dosya: ayni telefonu hem adb hem uygulama uzerinden gorunce
    /// Mac'in ikisini TEK cihaz sayabilmesi icin ortak bir anahtar lazim.
    /// ANDROID_ID iş görmüyor — Android 8'den beri UYGULAMA BASINA farkli
    /// uretiliyor (olculdu: uygulama 681bccdf…, adb kabugu b90e4d66…).
    /// Seri numarasi da Android 10'dan beri normal uygulamalara kapali.
    /// `getExternalFilesDir` ise `/sdcard/Android/data/...` altinda ve
    /// adb kabugu oradan okuyabiliyor.
    fun publishId() {
        runCatching {
            val dir = ctx.getExternalFilesDir(null) ?: return
            java.io.File(dir, "andros-id").writeText(deviceId)
        }
    }

    /** Anahtar yoksa uretir; ESKI surumlerin anahtarlarini temizler. */
    fun ensureKey() {
        val ks = keyStore()
        // KeyManagerFactory depodaki TUM anahtarlari goruyor ve ilk uygun
        // olani seciyor. Eski (kisitli ozetli) anahtar durdugu surece onu
        // secip el sikismayi "Incompatible digest" ile dusuruyordu —
        // olculdu. Bu yuzden bizim olmayan takma adlar siliniyor.
        for (a in ks.aliases().toList()) {
            if (a.startsWith("andros.tls") && a != ALIAS) {
                runCatching { ks.deleteEntry(a) }
            }
        }
        if (ks.containsAlias(ALIAS)) return
        val gen = java.security.KeyPairGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_EC, ANDROID_KEYSTORE)
        gen.initialize(
            KeyGenParameterSpec.Builder(ALIAS,
                KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY)
                // TUM ozetlere izin: TLS el sikismasi hangi ozeti
                // secerse secsin imzalayabilelim. Yalniz SHA-256/512'ye
                // izin verince el sikisma "Incompatible digest" ile
                // dusuyordu (olculdu) ve baglanti sessizce asili kaliyordu.
                .setDigests(KeyProperties.DIGEST_NONE, KeyProperties.DIGEST_SHA1,
                            KeyProperties.DIGEST_SHA224, KeyProperties.DIGEST_SHA256,
                            KeyProperties.DIGEST_SHA384, KeyProperties.DIGEST_SHA512)
                .setCertificateSubject(javax.security.auth.x500.X500Principal("CN=AndrOS"))
                .setCertificateSerialNumber(java.math.BigInteger.ONE)
                .setKeySize(256)
                .build())
        gen.generateKeyPair()
    }

    fun certificate(): X509Certificate? =
        keyStore().getCertificate(ALIAS) as? X509Certificate

    /** Mac'in sabitleyecegi parmak izi. */
    fun fingerprint(): String {
        val cert = certificate() ?: return ""
        val digest = MessageDigest.getInstance("SHA-256").digest(cert.encoded)
        return digest.joinToString(":") { "%02X".format(it) }
    }

    fun sslContext(): SSLContext {
        ensureKey()
        val kmf = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm())
        kmf.init(keyStore(), null)
        return SSLContext.getInstance("TLSv1.3").apply {
            init(kmf.keyManagers, null, java.security.SecureRandom())
        }
    }

    // ---- Eslestirilmis istemciler

    fun tokenFor(client: String): String? = prefs.getString("token.$client", null)

    fun addClient(name: String): String {
        val token = UUID.randomUUID().toString().replace("-", "") +
                    UUID.randomUUID().toString().replace("-", "")
        prefs.edit().putString("token.$token", name).apply()
        return token
    }

    fun isKnown(token: String): Boolean = prefs.contains("token.$token")

    fun clientName(token: String): String? = prefs.getString("token.$token", null)

    fun forget(token: String) { prefs.edit().remove("token.$token").apply() }

    /// Tum eslesmeleri siler; anahtar ve kimlik KALIR (cihaz ayni cihaz).
    fun forgetAll() {
        val e = prefs.edit()
        prefs.all.keys.filter { it.startsWith("token.") }.forEach { e.remove(it) }
        e.apply()
    }

    fun pairedClients(): List<Pair<String, String>> =
        prefs.all.entries.filter { it.key.startsWith("token.") }
            .map { it.key.removePrefix("token.") to (it.value as? String ?: "?") }

    companion object {
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        // v2: eski anahtar kisitli ozetlerle uretilmisti.
        private const val ALIAS = "andros.tls.v2"
    }
}
