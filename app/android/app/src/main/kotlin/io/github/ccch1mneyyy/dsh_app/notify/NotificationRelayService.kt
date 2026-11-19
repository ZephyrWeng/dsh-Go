package io.github.ccch1mneyyy.dsh_app.notify

import android.app.Notification
import android.content.Context
import android.content.SharedPreferences
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import org.json.JSONObject
import java.io.OutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.nio.charset.StandardCharsets
import java.util.concurrent.Executors

/**
 * Forwards this phone's notifications to a local HTTP endpoint, so a plugin can
 * act on them without a second app holding the system's notification access.
 *
 * The access itself is the system's: the person grants 通知使用权 to this app in
 * settings, and until they do the system never binds this service. What arrives
 * is posted as JSON to `http://127.0.0.1:<port>/notify` — loopback only, the
 * same shape the standalone relay used, so a plugin written for that works here
 * unchanged.
 *
 * What the text can hold is what the posting app put in the notification: with
 * 「通知显示消息详情」 off, WeChat posts "你收到了一条消息" and that is all anyone
 * — this service included — can read.
 */
class NotificationRelayService : NotificationListenerService() {

    override fun onListenerConnected() {
        super.onListenerConnected()
        RelayPrefs.record(this, "已连接系统通知")
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        val prefs = RelayPrefs.get(this)
        if (!prefs.getBoolean(RelayPrefs.ENABLED, false)) return
        if (sbn == null) return
        val notification = sbn.notification ?: return
        val pkg = sbn.packageName ?: return
        if (pkg == packageName) return // our own posts are not news
        if (sbn.isOngoing) return // a call in progress, music, a download bar

        val extras = notification.extras ?: return
        val title = text(extras.getCharSequence(Notification.EXTRA_TITLE))
        var body = text(extras.getCharSequence(Notification.EXTRA_TEXT))
        if (body.isEmpty()) body = text(extras.getCharSequence(Notification.EXTRA_BIG_TEXT))
        if (body.isEmpty()) body = text(extras.getCharSequence(Notification.EXTRA_SUMMARY_TEXT))
        if (title.isEmpty() && body.isEmpty()) return

        val payload = JSONObject()
            .put("app", labelOf(pkg))
            .put("pkg", pkg)
            .put("title", title)
            .put("text", body)
            .put("key", sbn.key)
            .put("at", sbn.postTime)
            .put("uid", uidOf(pkg))
            .toString()
        val port = prefs.getInt(RelayPrefs.PORT, RelayPrefs.DEFAULT_PORT)
        pool.execute { post(port, payload) }
    }

    private fun post(port: Int, body: String) {
        var connection: HttpURLConnection? = null
        try {
            connection = (URL("http://127.0.0.1:$port/notify").openConnection() as HttpURLConnection).apply {
                connectTimeout = 3000
                readTimeout = 8000
                requestMethod = "POST"
                doOutput = true
                setRequestProperty("Content-Type", "application/json; charset=utf-8")
            }
            connection.outputStream.use { it.write(body.toByteArray(StandardCharsets.UTF_8)) }
            val code = connection.responseCode
            RelayPrefs.record(this, if (code == 200) "已转发" else "端点返回 $code")
        } catch (error: Exception) {
            // Nothing is listening on that port yet: the plugin starts when it starts.
            RelayPrefs.record(this, "连不上 127.0.0.1:$port（${error.javaClass.simpleName}）")
            Log.d(TAG, "relay post failed", error)
        } finally {
            connection?.disconnect()
        }
    }

    private fun labelOf(pkg: String): String = try {
        val info = packageManager.getApplicationInfo(pkg, 0)
        packageManager.getApplicationLabel(info).toString()
    } catch (_: Exception) {
        pkg
    }

    private fun uidOf(pkg: String): Int = try {
        packageManager.getApplicationInfo(pkg, 0).uid / 100000
    } catch (_: Exception) {
        0
    }

    private fun text(value: CharSequence?): String = value?.toString()?.trim().orEmpty()

    private companion object {
        const val TAG = "dsh-notify-relay"
        val pool = Executors.newSingleThreadExecutor()
    }
}

/** Where the switch, the port and the last line live; shared with the plugin. */
object RelayPrefs {
    const val FILE = "notification_relay"
    const val ENABLED = "enabled"
    const val PORT = "port"
    const val DEFAULT_PORT = 38017
    private const val LAST = "last"

    fun get(context: Context): SharedPreferences =
        context.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    fun record(context: Context, line: String) {
        get(context).edit().putString(LAST, line.take(120)).apply()
    }

    fun last(context: Context): String = get(context).getString(LAST, "") ?: ""
}
