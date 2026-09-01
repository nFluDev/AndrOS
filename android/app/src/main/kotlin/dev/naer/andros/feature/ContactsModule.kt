package dev.naer.andros.feature

import android.Manifest
import android.content.Context
import android.provider.ContactsContract
import dev.naer.andros.net.Reply
import org.json.JSONArray
import org.json.JSONObject

class ContactsModule(private val ctx: Context) {

    fun list(id: Int, limit: Int): JSONObject {
        Permissions.missing(ctx, Manifest.permission.READ_CONTACTS)?.let {
            return Reply.err(id, "permission", it)
        }
        val out = JSONArray()
        val proj = arrayOf(
            ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
            ContactsContract.CommonDataKinds.Phone.NUMBER,
            ContactsContract.CommonDataKinds.Phone.PHOTO_URI,
            ContactsContract.CommonDataKinds.Phone.CONTACT_ID)
        ctx.contentResolver.query(
            ContactsContract.CommonDataKinds.Phone.CONTENT_URI, proj, null, null,
            // NOT: "COLLATE LOCALIZED" KULLANILMIYOR. Android 11'den
            // beri saglayici siralama ifadesini denetliyor ve bu cihazda
            // (ColorOS) reddediyor: "Invalid token LOCALIZED". Atilan
            // JSONException/SQLException isteği degil, o ana kadar TUM
            // BAGLANTIYI dusuruyordu — muzik acilinca aramalar da
            // kayboluyordu. Siralamayi Mac tarafi zaten yapiyor.
            "${ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME} ASC")
            ?.use { c ->
                // Ayni kisinin birden fazla numarasi ayri satir geliyor;
                // isim+numara ciftini tekillestiriyoruz.
                val seen = HashSet<String>()
                var n = 0
                while (c.moveToNext() && n < limit) {
                    val name = c.getString(0) ?: continue
                    val number = (c.getString(1) ?: "").replace(" ", "")
                    if (!seen.add("$name|$number")) continue
                    out.put(JSONObject()
                        .put("name", name)
                        .put("number", number)
                        .put("photo", c.getString(2) ?: JSONObject.NULL)
                        .put("contactId", c.getLong(3)))
                    n++
                }
            }
        return Reply.ok(id, JSONObject().put("contacts", out).put("me", me()))
    }

    /**
     * "Bu telefon": kullanicinin KENDI adi ve numarasi.
     *
     * Telefonun rehberi bunu en ustte ayri gosteriyor, biz de
     * gosterelim. Tek bir kaynak yok, uc yere birden bakiyoruz:
     *   1. Rehberdeki "Ben" profili — ad ve numara icin en dogrusu,
     *      ama cogu telefonda bos.
     *   2. SIM kartin kayitli numarasi — operator yazmissa dolu, cok
     *      SIM'li telefonlarda ilki.
     *   3. Eski `line1Number` — genelde bos doner, yine de deneriz.
     * Hicbiri yoksa `null` doneriz; Mac o zaman satiri hic gostermiyor.
     * Numara BULUNAMAMASI normal: Turkiye'de operatorlerin cogu SIM'e
     * numara yazmiyor.
     */
    private fun me(): Any {
        var name = ""
        var number = ""

        runCatching {
            ctx.contentResolver.query(
                ContactsContract.Profile.CONTENT_URI,
                arrayOf(ContactsContract.Profile.DISPLAY_NAME), null, null, null)
                ?.use { if (it.moveToFirst()) name = it.getString(0) ?: "" }
        }
        runCatching {
            val uri = android.net.Uri.withAppendedPath(
                ContactsContract.Profile.CONTENT_URI,
                ContactsContract.Contacts.Data.CONTENT_DIRECTORY)
            ctx.contentResolver.query(uri,
                arrayOf(ContactsContract.CommonDataKinds.Phone.NUMBER),
                "${ContactsContract.Data.MIMETYPE} = ?",
                arrayOf(ContactsContract.CommonDataKinds.Phone.CONTENT_ITEM_TYPE), null)
                ?.use { if (it.moveToFirst()) number = it.getString(0) ?: "" }
        }

        if (number.isBlank()) runCatching {
            val sm = ctx.getSystemService(Context.TELEPHONY_SUBSCRIPTION_SERVICE)
                as android.telephony.SubscriptionManager
            @Suppress("MissingPermission")
            val list = sm.activeSubscriptionInfoList
            val sub = list?.firstOrNull { !it.number.isNullOrBlank() }
            if (sub != null) {
                number = sub.number ?: ""
                if (name.isBlank()) name = sub.displayName?.toString() ?: ""
            }
        }
        if (number.isBlank()) runCatching {
            val tm = ctx.getSystemService(Context.TELEPHONY_SERVICE)
                as android.telephony.TelephonyManager
            @Suppress("MissingPermission", "DEPRECATION")
            number = tm.line1Number ?: ""
        }

        if (name.isBlank() && number.isBlank()) return JSONObject.NULL
        return JSONObject().put("name", name).put("number", number.replace(" ", ""))
    }
}
