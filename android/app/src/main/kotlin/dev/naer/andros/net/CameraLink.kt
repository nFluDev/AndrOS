package dev.naer.andros.net

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.ImageFormat
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.util.Size
import android.view.Surface
import androidx.core.content.ContextCompat
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import javax.net.ssl.SSLServerSocket
import kotlin.concurrent.thread

/**
 * Telefonun kamerasini Mac'e akitir.
 *
 * Ham kare gondermek mumkun degil: 1080p30 YUV ~750 Mbps eder. Bu
 * yuzden donanim kodlayicisiyla (MediaCodec) H.264'e cevirip
 * gonderiyoruz — Mac tarafinda zaten yansitma icin yazilmis
 * `VideoDecoder` (VideoToolbox) ayni akisi cozuyor.
 *
 * ONDEN/ARKADAN: `camera` alanini degistirmek oturumu yeniden kuruyor;
 * kodlayici ayakta kaldigi icin gecis yarim saniyeden kisa suruyor.
 *
 * AYRI SOKET (47825): goruntu buyuk ve surekli; denetim kanalinin
 * arkasinda beklerse hem kendi takiliyor hem otekini bekletiyor.
 */
class CameraLink(
    private val ctx: Context,
    private val identity: Identity,
) {
    @Volatile private var server: SSLServerSocket? = null
    @Volatile private var device: CameraDevice? = null
    @Volatile private var session: CameraCaptureSession? = null
    @Volatile private var encoder: MediaCodec? = null
    @Volatile private var inputSurface: Surface? = null
    @Volatile private var out: DataOutputStream? = null
    @Volatile private var running = false
    private var thread: HandlerThread? = null
    private var handler: Handler? = null

    /// "0" arka, "1" on — CameraManager'in kendi kimlikleri degil,
    /// bizim sabit yonlerimiz.
    @Volatile var facing = FACING_BACK
        private set

    fun start(): Int {
        stop()
        val ss = try {
            identity.sslContext().serverSocketFactory
                .createServerSocket(DEFAULT_PORT) as SSLServerSocket
        } catch (e: Exception) {
            Log.w(TAG, "kamera portu acilamadi: ${e.message}"); return 0
        }
        ss.enabledProtocols = arrayOf("TLSv1.3", "TLSv1.2")
        server = ss
        thread(isDaemon = true, name = "andros-cam-accept") {
            while (!ss.isClosed) {
                val s = try { ss.accept() } catch (e: Exception) { break }
                runCatching { s.tcpNoDelay = true; s.soTimeout = 15_000 }
                thread(isDaemon = true, name = "andros-cam") {
                    try { serve(s) }
                    catch (e: Throwable) { Log.d(TAG, "kamera baglantisi bitti: ${e.message}") }
                    finally { runCatching { s.close() }; stopCapture() }
                }
            }
        }
        Log.i(TAG, "kamera kanali dinliyor: ${ss.localPort}")
        return ss.localPort
    }

    fun stop() {
        runCatching { server?.close() }
        server = null
        stopCapture()
    }

    private fun serve(sock: java.net.Socket) {
        val input = DataInputStream(BufferedInputStream(sock.getInputStream()))
        val o = DataOutputStream(BufferedOutputStream(sock.getOutputStream(), 1 shl 16))
        sock.soTimeout = 0

        val kind = input.readByte().toInt()
        val len = input.readInt()
        if (kind != KIND_AUTH || len !in 1..4096) return
        val token = ByteArray(len).also { input.readFully(it) }.toString(Charsets.UTF_8)
        if (!identity.isKnown(token)) { Log.w(TAG, "kamera: yetkisiz istemci"); return }
        out = o
        Log.i(TAG, "kamera istemcisi baglandi")

        while (true) {
            val k = input.readByte().toInt()
            val n = input.readInt()
            val body = if (n > 0) ByteArray(n).also { input.readFully(it) } else ByteArray(0)
            when (k) {
                KIND_START -> {
                    val want = if (body.isNotEmpty()) body[0].toInt() else FACING_BACK
                    startCapture(want)
                }
                KIND_STOP   -> stopCapture()
                KIND_SWITCH -> {
                    val want = if (facing == FACING_BACK) FACING_FRONT else FACING_BACK
                    switchTo(want)
                }
            }
        }
    }

    // ---- Yakalama

    private fun startCapture(want: Int) {
        if (running) return
        if (ContextCompat.checkSelfPermission(ctx, Manifest.permission.CAMERA)
            != PackageManager.PERMISSION_GRANTED) {
            Log.w(TAG, "kamera izni yok"); sendError("permission"); return
        }
        val mgr = ctx.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val id = pickCamera(mgr, want) ?: run { Log.w(TAG, "kamera bulunamadi"); return }
        facing = want

        val t = HandlerThread("andros-cam-worker").also { it.start() }
        thread = t
        handler = Handler(t.looper)

        val size = pickSize(mgr, id)
        val fmt = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC,
                                                size.width, size.height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT,
                       MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, 6_000_000)
            setInteger(MediaFormat.KEY_FRAME_RATE, 30)
            // Sik anahtar kare: Mac gec baglansa da goruntu hemen otursun.
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
        }
        val enc = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        enc.configure(fmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        val surface = enc.createInputSurface()
        enc.start()
        encoder = enc
        inputSurface = surface
        running = true

        thread(isDaemon = true, name = "andros-cam-drain") { drain(enc) }

        try {
            mgr.openCamera(id, object : CameraDevice.StateCallback() {
                override fun onOpened(cam: CameraDevice) {
                    device = cam
                    val req = cam.createCaptureRequest(CameraDevice.TEMPLATE_RECORD)
                    req.addTarget(surface)
                    req.set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE,
                            android.util.Range(24, 30))
                    @Suppress("DEPRECATION")
                    cam.createCaptureSession(listOf(surface),
                        object : CameraCaptureSession.StateCallback() {
                            override fun onConfigured(s: CameraCaptureSession) {
                                session = s
                                runCatching { s.setRepeatingRequest(req.build(), null, handler) }
                                Log.i(TAG, "kamera acildi: $id ${size.width}x${size.height}")
                                sendMeta(size.width, size.height)
                            }
                            override fun onConfigureFailed(s: CameraCaptureSession) {
                                Log.w(TAG, "kamera oturumu kurulamadi")
                            }
                        }, handler)
                }
                override fun onDisconnected(cam: CameraDevice) { cam.close(); device = null }
                override fun onClosed(cam: CameraDevice) { closing = false }
                override fun onError(cam: CameraDevice, err: Int) {
                    Log.w(TAG, "kamera hatasi: $err"); cam.close(); device = null
                    // 1 = baska uygulama kullaniyor, 3 = politika ile kapali
                    // (hizmet arka plandan baslatilmis: kamera yetkisi yok).
                    sendError(when (err) {
                        ERROR_CAMERA_IN_USE -> "inuse"
                        ERROR_CAMERA_DISABLED -> "policy"
                        else -> "error$err"
                    })
                    stopCapture()
                }
            }, handler)
        } catch (e: SecurityException) {
            Log.w(TAG, "kamera acilamadi: ${e.message}")
            stopCapture()
        }
    }

    /// On/arka gecisi.
    ///
    /// `CameraDevice.close()` ES ZAMANLI DEGIL: kapanma bitmeden yeni
    /// kamerayi acmaya calisinca sistem `ERROR_MAX_CAMERAS_IN_USE` (2)
    /// donuyordu — kullanicinin gordugu "error2" buydu. Kapanmayi
    /// BEKLIYORUZ, sonra aciyoruz.
    private fun switchTo(want: Int) {
        val cam = device
        closing = true
        stopCapture()
        // `onClosed` gelene kadar bekle; gelmezse kisa bir pay birak.
        val deadline = System.currentTimeMillis() + 1500
        while (closing && System.currentTimeMillis() < deadline) {
            try { Thread.sleep(30) } catch (_: InterruptedException) { break }
        }
        closing = false
        startCapture(want)
        if (cam != null) Log.i(TAG, "kamera degistirildi -> $want")
    }

    @Volatile private var closing = false

    private fun stopCapture() {
        running = false
        runCatching { session?.stopRepeating() }
        runCatching { session?.close() }; session = null
        runCatching { device?.close() }; device = null
        runCatching { encoder?.stop(); encoder?.release() }; encoder = null
        runCatching { inputSurface?.release() }; inputSurface = null
        thread?.quitSafely(); thread = null; handler = null
    }

    /// Kodlayicidan cikan H.264 birimlerini sokete akitir.
    private fun drain(enc: MediaCodec) {
        val info = MediaCodec.BufferInfo()
        try {
            while (running) {
                val i = enc.dequeueOutputBuffer(info, 100_000)
                if (i < 0) continue
                val buf = enc.getOutputBuffer(i) ?: continue
                if (info.size > 0) {
                    buf.position(info.offset)
                    buf.limit(info.offset + info.size)
                    val b = ByteArray(info.size)
                    buf.get(b)
                    val o = out
                    if (o != null) synchronized(o) {
                        o.writeByte(KIND_FRAME)
                        o.writeInt(b.size)
                        o.write(b)
                        o.flush()
                    }
                }
                enc.releaseOutputBuffer(i, false)
            }
        } catch (e: Throwable) {
            Log.d(TAG, "kodlayici bitti: ${e.message}")
        }
    }

    private fun sendError(code: String) {
        val o = out ?: return
        val json = org.json.JSONObject().put("error", code)
            .toString().toByteArray(Charsets.UTF_8)
        runCatching {
            synchronized(o) { o.writeByte(KIND_META); o.writeInt(json.size); o.write(json); o.flush() }
        }
    }

    private fun sendMeta(w: Int, h: Int) {
        val o = out ?: return
        val json = org.json.JSONObject()
            .put("width", w).put("height", h).put("facing", facing)
            .toString().toByteArray(Charsets.UTF_8)
        synchronized(o) {
            o.writeByte(KIND_META); o.writeInt(json.size); o.write(json); o.flush()
        }
    }

    private fun pickCamera(mgr: CameraManager, want: Int): String? {
        val target = if (want == FACING_FRONT) CameraCharacteristics.LENS_FACING_FRONT
                     else CameraCharacteristics.LENS_FACING_BACK
        var fallback: String? = null
        for (id in mgr.cameraIdList) {
            val c = mgr.getCameraCharacteristics(id)
            if (fallback == null) fallback = id
            if (c.get(CameraCharacteristics.LENS_FACING) == target) return id
        }
        return fallback
    }

    /// 720p'ye en yakin desteklenen boyut: 1080p bant genisligini
    /// gereksiz sisiriyor, gorunt kalitesi farki webcam icin onemsiz.
    private fun pickSize(mgr: CameraManager, id: String): Size {
        val map = mgr.getCameraCharacteristics(id)
            .get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            ?: return Size(1280, 720)
        val sizes = map.getOutputSizes(ImageFormat.PRIVATE) ?: return Size(1280, 720)
        return sizes.filter { it.width <= 1280 && it.height <= 720 }
            .maxByOrNull { it.width.toLong() * it.height } ?: Size(1280, 720)
    }

    companion object {
        private const val TAG = "AndrOS.Camera"
        const val DEFAULT_PORT = 47825
        const val FACING_BACK = 0
        const val FACING_FRONT = 1

        const val KIND_AUTH   = 0
        const val KIND_START  = 1
        const val KIND_STOP   = 2
        const val KIND_SWITCH = 3
        const val KIND_FRAME  = 4   // H.264 birimi
        const val KIND_META   = 5   // boyut/yon bilgisi (JSON)
    }
}
