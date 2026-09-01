package dev.naer.andros.call

import org.bouncycastle.crypto.modes.ChaCha20Poly1305
import org.bouncycastle.crypto.params.AEADParameters
import org.bouncycastle.crypto.params.KeyParameter
import org.bouncycastle.crypto.params.X25519PublicKeyParameters
import org.json.JSONObject
import java.security.SecureRandom

/**
 * Uctan uca sifreli zarf.
 *
 * Sunucu bunu ACAMIYOR — yalnizca kime iletecegini biliyor. Iki tur var:
 *
 *  • TANISMA (acik): karsi taraf henuz benim sifreleme anahtarimi
 *    bilmiyor. Ed25519 acik anahtarimi, X25519 acik anahtarimi ve
 *    ikincisinin IMZASINI yolluyorum. Karsi taraf `hash(ed) == gonderen
 *    kimlik` esitligini dogruluyor; yani sunucu araya baska bir anahtar
 *    sokamiyor — sokarsa kimlik tutmuyor.
 *  • MUHURLU: ortak anahtarla ChaCha20-Poly1305. Nonce rastgele 12 bayt;
 *    sayac tutmuyoruz cunku iki taraf da bagimsiz yaziyor ve sayaci
 *    esitlemek tek basina bir sorun kaynagi olurdu. Bu hacimde rastgele
 *    nonce'un carpismasi pratikte imkansiz.
 *
 * Not: sunucunun `numara -> kimlik` eslemesine guvenmek zorundayiz.
 * Yalan soylerse araya girebilir. Bunun karsiligi kullanicinin
 * kimlikleri karsilastirmasi — kimlik ekranda gosteriliyor.
 */
object Envelope {

    const val TYPE_INTRO = 0
    const val TYPE_SEALED = 1
    private const val VERSION = 1
    private val rnd = SecureRandom()

    fun intro(keys: Keys): ByteArray {
        val xPub = keys.xPublic.encoded
        val sig = keys.sign("andros-intro".toByteArray() + xPub)
        return byteArrayOf(VERSION.toByte(), TYPE_INTRO.toByte()) +
               keys.edPublic.encoded + xPub + sig
    }

    /** Tanisma paketini acar; gonderen kimligiyle TUTMUYORSA reddeder. */
    fun openIntro(raw: ByteArray, fromId: String): Peer? {
        if (raw.size != 2 + 32 + 32 + 64) return null
        if (raw[1].toInt() != TYPE_INTRO) return null
        val ed = raw.copyOfRange(2, 34)
        val x = raw.copyOfRange(34, 66)
        val sig = raw.copyOfRange(66, 130)
        if (Keys.idFor(ed) != fromId) return null
        if (!Keys.verify(ed, "andros-intro".toByteArray() + x, sig)) return null
        return Peer(fromId, ed, X25519PublicKeyParameters(x, 0))
    }

    fun seal(key: ByteArray, payload: JSONObject): ByteArray {
        val nonce = ByteArray(12).also(rnd::nextBytes)
        val plain = payload.toString().toByteArray()
        val c = ChaCha20Poly1305()
        c.init(true, AEADParameters(KeyParameter(key), 128, nonce))
        val out = ByteArray(c.getOutputSize(plain.size))
        val n = c.processBytes(plain, 0, plain.size, out, 0)
        c.doFinal(out, n)
        return byteArrayOf(VERSION.toByte(), TYPE_SEALED.toByte()) + nonce + out
    }

    fun open(key: ByteArray, raw: ByteArray): JSONObject? = try {
        if (raw.size < 2 + 12 + 16 || raw[1].toInt() != TYPE_SEALED) null
        else {
            val nonce = raw.copyOfRange(2, 14)
            val body = raw.copyOfRange(14, raw.size)
            val c = ChaCha20Poly1305()
            c.init(false, AEADParameters(KeyParameter(key), 128, nonce))
            val out = ByteArray(c.getOutputSize(body.size))
            val n = c.processBytes(body, 0, body.size, out, 0)
            val total = n + c.doFinal(out, n)
            JSONObject(String(out, 0, total, Charsets.UTF_8))
        }
    } catch (e: Throwable) { null }

    fun typeOf(raw: ByteArray): Int = if (raw.size > 1) raw[1].toInt() else -1

    data class Peer(val id: String, val edPublic: ByteArray,
                    val xPublic: X25519PublicKeyParameters)
}
