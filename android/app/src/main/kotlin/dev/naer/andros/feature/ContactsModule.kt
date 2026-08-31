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
        return Reply.ok(id, JSONObject().put("contacts", out))
    }
}
