package dev.naer.andros

import android.app.*
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.app.NotificationCompat
import dev.naer.andros.feature.Handlers
import dev.naer.andros.net.Discovery
import dev.naer.andros.net.MediaServer
import dev.naer.andros.net.Identity
import dev.naer.andros.net.Reply
import dev.naer.andros.net.Server
import dev.naer.andros.net.Keepalive
import dev.naer.andros.net.UdpBeacon
import dev.naer.andros.net.AudioLink
import dev.naer.andros.net.CameraLink
import dev.naer.andros.net.ScreenLink
import org.json.JSONObject

/**
 * On plan hizmeti: uygulama kapaliyken de Mac baglanabilsin.
 *
 * On plan sart, arka plan degil — Android 10+ arka plandaki sureclerin
 * panoyu okumasini ve uzun sureli soket tutmasini engelliyor. Kalici
 * bildirim ayni zamanda kullanicinin "su an baglanti acik" bilgisini
 * gormesini sagliyor.
 */
class AndrOSService : Service() {

    private lateinit var identity: Identity
    private lateinit var discovery: Discovery
    private var server: Server? = null
    private val media = MediaServer()
    private var clientCount = 0
    private var keepalive: Keepalive? = null
    private var audio: AudioLink? = null
    private var camera: CameraLink? = null
    private var screen: ScreenLink? = null
    private var beacon: UdpBeacon? = null
    private var tlsPort = 0

