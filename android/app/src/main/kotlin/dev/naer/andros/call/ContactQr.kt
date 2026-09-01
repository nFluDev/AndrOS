package dev.naer.andros.call

import android.graphics.Bitmap
import android.graphics.Color
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel

/**
 * Kisi kartinin QR hali.
 *
 * Bicim olarak MECARD secildi — kendi bicimimizi uydurmadik. Sebep:
 * MECARD'i telefonlarin KENDI kamera uygulamalari taniyor ve "kisiyi
 * kaydet" diye soruyor. Yani karsi tarafta AndrOS olmasa da kart
 * okunuyor. Kendi bicimimiz yalnizca bizim okuyabilecegimiz bir kutu
 * olurdu.
 *
 * Okuma tarafi daha genis: MECARD, vCard, `tel:` ve duz numara da
 * kabul ediliyor, cunku insanlar ellerindeki her QR'i okutmayi deniyor.
 */
object ContactQr {

    fun encode(name: String, number: String): String {
        // MECARD'da `\`, `;`, `:` ve `,` kacisli yazilmali.
        fun esc(s: String) = s.replace("\\", "\\\\").replace(";", "\\;")
            .replace(":", "\\:").replace(",", "\\,")
        // Addaki virgul BOSLUGA ceviriliyor. MECARD'da `N:` alani
        // "Soyad,Ad" demek; kacisli yazsak bile okuyan taraf (baska
        // uygulamalar dahil) ayirmayi deneyip adi ters ceviriyor.
        val sb = StringBuilder("MECARD:")
        if (name.isNotBlank()) sb.append("N:").append(esc(name.replace(',', ' '))).append(';')
        if (number.isNotBlank()) sb.append("TEL:").append(esc(number)).append(';')
        return sb.append(';').toString()
    }

    fun bitmap(text: String, size: Int): Bitmap? = try {
        val hints = mapOf(
            EncodeHintType.ERROR_CORRECTION to ErrorCorrectionLevel.M,
            EncodeHintType.MARGIN to 1,
            EncodeHintType.CHARACTER_SET to "UTF-8")
        val m = QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, size, size, hints)
        val bmp = Bitmap.createBitmap(m.width, m.height, Bitmap.Config.ARGB_8888)
        for (y in 0 until m.height) for (x in 0 until m.width) {
            bmp.setPixel(x, y, if (m[x, y]) Color.BLACK else Color.WHITE)
        }
        bmp
    } catch (e: Throwable) { null }

    data class Card(val name: String, val number: String)

    fun parse(raw: String): Card? {
        val text = raw.trim()
        if (text.isEmpty()) return null

        if (text.startsWith("MECARD:", true)) return parseMecard(text)
        if (text.startsWith("BEGIN:VCARD", true)) return parseVCard(text)
        if (text.startsWith("tel:", true)) return Card("", text.substring(4).trim())
        // Duz numara: rakam, bosluk, +, -, parantez disinda bir sey yoksa.
        if (text.all { it.isDigit() || it in " +-()" } && text.count(Char::isDigit) >= 5) {
            return Card("", text.filter { it.isDigit() || it == '+' })
        }
        return null
    }

    private fun parseMecard(text: String): Card? {
        val body = text.substring(7)
        var name = ""
        var tel = ""
        // Kacisli `;` alan sonu DEGIL: elle geziyoruz.
        val fields = ArrayList<String>()
        val cur = StringBuilder()
        var i = 0
        while (i < body.length) {
            val c = body[i]
            if (c == '\\' && i + 1 < body.length) { cur.append(body[i + 1]); i += 2; continue }
            if (c == ';') { fields.add(cur.toString()); cur.setLength(0); i++; continue }
            cur.append(c); i++
        }
        if (cur.isNotEmpty()) fields.add(cur.toString())
        for (f in fields) {
            val cut = f.indexOf(':')
            if (cut <= 0) continue
            val key = f.substring(0, cut).uppercase()
            val value = f.substring(cut + 1)
            when (key) {
                // MECARD adi "Soyad,Ad" olarak yazabiliyor.
                "N" -> name = value.split(',').filter { it.isNotBlank() }
                    .reversed().joinToString(" ").trim()
                "TEL" -> if (tel.isBlank()) tel = value.trim()
            }
        }
        return if (name.isBlank() && tel.isBlank()) null else Card(name, tel)
    }

    private fun parseVCard(text: String): Card? {
        var name = ""
        var tel = ""
        for (line in text.lines()) {
            val cut = line.indexOf(':')
            if (cut <= 0) continue
            val key = line.substring(0, cut).uppercase()
            val value = line.substring(cut + 1).trim()
            when {
                key == "FN" -> name = value
                key.startsWith("N") && name.isBlank() ->
                    name = value.split(';').filter { it.isNotBlank() }
                        .reversed().joinToString(" ").trim()
                key.startsWith("TEL") && tel.isBlank() -> tel = value
            }
        }
        return if (name.isBlank() && tel.isBlank()) null else Card(name, tel)
    }
}
