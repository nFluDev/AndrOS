package dev.naer.andros.net

import android.content.Context
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.projection.MediaProjection
import android.os.Build
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
    /// Kacinci baglanti. Eskiyen baglantinin temizligi yenisini
    /// vurmasin diye.
    @Volatile private var sessionSeq = 0L
    /// Ekran izni yok: hizmet kullaniciya bildirim dussun.
    var onNeedProjection: (() -> Unit)? = null
    /// Izin ELDEN GITTI: hizmet durumunu guncellesin.
    var onProjectionLost: (() -> Unit)? = null

    private var width = 0
    private var height = 0
    private var rotation = -1
    /// Mac'in istedigi kalite. Varsayilanlar 1080p60/8 Mbit.
    private var maxSize = 1920
    private var fps = 60
    private var bitrate = 8_000_000
    private var displayListener: DisplayManager.DisplayListener? = null
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
                    val mine = ++sessionSeq
                    try { serve(s, mine) }
                    catch (e: Throwable) { Log.d(TAG, "ekran baglantisi bitti: ${e.message}") }
                    finally {
                        runCatching { s.close() }
                        // YALNIZ KENDI oturumunu kapat.
                        //
                        // Olculen dongu: Mac koptugunda yeniden
                        // baglaniyor, yeni baglanti yakalamayi baslatiyor,
                        // sonra ESKI baglantinin `finally`si calisip onu
                        // olduruyordu. Sonuc: saniyede bir "baglandi /
                        // koptu". Artik kapatan, o sirada gecerli olan
                        // oturum degilse hicbir sey yapmiyor.
                        if (sessionSeq == mine) stopCapture()
                    }
                }
            }
        }
        Log.i(TAG, "ekran kanali dinliyor: ${ss.localPort}")
        return ss.localPort
    }

    fun stop() {
        runCatching { server?.close() }
        server = null
        displayListener?.let {
            val dm = ctx.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
            runCatching { dm.unregisterDisplayListener(it) }
        }
        displayListener = null
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
                // Izin OLDU. Sistem bunu kendi de yapabiliyor (baska bir
                // uygulama yakalamaya baslayinca, ya da ColorOS arka
                // plandaki paylasimi kesince — oyun acinca olan buydu).
                // Referansi BIRAKMAK sart: olu bir izinle sanal ekran
                // acmaya calismak, Mac'i sonsuz yeniden baglanma
                // dongusune sokuyordu.
                Log.i(TAG, "ekran paylasimi sona erdi")
                projection = null
                stopCapture()
                onProjectionLost?.invoke()
                sendError("noprojection")
            }
        }, android.os.Handler(android.os.Looper.getMainLooper()))
    }

    private fun serve(sock: java.net.Socket, session: Long) {
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
                KIND_START -> {
                    // Mac hangi kalitede istedigini soyluyor. Cozunurluk
                    // ve kare hizi gecikmeyi bit hizindan cok etkiliyor:
                    // daha az piksel = daha az kodlama, daha az veri.
                    if (body.isNotEmpty()) runCatching {
                        val o = JSONObject(String(body, Charsets.UTF_8))
                        maxSize = o.optInt("maxSize", maxSize).coerceIn(480, 2560)
                        fps = o.optInt("fps", fps).coerceIn(15, 120)
                        bitrate = o.optInt("bitrate", bitrate).coerceIn(1, 40) * 1_000_000
                    }
                    startCapture()
                }
                KIND_STOP  -> stopCapture()
                KIND_INPUT -> handleInput(String(body, Charsets.UTF_8))
            }
        }
    }

    // MARK: - Goruntu

    /**
     * Telefonun ekranini UYANDIRIR.
     *
     * Ekran kapaliyken yakalama bos kaliyor ve kullanicinin telefonu
     * eline alip acmasi gerekiyordu — "uzaktan kullanma"nin butun
     * anlamini kaciran bir durum. `ACQUIRE_CAUSES_WAKEUP` eski bir yol
     * ve dokumanda "kullanmayin" yaziyor, ama adb'siz ekrani acmanin
     * baska yolu yok: yeni yol (`setTurnScreenOn`) bir ETKINLIK
     * gerektiriyor ve arka plandan etkinlik acmak Android 10'dan beri
     * yasak.
     *
     * KILIDI ACAMIYORUZ. Ekran acilir, kilit ekrani gelir; sifre alani
     * Android'in guvenlik kurali geregi yakalanamiyor.
     */
    private fun wakeScreen() {
        val pm = ctx.getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
        if (pm.isInteractive) return
        runCatching {
            @Suppress("DEPRECATION")
            val wl = pm.newWakeLock(
                android.os.PowerManager.SCREEN_BRIGHT_WAKE_LOCK or
                android.os.PowerManager.ACQUIRE_CAUSES_WAKEUP, "AndrOS:wake")
            wl.acquire(3000)
            Log.i(TAG, "ekran uyandirildi")
        }
    }

    private fun startCapture() {
        // Zaten calisiyorsa YENIDEN KUR, sessizce cikma. Baglanti
        // koptugunda eski yakalama bir sure daha ayakta kalabiliyor;
        // erken donmek yeni istemciye hic kare gitmemesi demekti.
        if (running) stopCapture()
        wakeScreen()
        val proj = projection ?: run {
            sendError("noprojection")
            // Kullanicinin uygulamayi acip izni aramasini beklemek yerine
            // bildirim dusuruyoruz: tek dokunus, dogrudan onay ekrani.
            onNeedProjection?.invoke()
            return
        }
        if (!InputService.isEnabled) {
            // Goruntu calisir ama kontrol calismaz — kullaniciya SOYLE.
            sendError("noinput")
        }

        val wm = ctx.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val metrics = DisplayMetrics()
        @Suppress("DEPRECATION")
        val disp = wm.defaultDisplay
        disp.getRealMetrics(metrics)
        rotation = disp.rotation
        // Istenen en buyuk kenara sigdir: daha buyugu bant genisligini
        // ve kodlama suresini bosa harciyor.
        val scale = minOf(1f, maxSize.toFloat() / maxOf(metrics.widthPixels, metrics.heightPixels))
        width = (metrics.widthPixels * scale).toInt() / 2 * 2
        height = (metrics.heightPixels * scale).toInt() / 2 * 2

        val fmt = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT,
                       MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
            setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            // GECIKME. Kodlayici varsayilan olarak birkac kareyi
            // tamponluyor ve akis "gec" hissettiriyor. Bu iki anahtar
            // donanim kodlayicisina "gercek zamanli, tampon yapma"
            // diyor. Desteklenmeyen cihazda yok sayiliyor, zarari yok.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                setInteger(MediaFormat.KEY_PRIORITY, 0)          // gercek zamanli
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                setInteger(MediaFormat.KEY_LATENCY, 1)           // 1 kare gecikme
            }
            // Sabit bit hizi: degisken hizda hareketli sahnede tampon
            // sisiyor ve gecikme birikiyor.
            setInteger(MediaFormat.KEY_BITRATE_MODE,
                       MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR)
        }
        // Kodlayici kurulumu cihaza gore atabiliyor (mesela olcu
        // desteklenmiyorsa). Cokmek yerine soyluyoruz.
        val enc: MediaCodec
        val surf: Surface
        try {
            enc = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
            enc.configure(fmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            surf = enc.createInputSurface()
            enc.start()
        } catch (e: Throwable) {
            Log.w(TAG, "kodlayici kurulamadi: ${e.message}")
            sendError("encoder")
            return
        }
        encoder = enc
        surface = surf
        running = true

        display = try {
            proj.createVirtualDisplay(
                "AndrOS", width, height, metrics.densityDpi,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, surf, null, null)
        } catch (e: Throwable) {
            // Olu izinle sanal ekran acilmiyor. Sessizce birakmak yerine
            // izni birakip kullanicidan yenisini istiyoruz — yoksa
            // karsi taraf bos ekrana bakip duruyor.
            Log.w(TAG, "sanal ekran acilamadi: ${e.message}")
            projection = null
            stopCapture()
            sendError("noprojection")
            onProjectionLost?.invoke()
            onNeedProjection?.invoke()
            return
        }

        sendMeta()
        // KILITLIYSE hemen soyle. Kilit ekrani Android'in guvenlik
        // kurali geregi yakalanamiyor; Mac'in siyah ekrani sessizce
        // gostermesi "bozuk" demekti.
        val km = ctx.getSystemService(Context.KEYGUARD_SERVICE) as android.app.KeyguardManager
        wasLocked = km.isKeyguardLocked
        if (wasLocked) sendError("locked")
        thread(isDaemon = true, name = "andros-screen-drain") { drain(enc) }
        watchRotation()
        Log.i(TAG, "ekran yakalaniyor: ${width}x$height (donus $rotation)")
    }

    /**
     * Telefon donunce yakalamayi YENIDEN KURAR.
     *
     * Sanal ekranin olcusu sabit; telefon yan cevrilince goruntu o sabit
     * cerceveye sikisiyor ve yamuk duruyordu. Kodlayicinin giris yuzeyi
     * de olusturulurken sabitlendigi icin yalniz `VirtualDisplay.resize`
     * yetmiyor — ikisini birden kuruyoruz. Mac tarafi yeni olcuyu
     * cozulen kareden anliyor, ek bir sey yapmasi gerekmiyor.
     */
    private fun watchRotation() {
        val dm = ctx.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
        if (displayListener != null) { pollRotation(); return }
        val l = object : DisplayManager.DisplayListener {
            override fun onDisplayAdded(id: Int) {}
            override fun onDisplayRemoved(id: Int) {}
            override fun onDisplayChanged(id: Int) {
                if (id != android.view.Display.DEFAULT_DISPLAY || !running) return
                val wm = ctx.getSystemService(Context.WINDOW_SERVICE) as WindowManager
                @Suppress("DEPRECATION")
                val now = wm.defaultDisplay.rotation
                if (now == rotation) return
                Log.i(TAG, "donus degisti: $rotation -> $now")
                runCatching { stopCapture(); startCapture() }
                    .onFailure { Log.w(TAG, "donuste yeniden kurulamadi: ${it.message}") }
            }
        }
        dm.registerDisplayListener(l, android.os.Handler(android.os.Looper.getMainLooper()))
        displayListener = l
        pollRotation()
    }

    private fun pollRotation() {
        // DINLEYICI TEK BASINA YETMIYOR. Bir uygulama kendi yonunu
        // dayattiginda (oyunlar) bazi cihazlarda `onDisplayChanged`
        // gelmiyor ya da olcu daha oturmadan geliyor; goruntu eski
        // cerceveye sikisip kaliyordu. Ucuz bir yoklama bunu kapatiyor:
        // saniyede uc kez tek bir tamsayi okumak.
        thread(isDaemon = true, name = "andros-rotation") {
            while (running) {
                Thread.sleep(300)
                if (!running) break
                // KILIT: kilit ekrani Android'in guvenlik kurali geregi
                // yakalanamiyor, karsi taraf simsiyah bir ekran goruyor
                // ve "bozuldu" saniyordu. Durumu SOYLUYORUZ.
                val km = ctx.getSystemService(Context.KEYGUARD_SERVICE)
                    as android.app.KeyguardManager
                val locked = km.isKeyguardLocked
                if (locked != wasLocked) {
                    wasLocked = locked
                    if (locked) sendError("locked")
                }
                val wm = ctx.getSystemService(Context.WINDOW_SERVICE) as WindowManager
                @Suppress("DEPRECATION")
                val now = wm.defaultDisplay.rotation
                if (now != rotation) {
                    Log.i(TAG, "donus (yoklama): $rotation -> $now")
                    // Olcunun oturmasini bekle: hemen okursak eski
                    // genislik/yukseklik geliyor.
                    Thread.sleep(150)
                    android.os.Handler(android.os.Looper.getMainLooper()).post {
                        runCatching { if (running) { stopCapture(); startCapture() } }
                            .onFailure { Log.w(TAG, "donuste yeniden kurulamadi: ${it.message}") }
                    }
                    break       // yeni yakalama kendi yoklamasini baslatir
                }
            }
        }
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
            "shade"   -> svc.notifications()
            "quick"   -> svc.quickSettings()
            "power"   -> svc.powerDialog()
            "lock"    -> svc.lockScreen()
            "shot"    -> svc.screenshot()
            // Ses: erisilebilirlik degil, ses yoneticisi isi. Donanim
            // tusu ENJEKTE EDILEMIYOR (adb'siz yolun siniri), ama sesi
            // dogrudan degistirmek ayni sonucu veriyor ve sistemin kendi
            // gostergesini de aciyor.
            "vol"     -> volume(o.optInt("d", 1))
            "rotate"  -> toggleRotation()
            "dim"     -> dim(o.optBoolean("on", true))
            "text"    -> svc.type(o.optString("s"))
            "backspace" -> svc.backspace()
        }
    }

    private fun volume(direction: Int) {
        val am = ctx.getSystemService(Context.AUDIO_SERVICE) as android.media.AudioManager
        val step = if (direction >= 0) android.media.AudioManager.ADJUST_RAISE
                   else android.media.AudioManager.ADJUST_LOWER
        runCatching {
            am.adjustStreamVolume(android.media.AudioManager.STREAM_MUSIC, step,
                                  android.media.AudioManager.FLAG_SHOW_UI)
        }
    }

    /**
     * Otomatik donmeyi ac/kapa.
     *
     * Ekrani ZORLA dondurmek adb (ya da sistem uygulamasi olmak)
     * istiyor; adb'siz yapabildigimiz, telefonun otomatik donmesini
     * acip kapamak. Bunun icin sistem ayarlarini yazma izni gerekiyor;
     * yoksa Mac'e soyluyoruz, sessizce dusurmuyoruz.
     */
    private fun toggleRotation() {
        runCatching {
            if (!android.provider.Settings.System.canWrite(ctx)) {
                sendError("nowritesettings"); return
            }
            val now = android.provider.Settings.System.getInt(
                ctx.contentResolver,
                android.provider.Settings.System.ACCELEROMETER_ROTATION, 0)
            android.provider.Settings.System.putInt(
                ctx.contentResolver,
                android.provider.Settings.System.ACCELEROMETER_ROTATION,
                if (now == 0) 1 else 0)
        }
    }

    /**
     * Telefon ekranini karart / geri ac.
     *
     * Ekrani GERCEKTEN kapatmak adb (ya da cihaz yoneticisi) istiyor;
     * scrcpy'nin `--turn-screen-off`'u shell yetkisiyle calisiyor.
     * Adb'siz yapabildigimiz parlakligi sifirlamak: yansitma surer,
     * telefon kararir. Onceki parlakligi saklayip geri veriyoruz.
     */
    private fun dim(on: Boolean) {
        if (!android.provider.Settings.System.canWrite(ctx)) { sendError("nowritesettings"); return }
        runCatching {
            val cr = ctx.contentResolver
            if (on) {
                if (savedBrightness < 0) {
                    savedBrightness = android.provider.Settings.System.getInt(
                        cr, android.provider.Settings.System.SCREEN_BRIGHTNESS, 128)
                }
                // Otomatik parlaklik acikken elle verilen deger hemen
                // eziliyor; once onu kapatmak gerekiyor.
                android.provider.Settings.System.putInt(
                    cr, android.provider.Settings.System.SCREEN_BRIGHTNESS_MODE,
                    android.provider.Settings.System.SCREEN_BRIGHTNESS_MODE_MANUAL)
                android.provider.Settings.System.putInt(
                    cr, android.provider.Settings.System.SCREEN_BRIGHTNESS, 0)
            } else {
                android.provider.Settings.System.putInt(
                    cr, android.provider.Settings.System.SCREEN_BRIGHTNESS,
                    if (savedBrightness > 0) savedBrightness else 128)
                savedBrightness = -1
            }
        }
    }

    private var savedBrightness = -1
    private var wasLocked = false

    /// Yazma hatasi UYGULAMAYI OLDURMEMELI.
    ///
    /// Olculen cokme: telefon donunce yakalama ana is parcaciginda
    /// yeniden kuruluyor ve buradaki `IOException` yakalanmadan yukari
    /// cikiyordu — surec oluyor, MediaProjection onunla birlikte gidiyor
    /// ve kullanicidan yeniden izin isteniyordu. Oyun acinca olan buydu:
    /// oyun ekrani cevirir, biz cokeriz.
    private fun sendMeta() {
        val o = out ?: return
        runCatching {
            val j = JSONObject().put("width", width).put("height", height)
                .put("input", InputService.isEnabled)
                .toString().toByteArray(Charsets.UTF_8)
            synchronized(o) { o.writeByte(KIND_META); o.writeInt(j.size); o.write(j); o.flush() }
        }.onFailure { Log.d(TAG, "meta yazilamadi: ${it.message}") }
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