    override fun onCreate() {
        super.onCreate()
        live = this
        identity = Identity(this)
        identity.publishId()
        discovery = Discovery(this)
        createChannel()
        startForeground(NOTIF_ID, buildNotification())

        val ka = Keepalive(this)
        ka.start()
        keepalive = ka

        val srv = Server(this, identity) { n ->
            clientCount = n
            // Islemci kilidi YALNIZ bagliyken: bosta pil yakmasin,
            // bagliyken Doze istekleri dakikalarca bekletmesin.
            ka.clients(n)
            notify(buildNotification())
        }
        val port = srv.start()
        tlsPort = port
        server = srv
        media.start()
        Handlers.mediaServer = media
        // Ses kanali: telefon Mac'in hoparloru ve mikrofonu olarak
        // gorunsun (bkz. AudioLink).
        val al = AudioLink(this, identity)
        al.start()
        audio = al
        // Kamera kanali: telefon Mac'e webcam olarak baglansin.
        val cl = CameraLink(this, identity)
        cl.start()
        camera = cl
        // Ekran yansitma: adb'siz yol (MediaProjection + erisilebilirlik).
        val sl = ScreenLink(this, identity)
        sl.onNeedProjection = { askForProjection() }
        sl.onProjectionLost = {
            capturingAudio = false
            audio?.setProjection(null)
            notify(buildNotification())
        }
        sl.start()
        screen = sl

        // mDNS'e ALTERNATIF bulma yolu. Wi-Fi yongasi guc tasarrufunda
        // multicast'i suzdugu (ve bazi yonlendiriciler hic gecirmedigi)
        // icin Bonjour tek basina guvenilir degil; olculdu.
        val bc = UdpBeacon {
            JSONObject()
                .put("andros", 1)
                .put("name", Build.MODEL)
                .put("manufacturer", Build.MANUFACTURER)
                .put("deviceId", identity.deviceId)
                .put("port", tlsPort)
                .put("fp", identity.fingerprint())
        }
        bc.start()
        beacon = bc

        // Bildirim gelir gelmez Mac'e yolla — sormasini beklemeden.
        dev.naer.andros.feature.NotificationListener.onChange = { obj ->
            if (obj != null) {
                srv.broadcast(Reply.event("notification", obj))
            } else {
                srv.broadcast(Reply.event("notifications.changed", JSONObject()))
            }
        }
        discovery.advertise(port, Build.MODEL, identity.deviceId, identity.fingerprint())
        running = true
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_DISCONNECT -> {
                // Bildirimden "baglantiyi kes": eslesmeler SILINMIYOR,
                // yalniz acik oturumlar kapaniyor. Kullanici sonra tekrar
                // baglandiginda kod sorulmuyor.
                server?.disconnectAll()
                notify(buildNotification())
            }
            ACTION_UNPAIR -> {
                // Tum eslesmeleri unut: bir dahaki sefere kod/QR gerekir.
                identity.forgetAll()
                server?.disconnectAll()
                notify(buildNotification())
            }
            // Telefonun kendi sesini Mac'e vermek icin ekran yakalama
            // izni gerekiyor (Android 10+). EKRAN PAYLASILMIYOR — izin
            // yalnizca ses yakalamanin kapisi; Android baska yol vermiyor.
            ACTION_CAPTURE_ON -> {
                val code = intent.getIntExtra(EXTRA_CODE, 0)
                val data: Intent? = if (Build.VERSION.SDK_INT >= 33)
                    intent.getParcelableExtra(EXTRA_DATA, Intent::class.java)
                else @Suppress("DEPRECATION") intent.getParcelableExtra(EXTRA_DATA)
                if (data != null) {
                    val mgr = getSystemService(android.media.projection.MediaProjectionManager::class.java)
                    runCatching {
                        // AYNI izin hem sesi hem ekrani besliyor:
                        // kullanici tek onay veriyor.
                        val p = mgr.getMediaProjection(code, data)
                        audio?.setProjection(p)
                        screen?.setProjection(p)
                        capturingAudio = true
                        // Bir dahaki acilista kendiliginden istensin:
                        // Android izni OTURUMLUK veriyor ve kalici
                        // yapmanin yolu yok, ama SORMAYI otomatiklestirmek
                        // kullaniciyi ayarlarda gezdirmekten iyi.
                        getSharedPreferences("andros", MODE_PRIVATE).edit()
                            .putBoolean("captureWanted", true).apply()
                        androidx.core.app.NotificationManagerCompat.from(this)
                            .cancel(NOTIF_CAPTURE)
                    }.onFailure { android.util.Log.w("AndrOS", "yakalama: ${it.message}") }
                }
                notify(buildNotification())
            }
            ACTION_CAPTURE_OFF -> {
                audio?.setProjection(null); capturingAudio = false; notify(buildNotification())
            }
            ACTION_STOP -> stopSelf()
        }
        return START_STICKY
    }

    override fun onDestroy() {
        discovery.stop()
        beacon?.stop()
        audio?.stop()
        camera?.stop()
        screen?.stop()
        server?.stop()
        media.stop()
        keepalive?.stop()
        running = false
        live = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    /// Bildirim kanallari.
    ///
    /// IKI kanal var cunku bir kanalin onceligi OLUSTURULDUKTAN SONRA
    /// degistirilemiyor. "Sessiz bildirim" ayari acikken en dusuk
    /// oncelikli kanal kullaniliyor: bildirim golgesinin dibinde,
    /// sessiz, rozetsiz duruyor. Android bu bildirimi tamamen
    /// kaldirmaya izin vermiyor — arka planda kalmanin sarti.
    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val normal = NotificationChannel(CHANNEL, "AndrOS",
                                         NotificationManager.IMPORTANCE_LOW)
        normal.description = "Mac bağlantısı"
        normal.setShowBadge(false)
        mgr.createNotificationChannel(normal)

        val quiet = NotificationChannel(CHANNEL_QUIET, "AndrOS (sessiz)",
                                        NotificationManager.IMPORTANCE_MIN)
        quiet.description = "Mac bağlantısı — sessiz"
        quiet.setShowBadge(false)
        mgr.createNotificationChannel(quiet)
    }

    private fun activeChannel(): String =
        if (SettingsActivity.prefs(this)
                .getBoolean(SettingsActivity.KEY_QUIET_NOTIF, false)) CHANNEL_QUIET
        else CHANNEL

    private fun buildNotification(): Notification {
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val paired = identity.pairedClients()
        val text = when {
            clientCount > 0 -> "$clientCount Mac bağlı"
            paired.isNotEmpty() -> "Eşleşmiş: " + paired.joinToString(", ") { it.second }
            else -> "Bağlantı bekleniyor"
        }
        val b = NotificationCompat.Builder(this, activeChannel())
            .setContentTitle("AndrOS")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setOngoing(true)
            .setContentIntent(open)
            .setPriority(NotificationCompat.PRIORITY_LOW)

        // Kalici bildirimden dogrudan mudahale: uygulamayi acmaya gerek yok.
        if (clientCount > 0) b.addAction(0, "Bağlantıyı kes", action(ACTION_DISCONNECT))
        if (paired.isNotEmpty()) b.addAction(0, "Eşleşmeyi kaldır", action(ACTION_UNPAIR))
        return b.build()
    }

    private fun action(name: String): PendingIntent =
        PendingIntent.getService(this, name.hashCode(),
            Intent(this, AndrOSService::class.java).setAction(name),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)

    private fun notify(n: Notification) {
        (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
            .notify(NOTIF_ID, n)
    }

    /**
     * Ekran izni yok: kullaniciya TEK DOKUNUSLUK bir bildirim.
     *
     * Arka plandaki hizmet dogrudan etkinlik acamiyor (Android 10+),
     * bu yuzden bildirim uzerinden gidiyoruz. Bildirime dokununca
     * uygulama acilip onay ekranini kendisi cikariyor.
     */
    private fun askForProjection() {
        val i = Intent(this, MainActivity::class.java)
            .setFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            .putExtra("requestCapture", true)
        val pi = PendingIntent.getActivity(this, 7, i,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val n = NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_launcher_foreground)
            .setContentTitle("Mac ekranını istiyor")
            .setContentText("Ekran paylaşımını başlatmak için dokun.")
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(pi)
            .setAutoCancel(true)
            .build()
        runCatching {
            androidx.core.app.NotificationManagerCompat.from(this).notify(NOTIF_CAPTURE, n)
        }
    }

    companion object {
        const val ACTION_DISCONNECT = "dev.naer.andros.DISCONNECT"
        const val ACTION_UNPAIR = "dev.naer.andros.UNPAIR"
        const val ACTION_STOP = "dev.naer.andros.STOP"
        const val ACTION_CAPTURE_ON = "dev.naer.andros.CAPTURE_ON"
        const val ACTION_CAPTURE_OFF = "dev.naer.andros.CAPTURE_OFF"
        const val EXTRA_CODE = "code"
        const val EXTRA_DATA = "data"
        /// Telefon sesi su an Mac'e akiyor mu (arayuz icin).
        @Volatile var capturingAudio = false

        /// Calisan hizmet — Kumanda ekrani girdi olaylarini buradan
        /// yolluyor. Yeni bir soket acmak yerine ZATEN acik olan denetim
        /// kanalini kullaniyoruz: baglanti, TLS ve yetkilendirme hazir.
        @Volatile private var live: AndrOSService? = null

        /// Mac'e tek bir girdi olayi. Bagli istemci yoksa sessizce duser.
        fun sendInput(o: JSONObject): Boolean {
            val srv = live?.server ?: return false
            srv.broadcast(Reply.event("remote.input", o))
            return true
        }

        /// Mac'e bagli miyiz (Kumanda ekraninin durum yazisi icin).
        val hasClient: Boolean get() = (live?.clientCount ?: 0) > 0
        private const val CHANNEL = "andros.connection"
        private const val CHANNEL_QUIET = "andros.connection.quiet"
        private const val NOTIF_ID = 1
        private const val NOTIF_CAPTURE = 2
        @Volatile var running = false
            private set

        /// Hizmet ON PLANDAN mi baslatildi?
        ///
        /// Android, ARKA PLANDAN baslatilan on plan hizmetine kamera ve
        /// mikrofon erisimi VERMIYOR ("Foreground service started from
        /// background can not have location/camera/microphone access").
        /// Bizim hizmetimiz acilista/bildirim dinleyicisinden de
        /// baslayabildigi icin bu durum sik oluyor; kamera acilmak
        /// istendiginde `Camera "0" disabled by policy` hatasi
        /// aliniyordu (olculdu). Kullanici uygulamayi bir kez acinca
        /// hizmet ON PLANDAN yeniden baslatiliyor ve yetki geliyor.
        @Volatile var startedFromForeground = false
            private set

        fun start(ctx: Context, fromForeground: Boolean = false) {
            if (fromForeground) startedFromForeground = true
            val i = Intent(ctx, AndrOSService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) ctx.startForegroundService(i)
            else ctx.startService(i)
        }

        /// Kamera/mikrofon yetkisi icin hizmeti ON PLANDAN yeniden kurar.
        fun restartFromForeground(ctx: Context) {
            stop(ctx)
            startedFromForeground = false
            Handler(Looper.getMainLooper()).postDelayed({ start(ctx, fromForeground = true) }, 400)
        }
        fun stop(ctx: Context) { ctx.stopService(Intent(ctx, AndrOSService::class.java)) }
    }
}
