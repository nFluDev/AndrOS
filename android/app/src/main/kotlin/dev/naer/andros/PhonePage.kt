package dev.naer.andros

import android.Manifest
import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.net.Uri
import android.text.Editable
import android.text.TextWatcher
import android.view.LayoutInflater
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.EditText
import android.widget.GridLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.app.ActivityCompat
import dev.naer.andros.feature.ContactsWriter
import dev.naer.andros.feature.Permissions
import kotlin.math.abs

/**
 * "Telefon" sekmesi: tus takimi ve rehber.
 *
 * Su an aramayi ve mesaji TELEFONUN KENDI HATTI yapiyor — internet
 * uzerinden arama ayri bir katman ve o gelene kadar bu ekran zaten
 * calisiyor olmali. Rehber telefonun kendi rehberi: ayri bir kopya
 * TUTMUYORUZ, cunku iki liste er ya da gec ayrisiyor. Eklenen kisi
 * telefonun rehberine yaziliyor, oradan da Mac'e ve varsa Google
 * hesabina kendiliginden gidiyor.
 */
class PhonePage(private val activity: Activity, private val root: View) {

    private val keypadBox: LinearLayout = root.findViewById(R.id.keypadBox)
    private val contactsBox: LinearLayout = root.findViewById(R.id.contactsBox)
    private val modeToggle: TextView = root.findViewById(R.id.phoneModeToggle)
    private val dialField: EditText = root.findViewById(R.id.dialField)
    private val dialMatch: TextView = root.findViewById(R.id.dialMatch)
    private val keypad: GridLayout = root.findViewById(R.id.keypad)
    private val contactList: LinearLayout = root.findViewById(R.id.contactList)
    private val contactSearch: EditText = root.findViewById(R.id.contactSearch)

    private data class Row(val id: Long, val name: String, val number: String)
    private var contacts: List<Row> = emptyList()
    private var showingContacts = false

    init {
        buildKeypad()
        modeToggle.setOnClickListener { setMode(!showingContacts) }
        root.findViewById<Button>(R.id.dialCall).setOnClickListener { call(dialField.text.toString()) }
        root.findViewById<Button>(R.id.dialMessage).setOnClickListener { message(dialField.text.toString()) }
        root.findViewById<Button>(R.id.dialSave).setOnClickListener {
            editDialog(null, "", dialField.text.toString())
        }
        root.findViewById<Button>(R.id.addContact).setOnClickListener { editDialog(null, "", "") }

        // Numara yazarken rehberde ARA: telefonun kendi tus takimi da
        // boyle davraniyor ve numarayi ezberlemek gerekmiyor.
        dialField.addTextChangedListener(simpleWatcher { showMatch() })
        contactSearch.addTextChangedListener(simpleWatcher { renderContacts() })
        setMode(false)
    }

    fun refresh() {
        contacts = loadContacts()
        renderContacts()
        showMatch()
    }

    private fun setMode(contactsMode: Boolean) {
        showingContacts = contactsMode
        keypadBox.visibility = if (contactsMode) View.GONE else View.VISIBLE
        contactsBox.visibility = if (contactsMode) View.VISIBLE else View.GONE
        modeToggle.setText(if (contactsMode) R.string.keypad else R.string.contacts)
        if (contactsMode) refresh()
    }

    // MARK: - Tus takimi

