package io.github.ccch1mneyyy.dsh_app.voice

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import io.github.ccch1mneyyy.dsh_app.MainActivity
import io.github.ccch1mneyyy.dsh_app.R
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.EventChannel

/**
 * Keeps the wake word listening while the app is off screen: a foreground service with the
 * `microphone` type holding a [WavRecorder], its PCM handed to Dart (still alive because the
 * engine outlives the activity) over a dedicated event channel.
 *
 * The spotter itself runs in Dart — this service only owns the microphone and the foreground
 * presence Android requires to keep reading it when the app is in the background.
 */
class WakeWordService : Service(), EventChannel.StreamHandler {

    private var recorder: WavRecorder? = null
    private var sink: EventChannel.EventSink? = null
    private var channel: EventChannel? = null
    private var pcmTapId: Long? = null

    @Volatile private var running = false

    override fun onCreate() {
        super.onCreate()
        ensureChannel()
        // The engine is cached by MainActivity; when the activity is gone it is still here, so
        // this channel stays reachable. Registering on the cached engine's messenger keeps the
        // subscription alive across activity recreation.
        val engine = FlutterEngineCache.getInstance().get("dsh-main")
        if (engine != null) {
            channel = EventChannel(engine.dartExecutor, "dsh/wake/events")
            channel!!.setStreamHandler(this)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                if (!hasPermission()) {
                    stopSelf()
                    return START_NOT_STICKY
                }
                if (!running) {
                    startForegroundCompat(buildNotification())
                    running = true
                    startRecording()
                }
            }
            ACTION_STOP -> {
                stopRecording()
                stopForegroundCompat()
                running = false
                stopSelf()
            }
            else -> {
                // Started by the system with no action: nothing to do.
                stopSelf()
            }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        stopRecording()
        running = false
        channel?.setStreamHandler(null)
        channel = null
        sink = null
        super.onDestroy()
    }

    private fun hasPermission(): Boolean =
        checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    @SuppressLint("MissingPermission") // checked in onStartCommand
    private fun startRecording() {
        stopRecording()
        val tapId = System.nanoTime()
        // The recorder emits its PCM through StreamingPcm with the "wake" source; this service
        // forwards those frames to Dart over its own event channel.
        StreamingPcm.enable("wake", tapId) { tap, bytes, valid ->
            if (StreamingPcm.current(tap) && valid()) {
                sink?.success(mapOf("type" to "pcm", "bytes" to bytes, "rate" to 16000, "pcmSession" to tap.id))
            }
        }
        pcmTapId = tapId
        val r = WavRecorder(
            maxSeconds = Int.MAX_VALUE / 2, // effectively unbounded; the service owns the lifetime
            onLevel = { },
            onLimit = { stopSelf() },
            onError = { stopSelf() },
            isCurrentCapture = { running },
            pcmSource = "wake",
        )
        val started = r.start()
        if (!started) {
            StreamingPcm.disable(tapId)
            pcmTapId = null
            r.discard()
            stopSelf()
            return
        }
        recorder = r
    }

    private fun stopRecording() {
        val tapId = pcmTapId
        pcmTapId = null
        if (tapId != null) StreamingPcm.disable(tapId)
        val r = recorder
        recorder = null
        if (r != null) {
            Thread { runCatching { r.discard() } }.start()
        }
    }

    // ── EventChannel ──────────────────────────────────────────────────────

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
        StreamingPcm.disable(pcmTapId)
    }

    // ── Foreground ────────────────────────────────────────────────────────

    private fun startForegroundCompat(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) stopForeground(STOP_FOREGROUND_REMOVE)
        else @Suppress("DEPRECATION") stopForeground(true)
    }

    private fun buildNotification(): Notification {
        val open = PendingIntent.getActivity(
            this,
            NOTIFICATION_ID,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val stop = PendingIntent.getService(
            this,
            NOTIFICATION_ID + 1,
            Intent(this, WakeWordService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_dsh)
            .setContentTitle(getString(R.string.wake_word_listening_title))
            .setContentText(getString(R.string.wake_word_listening_text))
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(open)
            .addAction(Notification.Action.Builder(null, getString(R.string.wake_word_stop), stop).build())
            .build()
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, getString(R.string.wake_word_listening_channel), NotificationManager.IMPORTANCE_LOW).apply {
                description = getString(R.string.wake_word_listening_channel_description)
                setShowBadge(false)
            },
        )
    }

    companion object {
        const val ACTION_START = "io.github.ccch1mneyyy.dsh_app.WAKE_WORD_START"
        const val ACTION_STOP = "io.github.ccch1mneyyy.dsh_app.WAKE_WORD_STOP"
        private const val CHANNEL_ID = "dsh-wake-word"
        private const val NOTIFICATION_ID = 3090

        fun start(context: Context) {
            val intent = Intent(context, WakeWordService::class.java).setAction(ACTION_START)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) context.startForegroundService(intent)
            else context.startService(intent)
        }

        fun stop(context: Context) {
            context.startService(Intent(context, WakeWordService::class.java).setAction(ACTION_STOP))
        }
    }
}
