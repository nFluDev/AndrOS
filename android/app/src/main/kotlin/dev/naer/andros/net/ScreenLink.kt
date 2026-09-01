package dev.naer.andros.net

import android.content.Context
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.projection.MediaProjection
import android.util.DisplayMetrics
import android.util.Log
import android.view.Surface
import android.view.WindowManager
import dev.naer.andros.feature.InputService
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import javax.net.ssl.SSLServerSocket
import kotlin.concurrent.thread

/**
 * Ekran yansitma — adb OLMADAN.
 *
 * scrcpy'nin yaptigi isi iki desteklenen parcayla yapiyoruz:
 *  • GORUNTU: `MediaProjection` + sanal ekran + `MediaCodec` (H.264).
 *    Ayni izin ses yakalama icin de kullaniliyor, yani kullanici tek
 *    onay veriyor.
 *  • GIRDI: `InputService` (erisilebilirlik). scrcpy girdiyi
 *    `InputManager` ile enjekte ediyor ve oraya yalniz shell yetkisiyle
 *    (adb) erisiliyor; erisilebilirlik hizmeti normal bir uygulamanin
 *    kullanabilecegi TEK yol.
 *
 * Bu yolun bedeli acikca soylenmeli: donanim tuslari enjekte edilemiyor
 * ve bazi guvenli ekranlar (parola alanlari, banka uygulamalari)
 * hem yakalamayi hem girdiyi reddediyor. Bunlar Android'in kurallari.
 */
