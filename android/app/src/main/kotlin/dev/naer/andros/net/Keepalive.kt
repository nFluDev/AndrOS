package dev.naer.andros.net

import android.content.Context
import android.net.wifi.WifiManager
import android.os.PowerManager
import android.util.Log

/**
 * Telefonu Mac icin ULASILABILIR tutar.
 *
 * Android'in guc yonetimi bu projenin en inatci dusmani; ColorOS gibi
 * uretici katmanlari daha da sert. Uc ayri kilit, uc ayri sorunu
 * cozuyor — hepsi gerekli:
 *
 *  - **Multicast kilidi**: Wi-Fi yongasi guc tasarrufunda multicast
 *    paketlerini SUZUYOR. mDNS/Bonjour tam olarak multicast; kilit
 *    olmadan telefon duyurusunu yayinlasa bile Mac goremiyor.
 *    (Olculdu: telefonun 47821 portu acikken `dns-sd -B _andros._tcp`
 *    hicbir sey dondurmedi.)
 *
 *  - **Wi-Fi kilidi (yuksek basarim)**: ekran kapaninca yonga uyku
 *    kipine geciyor; acik TCP baglantisi kopmasa da gecikme saniyelere
 *    ciakiyor ve yeni baglanti istekleri dusuyor.
 *
 *  - **Islemci kilidi**: yalniz BIR ISTEMCI BAGLIYKEN aliniyor.
 *    Surekli tutmak pili bosuna yer; bagliyken birakmak ise Doze
 *    sirasinda isteklerin dakikalarca beklemesine yol aciyor.
 */
class Keepalive(ctx: Context) {

    private val wifi = ctx.applicationContext
        .getSystemService(Context.WIFI_SERVICE) as WifiManager
    private val power = ctx.getSystemService(Context.POWER_SERVICE) as PowerManager

    private val multicast = wifi.createMulticastLock("andros.mdns").apply {
        setReferenceCounted(false)
    }
    private val wifiLock = wifi.createWifiLock(
        WifiManager.WIFI_MODE_FULL_HIGH_PERF, "andros.wifi").apply {
        setReferenceCounted(false)
    }
    private val cpu = power.newWakeLock(
        PowerManager.PARTIAL_WAKE_LOCK, "andros:session").apply {
        setReferenceCounted(false)
    }

    /** Hizmet ayaktayken: ag kilitleri. */
    fun start() {
        runCatching { if (!multicast.isHeld) multicast.acquire() }
        runCatching { if (!wifiLock.isHeld) wifiLock.acquire() }
        Log.i(TAG, "ag kilitleri alindi")
    }

    fun stop() {
        runCatching { if (multicast.isHeld) multicast.release() }
        runCatching { if (wifiLock.isHeld) wifiLock.release() }
        runCatching { if (cpu.isHeld) cpu.release() }
    }

    /** Bagli istemci sayisi degisince: islemci kilidini ac/kapa. */
    fun clients(n: Int) {
        runCatching {
            if (n > 0 && !cpu.isHeld) cpu.acquire()
            else if (n == 0 && cpu.isHeld) cpu.release()
        }
    }

    private companion object { const val TAG = "AndrOS.Keepalive" }
}
