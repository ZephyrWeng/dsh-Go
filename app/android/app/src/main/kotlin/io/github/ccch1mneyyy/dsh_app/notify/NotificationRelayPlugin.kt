package io.github.ccch1mneyyy.dsh_app.notify

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The settings side of [NotificationRelayService]: whether the person has given
 * this app notification access, where the relay posts, and a way to open that
 * system page. Channel `dsh/notify/relay`.
 */
class NotificationRelayPlugin private constructor(private val context: Context) :
    MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "dsh/notify/relay"

        fun register(messenger: BinaryMessenger, context: Context): NotificationRelayPlugin {
            val plugin = NotificationRelayPlugin(context)
            MethodChannel(messenger, CHANNEL).setMethodCallHandler(plugin)
            return plugin
        }

        /**
         * Whether 通知使用权 lists this app. Read from the system's own setting rather than
         * a cached flag: the person can revoke it at any time without telling the app.
         */
        fun granted(context: Context): Boolean {
            val expected = ComponentName(context, NotificationRelayService::class.java)
            val enabled = Settings.Secure.getString(context.contentResolver, "enabled_notification_listeners")
                ?: return false
            return enabled.split(':').any { entry ->
                val component = ComponentName.unflattenFromString(entry) ?: return@any false
                component == expected
            }
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val prefs = RelayPrefs.get(context)
        when (call.method) {
            "status" -> result.success(
                mapOf(
                    "granted" to granted(context),
                    "enabled" to prefs.getBoolean(RelayPrefs.ENABLED, false),
                    "port" to prefs.getInt(RelayPrefs.PORT, RelayPrefs.DEFAULT_PORT),
                    "last" to RelayPrefs.last(context),
                ),
            )
            "setEnabled" -> {
                val on = call.argument<Boolean>("on") == true
                prefs.edit().putBoolean(RelayPrefs.ENABLED, on).apply()
                result.success(null)
            }
            "setPort" -> {
                val port = call.argument<Int>("port") ?: RelayPrefs.DEFAULT_PORT
                if (port !in 1024..65535) {
                    result.error("port", "port must be 1024..65535", null)
                    return
                }
                prefs.edit().putInt(RelayPrefs.PORT, port).apply()
                result.success(null)
            }
            "openSettings" -> {
                // The one page only the system can grant on: no API hands this out.
                val intent = Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                try {
                    context.startActivity(intent)
                    result.success(true)
                } catch (_: Exception) {
                    result.success(false)
                }
            }
            else -> result.notImplemented()
        }
    }
}
