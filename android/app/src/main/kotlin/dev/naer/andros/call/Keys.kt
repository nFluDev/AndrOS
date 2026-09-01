package dev.naer.andros.call

import android.content.Context
import org.bouncycastle.crypto.agreement.X25519Agreement
import org.bouncycastle.crypto.digests.SHA256Digest
import org.bouncycastle.crypto.generators.HKDFBytesGenerator
import org.bouncycastle.crypto.params.Ed25519PrivateKeyParameters
import org.bouncycastle.crypto.params.Ed25519PublicKeyParameters
import org.bouncycastle.crypto.params.HKDFParameters
import org.bouncycastle.crypto.params.X25519PrivateKeyParameters
import org.bouncycastle.crypto.params.X25519PublicKeyParameters
import org.bouncycastle.crypto.signers.Ed25519Signer
import java.security.MessageDigest
import java.security.SecureRandom

/**
 * AndrOS aginin kimlik anahtarlari.
 *
 * IKI ANAHTAR var ve ayri durmalari bilincli:
 *  • Ed25519 — KIMLIK. Adres bunun ozetinden turetiliyor ve sunucuya
 *    "bu benim" demek icin imza atiliyor.
 *  • X25519  — SIFRELEME. Karsi tarafla ortak sir bundan cikiyor.
 * Tek anahtari iki ise kosmak (Ed25519'u X25519'a cevirmek) mumkun ama
 * imza ve anlasma ayni anahtari paylasinca birinin zayifligi otekini de
 * vuruyor.
 *
 * Anahtarlar Android Keystore'da DEGIL: Keystore X25519 anlasmasini
 * cihazlarin cogunda desteklemiyor ve ozel anahtari disari vermiyor —
 * yani ortak sirri hesaplayamiyorduk. Bunun yerine uygulamanin ozel
 * ayarlarinda duruyorlar; oraya baska uygulama erisemiyor (root haric).
 */
class Keys(ctx: Context) {

    private val prefs = ctx.getSharedPreferences("andros.call", Context.MODE_PRIVATE)

    val edPrivate: Ed25519PrivateKeyParameters
    val edPublic: Ed25519PublicKeyParameters
    val xPrivate: X25519PrivateKeyParameters
    val xPublic: X25519PublicKeyParameters

    init {
        val rnd = SecureRandom()
        val edSeed = load("ed", 32) { ByteArray(32).also(rnd::nextBytes) }
        val xSeed = load("x", 32) { ByteArray(32).also(rnd::nextBytes) }
        edPrivate = Ed25519PrivateKeyParameters(edSeed, 0)
        edPublic = edPrivate.generatePublicKey()
        xPrivate = X25519PrivateKeyParameters(xSeed, 0)
        xPublic = xPrivate.generatePublicKey()
    }

    private fun load(name: String, size: Int, make: () -> ByteArray): ByteArray {
        prefs.getString(name, null)?.let { s ->
            val b = android.util.Base64.decode(s, android.util.Base64.NO_WRAP)
            if (b.size == size) return b
        }
        val fresh = make()
        prefs.edit().putString(name,
            android.util.Base64.encodeToString(fresh, android.util.Base64.NO_WRAP)).apply()
        return fresh
    }

    /** Bu cihazin AndrOS kimligi. */
    val id: String get() = idFor(edPublic.encoded)

    /** Meydan okumayi imzalar — sunucuya kimligi kanitlamak icin. */
    fun sign(data: ByteArray): ByteArray {
        val s = Ed25519Signer()
        s.init(true, edPrivate)
        s.update(data, 0, data.size)
        return s.generateSignature()
    }

    companion object {
        /// Crockford base32: sesli okunurken karistirilan harfler
        /// (I, L, O, U) alfabede yok. Sunucudaki turetmenin AYNISI.
        private const val ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

        fun idFor(edPublic: ByteArray): String {
            val h = MessageDigest.getInstance("SHA-256").digest(edPublic).copyOf(10)
            var bits = 0
            var value = 0
            val out = StringBuilder()
            for (b in h) {
                value = (value shl 8) or (b.toInt() and 0xFF)
                bits += 8
                while (bits >= 5) { out.append(ALPHABET[(value ushr (bits - 5)) and 31]); bits -= 5 }
            }
            return out.toString()
        }

        fun verify(edPublic: ByteArray, data: ByteArray, sig: ByteArray): Boolean = try {
            val v = Ed25519Signer()
            v.init(false, Ed25519PublicKeyParameters(edPublic, 0))
            v.update(data, 0, data.size)
            v.verifySignature(sig)
        } catch (e: Throwable) { false }

        /**
         * Iki cihaz arasindaki ortak anahtar.
         *
         * Tuz olarak IKI KIMLIK SIRALI birlestiriliyor: iki taraf ayni
         * anahtari bagimsizca hesaplasin diye. Siralamasak her yon
         * baska anahtar uretirdi.
         */
        fun sharedKey(mine: X25519PrivateKeyParameters, theirs: X25519PublicKeyParameters,
                      idA: String, idB: String): ByteArray {
            val secret = ByteArray(32)
            X25519Agreement().apply { init(mine) }.calculateAgreement(theirs, secret, 0)
            val salt = (if (idA < idB) idA + idB else idB + idA).toByteArray()
            val out = ByteArray(32)
            HKDFBytesGenerator(SHA256Digest()).apply {
                init(HKDFParameters(secret, salt, "andros-e2e-v1".toByteArray()))
            }.generateBytes(out, 0, out.size)
            return out
        }
    }
}
