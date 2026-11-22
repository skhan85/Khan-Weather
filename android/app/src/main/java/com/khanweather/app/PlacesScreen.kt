package com.khanweather.app

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.khanweather.core.PlaceSearch
import com.khanweather.core.SavedPlace
import kotlinx.coroutines.delay

/** Pick the current location or a saved place, add places by name, remove them. */
@Composable
fun PlacesScreen(selectedId: String?, onSelect: (String?) -> Unit) {
    var places by remember { mutableStateOf(Prefs.places) }
    var query by remember { mutableStateOf("") }
    var results by remember { mutableStateOf<List<SavedPlace>>(emptyList()) }
    var searching by remember { mutableStateOf(false) }
    LaunchedEffect(query) {
        if (query.trim().length < 2) { results = emptyList(); return@LaunchedEffect }
        delay(350)
        searching = true
        results = runCatching { PlaceSearch().search(query) }.getOrDefault(emptyList())
        searching = false
    }
    Column(Modifier.verticalScroll(rememberScrollState()).padding(vertical = 8.dp)) {
        Section("Places", Icons.Filled.Place, PaddingValues(horizontal = 16.dp, vertical = 2.dp)) {
            PlaceRow(Icons.Filled.NearMe, "Current location", null, selectedId == null, onClick = { onSelect(null) })
            for (p in places) {
                RowDivider()
                PlaceRow(Icons.Filled.Place, p.name, p.detail, selectedId == p.id, onClick = { onSelect(p.id) }, onDelete = {
                    places = places.filter { it.id != p.id }
                    Prefs.places = places
                    if (selectedId == p.id) onSelect(null)
                })
            }
        }
        Section("Add a place", Icons.Filled.Search, PaddingValues(horizontal = 16.dp, vertical = 10.dp)) {
            OutlinedTextField(query, { query = it }, Modifier.fillMaxWidth(), placeholder = { Text("Town or city") }, singleLine = true,
                colors = OutlinedTextFieldDefaults.colors(focusedTextColor = Color.White, unfocusedTextColor = Color.White,
                    focusedBorderColor = Gold, unfocusedBorderColor = Color.White.copy(alpha = 0.4f), cursorColor = Gold,
                    focusedPlaceholderColor = White82, unfocusedPlaceholderColor = White82))
            if (searching) Text("Searching…", style = style(13.sp, color = White82), modifier = Modifier.padding(top = 8.dp))
            for (r in results) {
                PlaceRow(Icons.Filled.Add, r.name, r.detail, false, onClick = {
                    places = places + r
                    Prefs.places = places
                    query = ""
                    onSelect(r.id)
                })
            }
            Text("Place search: Open-Meteo and GeoNames (CC BY 4.0).", style = style(11.sp, color = Color.White.copy(alpha = 0.7f)), modifier = Modifier.padding(top = 8.dp))
        }
    }
}

@Composable
private fun PlaceRow(icon: androidx.compose.ui.graphics.vector.ImageVector, name: String, detail: String?, selected: Boolean,
                     onClick: () -> Unit, onDelete: (() -> Unit)? = null) {
    Row(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, tint = Gold, modifier = Modifier.size(20.dp))
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(name, style = style(16.sp, FontWeight.SemiBold))
            detail?.let { Text(it, style = style(13.sp, color = White82)) }
        }
        if (selected) Icon(Icons.Filled.Check, null, tint = Gold)
        if (onDelete != null) IconButton(onClick = onDelete) { Icon(Icons.Filled.Delete, "Remove", tint = White82) }
    }
}
