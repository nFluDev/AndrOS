package dev.naer.andros.net

import android.util.Log
import java.io.File
import java.io.OutputStream
import java.net.ServerSocket
import java.net.URLDecoder
import java.util.UUID
import kotlin.concurrent.thread

/**
 * Kucuk HTTP sunucusu — video/ses AKISI icin.
 *
 * Neden gerekli: dosyayi bastan sona indirip oynatmak buyuk videoda
 * dakikalar suruyordu; kullanici cift tikliyor, hicbir sey olmuyor
 * saniyor, sonra baska yere gezerken oynatici birden aciliyordu.
 * `AVPlayer` HTTP kaynagindan AKITARAK oynatabiliyor — YouTube gibi,
 * ilk saniyeler gelir gelmez baslar.
 *
 * **Byte-range** destegi sart: oynaticinin ileri sarmasi buna dayaniyor.
 *
 * Guvenlik: yollar TEK KULLANIMLIK bir belirtecin arkasinda. Belirteci
 * bilmeyen (ayni agdaki baska biri dahil) hicbir dosyaya erisemiyor;
 * ayrica yalniz paylasilan depolamadaki dosyalar servis ediliyor.
 */
class MediaServer {

    private var socket: ServerSocket? = null
    private val tokens = java.util.concurrent.ConcurrentHashMap<String, String>()

    val port: Int get() = socket?.localPort ?: 0

    fun start(): Int {
        stop()
        val ss = try { ServerSocket(DEFAULT_PORT) } catch (e: Exception) { ServerSocket(0) }
        socket = ss
        thread(isDaemon = true, name = "andros-media") {
            while (!ss.isClosed) {
                val c = try { ss.accept() } catch (e: Exception) { break }
                // Video akisi: gecikme degil BASARIM onemli. Buyuk
                // bloklar halinde akiyor; isaret yonlendiricinin
                // kuyruklamasina yardim ediyor.
                runCatching { c.trafficClass = 0x08 }   // IPTOS_THROUGHPUT
                // TEK BIR ISTEK UYGULAMAYI OLDURMESIN. Android'in
                // varsayilan isleyicisi yakalanmamis istisnada tum sureci
                // kapatiyor; video oynatici baglantiyi ortada kestiginde
                // ("broken pipe") uygulama duserdi.
                thread(isDaemon = true) {
                    try { serve(c) }
                    catch (e: Throwable) {
                        Log.d(TAG, "istek yarida kesildi: ${e.message}")
                        try { c.close() } catch (_: Exception) {}
                    }
                }
            }
        }
        Log.i(TAG, "medya sunucusu: ${ss.localPort}")
        return ss.localPort
    }

    fun stop() {
        try { socket?.close() } catch (_: Exception) {}
        socket = null
        tokens.clear()
    }

    /** Bir dosya icin tek kullanimlik yol uretir. */
    fun publish(path: String): String {
        val token = UUID.randomUUID().toString().replace("-", "")
        tokens[token] = path
        return "/f/$token"
    }

    private fun serve(c: java.net.Socket) {
        c.use { sock ->
            val input = sock.getInputStream().bufferedReader()
            val request = input.readLine() ?: return
            var line = input.readLine()
            var rangeStart = 0L
            var rangeEnd = -1L
            while (!line.isNullOrEmpty()) {
                if (line.startsWith("Range:", true)) {
                    // "Range: bytes=1234-" ya da "bytes=100-200"
                    val v = line.substringAfter("=").trim()
                    rangeStart = v.substringBefore("-").toLongOrNull() ?: 0
                    rangeEnd = v.substringAfter("-").toLongOrNull() ?: -1
                }
                line = input.readLine()
            }
            val out = sock.getOutputStream()
            val parts = request.split(" ")
            if (parts.size < 2) { fail(out, 400, "Bad Request"); return }
            val token = URLDecoder.decode(parts[1], "UTF-8").removePrefix("/f/")
            val path = tokens[token]
            if (path == null) { fail(out, 404, "Not Found"); return }
            val f = File(path)
            if (!f.isFile) { fail(out, 404, "Not Found"); return }

            val total = f.length()
            val end = if (rangeEnd in 0 until total) rangeEnd else total - 1
            val start = rangeStart.coerceIn(0, end)
            val length = end - start + 1
            val partial = rangeStart > 0 || rangeEnd >= 0

            val head = buildString {
                append(if (partial) "HTTP/1.1 206 Partial Content\r\n"
                       else "HTTP/1.1 200 OK\r\n")
                append("Content-Type: ${mime(f.name)}\r\n")
                append("Content-Length: $length\r\n")
                append("Accept-Ranges: bytes\r\n")
                if (partial) append("Content-Range: bytes $start-$end/$total\r\n")
                append("Connection: close\r\n\r\n")
            }
            out.write(head.toByteArray())

            f.inputStream().use { fis ->
                fis.skip(start)
                val buf = ByteArray(64 * 1024)
                var left = length
                while (left > 0) {
                    val n = fis.read(buf, 0, minOf(buf.size.toLong(), left).toInt())
                    if (n <= 0) break
                    out.write(buf, 0, n)
                    left -= n
                }
            }
            out.flush()
        }
    }

    private fun fail(out: OutputStream, code: Int, text: String) {
        out.write("HTTP/1.1 $code $text\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                      .toByteArray())
        out.flush()
    }

    private fun mime(name: String): String = when (name.substringAfterLast('.').lowercase()) {
        "mp4", "m4v" -> "video/mp4"
        "mkv"        -> "video/x-matroska"
        "webm"       -> "video/webm"
        "3gp"        -> "video/3gpp"
        "mp3"        -> "audio/mpeg"
        "m4a", "aac" -> "audio/mp4"
        "flac"       -> "audio/flac"
        "wav"        -> "audio/wav"
        "jpg", "jpeg" -> "image/jpeg"
        "png"        -> "image/png"
        else         -> "application/octet-stream"
    }

    companion object {
        private const val TAG = "AndrOS.Media"
        const val DEFAULT_PORT = 47822
    }
}
