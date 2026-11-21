package com.khanweather.app.widget

import android.widget.FrameLayout
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.glance.appwidget.ExperimentalGlanceRemoteViewsApi
import androidx.glance.appwidget.GlanceRemoteViews
import android.widget.RemoteViews
import com.khanweather.app.style

/** Draws the three home-screen widgets in the app, from the same snapshot, for screenshots. */
@OptIn(ExperimentalGlanceRemoteViewsApi::class)
@Composable
fun WidgetPreviewScreen() {
    val context = LocalContext.current
    var views by remember { mutableStateOf<List<Pair<String, Pair<RemoteViews, DpSize>>>>(emptyList()) }
    LaunchedEffect(Unit) {
        val data = Widgets.load(context)
        val g = GlanceRemoteViews()
        val sizes = listOf("Small" to DpSize(170.dp, 170.dp), "Medium" to DpSize(360.dp, 170.dp), "Large" to DpSize(360.dp, 360.dp))
        views = sizes.mapIndexed { i, (name, size) ->
            val rv = g.compose(context, size) {
                when (i) { 0 -> SummaryContent(data); 1 -> HourlyContent(data); else -> DailyContent(data) }
            }.remoteViews
            name to (rv to size)
        }
    }
    Column(Modifier.verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        for ((name, pair) in views) {
            Text(name, style = style(15.sp))
            AndroidView(factory = { FrameLayout(it) }, modifier = Modifier.size(pair.second.width, pair.second.height),
                update = { frame -> frame.removeAllViews(); frame.addView(pair.first.apply(frame.context, frame)) })
        }
    }
}
