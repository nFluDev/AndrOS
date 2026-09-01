package dev.naer.andros.feature

import android.content.ContentProviderOperation
import android.content.Context
import android.provider.ContactsContract
import android.util.Log

/**
 * Rehbere YAZMA: kisi ekle, duzenle, sil.
 *
 * Okuma tarafi `ContactsModule`'da. Yazma ayri duruyor cunku
 * `ContactsContract` yazarken toplu islem (`applyBatch`) istiyor: bir
 * kisi tek satir degil, "ham kisi" + ad satiri + numara satiri.
 *
 * Kaydi HANGI hesaba yazdigimiz onemli: hesap verilmezse kisi
 * "yalniz bu telefonda" olarak kaydediliyor ve Google hesabina
 * senkronlanmiyor. Kullanicinin telefonunda ne varsa ona uyuyoruz —
 * bulamazsak yerel kayit.
 */
object ContactsWriter {

    private const val TAG = "AndrOS.ContactsW"
    private const val AUTH = ContactsContract.AUTHORITY

    /** Yeni kisi. Basarili olursa ham kisi kimligi doner. */
    fun add(ctx: Context, name: String, number: String): Long? {
        if (name.isBlank() && number.isBlank()) return null
        val (type, account) = defaultAccount(ctx)
        val ops = arrayListOf<ContentProviderOperation>()
        ops.add(ContentProviderOperation
            .newInsert(ContactsContract.RawContacts.CONTENT_URI)
            .withValue(ContactsContract.RawContacts.ACCOUNT_TYPE, type)
            .withValue(ContactsContract.RawContacts.ACCOUNT_NAME, account)
            .build())
        if (name.isNotBlank()) {
            ops.add(ContentProviderOperation
                .newInsert(ContactsContract.Data.CONTENT_URI)
                .withValueBackReference(ContactsContract.Data.RAW_CONTACT_ID, 0)
                .withValue(ContactsContract.Data.MIMETYPE,
                           ContactsContract.CommonDataKinds.StructuredName.CONTENT_ITEM_TYPE)
                .withValue(ContactsContract.CommonDataKinds.StructuredName.DISPLAY_NAME, name)
                .build())
        }
        if (number.isNotBlank()) {
            ops.add(ContentProviderOperation
                .newInsert(ContactsContract.Data.CONTENT_URI)
                .withValueBackReference(ContactsContract.Data.RAW_CONTACT_ID, 0)
                .withValue(ContactsContract.Data.MIMETYPE,
                           ContactsContract.CommonDataKinds.Phone.CONTENT_ITEM_TYPE)
                .withValue(ContactsContract.CommonDataKinds.Phone.NUMBER, number)
                .withValue(ContactsContract.CommonDataKinds.Phone.TYPE,
                           ContactsContract.CommonDataKinds.Phone.TYPE_MOBILE)
                .build())
        }
        return try {
            val r = ctx.contentResolver.applyBatch(AUTH, ops)
            r.firstOrNull()?.uri?.lastPathSegment?.toLongOrNull()
        } catch (e: Throwable) {
            Log.w(TAG, "kisi eklenemedi: ${e.message}"); null
        }
    }

    /** Adi ve numarayi gunceller. */
    fun update(ctx: Context, contactId: Long, name: String, number: String): Boolean {
        val ops = arrayListOf<ContentProviderOperation>()
        if (name.isNotBlank()) {
            ops.add(ContentProviderOperation
                .newUpdate(ContactsContract.Data.CONTENT_URI)
                .withSelection("${ContactsContract.Data.CONTACT_ID}=? AND " +
                               "${ContactsContract.Data.MIMETYPE}=?",
                    arrayOf(contactId.toString(),
                            ContactsContract.CommonDataKinds.StructuredName.CONTENT_ITEM_TYPE))
                .withValue(ContactsContract.CommonDataKinds.StructuredName.DISPLAY_NAME, name)
                .build())
        }
        if (number.isNotBlank()) {
            ops.add(ContentProviderOperation
                .newUpdate(ContactsContract.Data.CONTENT_URI)
                .withSelection("${ContactsContract.Data.CONTACT_ID}=? AND " +
                               "${ContactsContract.Data.MIMETYPE}=?",
                    arrayOf(contactId.toString(),
                            ContactsContract.CommonDataKinds.Phone.CONTENT_ITEM_TYPE))
                .withValue(ContactsContract.CommonDataKinds.Phone.NUMBER, number)
                .build())
        }
        if (ops.isEmpty()) return false
        return try {
            ctx.contentResolver.applyBatch(AUTH, ops); true
        } catch (e: Throwable) {
            Log.w(TAG, "kisi guncellenemedi: ${e.message}"); false
        }
    }

    /**
     * Kisiyi siler.
     *
     * `Contacts` uzerinden siliyoruz, `RawContacts` uzerinden degil:
     * bir kisi birden fazla hesapta birlestirilmis olabiliyor ve tek ham
     * kaydi silmek kisiyi listede birakiyor.
     */
    fun delete(ctx: Context, contactId: Long): Boolean = try {
        val uri = android.content.ContentUris.withAppendedId(
            ContactsContract.Contacts.CONTENT_URI, contactId)
        ctx.contentResolver.delete(uri, null, null) > 0
    } catch (e: Throwable) {
        Log.w(TAG, "kisi silinemedi: ${e.message}"); false
    }

    /// Kisilerin cogunlukla yazildigi hesap. Yoksa yerel kayit.
    private fun defaultAccount(ctx: Context): Pair<String?, String?> {
        return try {
            ctx.contentResolver.query(ContactsContract.RawContacts.CONTENT_URI,
                arrayOf(ContactsContract.RawContacts.ACCOUNT_TYPE,
                        ContactsContract.RawContacts.ACCOUNT_NAME),
                "${ContactsContract.RawContacts.ACCOUNT_TYPE} IS NOT NULL", null, null)
                ?.use { c ->
                    val tally = HashMap<Pair<String?, String?>, Int>()
                    var n = 0
                    while (c.moveToNext() && n < 500) {
                        val k = c.getString(0) to c.getString(1)
                        tally[k] = (tally[k] ?: 0) + 1
                        n++
                    }
                    tally.maxByOrNull { it.value }?.key ?: (null to null)
                } ?: (null to null)
        } catch (e: Throwable) { null to null }
    }
}
