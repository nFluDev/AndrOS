package dev.naer.andros

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Telefon yeniden basladiginda ya da uygulama guncellendiginde hizmeti
 * geri getirir.
 *
 * Olmadan: kullanicinin her acilistan sonra uygulamayi elle acmasi
 * gerekiyordu; "eslesme kapandiktan sonra da surer" sozu bosa cikiyordu.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            "android.intent.action.QUICKBOOT_POWERON" -> {
                // Kullanici "acilista baslat"i kapatmissa saygi goster.
                val on = SettingsActivity.prefs(ctx)
                    .getBoolean(SettingsActivity.KEY_RUN_AT_BOOT, true)
                if (!on) { Log.i("AndrOS.Boot", "acilista baslatma kapali"); return }
                Log.i("AndrOS.Boot", "hizmet yeniden baslatiliyor: ${intent.action}")
                runCatching { AndrOSService.start(ctx) }
            }
        }
    }
}
