package com.khanweather.app

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material.icons.filled.Straighten
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.khanweather.core.*

/**
 * Asked once, the first time the app opens: which units to show. The phone's region picks the
 * suggested set (or the units already saved, for someone updating). Same as the iOS app.
 */
@Composable
fun UnitsWelcomeScreen(onDone: () -> Unit) {
    var choice by remember {
        mutableStateOf((if (Prefs.hasSavedUnits) Prefs.units.preset else null) ?: UnitPreset.deviceDefault)
    }
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp, vertical = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Icon(Icons.Filled.Straighten, null, tint = Color.White, modifier = Modifier.size(40.dp))
        Text("Which units do you use?", style = style(24.sp, FontWeight.Bold))
        Text("Temperatures, wind, rain and snow, distances and pressure all follow your choice, on every screen, widget and notification.",
            style = style(15.sp, color = White82), textAlign = TextAlign.Center)
        for (preset in UnitPreset.entries) {
            val s = preset.settings
            val sample = listOf(WeatherFormat.temperature(21.0, s.temperature), WeatherFormat.wind(20.0, s.wind),
                WeatherFormat.precipitationTotals(25.0, null, s.precipitation) ?: "", WeatherFormat.distance(3.0, s.distance) ?: "")
                .joinToString(" · ")
            val selected = choice == preset
            Row(
                Modifier.fillMaxWidth().clip14()
                    .background(Color.White.copy(alpha = if (selected) 0.25f else 0.10f))
                    .border(1.5.dp, Color.White.copy(alpha = if (selected) 0.8f else 0.2f), RoundedCornerShape(14.dp))
                    .clickable { choice = preset }.padding(14.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Text(preset.label, style = style(17.sp, FontWeight.SemiBold))
                    Text(preset.detail, style = style(15.sp, color = White82))
                    Text("e.g. $sample", style = style(13.sp, color = Color.White.copy(alpha = 0.7f)))
                }
                Icon(if (selected) Icons.Filled.CheckCircle else Icons.Filled.RadioButtonUnchecked, null,
                    tint = Color.White, modifier = Modifier.size(26.dp))
            }
        }
        Text("You can change any single unit later in Settings.", style = style(13.sp, color = Color.White.copy(alpha = 0.75f)))
        Spacer(Modifier.height(4.dp))
        Button(
            onClick = { Prefs.saveUnits(choice.settings); Prefs.unitsChosen = true; onDone() },
            colors = ButtonDefaults.buttonColors(containerColor = Color.White, contentColor = Color(0xFF1565C0)),
            modifier = Modifier.fillMaxWidth(),
        ) { Text("Continue", style = style(17.sp, FontWeight.SemiBold, Color(0xFF1565C0)), modifier = Modifier.padding(vertical = 4.dp)) }
    }
}

private fun Modifier.clip14() = this.then(Modifier.clip(RoundedCornerShape(14.dp)))
