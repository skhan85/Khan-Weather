package com.khanweather.app.widget

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Shader
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.*
import androidx.glance.action.clickable
import androidx.glance.appwidget.*
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.layout.*
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import com.khanweather.app.*
import com.khanweather.core.*
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/** What every widget shows: the last saved snapshot for the current location (the app and the background check write it). */
data class WidgetData(
    val forecast: Forecast,
    val placeName: String?,
    val alert: WeatherAlert?,
)

object Widgets {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    suspend fun updateAll(context: Context) {
        runCatching { SummaryWidget().updateAll(context) }
        runCatching { HourlyWidget().updateAll(context) }
        runCatching { DailyWidget().updateAll(context) }
    }

    fun updateAllAsync(context: Context) { scope.launch { updateAll(context.applicationContext) } }

    fun load(context: Context): WidgetData? {
        Prefs.init(context)
        val s = SnapshotStore.load(context, null, 24 * 3600.0) ?: return null
        return WidgetData(s.forecast.rolledForward(), s.placeName, s.alerts.firstOrNull())
    }

    fun sky(condition: WeatherCondition, isDay: Boolean): Bitmap {
        val sky = Sky.of(condition, isDay)
        val bmp = Bitmap.createBitmap(8, 160, Bitmap.Config.ARGB_8888)
        Paint().apply {
            shader = LinearGradient(0f, 0f, 0f, 160f, sky.top.toArgb(), sky.bottom.toArgb(), Shader.TileMode.CLAMP)
            Canvas(bmp).drawRect(0f, 0f, 8f, 160f, this)
        }
        return bmp
    }

    fun icon(condition: WeatherCondition, isDay: Boolean, px: Int = 96) = WeatherIcons.bitmap(condition, isDay, px)
}

private val white = ColorProvider(Color.White)
private val dim = ColorProvider(Color.White.copy(alpha = 0.85f))
private val gold = ColorProvider(Gold)

private fun ts(size: TextUnit, weight: FontWeight = FontWeight.Normal, color: ColorProvider = white) =
    TextStyle(color = color, fontSize = size, fontWeight = weight)

@Composable
private fun WidgetFrame(data: WidgetData?, content: @Composable (WidgetData) -> Unit) {
    val f = data?.forecast
    Box(
        GlanceModifier.fillMaxSize().cornerRadius(20.dp)
            .background(ImageProvider(Widgets.sky(f?.current?.condition ?: WeatherCondition.partlyCloudy, f?.current?.isDay ?: true)),
                androidx.glance.layout.ContentScale.FillBounds)
            .clickable(actionStartActivity<MainActivity>())
            .padding(14.dp),
    ) {
        if (data == null) Text("Open Khan Weather to load the weather", style = ts(13.sp, FontWeight.Medium))
        else content(data)
    }
}

@Composable
private fun Icon(condition: WeatherCondition, isDay: Boolean, size: Int) {
    Image(ImageProvider(Widgets.icon(condition, isDay)), condition.description, GlanceModifier.size(size.dp))
}

@Composable
private fun Header(d: WidgetData, big: Int = 42) {
    val c = d.forecast.current
    val today = d.forecast.displayDay()
    Row(GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.Top) {
        Column(GlanceModifier.defaultWeight()) {
            Text(d.placeName ?: "Current location", style = ts(14.sp, FontWeight.Bold), maxLines = 1)
            Text(WeatherFormat.temperature(c.temperature), style = ts(big.sp, FontWeight.Bold), maxLines = 1)
        }
        Icon(c.condition, c.isDay, 40)
    }
    Text("Feels ${WeatherFormat.temperature(c.feelsLike)} · " + (d.forecast.nowcast()?.shortText ?: (d.forecast.observation?.conditionText ?: c.condition.description)),
        style = ts(12.sp, FontWeight.Bold, dim), maxLines = 1)
    val alert = d.alert
    if (alert != null) Text("⚠ ${alert.title}", style = ts(12.sp, FontWeight.Bold, gold), maxLines = 1)
    else if (today != null) Text("H ${WeatherFormat.temperature(today.high)} · L ${WeatherFormat.temperature(today.low)}", style = ts(12.sp, FontWeight.Bold), maxLines = 1)
}

