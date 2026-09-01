package dev.naer.andros

import android.Manifest
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.LayoutInflater
import android.view.ViewGroup
import android.widget.*
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import dev.naer.andros.feature.NotificationListener
import dev.naer.andros.feature.InputService
import dev.naer.andros.feature.Permissions
import dev.naer.andros.feature.TrackpadView
import dev.naer.andros.net.Identity
import dev.naer.andros.net.Pairing

/**
 * Altta sekmeler: Ana sayfa · Kumanda · Ayarlar.
 *
 * Ana sayfa baglantiyi yonetiyor; Kumanda telefonu Mac'in dokunmatik
 * yuzeyi yapiyor. Sekmeler AYRI EKRAN ACMIYOR — ayni pencerede sayfa
 * degistiriyor, boylece eslestirme kodu ya da baglanti durumu geciste
 * kaybolmuyor. Tasarim Mac uygulamasiyla ayni dili konusuyor: koyu
 * zemin, yumusak koseli kartlar, yesil vurgu.
 */
class MainActivity : AppCompatActivity() {

    private lateinit var statusPill: TextView
    private lateinit var connectionText: TextView
    private lateinit var pairedText: TextView
    private lateinit var pairHint: TextView
    private lateinit var codeView: TextView
    private lateinit var codeCountdown: ProgressBar
    private var countdownTimer: android.os.CountDownTimer? = null
    private lateinit var toggleButton: Button
    private lateinit var scanButton: Button
    private lateinit var permBox: LinearLayout

    // --- Kumanda sekmesi
    private lateinit var pageHome: android.view.View
    private lateinit var pageControl: android.view.View
    private lateinit var trackpad: TrackpadView
    private lateinit var controlStatus: TextView
    private lateinit var keyInput: EditText
    private val tabs by lazy {
        listOf(findViewById<LinearLayout>(R.id.tabHome),
               findViewById<LinearLayout>(R.id.tabControl),
               findViewById<LinearLayout>(R.id.tabSettings))
    }