class ScreenLink(
    private val ctx: Context,
    private val identity: Identity,
) {
    @Volatile private var server: SSLServerSocket? = null
    @Volatile private var projection: MediaProjection? = null
    @Volatile private var display: VirtualDisplay? = null
    @Volatile private var encoder: MediaCodec? = null
    @Volatile private var surface: Surface? = null
    @Volatile private var out: DataOutputStream? = null
    @Volatile private var running = false

    private var width = 0
    private var height = 0
    /// En son ne zaman "erisilebilirlik kapali" dedik.
    private var lastNoInputAt = 0L

    fun start(): Int {
        stop()
        val ss = try {
            identity.sslContext().serverSocketFactory
                .createServerSocket(DEFAULT_PORT) as SSLServerSocket
        } catch (e: Exception) {
            Log.w(TAG, "ekran portu acilamadi: ${e.message}"); return 0
        }
        ss.enabledProtocols = arrayOf("TLSv1.3", "TLSv1.2")
        server = ss
        thread(isDaemon = true, name = "andros-screen-accept") {
            while (!ss.isClosed) {
                val s = try { ss.accept() } catch (e: Exception) { break }
                runCatching { s.tcpNoDelay = true; s.soTimeout = 15_000 }
                thread(isDaemon = true, name = "andros-screen") {
                    try { serve(s) }
                    catch (e: Throwable) { Log.d(TAG, "ekran baglantisi bitti: ${e.message}") }
                    finally { runCatching { s.close() }; stopCapture() }
                }
            }
        }
        Log.i(TAG, "ekran kanali dinliyor: ${ss.localPort}")
        return ss.localPort
    }

    fun stop() {
        runCatching { server?.close() }
        server = null
        stopCapture()
    }

    /** Ses tarafiyla AYNI izin: kullanici bir kez onayliyor. */
    fun setProjection(p: MediaProjection?) {
        projection = p
        // Android 14'ten beri sanal ekran acmadan ONCE geri arama
        // kaydedilmis olmali; kaydedilmezse `createVirtualDisplay`
        // `IllegalStateException` atiyor. Ayrica kullanici paylasimi
        // telefondan durdurunca haberimiz olsun.
        p?.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() {
                Log.i(TAG, "ekran paylasimi telefondan durduruldu")
                stopCapture()
            }
        }, android.os.Handler(android.os.Looper.getMainLooper()))
    }

    private fun serve(sock: java.net.Socket) {
        val input = DataInputStream(BufferedInputStream(sock.getInputStream()))
        val o = DataOutputStream(BufferedOutputStream(sock.getOutputStream(), 1 shl 16))
        sock.soTimeout = 0

        val kind = input.readByte().toInt()
        val len = input.readInt()
        if (kind != KIND_AUTH || len !in 1..4096) return
        val token = ByteArray(len).also { input.readFully(it) }.toString(Charsets.UTF_8)
        if (!identity.isKnown(token)) { Log.w(TAG, "ekran: yetkisiz istemci"); return }
        out = o
        Log.i(TAG, "ekran istemcisi baglandi")

        while (true) {
            val k = input.readByte().toInt()
            val n = input.readInt()
            val body = if (n > 0) ByteArray(n).also { input.readFully(it) } else ByteArray(0)
            when (k) {
                KIND_START -> startCapture()
                KIND_STOP  -> stopCapture()
                KIND_INPUT -> handleInput(String(body, Charsets.UTF_8))
            }
        }
    }

    // MARK: - Goruntu

    private fun startCapture() {
        if (running) return
        val proj = projection ?: run { sendError("noprojection"); return }
        if (!InputService.isEnabled) {
            // Goruntu calisir ama kontrol calismaz — kullaniciya SOYLE.
            sendError("noinput")
        }

        val wm = ctx.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val metrics = DisplayMetrics()
        @Suppress("DEPRECATION")
        wm.defaultDisplay.getRealMetrics(metrics)
        // 1080p'ye sigdir: daha buyugu bant genisligini bosa harciyor.
        val scale = minOf(1f, 1920f / maxOf(metrics.widthPixels, metrics.heightPixels))
        width = (metrics.widthPixels * scale).toInt() / 2 * 2
        height = (metrics.heightPixels * scale).toInt() / 2 * 2

        val fmt = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT,
                       MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, 8_000_000)
            setInteger(MediaFormat.KEY_FRAME_RATE, 60)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
        }
        val enc = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        enc.configure(fmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        val surf = enc.createInputSurface()
        enc.start()
        encoder = enc
        surface = surf
        running = true

        display = proj.createVirtualDisplay(
            "AndrOS", width, height, metrics.densityDpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, surf, null, null)

        sendMeta()
        thread(isDaemon = true, name = "andros-screen-drain") { drain(enc) }
        Log.i(TAG, "ekran yakalaniyor: ${width}x$height")
    }

    private fun stopCapture() {
        running = false
        runCatching { display?.release() }; display = null
        runCatching { encoder?.stop(); encoder?.release() }; encoder = null
        runCatching { surface?.release() }; surface = null
    }

    private fun drain(enc: MediaCodec) {
        val info = MediaCodec.BufferInfo()
        try {
            while (running) {
                val i = enc.dequeueOutputBuffer(info, 100_000)
                if (i < 0) continue
                val buf = enc.getOutputBuffer(i)
                if (buf != null && info.size > 0) {
                    buf.position(info.offset)
                    buf.limit(info.offset + info.size)
                    val b = ByteArray(info.size)
                    buf.get(b)
                    val o = out
                    if (o != null) synchronized(o) {
                        o.writeByte(KIND_FRAME); o.writeInt(b.size); o.write(b); o.flush()
                    }
                }
                enc.releaseOutputBuffer(i, false)
            }
        } catch (e: Throwable) { Log.d(TAG, "kodlayici bitti: ${e.message}") }
    }

    // MARK: - Girdi

    /**
     * Mac'ten gelen girdi. Koordinatlar 0..1 arasinda ORANLI geliyor:
     * Mac penceresi olceklenebiliyor ve piksel gondermek yanlis yere
     * dokunmaya yol aciyordu.
     */
    private fun handleInput(json: String) {
        val svc = InputService.instance
        if (svc == null) {
            // Erisilebilirlik acilmamis. Mac'e SOYLE — sessizce yutmak
            // "yansitma bozuk" izlenimi veriyordu. Her dokunusta degil,
            // saniyede bir: kullanici ekrani ovusturunca sel olurdu.
            val now = System.currentTimeMillis()
            if (now - lastNoInputAt > 1000) { lastNoInputAt = now; sendError("noinput") }
            return
        }
        // Hizmet SONRADAN acilmis olabilir: Mac'teki uyariyi kaldir.
        if (lastNoInputAt != 0L) { lastNoInputAt = 0L; sendMeta() }
        val o = runCatching { JSONObject(json) }.getOrNull() ?: return
        fun px(key: String) = (o.optDouble(key, 0.0) * width).toFloat()
        fun py(key: String) = (o.optDouble(key, 0.0) * height).toFloat()
        when (o.optString("t")) {
            "tap"   -> svc.tap(px("x"), py("y"))
            "long"  -> svc.longPress(px("x"), py("y"))
            "swipe" -> {
                val pts = o.optJSONArray("p") ?: return
                val list = ArrayList<Pair<Float, Float>>(pts.length())
                for (i in 0 until pts.length()) {
                    val q = pts.optJSONObject(i) ?: continue
                    list.add((q.optDouble("x") * width).toFloat() to
                             (q.optDouble("y") * height).toFloat())
                }
                svc.swipe(list, o.optLong("ms", 120))
            }
            "back"    -> svc.back()
            "home"    -> svc.home()
            "recents" -> svc.recents()
            "text"    -> svc.type(o.optString("s"))
            "backspace" -> svc.backspace()
        }
    }

    private fun sendMeta() {
        val o = out ?: return
        val j = JSONObject().put("width", width).put("height", height)
            .put("input", InputService.isEnabled)
            .toString().toByteArray(Charsets.UTF_8)
        synchronized(o) { o.writeByte(KIND_META); o.writeInt(j.size); o.write(j); o.flush() }
    }

    private fun sendError(code: String) {
        val o = out ?: return
        val j = JSONObject().put("error", code).toString().toByteArray(Charsets.UTF_8)
        runCatching {
            synchronized(o) { o.writeByte(KIND_META); o.writeInt(j.size); o.write(j); o.flush() }
        }
    }

    companion object {
        private const val TAG = "AndrOS.Screen"
        const val DEFAULT_PORT = 47826

        const val KIND_AUTH  = 0
        const val KIND_START = 1
        const val KIND_STOP  = 2
        const val KIND_INPUT = 3
        const val KIND_FRAME = 4
        const val KIND_META  = 5
    }
}
