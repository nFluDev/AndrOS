package dev.naer.andros.feature

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.util.AttributeSet
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import org.json.JSONObject
import kotlin.math.abs
import kotlin.math.hypot

/**
 * Telefon ekrani = Mac'in dokunmatik yuzeyi.
 *
 * Mac'in kendi trackpad'i gibi davransin diye kurallar buradan geliyor:
 *  • tek parmak surukleme  → imleci oynat
 *  • tek parmak dokunma    → sol tik
 *  • iki parmak dokunma    → sag tik
 *  • iki parmak surukleme  → kaydirma
 *  • dokun-ve-surukle      → dugme basili surukleme (secme, tasima)
 *  • uc parmak sag/sol     → sanal masaustu degistir
 *  • uc parmak yukari/asagi→ Mission Control / geri
 *
 * Imlec KONUMU degil FARKI gonderiliyor: telefon ekraniyla Mac ekrani
 * ayni sekilde degil ve mutlak esleme dokunmatik ekran gibi davranirdi;
 * trackpad'in dogru davranisi goreli olan.
 */
class TrackpadView @JvmOverloads constructor(
    ctx: Context, attrs: AttributeSet? = null,
) : View(ctx, attrs) {

    /// Ureticiye tek bir olay. Ekran ne yapacagini bilmiyor, yalniz
    /// yolluyor — boylece bu gorunum sinanabilir kaliyor.
    var onEvent: ((JSONObject) -> Unit)? = null

    /// Imlec hizi. 1.0 = telefonda 1 piksel, Mac'te 1 nokta.
    var speed = 1.9f

    private val touchSlop = ViewConfiguration.get(ctx).scaledTouchSlop
    private val tapTimeout = ViewConfiguration.getTapTimeout().toLong()
    private val doubleTapWindow = 280L

    private var downX = 0f
    private var downY = 0f
    private var lastX = 0f
    private var lastY = 0f
    private var lastScrollY = 0f
    private var lastScrollX = 0f
    private var downAt = 0L
    private var maxPointers = 0
    private var moved = false
    private var dragging = false
    private var gestureSent = false
    private var lastTapAt = 0L

    // Parmak izi halkalari: dokunulan yer gorunur olsun.
    private val ripple = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.parseColor("#334ADE80")
    }
    private var touches: List<Pair<Float, Float>> = emptyList()

    override fun onTouchEvent(e: MotionEvent): Boolean {
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                downX = e.x; downY = e.y
                lastX = e.x; lastY = e.y
                lastScrollX = e.x; lastScrollY = e.y
                downAt = System.currentTimeMillis()
                maxPointers = 1
                moved = false
                gestureSent = false
                // Dokun-ve-surukle: onceki dokunustan hemen sonra basip
                // surukleme "tut ve tasi" demek — Mac trackpad'inde de
                // boyle. Dugmeyi SIMDI basili tutuyoruz.
                if (System.currentTimeMillis() - lastTapAt < doubleTapWindow) {
                    dragging = true
                    send(JSONObject().put("t", "down"))
                }
            }

            MotionEvent.ACTION_POINTER_DOWN -> {
                maxPointers = maxOf(maxPointers, e.pointerCount)
                lastScrollX = e.x; lastScrollY = e.y
            }

            MotionEvent.ACTION_MOVE -> {
                maxPointers = maxOf(maxPointers, e.pointerCount)
                when {
                    e.pointerCount >= 3 -> threeFinger(e)
                    e.pointerCount == 2 -> {
                        val dx = e.x - lastScrollX
                        val dy = e.y - lastScrollY
                        if (abs(dx) > 0.5f || abs(dy) > 0.5f) {
                            moved = true
                            lastScrollX = e.x; lastScrollY = e.y
                            send(JSONObject().put("t", "scroll")
                                .put("dx", dx.toDouble()).put("dy", dy.toDouble()))
                        }
                    }
                    else -> {
                        val dx = e.x - lastX
                        val dy = e.y - lastY
                        lastX = e.x; lastY = e.y
                        if (hypot(e.x - downX, e.y - downY) > touchSlop) moved = true
                        if (abs(dx) > 0.01f || abs(dy) > 0.01f) {
                            send(JSONObject().put("t", "move")
                                .put("dx", (dx * speed).toDouble())
                                .put("dy", (dy * speed).toDouble()))
                        }
                    }
                }
            }

            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                val held = System.currentTimeMillis() - downAt
                if (dragging) {
                    dragging = false
                    send(JSONObject().put("t", "up"))
                } else if (!moved && !gestureSent && held < tapTimeout * 3) {
                    // Kac parmakla DOKUNULDUGU tikin turunu belirliyor.
                    when (maxPointers) {
                        1 -> { send(JSONObject().put("t", "click").put("b", "left"))
                               lastTapAt = System.currentTimeMillis() }
                        2 -> send(JSONObject().put("t", "click").put("b", "right"))
                    }
                }
                maxPointers = 0
            }
        }
        touches = (0 until e.pointerCount)
            .filter { e.actionMasked != MotionEvent.ACTION_UP }
            .map { e.getX(it) to e.getY(it) }
        if (e.actionMasked == MotionEvent.ACTION_UP ||
            e.actionMasked == MotionEvent.ACTION_CANCEL) touches = emptyList()
        invalidate()
        return true
    }

    /// Uc parmak: jest BIR KEZ atesleniyor. Aksi halde tek bir kaydirma
    /// sirasinda onlarca masaustu degistirirdi.
    private fun threeFinger(e: MotionEvent) {
        if (gestureSent) return
        val dx = e.x - downX
        val dy = e.y - downY
        val threshold = touchSlop * 4
        val g = when {
            abs(dx) > abs(dy) && dx > threshold  -> "desktopLeft"
            abs(dx) > abs(dy) && dx < -threshold -> "desktopRight"
            abs(dy) > abs(dx) && dy < -threshold -> "missionControl"
            abs(dy) > abs(dx) && dy > threshold  -> "back"
            else -> null
        } ?: return
        gestureSent = true
        moved = true
        send(JSONObject().put("t", "gesture").put("g", g))
    }

    private fun send(o: JSONObject) { onEvent?.invoke(o) }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        for ((x, y) in touches) canvas.drawCircle(x, y, 34f, ripple)
    }

    /// Klavye ve dugmeler icin disaridan cagrilan yardimcilar.
    fun click(right: Boolean) =
        send(JSONObject().put("t", "click").put("b", if (right) "right" else "left"))
    fun text(s: String) = send(JSONObject().put("t", "text").put("s", s))
    fun key(k: String) = send(JSONObject().put("t", "key").put("k", k))
}