    /// Kamerayla QR okuma UYGULAMANIN ICINDE: kullanicinin telefonunda
    /// kamera uygulamasi QR okumuyor, dolayisiyla derin baglantiya
    /// guvenemiyoruz.
    /// Telefonun kendi sesini Mac'e vermek icin ekran yakalama izni.
    /// EKRAN PAYLASILMIYOR — Android ses yakalamayi baska yolla vermiyor.
    private val projectionRequest = registerForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.StartActivityForResult()) { r ->
        val data = r.data
        if (r.resultCode == RESULT_OK && data != null) {
            startService(Intent(this, AndrOSService::class.java)
                .setAction(AndrOSService.ACTION_CAPTURE_ON)
                .putExtra(AndrOSService.EXTRA_CODE, r.resultCode)
                .putExtra(AndrOSService.EXTRA_DATA, data))
            toggleButton.postDelayed({ refresh() }, 600)
        }
    }

    private val scanner = registerForActivityResult(ScanContract()) { result ->
        val text = result.contents ?: return@registerForActivityResult
        handlePairUri(Uri.parse(text))
    }

    override fun onCreate(saved: Bundle?) {
        super.onCreate(saved)
        setTheme(R.style.Theme_AndrOS)
        setContentView(R.layout.activity_main)

        statusPill = findViewById(R.id.statusPill)
        connectionText = findViewById(R.id.connectionText)
        pairedText = findViewById(R.id.pairedText)
        pairHint = findViewById(R.id.pairHint)
        codeView = findViewById(R.id.codeView)
        codeCountdown = findViewById(R.id.codeCountdown)
        toggleButton = findViewById(R.id.toggleButton)
        scanButton = findViewById(R.id.scanButton)
        permBox = findViewById(R.id.permBox)
        setupTabs()

        toggleButton.setOnClickListener {
            if (AndrOSService.running) AndrOSService.stop(this)
            else AndrOSService.start(this, fromForeground = true)
            toggleButton.postDelayed({ refresh() }, 700)
        }
        scanButton.setOnClickListener { startScan() }

        Pairing.listener = { code, client ->
            runOnUiThread {
                if (code != null) {
                    codeView.text = code
                    codeView.visibility = TextView.VISIBLE
                    pairHint.text = "“${client ?: "Mac"}” eşleşmek istiyor.\n" +
                                    "Bu kodu Mac’teki kutuya yaz — ya da QR’ı tara."
                    startCountdown()
                } else {
                    codeView.visibility = TextView.GONE
                    codeCountdown.visibility = ProgressBar.GONE
                    countdownTimer?.cancel()
                    pairHint.setText(R.string.pair_hint)
                    refresh()
                }
            }
        }

        // Hizmeti ON PLANDAN baslat: Android arka plandan baslatilan on
        // plan hizmetine kamera/mikrofon erisimi vermiyor. Zaten
        // calisiyorsa ve arka plandan baslamissa yeniden kuruyoruz —
        // yoksa kamera "policy ile kapali" diye reddediliyor.
        if (!AndrOSService.running) {
            AndrOSService.start(this, fromForeground = true)
        } else if (!AndrOSService.startedFromForeground) {
            AndrOSService.restartFromForeground(this)
        }
        requestCorePermissions()
        maybeCheckForUpdate()
        handlePairUri(intent?.data)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handlePairUri(intent.data)
    }

    override fun onResume() { super.onResume(); refresh() }

    /// Kodun ne kadar gecerli kaldigini %100'den %0'a inen bir cubukla
    /// gosterir — rakamli geri sayimdan daha az dikkat istiyor.
    private fun startCountdown() {
        countdownTimer?.cancel()
        codeCountdown.visibility = ProgressBar.VISIBLE
        countdownTimer = object : android.os.CountDownTimer(Pairing.TTL_MS, 33) {
            override fun onTick(left: Long) {
                codeCountdown.progress = (left * 1000 / Pairing.TTL_MS).toInt()
            }
            override fun onFinish() { codeCountdown.progress = 0 }
        }.start()
    }

    // MARK: - Eslestirme

    private fun startScan() {
        if (!Permissions.has(this, Manifest.permission.CAMERA)) {
            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.CAMERA), 2)
            return
        }
        scanner.launch(ScanOptions().apply {
            setPrompt("Mac ekranındaki QR’ı çerçeveye al")
            setBeepEnabled(false)
            setOrientationLocked(false)
            setDesiredBarcodeFormats(ScanOptions.QR_CODE)
        })
    }

    /** `andros://pair?c=123456&n=MacAdi` */
    private fun handlePairUri(uri: Uri?) {
        if (uri == null || uri.scheme != "andros" || uri.host != "pair") return
        val code = uri.getQueryParameter("c") ?: return
        val who = uri.getQueryParameter("n") ?: "Mac"
        Pairing.preauthorize(code, who)
        Toast.makeText(this, "“$who” ile eşleşiliyor…", Toast.LENGTH_LONG).show()
    }

    // MARK: - Durum

    /// Gunde BIR kez sessiz guncelleme denetimi.
    ///
    /// SESSIZ KURULUM YOK: Android buna izin vermiyor ve vermemeli de.
    /// Yeni surum varsa haber veriyoruz, indirmeyi ve kurulumu
    /// kullanici onayliyor.
    private fun maybeCheckForUpdate() {
        val p = SettingsActivity.prefs(this)
        if (!p.getBoolean(SettingsActivity.KEY_AUTO_UPDATE, true)) return
        val last = p.getLong("lastUpdateCheck", 0L)
        val now = System.currentTimeMillis()
        if (now - last < 24 * 60 * 60 * 1000L) return
        p.edit().putLong("lastUpdateCheck", now).apply()
        Updates.check(this) { r ->
            if (r !is Updates.Result.Available) return@check
            runOnUiThread {
                android.app.AlertDialog.Builder(this)
                    .setTitle("Yeni sürüm: ${r.version}")
                    .setMessage(r.notes.ifBlank { "Değişiklik notu yok." })
                    .setPositiveButton("İndir ve kur") { _, _ ->
                        Installer.downloadAndInstall(this, r.url, r.version)
                    }
                    .setNegativeButton("Şimdi değil", null)
                    .show()
            }
        }
    }

    // MARK: - Sekmeler ve Kumanda

    private fun setupTabs() {
        pageHome = findViewById(R.id.pageHome)
        pageControl = findViewById(R.id.pageControl)
        trackpad = findViewById(R.id.trackpad)
        controlStatus = findViewById(R.id.controlStatus)
        keyInput = findViewById(R.id.keyInput)

        // Girdiler ZATEN ACIK denetim kanalindan gidiyor: yeni soket
        // acmak yeni TLS el sikismasi ve yeni yetkilendirme demekti.
        trackpad.onEvent = { AndrOSService.sendInput(it) }

        findViewById<Button>(R.id.leftClick).setOnClickListener { trackpad.click(false) }
        findViewById<Button>(R.id.rightClick).setOnClickListener { trackpad.click(true) }
        findViewById<Button>(R.id.keyboardButton).setOnClickListener { toggleKeyboard() }

        // Yazilan her harf ANINDA Mac'e gidiyor; kutu birikmiyor.
        // "Gonder" dugmesi beklemek yaziyi gecikmeli hissettiriyordu.
        keyInput.addTextChangedListener(object : android.text.TextWatcher {
            var last = ""
            override fun afterTextChanged(s: android.text.Editable?) {
                val now = s?.toString() ?: ""
                when {
                    now.length > last.length && now.startsWith(last) ->
                        trackpad.text(now.substring(last.length))
                    now.length < last.length ->
                        repeat(last.length - now.length) { trackpad.key("backspace") }
                    now != last -> { // toptan degisti: bastan yaz
                        repeat(last.length) { trackpad.key("backspace") }
                        if (now.isNotEmpty()) trackpad.text(now)
                    }
                }
                last = now
                // Kutu buyumesin: uzun metinde imlec kaymasi olurdu.
                if (now.length > 200) { keyInput.setText(""); last = "" }
            }
            override fun beforeTextChanged(c: CharSequence?, a: Int, b: Int, d: Int) {}
            override fun onTextChanged(c: CharSequence?, a: Int, b: Int, d: Int) {}
        })
        keyInput.setOnEditorActionListener { _, _, _ -> trackpad.key("enter"); true }

        tabs[0].setOnClickListener { showTab(0) }
        tabs[1].setOnClickListener { showTab(1) }
        tabs[2].setOnClickListener { startActivity(Intent(this, SettingsActivity::class.java)) }
        showTab(0)
    }

    private fun showTab(i: Int) {
        pageHome.visibility = if (i == 0) android.view.View.VISIBLE else android.view.View.GONE
        pageControl.visibility = if (i == 1) android.view.View.VISIBLE else android.view.View.GONE
        for ((k, t) in tabs.withIndex()) {
            val active = k == i
            val color = getColor(if (active) R.color.accent else R.color.text_dim)
            (t.getChildAt(0) as ImageView).setColorFilter(color)
            (t.getChildAt(1) as TextView).setTextColor(color)
        }
        if (i == 1) refreshControlStatus() else hideKeyboard()
    }

    private fun refreshControlStatus() {
        val ok = AndrOSService.hasClient
        controlStatus.setText(if (ok) R.string.control_ready else R.string.control_offline)
        controlStatus.setTextColor(getColor(if (ok) R.color.accent else R.color.text_dim))
        trackpad.alpha = if (ok) 1f else 0.45f
    }

    private fun toggleKeyboard() {
        if (keyInput.visibility == android.view.View.VISIBLE) { hideKeyboard(); return }
        keyInput.visibility = android.view.View.VISIBLE
        keyInput.requestFocus()
        val imm = getSystemService(Context.INPUT_METHOD_SERVICE)
            as android.view.inputmethod.InputMethodManager
        imm.showSoftInput(keyInput, android.view.inputmethod.InputMethodManager.SHOW_IMPLICIT)
    }

    private fun hideKeyboard() {
        if (!this::keyInput.isInitialized) return
        keyInput.visibility = android.view.View.GONE
        val imm = getSystemService(Context.INPUT_METHOD_SERVICE)
            as android.view.inputmethod.InputMethodManager
        imm.hideSoftInputFromWindow(keyInput.windowToken, 0)
    }

    private fun refresh() {
        if (this::controlStatus.isInitialized) refreshControlStatus()
        val on = AndrOSService.running
        statusPill.text = if (on) "Açık" else "Kapalı"
        statusPill.setTextColor(getColor(if (on) R.color.accent else R.color.text_dim))
        connectionText.text = if (on)
            "Bu ağdaki Mac’ler bu telefonu görebilir.\nKabloyla da aynı uygulama üzerinden çalışır."
        else "Kapalı — Mac’ler bağlanamaz."
        toggleButton.setText(if (on) R.string.stop else R.string.start)

        val paired = Identity(this).pairedClients()
        pairedText.text = if (paired.isEmpty()) "Henüz eşleşmiş Mac yok."
                          else "Eşleşmiş: " + paired.joinToString(", ") { it.second }
        buildPermissionRows()
    }

    // MARK: - Izinler

    private val corePerms: List<Pair<String, String>> = buildList {
        add(Manifest.permission.READ_SMS to "Mesajları oku")
        add(Manifest.permission.SEND_SMS to "Mesaj gönder")
        add(Manifest.permission.READ_CONTACTS to "Kişiler")
        add(Manifest.permission.READ_CALL_LOG to "Arama geçmişi")
        add(Manifest.permission.CAMERA to "Kamera (QR tarama)")
        // Telefonu Mac'in MIKROFONU yapmak icin. Izin istenmedigi surece
        // ses kanali aciliyor ama kayit hic baslamiyordu (olculdu:
        // RECORD_AUDIO granted=false).
        add(Manifest.permission.RECORD_AUDIO to "Mikrofon (Mac'te kullanmak için)")
        if (Build.VERSION.SDK_INT >= 33) {
            add(Manifest.permission.READ_MEDIA_IMAGES to "Fotoğraflar")
            add(Manifest.permission.READ_MEDIA_VIDEO to "Videolar")
            add(Manifest.permission.READ_MEDIA_AUDIO to "Müzik")
            add(Manifest.permission.POST_NOTIFICATIONS to "Bildirim gösterme")
        } else {
            add(Manifest.permission.READ_EXTERNAL_STORAGE to "Dosyalar ve medya")
        }
    }

    private fun requestCorePermissions() {
        val missing = corePerms.map { it.first }.filter { !Permissions.has(this, it) }
        if (missing.isNotEmpty()) ActivityCompat.requestPermissions(this, missing.toTypedArray(), 1)
    }

    override fun onRequestPermissionsResult(
        code: Int, perms: Array<out String>, results: IntArray) {
        super.onRequestPermissionsResult(code, perms, results)
        refresh()
        if (code == 2 && results.firstOrNull() == android.content.pm.PackageManager.PERMISSION_GRANTED) {
            startScan()
        }
    }

    private fun buildPermissionRows() {
        permBox.removeAllViews()
        for ((perm, label) in corePerms) {
            row(label, Permissions.has(this, perm)) {
                ActivityCompat.requestPermissions(this, arrayOf(perm), 1)
            }
        }
        // Ekran yakalama izni IKI ise birden yariyor: ekran yansitma ve
        // telefonun kendi sesini Mac'e verme ("iki cihaz bagliymis gibi").
        // Bu yuzden tek satir, tek onay. Gorusme sesi hicbir kosulda
        // yakalanamiyor — bu Android'in kurali, bizim eksigimiz degil.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            row("Ekranı ve sesi Mac’e ver", AndrOSService.capturingAudio) {
                val mgr = getSystemService(android.media.projection.MediaProjectionManager::class.java)
                projectionRequest.launch(mgr.createScreenCaptureIntent())
            }
        }
        // Mac'ten telefona DOKUNMAK icin erisilebilirlik sart. Bu, adb
        // olmadan baska bir uygulamaya dokunmanin tek desteklenen yolu:
        // scrcpy bunu `InputManager` ile yapiyor ve oraya yalniz shell
        // (adb) erisebiliyor.
        row("Mac’ten telefonu kontrol et", InputService.isEnabled) {
            startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
        }
        // Pil eniyilestirmesi: bu acikken sistem hizmeti arka planda
        // olduruyor ve Mac baglantisi kopuyor.
        row("Pil kısıtlamasından muaf", isBatteryExempt()) {
            startActivity(Intent(
                Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                Uri.parse("package:$packageName")))
        }
        // Bildirim erisimi ve tum dosyalar normal izin diyaloguyla
        // verilemiyor; kullanici ayri bir ekrandan aciyor.
        row("Bildirim erişimi", NotificationListener.isEnabled(this)) {
            startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
        }
        if (Build.VERSION.SDK_INT >= 30) {
            row("Tüm dosyalara erişim", android.os.Environment.isExternalStorageManager()) {
                startActivity(Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                                     Uri.parse("package:$packageName")))
            }
        }
    }

    private fun isBatteryExempt(): Boolean {
        val pm = getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
        return pm.isIgnoringBatteryOptimizations(packageName)
    }

    private fun row(label: String, granted: Boolean, onClick: () -> Unit) {
        val v = LayoutInflater.from(this).inflate(R.layout.perm_row, permBox, false)
        v.findViewById<TextView>(R.id.mark).apply {
            text = if (granted) "✓" else "○"
            setTextColor(getColor(if (granted) R.color.accent else R.color.text_dim))
        }
        v.findViewById<TextView>(R.id.label).apply {
            text = label
            alpha = if (granted) 1f else 0.7f
        }
        v.findViewById<TextView>(R.id.action).text = if (granted) "" else "İzin ver"
        if (!granted) v.setOnClickListener { onClick() }
        permBox.addView(v, ViewGroup.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
    }
}
