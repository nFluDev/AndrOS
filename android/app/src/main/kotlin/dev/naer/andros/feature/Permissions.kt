package dev.naer.andros.feature

import android.content.Context
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat

/**
 * Izin denetimi.
 *
 * Modul izin isteyip alamazsa Mac'e `permission` hatasi ve EKSIK IZNIN
 * ADI donuyor; Mac tarafi bunu gorunce kullaniciyi telefonda izin
 * vermeye yonlendirebiliyor. Sessizce bos liste donmek en kotusu olurdu:
 * kullanici "veri yok" sanardi.
 */
object Permissions {
    fun has(ctx: Context, perm: String): Boolean =
        ContextCompat.checkSelfPermission(ctx, perm) == PackageManager.PERMISSION_GRANTED

    fun missing(ctx: Context, vararg perms: String): String? =
        perms.firstOrNull { !has(ctx, it) }
}
