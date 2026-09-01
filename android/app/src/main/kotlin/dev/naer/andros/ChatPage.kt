package dev.naer.andros

import android.app.Activity
import android.graphics.Color
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import dev.naer.andros.call.Hub
import dev.naer.andros.call.MessageStore
import dev.naer.andros.call.SignalClient
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * "Sohbetler" sekmesi: AndrOS agindan gelen mesajlar.
 *
 * SMS BURADA DEGIL. Ikisi ayni yerden gelmiyor: SMS operatorden,
 * telefonun kendi mesaj uygulamasinda; bunlar internetten, uctan uca
 * sifreli ve yalniz iki cihazin elinde. Ayni listede gostermek
 * "neden bu gitmedi" sorusunu dogurur — Mac'te tek akista
 * birlestiriyoruz cunku orada iki kaynak da elimizde, burada degil.
 */
class ChatPage(private val activity: Activity, private val root: View) {

    private val hub = Hub.get(activity)
    private val body: LinearLayout = root.findViewById(R.id.chatBody)
    private val scroll: ScrollView = root.findViewById(R.id.chatScroll)
    private val title: TextView = root.findViewById(R.id.chatTitle)
    private val status: TextView = root.findViewById(R.id.chatStatus)
    private val back: TextView = root.findViewById(R.id.chatBack)
    private val compose: LinearLayout = root.findViewById(R.id.chatCompose)
    private val input: EditText = root.findViewById(R.id.chatInput)

    private var openPeer: String? = null
    private val time = SimpleDateFormat("d MMM HH:mm", Locale("tr"))

    init {
        back.setOnClickListener { showList() }
        root.findViewById<Button>(R.id.chatSend).setOnClickListener { send() }
        input.setOnEditorActionListener { _, _, _ -> send(); true }
        hub.onMessage = { from, _, _ ->
            activity.runOnUiThread {
                if (openPeer == from) showThread(from) else if (openPeer == null) showList()
            }
        }
        hub.onState = { activity.runOnUiThread { refreshStatus() } }
        showList()
    }

    fun refresh() {
        refreshStatus()
        openPeer?.let { showThread(it) } ?: showList()
    }

    /// Bildirimden gelindiyse dogrudan o sohbeti ac.
    fun open(peer: String) = showThread(peer)

    private fun refreshStatus() {
        val st = hub.client?.state ?: SignalClient.State.OFFLINE
        status.text = when (st) {
            SignalClient.State.READY -> "Bağlı"
            SignalClient.State.CONNECTING -> "Bağlanılıyor…"
            SignalClient.State.OFFLINE -> "Bağlı değil"
        }
        status.setTextColor(activity.getColor(
            if (st == SignalClient.State.READY) R.color.accent else R.color.text_dim))
    }

    // MARK: - Sohbet listesi

    private fun showList() {
        openPeer = null
        back.visibility = View.GONE
        compose.visibility = View.GONE
        title.setText(R.string.tab_chat)
        body.removeAllViews()
        refreshStatus()

        val peers = hub.store.peers()
            .map { it to (hub.store.messages(it).lastOrNull()?.at ?: 0L) }
            .sortedByDescending { it.second }
        if (peers.isEmpty()) {
            body.addView(hint("Henüz AndrOS mesajı yok.\n\n" +
                "Karşı tarafta da AndrOS kurulu ve bağlıysa, Mac'teki Mesajlar " +
                "panelinden ya da buradan yazışabilirsin. Bu mesajlar SMS değil: " +
                "internetten gider, ücretsizdir ve uçtan uca şifrelidir."))
            return
        }
        for ((peer, _) in peers) {
            val last = hub.store.messages(peer).lastOrNull()
            val who = hub.store.number(peer) ?: peer
            val row = LinearLayout(activity).apply {
                orientation = LinearLayout.VERTICAL
                setBackgroundResource(R.drawable.ripple_soft)
                setPadding(24, 28, 24, 28)
                setOnClickListener { showThread(peer) }
            }
            row.addView(TextView(activity).apply {
                text = who
                textSize = 15f
                setTextColor(activity.getColor(R.color.text))
            })
            row.addView(TextView(activity).apply {
                text = last?.text?.replace("\n", " ") ?: ""
                textSize = 12f
                maxLines = 1
                setTextColor(activity.getColor(R.color.text_dim))
            })
            body.addView(row)
        }
    }

    // MARK: - Tek sohbet

    private fun showThread(peer: String) {
        openPeer = peer
        back.visibility = View.VISIBLE
        compose.visibility = View.VISIBLE
        title.text = hub.store.number(peer) ?: peer
        body.removeAllViews()

        val msgs = hub.store.messages(peer)
        if (msgs.isEmpty()) body.addView(hint("Bu sohbette henüz mesaj yok."))
        for (m in msgs.takeLast(300)) body.addView(bubble(m))
        scroll.post { scroll.fullScroll(View.FOCUS_DOWN) }
    }

    private fun bubble(m: MessageStore.Message): View {
        val text = TextView(activity).apply {
            this.text = m.text
            textSize = 14f
            setTextColor(if (m.outgoing) Color.WHITE else activity.getColor(R.color.text))
            setPadding(28, 20, 28, 20)
            // Baloncuk: giden yesil (AndrOS'un rengi), gelen soluk
            // zemin — Mac tarafiyla ayni dil.
            background = android.graphics.drawable.GradientDrawable().apply {
                cornerRadius = 34f
                setColor(if (m.outgoing) activity.getColor(R.color.accent)
                         else Color.parseColor("#1C2637"))
            }
        }
        val stamp = TextView(activity).apply {
            this.text = time.format(Date(m.at))
            textSize = 9f
            setTextColor(activity.getColor(R.color.text_dim))
            gravity = if (m.outgoing) Gravity.END else Gravity.START
        }
        return LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            gravity = if (m.outgoing) Gravity.END else Gravity.START
            setPadding(0, 10, 0, 0)
            addView(text)
            addView(stamp)
        }
    }

    private fun send() {
        val peer = openPeer ?: return
        val text = input.text.toString().trim()
        if (text.isEmpty()) return
        hub.sendMessage(peer, text)
        input.setText("")
        showThread(peer)
    }

    private fun hint(s: String) = TextView(activity).apply {
        text = s
        textSize = 13f
        setTextColor(activity.getColor(R.color.text_dim))
        setPadding(16, 48, 16, 16)
    }
}
