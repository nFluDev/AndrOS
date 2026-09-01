package dev.naer.andros.feature

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.os.Bundle
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

/**
 * Ekrana DOKUNMA ve yazma — adb OLMADAN.
 *
 * Neden bu yol: scrcpy girdiyi `InputManager` uzerinden enjekte ediyor
 * ve buna yalniz shell yetkisiyle (yani adb ile) erisilebiliyor. Normal
 * bir uygulamanin baska uygulamalara dokunabilmesinin TEK desteklenen
 * yolu erisilebilirlik hizmeti: `dispatchGesture` gercek dokunma
 * uretiyor, `performGlobalAction` geri/ana ekran/son uygulamalar
 * dugmelerini basiyor.
 *
 * Kullanici bunu Ayarlar > Erisilebilirlik'ten bir kez aciyor —
 * bildirim erisimiyle ayni sinifta, tek seferlik bir onay.
 *
 * SINIRLARI acikca yaziyoruz: donanim tuslari (ses, guc) enjekte
 * edilemiyor ve bazi guvenli alanlar (parola, banka uygulamalari)
 * erisilebilirlik girdisini reddediyor. Bunlar Android'in kurallari.
 */
class InputService : AccessibilityService() {

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        Log.i(TAG, "girdi hizmeti baglandi")
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}
    override fun onInterrupt() {}

    // MARK: - Hareketler

    /** Tek dokunus. */
    fun tap(x: Float, y: Float) {
        stroke(listOf(x to y), durationMs = 40)
    }

    /** Uzun basma. */
    fun longPress(x: Float, y: Float) {
        stroke(listOf(x to y), durationMs = 600)
    }

    /**
     * Surukleme / kaydirma.
     *
     * Noktalar ARA NOKTALARIYLA geliyor: iki uc nokta arasinda duz cizgi
     * cizmek "firlatma" (fling) hissini bozuyor, liste kaydirmalari
     * yanlis hizda oluyordu.
     */
    fun swipe(points: List<Pair<Float, Float>>, durationMs: Long) {
        stroke(points, durationMs)
    }

    private fun stroke(points: List<Pair<Float, Float>>, durationMs: Long) {
        if (points.isEmpty()) return
        val path = Path()
        path.moveTo(points[0].first, points[0].second)
        for (p in points.drop(1)) path.lineTo(p.first, p.second)
        // Tek nokta: `Path` bos kalmasin diye bir piksel ilerlet.
        if (points.size == 1) path.lineTo(points[0].first + 1f, points[0].second)
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, durationMs.coerceAtLeast(1)))
            .build()
        runCatching { dispatchGesture(gesture, null, null) }
            .onFailure { Log.w(TAG, "hareket gonderilemedi: ${it.message}") }
    }

    // MARK: - Sistem dugmeleri

    fun back()    = performGlobalAction(GLOBAL_ACTION_BACK)
    fun home()    = performGlobalAction(GLOBAL_ACTION_HOME)
    fun recents() = performGlobalAction(GLOBAL_ACTION_RECENTS)
    fun notifications() = performGlobalAction(GLOBAL_ACTION_NOTIFICATIONS)

    /// Hizli ayarlar, guc menusu, kilit ve ekran goruntusu de
    /// erisilebilirligin KENDI global eylemleri — adb gerekmiyor.
    /// Kilit ve ekran goruntusu daha yeni surumlerde eklendi; olmayan
    /// surumde sessizce yok sayiliyor.
    fun quickSettings() = performGlobalAction(GLOBAL_ACTION_QUICK_SETTINGS)
    fun powerDialog(): Boolean = performGlobalAction(GLOBAL_ACTION_POWER_DIALOG)
    fun lockScreen(): Boolean =
        if (android.os.Build.VERSION.SDK_INT >= 28)
            performGlobalAction(GLOBAL_ACTION_LOCK_SCREEN) else false
    fun screenshot(): Boolean =
        if (android.os.Build.VERSION.SDK_INT >= 30)
            performGlobalAction(GLOBAL_ACTION_TAKE_SCREENSHOT) else false

    // MARK: - Metin

    /**
     * Odaklanmis alana metin yazar.
     *
     * Erisilebilirlik tus tus yazamiyor; alanin ICERIGINI degistiriyoruz.
     * Bu yuzden metin SONUNA ekleniyor: kullanicinin yazdigi silinmesin.
     */
    fun type(text: String): Boolean {
        val node = findFocused() ?: return false
        val current = node.text?.toString() ?: ""
        val args = Bundle()
        args.putCharSequence(
            AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, current + text)
        return node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
    }

    /** Son karakteri siler. */
    fun backspace(): Boolean {
        val node = findFocused() ?: return false
        val current = node.text?.toString() ?: ""
        if (current.isEmpty()) return true
        val args = Bundle()
        args.putCharSequence(
            AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, current.dropLast(1))
        return node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
    }

    private fun findFocused(): AccessibilityNodeInfo? =
        findFocus(AccessibilityNodeInfo.FOCUS_INPUT)

    companion object {
        private const val TAG = "AndrOS.Input"
        @Volatile var instance: InputService? = null
            private set

        val isEnabled: Boolean get() = instance != null
    }
}
