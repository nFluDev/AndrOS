package dev.naer.andros.net

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.AudioPlaybackCaptureConfiguration
import android.media.MediaRecorder
import android.media.projection.MediaProjection
import android.os.Build
import android.util.Log
import androidx.core.content.ContextCompat
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import javax.net.ssl.SSLServerSocket
import kotlin.concurrent.thread

/**
 * Telefonu Mac'in ses aygiti yapan kanal.
 *
 * Iki yon ayni sokette:
 *   • Mac'in cikisi -> telefonun hoparloru/kulakligi  (`AudioTrack`)
 *   • Telefonun mikrofonu -> Mac'in girisi            (`AudioRecord`)
 *
 * Boylece kulakligi TELEFONA takip Mac'in sesini oradan dinleyebiliyor,
 * ayni anda telefonun mikrofonunu Mac'te kullanabiliyorsun.
 *
 * AYRI SOKET: denetim kanali istek/yanit tasiyor ve ses onun arkasinda
 * beklerse cizilme (dropout) oluyor. Burasi yalnizca ham PCM akitiyor.
 *
 * Bicim 48 kHz / 16 bit; cikis stereo, mikrofon MONO (cogu telefon MIC
 * kaynagini stereo acmiyor — Mac tarafinda ikiye kopyalaniyor).
 */
