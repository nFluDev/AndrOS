package dev.naer.andros.feature

import android.content.Context
import android.os.Environment
import dev.naer.andros.net.Frame
import dev.naer.andros.net.Reply
import org.json.JSONArray
import org.json.JSONObject
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File

/**
 * Dosya gezgini ve aktarim.
 *
 * Icerik IKILI cerceve olarak akiyor: once JSON basligi (boyut, ad),
 * sonra 256 KB'lik bloklar. Base64'e cevirmek 4/3 sisme ve fazladan
 * kopya demekti; buyuk dosyalarda ikisi de gozle gorulur.
 *
 * Yol kontrolu: istekler paylasilan depolamanin DISINA cikamiyor.
 * Aksi halde uygulamanin kendi ozel verisi de okunabilir olurdu.
 */
class FilesModule(private val ctx: Context) {

    private val roots: List<File> = listOfNotNull(
        Environment.getExternalStorageDirectory(),
    )

    private fun resolve(path: String): File? {
        val f = File(if (path.isEmpty()) roots.first().path else path).canonicalFile
        // ".." ile yukari cikilamasin.
        return if (roots.any { f.path == it.canonicalPath || f.path.startsWith(it.canonicalPath + "/") }) f
               else null
    }

    fun list(id: Int, path: String): JSONObject {
        val dir = resolve(path) ?: return Reply.err(id, "denied", "Bu klasör dışarıda")
        if (!dir.isDirectory) return Reply.err(id, "notdir", "Klasör değil")
        val out = JSONArray()
        dir.listFiles()?.sortedWith(
            compareByDescending<File> { it.isDirectory }
                .thenBy { it.name.lowercase() })?.forEach { f ->
            out.put(JSONObject()
                .put("name", f.name)
                .put("path", f.path)
                .put("dir", f.isDirectory)
                .put("size", if (f.isDirectory) 0L else f.length())
                .put("modified", f.lastModified()))
        }
        return Reply.ok(id, JSONObject().put("path", dir.path).put("entries", out))
    }

    /** Dosyayi ikili cerceveler halinde akitir; JSON yaniti kendisi yazar. */
    fun read(id: Int, path: String, out: DataOutputStream): JSONObject? {
        val f = resolve(path) ?: return Reply.err(id, "denied", "Bu dosya dışarıda")
        if (!f.isFile) return Reply.err(id, "notfound", "Dosya yok")
        Frame.writeJson(out, Reply.ok(id, JSONObject()
            .put("streaming", true).put("size", f.length()).put("name", f.name)))
        val buf = ByteArray(256 * 1024)
        f.inputStream().use { input ->
            while (true) {
                val n = input.read(buf)
                if (n <= 0) break
                Frame.writeBlob(out, id, buf, 0, n)
            }
        }
        // Bos blok = akis bitti.
        Frame.writeBlob(out, id, ByteArray(0), 0, 0)
        return null
    }

    /**
     * Mac'ten dosya alir.
     *
     * Akis `read`in tersi: Mac once bu istegi yolluyor, sonra 256 KB'lik
     * ikili bloklar geliyor; bos blok "bitti" demek. Bloklari BURADAN
     * okuyoruz, cunku okuma dongusu bu istegi sirali (STREAMING)
     * isliyor ve arada baska cerceve giremiyor.
     */
    fun write(id: Int, path: String, input: DataInputStream): JSONObject {
        val f = resolve(path) ?: return Reply.err(id, "denied", "Bu yol dışarıda")
        f.parentFile?.mkdirs()
        var written = 0L
        try {
            f.outputStream().use { out ->
                while (true) {
                    val msg = Frame.read(input)
                    if (msg.type != Frame.BLOB) continue
                    // Ilk 4 bayt istek kimligi.
                    if (msg.body.size <= 4) break          // bos blok = bitti
                    out.write(msg.body, 4, msg.body.size - 4)
                    written += msg.body.size - 4
                }
            }
        } catch (e: Throwable) {
            runCatching { f.delete() }
            return Reply.err(id, "failed", e.message ?: "yazılamadı")
        }
        // Galeri/muzik uygulamalari yeni dosyayi gorsun.
        runCatching {
            android.media.MediaScannerConnection.scanFile(
                ctx, arrayOf(f.path), null, null)
        }
        return Reply.ok(id, JSONObject().put("written", written))
    }

    fun mkdir(id: Int, path: String): JSONObject {
        val f = resolve(path) ?: return Reply.err(id, "denied", "Bu yol dışarıda")
        return if (f.mkdirs() || f.isDirectory) Reply.ok(id)
               else Reply.err(id, "failed", "Klasör oluşturulamadı")
    }

    fun delete(id: Int, path: String): JSONObject {
        val f = resolve(path) ?: return Reply.err(id, "denied", "Bu yol dışarıda")
        return if (f.deleteRecursively()) Reply.ok(id)
               else Reply.err(id, "failed", "Silinemedi")
    }

    fun move(id: Int, from: String, to: String): JSONObject {
        val a = resolve(from) ?: return Reply.err(id, "denied", "Kaynak dışarıda")
        val b = resolve(to) ?: return Reply.err(id, "denied", "Hedef dışarıda")
        return if (a.renameTo(b)) Reply.ok(id) else Reply.err(id, "failed", "Taşınamadı")
    }
}
