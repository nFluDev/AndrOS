package dev.naer.andros.feature

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.Build
import android.os.Environment
import android.os.StatFs
import org.json.JSONObject

/** Cihaz ozeti — Mac'teki Cihazlar kategorisini besler. */
class DeviceModule(private val ctx: Context) {

    fun info(): JSONObject {
        val stat = StatFs(Environment.getDataDirectory().path)
        return JSONObject()
            .put("model", Build.MODEL)
            .put("manufacturer", Build.MANUFACTURER)
            .put("device", Build.DEVICE)
            .put("android", Build.VERSION.RELEASE)
            .put("sdk", Build.VERSION.SDK_INT)
            .put("board", Build.BOARD)
            .put("androidId", android.provider.Settings.Secure.getString(
                ctx.contentResolver, android.provider.Settings.Secure.ANDROID_ID) ?: "")
            .put("storageTotal", stat.totalBytes)
            .put("storageFree", stat.availableBytes)
    }

    fun battery(): JSONObject {
        val bm = ctx.getSystemService(Context.BATTERY_SERVICE) as BatteryManager
        val status = ctx.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val temp = status?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, -1) ?: -1
        return JSONObject()
            .put("level", bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY))
            .put("charging", bm.isCharging)
            // Android onda birlik derece veriyor.
            .put("temperature", if (temp > 0) temp / 10.0 else JSONObject.NULL)
    }
}
