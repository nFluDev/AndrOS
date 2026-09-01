package dev.naer.andros.feature

import android.content.Context
import android.graphics.Bitmap
import android.provider.MediaStore
import android.util.Size
import dev.naer.andros.net.Reply
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream

/**
 * Resim, video ve muzik listesi + kucuk resimler.
 *
 * Kucuk resim `loadThumbnail` ile ureti1iyor: dosyanin tamamini
 * indirmeye gerek kalmiyor. adb yolunda kucuk resmi olmayan videolar
 * icin saglayici hata METNI donuyordu (olculdu: 644 bayt) — burada
 * boyle bir tuzak yok, uretemezse duzgun bir hata donuyor.
 */
class MediaModule(private val ctx: Context) {

    fun images(id: Int, limit: Int) = query(id, "images", limit)
    fun videos(id: Int, limit: Int) = query(id, "videos", limit)

    private fun query(id: Int, kind: String, limit: Int): JSONObject {
        val uri = if (kind == "videos") MediaStore.Video.Media.EXTERNAL_CONTENT_URI
                  else MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        // MUTLAK yol donduruyoruz. `RELATIVE_PATH` "DCIM/Camera/" gibi
        // geliyor; Mac tarafi onu dosya yolu sanip cekmeye calisinca
        // basarisiz oluyordu (kucuk resim de goruntuleyici de bozuktu).
        val proj = if (kind == "videos")
            arrayOf(MediaStore.Video.Media._ID, MediaStore.Video.Media.DISPLAY_NAME,
                    MediaStore.Video.Media.SIZE, MediaStore.Video.Media.DATE_MODIFIED,
                    MediaStore.Video.Media.DURATION, MediaStore.Video.Media.DATA)
        else
            arrayOf(MediaStore.Images.Media._ID, MediaStore.Images.Media.DISPLAY_NAME,
                    MediaStore.Images.Media.SIZE, MediaStore.Images.Media.DATE_MODIFIED,
                    MediaStore.Images.Media.WIDTH, MediaStore.Images.Media.DATA)
        val out = JSONArray()
        ctx.contentResolver.query(uri, proj, null, null,
            "${MediaStore.MediaColumns.DATE_MODIFIED} DESC")?.use { c ->
            var n = 0
            while (c.moveToNext() && n < limit) {
                // Suresi olmayan "video" aslinda video degil: Android MIME
                // turunu yalniz UZANTIYA bakarak atadigi icin .ts uzantili
                // TypeScript dosyalari video sayilip listeye giriyordu.
                if (kind == "videos" && c.getLong(4) <= 0L) continue
                out.put(JSONObject()
                    .put("id", c.getLong(0))
                    .put("name", c.getString(1) ?: "")
                    .put("size", c.getLong(2))
                    .put("date", c.getLong(3))
                    .put("path", c.getString(5) ?: "")
                    .put("video", kind == "videos"))
                n++
            }
        }
        return Reply.ok(id, JSONObject().put("items", out))
    }

    fun thumbnail(id: Int, mediaId: Long, video: Boolean, px: Int): JSONObject {
        return try {
            val uri = if (video)
                MediaStore.Video.Media.EXTERNAL_CONTENT_URI.buildUpon()
                    .appendPath(mediaId.toString()).build()
            else
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI.buildUpon()
                    .appendPath(mediaId.toString()).build()
            val bmp: Bitmap = ctx.contentResolver.loadThumbnail(uri, Size(px, px), null)
            val bos = ByteArrayOutputStream()
            bmp.compress(Bitmap.CompressFormat.JPEG, 85, bos)
            Reply.ok(id, JSONObject().put("jpeg",
                android.util.Base64.encodeToString(bos.toByteArray(),
                                                   android.util.Base64.NO_WRAP)))
        } catch (e: Exception) {
            Reply.err(id, "nothumb", e.message ?: "kucuk resim uretilemedi")
        }
    }

    /**
     * Album kapagi.
     *
     * `albumId` uzerinden album sanatini okuyup JPEG olarak donuyor.
     * adb yolunda bu dosya `content read` ile cekiliyordu; hata
     * ayiklama kapaliyken kapaklar hic gelmiyordu.
     */
    fun albumArt(id: Int, albumId: Long, px: Int): JSONObject {
        return try {
            val uri = android.content.ContentUris.withAppendedId(
                android.net.Uri.parse("content://media/external/audio/albumart"), albumId)
            val bmp = ctx.contentResolver.loadThumbnail(uri, Size(px, px), null)
            val bos = ByteArrayOutputStream()
            bmp.compress(Bitmap.CompressFormat.JPEG, 88, bos)
            Reply.ok(id, JSONObject().put("jpeg",
                android.util.Base64.encodeToString(bos.toByteArray(),
                                                   android.util.Base64.NO_WRAP)))
        } catch (e: Exception) {
            Reply.err(id, "noart", e.message ?: "kapak yok")
        }
    }

    fun tracks(id: Int, limit: Int): JSONObject {
        val out = JSONArray()
        // MUTLAK yol (DATA) SART: Mac dosyayi indirirken bu yolu
        // kullaniyor. Yalnizca DISPLAY_NAME gonderilince telefon
        // "Bu dosya disarida" diyip reddediyordu (olculdu) — galeride
        // duzeltilen ayni hata burada kalmis.
        val proj = arrayOf(MediaStore.Audio.Media._ID, MediaStore.Audio.Media.TITLE,
                           MediaStore.Audio.Media.ARTIST, MediaStore.Audio.Media.ALBUM,
                           MediaStore.Audio.Media.ALBUM_ID, MediaStore.Audio.Media.DURATION,
                           MediaStore.Audio.Media.SIZE, MediaStore.Audio.Media.DISPLAY_NAME,
                           MediaStore.Audio.Media.DATA)
        ctx.contentResolver.query(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, proj,
            "${MediaStore.Audio.Media.IS_MUSIC}!=0", null,
            // NOT: "COLLATE LOCALIZED" KULLANILMIYOR. Android 11'den
            // beri saglayici siralama ifadesini denetliyor ve bu cihazda
            // (ColorOS) reddediyor: "Invalid token LOCALIZED". Atilan
            // JSONException/SQLException isteği degil, o ana kadar TUM
            // BAGLANTIYI dusuruyordu — muzik acilinca aramalar da
            // kayboluyordu. Siralamayi Mac tarafi zaten yapiyor.
            "${MediaStore.Audio.Media.TITLE} ASC")?.use { c ->
            var n = 0
            while (c.moveToNext() && n < limit) {
                out.put(JSONObject()
                    .put("id", c.getLong(0))
                    .put("title", c.getString(1) ?: "")
                    .put("artist", c.getString(2) ?: "")
                    .put("album", c.getString(3) ?: "")
                    .put("albumId", c.getLong(4))
                    .put("duration", c.getLong(5))
                    .put("size", c.getLong(6))
                    .put("name", c.getString(7) ?: "")
                    .put("path", c.getString(8) ?: ""))
                n++
            }
        }
        return Reply.ok(id, JSONObject().put("tracks", out))
    }
}
