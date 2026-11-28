package __PKG__

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "crypto_radar/native"
    private val alertChannelId = "radar_alerts"
    private var notifId = 1000

    override fun onCreate(savedInstanceState: Bundle?) {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { t, e ->
            try {
                java.io.File(filesDir, "crash.txt").writeText(android.util.Log.getStackTraceString(e))
            } catch (x: Exception) {
            }
            previous?.uncaughtException(t, e)
        }
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        createAlertChannel()
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "saveFile" -> {
                    try {
                        val name = call.argument<String>("name") ?: "journal.csv"
                        val mime = call.argument<String>("mime") ?: "text/csv"
                        val content = call.argument<String>("content") ?: ""
                        result.success(saveToDownloads(name, mime, content))
                    } catch (e: Exception) {
                        result.error("save_failed", e.toString(), null)
                    }
                }
                "getCrash" -> {
                    val f = java.io.File(filesDir, "crash.txt")
                    if (f.exists()) {
                        val txt = f.readText()
                        f.delete()
                        result.success(txt)
                    } else {
                        result.success(null)
                    }
                }
                "requestPermission" -> {
                    requestNotifPermission()
                    result.success(true)
                }
                "notify" -> {
                    val title = call.argument<String>("title") ?: ""
                    val body = call.argument<String>("body") ?: ""
                    showNotification(title, body)
                    result.success(true)
                }
                "startService" -> {
                    val i = Intent(this, RadarService::class.java)
                    if (Build.VERSION.SDK_INT >= 26) {
                        startForegroundService(i)
                    } else {
                        startService(i)
                    }
                    result.success(true)
                }
                "stopService" -> {
                    stopService(Intent(this, RadarService::class.java))
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun saveToDownloads(name: String, mime: String, content: String): String {
        val bytes = content.toByteArray(Charsets.UTF_8)
        if (Build.VERSION.SDK_INT >= 29) {
            val values = android.content.ContentValues()
            values.put(android.provider.MediaStore.MediaColumns.DISPLAY_NAME, name)
            values.put(android.provider.MediaStore.MediaColumns.MIME_TYPE, mime)
            values.put(android.provider.MediaStore.MediaColumns.RELATIVE_PATH, android.os.Environment.DIRECTORY_DOWNLOADS)
            val uri = contentResolver.insert(android.provider.MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw java.io.IOException("insertion impossible")
            val out = contentResolver.openOutputStream(uri) ?: throw java.io.IOException("ecriture impossible")
            out.use { it.write(bytes) }
            return "Telechargements/" + name
        }
        val dir = getExternalFilesDir(android.os.Environment.DIRECTORY_DOWNLOADS) ?: filesDir
        dir.mkdirs()
        val f = java.io.File(dir, name)
        f.writeBytes(bytes)
        return f.absolutePath
    }

    private fun createAlertChannel() {
        if (Build.VERSION.SDK_INT >= 26) {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val ch = NotificationChannel(alertChannelId, "Alertes radar", NotificationManager.IMPORTANCE_HIGH)
            ch.description = "Jetons qui se preparent a bouger"
            ch.enableVibration(true)
            nm.createNotificationChannel(ch)
        }
    }

    private fun requestNotifPermission() {
        if (Build.VERSION.SDK_INT >= 33) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1001)
        }
    }

    private fun showNotification(title: String, body: String) {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val launch = packageManager.getLaunchIntentForPackage(packageName) ?: Intent()
        val pi = PendingIntent.getActivity(this, 0, launch, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val b: Notification.Builder = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(this, alertChannelId)
        } else {
            Notification.Builder(this)
        }
        b.setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setSmallIcon(android.R.drawable.stat_notify_more)
            .setContentIntent(pi)
            .setAutoCancel(true)
        notifId += 1
        nm.notify(notifId, b.build())
    }
}