/** Small: now, feels like, nowcast or condition, alert or today's high and low. */
class SummaryWidget : GlanceAppWidget() {
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val data = Widgets.load(context)
        provideContent { SummaryContent(data) }
    }
}

/** Medium: the summary and the next six hours. */
class HourlyWidget : GlanceAppWidget() {
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val data = Widgets.load(context)
        provideContent { HourlyContent(data) }
    }
}

@Composable
fun SummaryContent(data: WidgetData?) = WidgetFrame(data) { d -> Column(GlanceModifier.fillMaxSize()) { Header(d) } }

@Composable
fun HourlyContent(data: WidgetData?) {
            WidgetFrame(data) { d ->
                Column(GlanceModifier.fillMaxSize()) {
                    Header(d, 34)
                    Spacer(GlanceModifier.height(6.dp))
                    val zone = d.forecast.timeZoneIdentifier
                    Row(GlanceModifier.fillMaxWidth()) {
                        d.forecast.hoursStartingNow(count = 7).drop(1).forEach { h ->
                            Column(GlanceModifier.defaultWeight(), horizontalAlignment = Alignment.CenterHorizontally) {
                                Text(TimeText.hour(h.time, zone), style = ts(11.sp, FontWeight.Medium, dim), maxLines = 1)
                                Icon(h.condition, h.isDay, 22)
                                Text(WeatherFormat.temperature(h.temperature), style = ts(13.sp, FontWeight.Bold))
                                val p = h.precipitationProbability
                                Text(if (p != null && p >= 10) WeatherFormat.percent(p) else " ", style = ts(10.sp, FontWeight.Bold, ColorProvider(ChanceBlue)))
                            }
                        }
                    }
                }
            }
}

/** Large: the summary and the next five days. */
class DailyWidget : GlanceAppWidget() {
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val data = Widgets.load(context)
        provideContent { DailyContent(data) }
    }
}

@Composable
fun DailyContent(data: WidgetData?) {
            WidgetFrame(data) { d ->
                Column(GlanceModifier.fillMaxSize()) {
                    Header(d)
                    Spacer(GlanceModifier.height(8.dp))
                    val zone = d.forecast.timeZoneIdentifier
                    d.forecast.displayDaily().take(5).forEachIndexed { i, day ->
                        Row(GlanceModifier.fillMaxWidth().padding(vertical = 3.dp), verticalAlignment = Alignment.CenterVertically) {
                            Text(if (i == 0) "Today" else TimeText.weekdayShort(day.date, zone),
                                style = ts(14.sp, FontWeight.Bold, if (i == 0) gold else white), modifier = GlanceModifier.width(58.dp))
                            Icon(day.condition, true, 24)
                            val p = day.precipitationProbability
                            Text(if (p != null && p >= 10) WeatherFormat.percent(p) else "", style = ts(11.sp, FontWeight.Bold, ColorProvider(ChanceBlue)),
                                modifier = GlanceModifier.width(40.dp).padding(start = 6.dp))
                            Spacer(GlanceModifier.defaultWeight())
                            Text(WeatherFormat.temperature(day.high), style = ts(14.sp, FontWeight.Bold), modifier = GlanceModifier.width(40.dp))
                            Text(WeatherFormat.temperature(day.low), style = ts(14.sp, FontWeight.Medium, dim), modifier = GlanceModifier.width(36.dp))
                        }
                    }
                }
            }
}

class SummaryWidgetReceiver : GlanceAppWidgetReceiver() { override val glanceAppWidget: GlanceAppWidget = SummaryWidget() }
class HourlyWidgetReceiver : GlanceAppWidgetReceiver() { override val glanceAppWidget: GlanceAppWidget = HourlyWidget() }
class DailyWidgetReceiver : GlanceAppWidgetReceiver() { override val glanceAppWidget: GlanceAppWidget = DailyWidget() }