    private fun buildKeypad() {
        val keys = listOf("1" to "", "2" to "ABC", "3" to "DEF",
                          "4" to "GHI", "5" to "JKL", "6" to "MNO",
                          "7" to "PQRS", "8" to "TUV", "9" to "WXYZ",
                          "*" to "", "0" to "+", "#" to "")
        keypad.removeAllViews()
        for ((digit, letters) in keys) {
            val cell = LinearLayout(activity).apply {
                orientation = LinearLayout.VERTICAL
                gravity = android.view.Gravity.CENTER
                setBackgroundResource(R.drawable.ripple_soft)
            }
            cell.addView(TextView(activity).apply {
                text = digit
                textSize = 24f
                setTextColor(activity.getColor(R.color.text))
                gravity = android.view.Gravity.CENTER
            })
            if (letters.isNotEmpty()) {
                cell.addView(TextView(activity).apply {
                    text = letters
                    textSize = 10f
                    setTextColor(activity.getColor(R.color.text_dim))
                    gravity = android.view.Gravity.CENTER
                })
            }
            val lp = GridLayout.LayoutParams().apply {
                width = 0; height = 0
                columnSpec = GridLayout.spec(GridLayout.UNDEFINED, 1f)
                rowSpec = GridLayout.spec(GridLayout.UNDEFINED, 1f)
                setMargins(4, 4, 4, 4)
            }
            cell.layoutParams = lp
            cell.setOnClickListener { dialField.append(digit) }
            // "0"a basili tutmak "+" yaziyor — uluslararasi numara icin.
            if (digit == "0") cell.setOnLongClickListener {
                dialField.append("+"); true
            }
            keypad.addView(cell)
        }
    }

    /// Yazilan numara rehberde kime denk geliyor?
    private fun showMatch() {
        val typed = dialField.text.toString().filter { it.isDigit() }
        if (typed.length < 3) { dialMatch.text = ""; return }
        if (contacts.isEmpty()) contacts = loadContacts()
        val hit = contacts.firstOrNull { it.number.filter(Char::isDigit).endsWith(typed) }
        dialMatch.text = hit?.name ?: ""
    }

    // MARK: - Rehber

    private fun loadContacts(): List<Row> {
        if (Permissions.missing(activity, Manifest.permission.READ_CONTACTS) != null) {
            ActivityCompat.requestPermissions(
                activity, arrayOf(Manifest.permission.READ_CONTACTS), 3)
            return emptyList()
        }
        val out = ArrayList<Row>()
        val proj = arrayOf(
            android.provider.ContactsContract.CommonDataKinds.Phone.CONTACT_ID,
            android.provider.ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
            android.provider.ContactsContract.CommonDataKinds.Phone.NUMBER)
        runCatching {
            activity.contentResolver.query(
                android.provider.ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
                proj, null, null, null)?.use { c ->
                val seen = HashSet<String>()
                while (c.moveToNext()) {
                    val name = c.getString(1) ?: continue
                    val num = (c.getString(2) ?: "").replace(" ", "")
                    if (!seen.add("$name|$num")) continue
                    out.add(Row(c.getLong(0), name, num))
                }
            }
        }
        return out.sortedBy { it.name.lowercase() }
    }

    private fun renderContacts() {
        val q = contactSearch.text.toString().trim().lowercase()
        val shown = if (q.isEmpty()) contacts
                    else contacts.filter {
                        it.name.lowercase().contains(q) || it.number.contains(q)
                    }
        contactList.removeAllViews()
        for (r in shown.take(500)) contactList.addView(contactRow(r))
        if (shown.isEmpty()) {
            contactList.addView(TextView(activity).apply {
                text = if (contacts.isEmpty()) "Rehber boş ya da izin verilmedi."
                       else "Eşleşen kişi yok."
                setTextColor(activity.getColor(R.color.text_dim))
                textSize = 13f
                setPadding(12, 24, 12, 24)
            })
        }
    }

    private fun contactRow(r: Row): View {
        val v = LayoutInflater.from(activity)
            .inflate(R.layout.contact_row, contactList, false)
        v.findViewById<TextView>(R.id.rowName).text = r.name
        v.findViewById<TextView>(R.id.rowNumber).text = r.number
        v.findViewById<TextView>(R.id.rowHint).setText(R.string.swipe_hint)
        // SOLA kaydir: mesaj · SAGA kaydir: ara. Mac tarafindaki
        // Aramalar/Kisiler panelleriyle ayni jest — iki uygulama ayni
        // dili konussun.
        v.setOnTouchListener(object : View.OnTouchListener {
            var startX = 0f
            override fun onTouch(view: View, e: MotionEvent): Boolean {
                when (e.action) {
                    MotionEvent.ACTION_DOWN -> startX = e.x
                    MotionEvent.ACTION_UP -> {
                        val dx = e.x - startX
                        when {
                            dx > 120 -> call(r.number)
                            dx < -120 -> message(r.number)
                            abs(dx) < 12 -> editDialog(r.id, r.name, r.number)
                        }
                        view.performClick()
                    }
                }
                return true
            }
        })
        return v
    }