class AudioLink(
    private val ctx: Context,
    private val identity: Identity,
) {
    @Volatile private var server: SSLServerSocket? = null
    @Volatile private var track: AudioTrack? = null
    @Volatile private var record: AudioRecord? = null
    @Volatile private var micThread: Thread? = null
    /// Telefonun KENDI sesini yakalayan kayit (bildirim, muzik…).
    @Volatile private var capture: AudioRecord? = null
    @Volatile private var captureThread: Thread? = null
    @Volatile private var projection: MediaProjection? = null
    /// Bagli istemciye yollamak icin acik cikis akisi.
    @Volatile private var live: DataOutputStream? = null
    @Volatile var clients = 0
        private set

    fun start(): Int {
        stop()
        val ss = try {
            identity.sslContext().serverSocketFactory
                .createServerSocket(DEFAULT_PORT) as SSLServerSocket
        } catch (e: Exception) {
            Log.w(TAG, "ses portu acilamadi: ${e.message}"); return 0
        }
        ss.enabledProtocols = arrayOf("TLSv1.3", "TLSv1.2")
        server = ss
        thread(isDaemon = true, name = "andros-audio-accept") {
            while (!ss.isClosed) {
                val s = try { ss.accept() } catch (e: Exception) { break }
                runCatching {
                    s.tcpNoDelay = true
                    s.trafficClass = 0x10          // IPTOS_LOWDELAY
                    // Bkz. Server.kt: yarim kalan el sikismasi is
                    // parcacigini sonsuza kadar tutuyordu.
                    s.soTimeout = 15_000
                }
                thread(isDaemon = true, name = "andros-audio") {
                    try { serve(s) }
                    catch (e: Throwable) { Log.d(TAG, "ses baglantisi bitti: ${e.message}") }
                    finally {
                        runCatching { s.close() }
                        clients = (clients - 1).coerceAtLeast(0)
                        live = null
                        stopPlayback()
                        stopMic()
                        stopCapture()
                    }
                }
            }
        }
        Log.i(TAG, "ses kanali dinliyor: ${ss.localPort}")
        return ss.localPort
    }

    fun stop() {
        runCatching { server?.close() }
        server = null
        stopPlayback()
        stopMic()
        stopCapture()
        projection?.stop(); projection = null
        clients = 0
    }

    private fun serve(sock: java.net.Socket) {
        val input = DataInputStream(BufferedInputStream(sock.getInputStream(), 1 shl 16))
        val out = DataOutputStream(BufferedOutputStream(sock.getOutputStream(), 1 shl 16))
        sock.soTimeout = 0

        // Ilk cerceve: belirtec. Eslestirilmemis istemci ses ALAMAZ ve
        // VEREMEZ — mikrofon ve hoparlor en hassas iki uc.
        val kind = input.readByte().toInt()
        val len = input.readInt()
        if (kind != KIND_AUTH || len !in 1..4096) return
        val token = ByteArray(len).also { input.readFully(it) }.toString(Charsets.UTF_8)
        if (!identity.isKnown(token)) {
            Log.w(TAG, "ses: yetkisiz istemci"); return
        }
        clients++
        live = out
        Log.i(TAG, "ses istemcisi baglandi")
        // Telefon sesi yakalama zaten aciksa yeni istemciye de aksin.
        if (projection != null) startCapture()

        val buf = ByteArray(1 shl 16)
        while (true) {
            val k = input.readByte().toInt()
            val n = input.readInt()
            if (n < 0 || n > buf.size) throw IllegalStateException("gecersiz uzunluk $n")
            when (k) {
                KIND_PLAY -> {
                    input.readFully(buf, 0, n)
                    ensurePlayback().write(buf, 0, n)
                }
                KIND_MIC_ON  -> { if (n > 0) input.skipBytes(n); startMic(out) }
                KIND_MIC_OFF -> { if (n > 0) input.skipBytes(n); stopMic() }
                KIND_PLAY_OFF -> { if (n > 0) input.skipBytes(n); stopPlayback() }
                // Mac yansitma sesini actiysa telefon sesini BURADAN
                // yollamayi birakiyoruz: ayni ses iki yoldan gelirdi.
                KIND_CAPTURE_PAUSE -> { if (n > 0) input.skipBytes(n); stopCapture() }
                KIND_CAPTURE_RESUME -> { if (n > 0) input.skipBytes(n); startCapture() }
                else -> if (n > 0) input.skipBytes(n)
            }
        }
    }

    // ---- Mac -> telefon

    private fun ensurePlayback(): AudioTrack {
        track?.let { return it }
        val min = AudioTrack.getMinBufferSize(
            RATE, AudioFormat.CHANNEL_OUT_STEREO, AudioFormat.ENCODING_PCM_16BIT)
        // Iki katı: ag dalgalanmasini yutar, gecikmeyi hissettirmez.
        val t = AudioTrack.Builder()
            .setAudioAttributes(AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                .build())
            .setAudioFormat(AudioFormat.Builder()
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setSampleRate(RATE)
                .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                .build())
            .setBufferSizeInBytes(min * 2)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
        t.play()
        track = t
        Log.i(TAG, "hoparlor acildi")
        return t
    }

    private fun stopPlayback() {
        val t = track ?: return
        track = null
        runCatching { t.pause(); t.flush(); t.release() }
        Log.i(TAG, "hoparlor kapandi")
    }

    // ---- telefon -> Mac

    private fun startMic(out: DataOutputStream) {
        if (micThread != null) return
        if (ContextCompat.checkSelfPermission(ctx, Manifest.permission.RECORD_AUDIO)
            != PackageManager.PERMISSION_GRANTED) {
            Log.w(TAG, "mikrofon izni yok")
            return
        }
        val min = AudioRecord.getMinBufferSize(
            RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val r = try {
            AudioRecord(MediaRecorder.AudioSource.VOICE_COMMUNICATION, RATE,
                        AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, min * 2)
        } catch (e: Exception) { Log.w(TAG, "mikrofon acilamadi: ${e.message}"); return }
        if (r.state != AudioRecord.STATE_INITIALIZED) { r.release(); return }
        record = r
        r.startRecording()
        Log.i(TAG, "mikrofon acildi")
        micThread = thread(isDaemon = true, name = "andros-mic") {
            val b = ByteArray(1920 * 2)      // ~20 ms mono
            try {
                while (record === r) {
                    val n = r.read(b, 0, b.size)
                    if (n <= 0) break
                    synchronized(out) {
                        out.writeByte(KIND_MIC)
                        out.writeInt(n)
                        out.write(b, 0, n)
                        out.flush()
                    }
                }
            } catch (e: Throwable) {
                Log.d(TAG, "mikrofon akisi bitti: ${e.message}")
            }
        }
    }

    // ---- Telefonun KENDI sesi -> Mac
    //
    // "Kulaklikta iki cihaz bagliymis gibi": Mac'te calisirken telefona
    // gelen bildirim/muzik sesi de ayni kulakliktan duyulsun. Android
    // 10'dan beri bunun yolu `AudioPlaybackCapture`; ekran yakalama
    // izniyle (MediaProjection) aciliyor, ekrani PAYLASMIYORUZ —
    // yalnizca ses. Uygulamalar kendilerini bu yakalamaya kapatabiliyor
    // (`allowAudioPlaybackCapture=false`) ve GORUSME sesi hicbir
    // kosulda yakalanamiyor; bu Android'in kurali.

    fun setProjection(p: MediaProjection?) {
        if (p == null) { stopCapture(); projection?.stop(); projection = null; return }
        projection = p
        startCapture()
    }

    val capturing: Boolean get() = capture != null

    private fun startCapture() {
        if (captureThread != null) return
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        val proj = projection ?: return
        val out = live ?: return
        val cfg = AudioPlaybackCaptureConfiguration.Builder(proj)
            .addMatchingUsage(android.media.AudioAttributes.USAGE_MEDIA)
            .addMatchingUsage(android.media.AudioAttributes.USAGE_NOTIFICATION)
            .addMatchingUsage(android.media.AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
            .addMatchingUsage(android.media.AudioAttributes.USAGE_ALARM)
            .addMatchingUsage(android.media.AudioAttributes.USAGE_GAME)
            .addMatchingUsage(android.media.AudioAttributes.USAGE_UNKNOWN)
            .build()
        val min = AudioRecord.getMinBufferSize(
            RATE, AudioFormat.CHANNEL_IN_STEREO, AudioFormat.ENCODING_PCM_16BIT)
        val r = try {
            AudioRecord.Builder()
                .setAudioPlaybackCaptureConfig(cfg)
                .setAudioFormat(AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(RATE)
                    .setChannelMask(AudioFormat.CHANNEL_IN_STEREO)
                    .build())
                .setBufferSizeInBytes(min * 2)
                .build()
        } catch (e: Exception) { Log.w(TAG, "ses yakalama acilamadi: ${e.message}"); return }
        if (r.state != AudioRecord.STATE_INITIALIZED) { r.release(); return }
        capture = r
        r.startRecording()
        Log.i(TAG, "telefon sesi yakalaniyor")
        captureThread = thread(isDaemon = true, name = "andros-capture") {
            val b = ByteArray(1920 * 4)      // ~20 ms stereo
            try {
                while (capture === r) {
                    val n = r.read(b, 0, b.size)
                    if (n <= 0) break
                    synchronized(out) {
                        out.writeByte(KIND_PHONE)
                        out.writeInt(n)
                        out.write(b, 0, n)
                        out.flush()
                    }
                }
            } catch (e: Throwable) { Log.d(TAG, "yakalama bitti: ${e.message}") }
        }
    }

    private fun stopCapture() {
        val r = capture ?: return
        capture = null
        captureThread = null
        runCatching { r.stop(); r.release() }
        Log.i(TAG, "telefon sesi yakalama kapandi")
    }

    private fun stopMic() {
        val r = record ?: return
        record = null
        micThread = null
        runCatching { r.stop(); r.release() }
        Log.i(TAG, "mikrofon kapandi")
    }

    companion object {
        private const val TAG = "AndrOS.Audio"
        const val DEFAULT_PORT = 47824
        const val RATE = 48000

        const val KIND_AUTH     = 0
        const val KIND_PLAY     = 1   // Mac -> telefon (stereo 16 bit)
        const val KIND_MIC      = 2   // telefon -> Mac (mono 16 bit)
        const val KIND_MIC_ON   = 3
        const val KIND_MIC_OFF  = 4
        const val KIND_PLAY_OFF = 5
        const val KIND_PHONE    = 6   // telefonun kendi sesi -> Mac (stereo)
        const val KIND_CAPTURE_PAUSE  = 7
        const val KIND_CAPTURE_RESUME = 8
    }
}
