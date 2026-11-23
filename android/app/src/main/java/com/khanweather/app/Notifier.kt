package com.khanweather.app

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.work.*
import com.khanweather.app.widget.Widgets
import com.khanweather.core.*
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json
import java.util.concurrent.TimeUnit
import android.net.Uri
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.net.HttpURLConnection
import java.net.URL

/**
 * The app's own notifications, no third-party service: every 30 minutes or so WorkManager runs
 * [CheckWorker], which refreshes the widgets and asks the official alert services about the
 * current location and saved places, then posts anything new. Rain and frost heads-ups follow
 * the same rules as the iPhone app.
 */
object Notifier {
    private const val ALERTS = "alerts"
    private const val RAIN = "rain"
    private const val FROST = "frost"
    private const val UPDATES = "updates"
    private val json = Json

    fun createChannels(context: Context) {
        if (Build.VERSION.SDK_INT < 26) return
        val nm = context.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(ALERTS, "Weather alerts", NotificationManager.IMPORTANCE_HIGH))
        nm.createNotificationChannel(NotificationChannel(RAIN, "Rain and snow starting", NotificationManager.IMPORTANCE_DEFAULT))
        nm.createNotificationChannel(NotificationChannel(FROST, "Frost tonight", NotificationManager.IMPORTANCE_DEFAULT))
        nm.createNotificationChannel(NotificationChannel(UPDATES, "App updates", NotificationManager.IMPORTANCE_DEFAULT))
    }

    /** Background checks also keep the widgets fresh, so they always run. */
    fun schedule(context: Context) {
        val request = PeriodicWorkRequestBuilder<CheckWorker>(30, TimeUnit.MINUTES)
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .build()
        WorkManager.getInstance(context).enqueueUniquePeriodicWork("checks", ExistingPeriodicWorkPolicy.KEEP, request)
    }

    // Alerts already notified or seen in the app, with when to forget them.
    private var notified: Map<String, Double>
        get() = Prefs.prefs.getString("notifiedAlertIDs", null)?.let {
            runCatching { json.decodeFromString(MapSerializer(String.serializer(), Double.serializer()), it) }.getOrNull()
        } ?: emptyMap()
        set(v) = Prefs.prefs.edit().putString("notifiedAlertIDs", json.encodeToString(MapSerializer(String.serializer(), Double.serializer()), v)).apply()

    private fun forgetTime(a: WeatherAlert) = (a.expiresAt ?: a.eventEndsAt ?: (nowEpoch() + 2 * 86400)) + 86400

    /** Alerts shown on screen don't need a notification later. */
    fun markSeen(alerts: List<WeatherAlert>) {
        val seen = notified.toMutableMap()
        for (a in alerts) seen[a.id] = forgetTime(a)
        notified = seen
    }

    fun shouldNotify(a: WeatherAlert, includeAdvisories: Boolean) = when (a.kind) {
        WeatherAlert.Kind.warning, WeatherAlert.Kind.watch -> true
        else -> includeAdvisories
    }

    /** Opening the app shows the same "rain starting" line, so don't repeat it as a notification. */
    fun markRainSeen(nowcast: Nowcast?) {
        if (nowcast?.change is Nowcast.Change.Starting) Prefs.prefs.edit().putString("lastRainNotification", nowEpoch().toString()).apply()
    }

    private fun canPost(context: Context) = Build.VERSION.SDK_INT < 33 ||
        ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    private fun post(context: Context, channel: String, id: Int, title: String, body: String) {
        if (!canPost(context)) return
        val open = PendingIntent.getActivity(context, 0, Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val n = NotificationCompat.Builder(context, channel)
            .setSmallIcon(android.R.drawable.ic_dialog_alert)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setContentIntent(open)
            .setAutoCancel(true)
            .build()
        try { NotificationManagerCompat.from(context).notify(id, n) } catch (_: SecurityException) {}
    }

    fun sendTest(context: Context) = post(context, ALERTS, 1, "Khan Weather test", "Notifications from Khan Weather reach this phone.")

    /** Everything one background run does. */
    suspend fun checkAll(context: Context) = coroutineScope {
        val here = LocationHelper.lastKnown(context)
        val target = here ?: Coordinate.fallback
        // Fresh widget data: the same steps as the app.
        val obs = async { WeatherLoader.observation(target) }
        val radar = async { WeatherLoader.radar(target) }
        val alertsHere = async { WeatherLoader.alerts(target) }
        val name = async { if (here != null) PlaceNames.name(context, target) else "Toronto" }
        val forecast = runCatching { WeatherLoader.full(target, obs.await(), radar.await()) }.getOrNull()
        if (forecast != null) {
            val old = SnapshotStore.load(context, null, 48 * 3600.0)
            SnapshotStore.save(context, null, Snapshot(forecast, name.await() ?: old?.placeName, alertsHere.await() ?: old?.alerts ?: emptyList(),
                old?.airQuality, nowEpoch(), here != null))
        }
        Widgets.updateAll(context)
        if (Prefs.alertNotifications) checkAlerts(context, here, alertsHere.await())
        if (forecast != null && here != null) {
            if (Prefs.rainNotifications) checkRain(context, forecast)
            if (Prefs.frostNotifications) checkFrost(context, forecast)
        }
    }

    private suspend fun checkAlerts(context: Context, here: Coordinate?, hereAlerts: List<WeatherAlert>?) {
        val include = Prefs.advisoryNotifications
        val seen = notified.filter { it.value > nowEpoch() }.toMutableMap()
        val places = mutableListOf<Pair<String, List<WeatherAlert>?>>()
        if (here != null) places += "your location" to hereAlerts
        for (p in Prefs.places) places += p.name to WeatherLoader.alerts(p.coordinate)
        for ((place, alerts) in places) {
            for (a in alerts ?: continue) {
                if (seen[a.id] != null || !shouldNotify(a, include)) continue
                seen[a.id] = forgetTime(a)
                post(context, ALERTS, a.id.hashCode(), "${a.title} for $place", a.notificationBody)
            }
        }
        notified = seen
    }

    private fun checkRain(context: Context, forecast: Forecast) {
        val now = nowEpoch()
        val last = Prefs.prefs.getString("lastRainNotification", null)?.toDoubleOrNull()
        if (last != null && now - last < RainHeadsUp.quietPeriod) return
        val nowcast = forecast.nowcast(now)
        val soon = RainHeadsUp.shouldNotify(nowcast, last, now)
        if (soon != null && ModelAgreement.wetAgrees(forecast.hourly, now)) {
            Prefs.prefs.edit().putString("lastRainNotification", now.toString()).apply()
            post(context, RAIN, 2, if (soon.kind == Nowcast.Kind.snow) "Snow on the way" else "Rain on the way", rainBody(soon, now, forecast.timeZoneIdentifier))
        }
    }

    fun rainBody(n: Nowcast, now: Epoch, zone: String): String {
        val c = n.change as? Nowcast.Change.Starting ?: return n.text + "."
        return "${n.text}, around ${TimeText.time(now + c.minutes * 60.0, zone)}."
    }

    /** "Frost likely tonight", once a day, from 2 PM to 10 PM, when most models agree. */
    private fun checkFrost(context: Context, forecast: Forecast) {
        val now = nowEpoch()
        val cal = forecast.cal
        val hour = cal.hour(now)
        val today = cal.localDate(now).toString()
        if (hour < 14 || hour > 22 || Prefs.prefs.getString("lastFrostNotificationDay", null) == today) return
        val frost = ModelAgreement.frost(forecast, now) ?: return
        Prefs.prefs.edit().putString("lastFrostNotificationDay", today).apply()
        post(context, FROST, 3, "Frost likely tonight",
            "${frost.agreeing} of ${frost.total} forecast models drop to ${WeatherFormat.temperature(0.0)} or below by about ${TimeText.hour(frost.time, forecast.timeZoneIdentifier)}. Cover plants and watch for icy spots.")
    }

    /** Checks GitHub's fixed `android-latest` release at most once every 6 hours and notifies when a newer build is posted. */
    suspend fun checkAppUpdate(context: Context) {
        val now = nowEpoch()
        val lastCheck = Prefs.prefs.getString("lastUpdateCheck", null)?.toDoubleOrNull() ?: 0.0
        if (now - lastCheck < 6 * 3600.0) return
        Prefs.prefs.edit().putString("lastUpdateCheck", now.toString()).apply()

        val remoteBuild = withContext(Dispatchers.IO) {
            runCatching {
                val conn = (URL("https://api.github.com/repos/skhan85/Khan-Weather/releases/tags/android-latest").openConnection() as HttpURLConnection).apply {
                    connectTimeout = 6000; readTimeout = 6000
                    setRequestProperty("Accept", "application/vnd.github+json")
                    setRequestProperty("User-Agent", "KhanWeather-Android")
                }
                try {
                    if (conn.responseCode != 200) return@runCatching null
                    val obj = json.parseToJsonElement(conn.inputStream.bufferedReader().readText()).jsonObject
                    val body = obj["body"]?.jsonPrimitive?.content ?: ""
                    Regex("Android build (\\d+)").find(body)?.groupValues?.get(1)?.toIntOrNull()
                } finally {
                    conn.disconnect()
                }
            }.getOrNull()
        } ?: return

        val info = runCatching { context.packageManager.getPackageInfo(context.packageName, 0) }.getOrNull() ?: return
        val installed = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode.toInt() else @Suppress("DEPRECATION") info.versionCode
        val notifiedBuild = Prefs.prefs.getInt("notifiedUpdateBuild", 0)
        if (remoteBuild <= installed || remoteBuild <= notifiedBuild) return

        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) return

        createChannels(context)
        val downloadIntent = Intent(
            Intent.ACTION_VIEW,
            Uri.parse("https://github.com/skhan85/Khan-Weather/releases/download/android-latest/KhanWeather.apk"),
        )
        val pi = PendingIntent.getActivity(context, 9001, downloadIntent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notif = NotificationCompat.Builder(context, UPDATES)
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setContentTitle("Khan Weather update available")
            .setContentText("Build $remoteBuild (v1.0.$remoteBuild) is ready — tap to download.")
            .setContentIntent(pi)
            .setAutoCancel(true)
            .build()
        NotificationManagerCompat.from(context).notify(9001, notif)
        Prefs.prefs.edit().putInt("notifiedUpdateBuild", remoteBuild).apply()
    }
}

class CheckWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        Prefs.init(applicationContext)
        runCatching { Notifier.checkAll(applicationContext) }
        runCatching { Notifier.checkAppUpdate(applicationContext) }
        return Result.success()
    }
}
