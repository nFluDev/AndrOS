package dev.naer.andros.net

import android.util.Log
import org.json.JSONObject
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import kotlin.concurrent.thread

/**
 * mDNS'siz bulma ve yerel UYANDIRMA.
 *
 * Neden gerekli: Bonjour/mDNS multicast'e dayaniyor ve Wi-Fi yongasi
 * guc tasarrufunda multicast'i suzuyor; olculdu — telefonun TLS portu
 * acikken Mac hicbir duyuru goremedi. Ayrica bazi yonlendiriciler
 * istemci yalitimi (client isolation) ya da IGMP snooping yuzunden
 * multicast'i hic gecirmiyor.
 *
 * Burasi TEK YONLU ve cok kucuk: Mac yayin adresine "ANDROS?" yolluyor,
 * telefon kendini tanitan bir JSON ile cevap veriyor. Paket UDP oldugu
 * icin cihazi Doze'dan da cikariyor (yayin paketi islemciyi kisa sure
 * uyandirir) — kullanicinin istedigi "Wake-on-LAN benzeri" davranis.
 *
 * Sir icermiyor: yalniz model adi, cihaz kimligi, port ve sertifika
 * parmak izi. Eslestirme yine TLS uzerinde belirtec/QR ile yapiliyor.
 */
class UdpBeacon(
    private val info: () -> JSONObject,
) {
    @Volatile private var socket: DatagramSocket? = null

    fun start() {
        stop()
        val s = try {
            DatagramSocket(null).apply {
                reuseAddress = true
                broadcast = true
                bind(java.net.InetSocketAddress(PORT))
            }
        } catch (e: Exception) {
            Log.w(TAG, "UDP dinleyici acilamadi: ${e.message}"); return
        }
        socket = s
        thread(isDaemon = true, name = "andros-beacon") {
            val buf = ByteArray(256)
            while (!s.isClosed) {
                try {
                    val p = DatagramPacket(buf, buf.size)
                    s.receive(p)
                    val msg = String(p.data, 0, p.length, Charsets.UTF_8).trim()
                    if (msg != PROBE) continue
                    val body = info().toString().toByteArray(Charsets.UTF_8)
                    s.send(DatagramPacket(body, body.size, p.address, p.port))
                } catch (e: Throwable) {
                    if (s.isClosed) break
                    Log.d(TAG, "yoklama hatasi: ${e.message}")
                }
            }
        }
        Log.i(TAG, "UDP bulucu dinliyor: $PORT")
    }

    fun stop() {
        runCatching { socket?.close() }
        socket = null
    }

    companion object {
        private const val TAG = "AndrOS.Beacon"
        const val PORT = 47823
        const val PROBE = "ANDROS?"
    }
}
