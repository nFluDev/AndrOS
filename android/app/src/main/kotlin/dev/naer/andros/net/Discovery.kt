package dev.naer.andros.net

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.util.Log

/**
 * Telefonu agda duyurur (Bonjour / mDNS).
 *
 * Neden mDNS: Mac tarafinda IP yazmaya gerek kalmasin. macOS'ta Bonjour
 * yerlesik, Android'de NsdManager var; ikisi ayni protokolu konusuyor.
 * Kullanici hicbir sey ayarlamadan telefon Mac'te listede belirir.
 *
 * USB ile baglanti da ayni yoldan yurur: USB baglanti paylasimi acikken
 * Mac'e bir ag arayuzu gelir, telefon o ag uzerinde de gorunur —
 * yani USB hata ayiklama GEREKMEZ.
 */
class Discovery(private val ctx: Context) {

    private val nsd by lazy { ctx.getSystemService(Context.NSD_SERVICE) as NsdManager }
    private var listener: NsdManager.RegistrationListener? = null

    fun advertise(port: Int, deviceName: String, deviceId: String, fingerprint: String) {
        val androidId = android.provider.Settings.Secure.getString(
            ctx.contentResolver, android.provider.Settings.Secure.ANDROID_ID) ?: ""
        stop()
        val info = NsdServiceInfo().apply {
            serviceName = "AndrOS $deviceName"
            serviceType = SERVICE_TYPE
            setPort(port)
            setAttribute("id", deviceId)
            setAttribute("name", deviceName)
            setAttribute("v", "1")
            // Mac bunu adb'den okudugu android_id ile karsilastirip ayni
            // cihazi tek satirda gosteriyor.
            setAttribute("aid", androidId)
            // Parmak izinin ILK 16 baytini duyuruyoruz: Mac boylece daha
            // el sikismadan hangi cihaz oldugunu ayirt edebiliyor.
            setAttribute("fp", fingerprint.replace(":", "").take(32))
        }
        val l = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) {
                Log.i(TAG, "duyuru basladi: ${info.serviceName}")
            }
            override fun onRegistrationFailed(info: NsdServiceInfo, code: Int) {
                Log.w(TAG, "duyuru basarisiz: $code")
            }
            override fun onServiceUnregistered(info: NsdServiceInfo) {}
            override fun onUnregistrationFailed(info: NsdServiceInfo, code: Int) {}
        }
        listener = l
        nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, l)
    }

    fun stop() {
        listener?.let { try { nsd.unregisterService(it) } catch (_: Exception) {} }
        listener = null
    }

    companion object {
        const val SERVICE_TYPE = "_andros._tcp"
        private const val TAG = "AndrOS.Discovery"
    }
}