    /// Ekleme ve duzenleme AYNI kutu: alanlar ayni, tek fark kaydetme.
    private fun editDialog(id: Long?, name: String, number: String) {
        val box = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(56, 24, 56, 8)
        }
        val nameField = EditText(activity).apply {
            setHint(R.string.contact_name)
            setText(name)
            inputType = android.text.InputType.TYPE_TEXT_FLAG_CAP_WORDS
        }
        val numField = EditText(activity).apply {
            setHint(R.string.number)
            setText(number)
            inputType = android.text.InputType.TYPE_CLASS_PHONE
        }
        box.addView(nameField)
        box.addView(numField)

        val b = AlertDialog.Builder(activity)
            .setTitle(if (id == null) R.string.add_contact else R.string.edit)
            .setView(box)
            .setPositiveButton(R.string.save) { _, _ ->
                val n = nameField.text.toString().trim()
                val num = numField.text.toString().trim()
                if (Permissions.missing(activity, Manifest.permission.WRITE_CONTACTS) != null) {
                    ActivityCompat.requestPermissions(
                        activity, arrayOf(Manifest.permission.WRITE_CONTACTS), 4)
                    return@setPositiveButton
                }
                val ok = if (id == null) ContactsWriter.add(activity, n, num) != null
                         else ContactsWriter.update(activity, id, n, num)
                toast(if (ok) "Kaydedildi." else "Kaydedilemedi.")
                refresh()
            }
            .setNegativeButton(R.string.cancel, null)
        if (id != null) {
            b.setNeutralButton(R.string.delete) { _, _ ->
                AlertDialog.Builder(activity)
                    .setTitle("“$name” silinsin mi?")
                    .setMessage("Kişi telefonun rehberinden kalkar.")
                    .setPositiveButton(R.string.delete) { _, _ ->
                        toast(if (ContactsWriter.delete(activity, id)) "Silindi."
                              else "Silinemedi.")
                        refresh()
                    }
                    .setNegativeButton(R.string.cancel, null)
                    .show()
            }
        }
        b.show()
    }

    // MARK: - Arama ve mesaj

    private fun call(number: String) {
        val n = number.trim()
        if (n.isBlank()) return
        val direct = Permissions.has(activity, Manifest.permission.CALL_PHONE)
        val action = if (direct) Intent.ACTION_CALL else Intent.ACTION_DIAL
        runCatching {
            activity.startActivity(Intent(action, Uri.fromParts("tel", n, null)))
        }.onFailure { toast("Arama başlatılamadı.") }
    }

    private fun message(number: String) {
        val n = number.trim()
        if (n.isBlank()) return
        runCatching {
            activity.startActivity(Intent(Intent.ACTION_SENDTO, Uri.parse("smsto:$n")))
        }.onFailure { toast("Mesaj uygulaması açılamadı.") }
    }

    private fun toast(s: String) =
        android.widget.Toast.makeText(activity, s, android.widget.Toast.LENGTH_SHORT).show()

    private fun simpleWatcher(onChange: () -> Unit) = object : TextWatcher {
        override fun afterTextChanged(s: Editable?) = onChange()
        override fun beforeTextChanged(c: CharSequence?, a: Int, b: Int, d: Int) {}
        override fun onTextChanged(c: CharSequence?, a: Int, b: Int, d: Int) {}
    }
}
