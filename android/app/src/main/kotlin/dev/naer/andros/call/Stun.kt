package dev.naer.andros.call

import android.util.Log
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.security.SecureRandom

/**
 * Kendi dis adresini ogrenmek (RFC 5389 Binding).
 *
 * NAT arkasindaki iki cihaz birbirine dogrudan paket yollayacaksa once
 * KENDI disaridan gorunen adreslerini bilmeleri gerekiyor. Bunu ancak
 * disaridaki biri soyleyebilir.
 *
 * AYNI SOKET SART. NAT esleme soket basina aciliyor: yoklamayi bir
 * soketle yapip sesi baskasindan yollamak, ogrenilen adresi gecersiz
 * kilar. Bu yuzden soket disaridan veriliyor.
 */
object Stun {

    private const val TAG = "AndrOS.Stun"
    private const val MAGIC = 0x2112A442.toInt()

    /// Sunucunun adresi. Alan adi Cloudflare gibi bir VEKILDEN
    /// gecmemeli: vekiller yalniz HTTP tasiyor, UDP tasimiyor ve paket
    /// hic sunucuya varmiyor.
    const val DEFAULT_HOST = "stun.gamehost.dev"
    const val DEFAULT_PORT = 3478

    data class Mapped(val host: String, val port: Int)

    /**
     * Dis adresi sorar. UDP paketi kaybolabildigi icin uc kez
     * deneniyor — tek denemede vazgecmek, calisan bir sunucuda
     * "arama kurulamadi" demek olurdu.
     */
    fun discover(socket: DatagramSocket, host: String = DEFAULT_HOST,
                 port: Int = DEFAULT_PORT, timeoutMs: Int = 2000,
                 attempts: Int = 3): Mapped? {
        repeat(attempts) { i ->
            probe(socket, host, port, timeoutMs)?.let {
                if (i > 0) Log.i(TAG, "${i + 1}. denemede yanit geldi")
                return it
            }
        }
        return null
    }

    private fun probe(socket: DatagramSocket, host: String, port: Int,
                      timeoutMs: Int): Mapped? = try {
        val txn = ByteArray(12).also { SecureRandom().nextBytes(it) }
        val req = ByteArray(20)
        req[0] = 0x00; req[1] = 0x01                    // Binding istegi
        req[4] = 0x21; req[5] = 0x12; req[6] = 0xA4.toByte(); req[7] = 0x42
        System.arraycopy(txn, 0, req, 8, 12)

        val addr = InetAddress.getByName(host)
        socket.send(DatagramPacket(req, req.size, addr, port))
        socket.soTimeout = timeoutMs

        val buf = ByteArray(512)
        val res = DatagramPacket(buf, buf.size)
        socket.receive(res)
        parse(buf, res.length, txn)
    } catch (e: Throwable) {
        Log.d(TAG, "yanit yok: ${e.javaClass.simpleName}")
        null
    }

    private fun parse(buf: ByteArray, n: Int, txn: ByteArray): Mapped? {
        if (n < 20) return null
        if (buf[0].toInt() != 0x01 || buf[1].toInt() != 0x01) return null
        for (i in 0 until 12) if (buf[8 + i] != txn[i]) return null

        var i = 20
        while (i + 4 <= n) {
            val type = ((buf[i].toInt() and 0xFF) shl 8) or (buf[i + 1].toInt() and 0xFF)
            val len = ((buf[i + 2].toInt() and 0xFF) shl 8) or (buf[i + 3].toInt() and 0xFF)
            val v = i + 4
            if (v + len > n) break
            // XOR-MAPPED-ADDRESS, IPv4
            if (type == 0x0020 && len >= 8 && buf[v + 1].toInt() == 0x01) {
                val port = (((buf[v + 2].toInt() and 0xFF) shl 8) or
                            (buf[v + 3].toInt() and 0xFF)) xor (MAGIC ushr 16)
                val ip = (0 until 4).joinToString(".") { k ->
                    ((buf[v + 4 + k].toInt() and 0xFF) xor
                     ((MAGIC ushr (24 - 8 * k)) and 0xFF)).toString()
                }
                return Mapped(ip, port)
            }
            i = v + len + ((4 - len % 4) % 4)          // 4 bayta hizali
        }
        return null
    }

    /// Cagri icin kullanilacak soket. Ayni soket hem yoklamada hem
    /// medyada kullanilmali.
    fun makeSocket(): DatagramSocket = DatagramSocket()
}
