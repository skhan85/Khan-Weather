package com.khanweather.app

import android.annotation.SuppressLint
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.khanweather.core.Coordinate
import com.khanweather.core.DistanceUnit
import com.khanweather.core.RadarFreshness
import com.khanweather.core.UnitSettings
import kotlinx.coroutines.delay
import java.util.Locale

/**
 * Environment Canada radar (last 1 or 3 hours, looping, plus RainViewer's short nowcast when it
 * has one), lightning, warnings and distance rings, and HRDPS temperature, wind and cloud maps,
 * drawn with Leaflet in a WebView. Outside Canada and the US, RainViewer's worldwide radar.
 */
@Composable
fun RadarScreen(center: Coordinate) {
    RadarWebView(center, card = false, Modifier.fillMaxSize(), rememberLatestRadarFrame(center))
}

/** The newest radar frame for this spot (Environment Canada's, else RainViewer's), or null until known. */
@Composable
private fun rememberLatestRadarFrame(center: Coordinate): Long? {
    var latest by remember(center) { mutableStateOf<Long?>(null) }
    LaunchedEffect(center) {
        latest = if (radarCovers(center)) RadarFreshness.latestEcccFrame() else RadarFreshness.latestRainViewerFrame()
    }
    return latest
}

/** The main screen's small looping radar. Tapping it opens the full map. */
@Composable
fun RadarCard(center: Coordinate, onOpen: () -> Unit) {
    val latest = rememberLatestRadarFrame(center)
    // Re-reads the clock every 30 s so "6 min ago" keeps up while the screen stays open.
    var nowMs by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) { while (true) { delay(30_000); nowMs = System.currentTimeMillis() } }
    Column {
        Box(Modifier.fillMaxWidth().height(210.dp).clip(RoundedCornerShape(12.dp))) {
            RadarWebView(center, card = true, Modifier.matchParentSize(), latest)
            // Over the map, so a tap opens the full radar instead of panning the little one.
            Box(Modifier.matchParentSize().clickable(onClick = onOpen))
        }
        if (latest != null) {
            val fresh = RadarFreshness.level(latest, nowMs) == RadarFreshness.Level.FRESH
            Text(
                (if (fresh) "" else "⚠ ") + RadarFreshness.text(latest, nowMs),
                style = style(13.sp, FontWeight.SemiBold, color = if (fresh) White82 else Color(0xFFFF9F40)),
                modifier = Modifier.padding(top = 8.dp),
            )
        }
        Text(
            if (radarCovers(center)) "Rain and snow, last hour. Tap for the full map with lightning and warnings."
            else "Rain and snow, last 2 hours. Tap for the full map.",
            style = style(13.sp, color = White82), modifier = Modifier.padding(top = 8.dp),
        )
    }
}

@SuppressLint("SetJavaScriptEnabled")
@Composable
private fun RadarWebView(center: Coordinate, card: Boolean, modifier: Modifier, latest: Long?) {
    val twelve = Prefs.clock != "twentyFourHour"
    val miles = UnitSettings.current.distance == DistanceUnit.mi
    val fahr = UnitSettings.current.temperature.convert(0.0) > 1.0
    AndroidView(modifier = modifier, factory = { ctx ->
        WebView(ctx).apply {
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.userAgentString = settings.userAgentString + " KhanWeather-Android"
            webViewClient = object : WebViewClient() {
                override fun onPageFinished(view: WebView, url: String?) {
                    (view.tag as? Long)?.let { view.evaluateJavascript("setLatest($it)", null) }
                }
            }
            // The map's JavaScript messages and errors go to logcat (tag KhanWeatherRadar).
            webChromeClient = object : android.webkit.WebChromeClient() {
                override fun onConsoleMessage(m: android.webkit.ConsoleMessage): Boolean {
                    android.util.Log.i("KhanWeatherRadar", "${m.messageLevel()} ${m.message()} (line ${m.lineNumber()})")
                    return true
                }
            }
            setBackgroundColor(android.graphics.Color.parseColor("#1b2636"))
            val html = radarHtml(center, twelve, miles, fahr, card, radarCovers(center))
            // Load once the view has its real size: a map started at 0×0 draws no tiles.
            var loaded = false
            fun loadIfSized() {
                if (loaded || width == 0 || height == 0) return
                loaded = true
                loadDataWithBaseURL("https://khanweather.local/", html, "text/html", "utf-8", null)
            }
            addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> loadIfSized() }
            post { loadIfSized() }
        }
    }, update = { view ->
        if (latest != null && view.tag != latest) {
            view.tag = latest
            view.evaluateJavascript("if(window.setLatest)setLatest($latest)", null)
        }
    })
}

private fun radarHtml(c: Coordinate, twelve: Boolean, miles: Boolean, fahr: Boolean, card: Boolean, covered: Boolean) = """
<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
<link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css">
<script>window.onerror=function(m,u,l){console.log('radar error '+m+' line '+l)};window.L_DISABLE_3D=true;/* plain 2D positioning: some WebViews draw nothing for 3D-transformed map panes */</script>
<script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
<style>
 html,body{margin:0;height:100%;background:#1b2636;font-family:sans-serif}
 #map{position:fixed;top:0;left:0;right:0;bottom:0;background:#1b2636}
 .bar{position:fixed;left:12px;right:12px;z-index:1000;background:rgba(20,24,32,.86);color:#fff;border-radius:14px;padding:10px 12px;box-sizing:border-box}
 #top{top:12px;display:flex;gap:6px;padding:6px}
 #top button{flex:1;border:0;border-radius:9px;padding:8px 0;background:transparent;color:#fff;font-size:14px;font-weight:600}
 #top button.on{background:#ffc752;color:#111}
 #bottom{bottom:30px}
 .row{display:flex;align-items:center;gap:12px}
 #chips{display:flex;gap:6px;overflow-x:auto;margin-bottom:8px}
 .chip{border:0;border-radius:14px;padding:6px 10px;background:rgba(255,255,255,.12);color:#fff;font-size:12px;font-weight:700;white-space:nowrap}
 .chip.on{background:#ffc752;color:#111}
 #key{display:flex;align-items:center;gap:6px;font-size:11px;font-weight:600;color:#cfd6e0;margin-bottom:8px}
 #key .ramp{flex:1;height:6px;border-radius:3px;background:linear-gradient(90deg,#99ccff,#008cff,#1abf33,#ffe600,#ff8000,#e60000,#cc00cc)}
 #bolt{display:none;color:#ffe600}
 #play{width:36px;height:36px;border:0;border-radius:18px;background:#ffc752;color:#111;font-size:16px;font-weight:700}
 #slider{flex:1;accent-color:#ffc752}
 #time{min-width:76px;text-align:right;font-size:14px;font-weight:600;font-variant-numeric:tabular-nums}
 #rel{color:#cfd6e0;font-size:11px;font-weight:800;display:block}
 #rel.fc{color:#ff9f40}
 #legend{bottom:30px;display:none;font-size:12px}
 #legend img{max-height:150px;display:block;margin-top:6px;background:#fff;border-radius:6px}
 #me{position:absolute;right:12px;z-index:1000;width:40px;height:40px;border:0;border-radius:20px;background:rgba(20,24,32,.86);color:#ffc752;font-size:20px}
 #badge{position:absolute;top:8px;left:8px;z-index:1000;color:#fff;font-size:12px;font-weight:700;padding:4px 8px;border-radius:10px;background:rgba(0,0,0,.55);font-variant-numeric:tabular-nums}
 #badge.fc{background:rgba(255,140,0,.85)}
 .ring{color:#fff;font-size:11px;font-weight:700;background:rgba(0,0,0,.55);border-radius:6px;padding:1px 5px;white-space:nowrap}
 .pws{background:rgba(20,24,32,.88);color:#fff;border:1.5px solid #ffc752;border-radius:10px;padding:1px 6px;font-size:11px;font-weight:700;white-space:nowrap}
 #note{position:absolute;left:0;right:0;top:50%;text-align:center;color:#fff;z-index:900;display:none}
</style></head><body><div id="map"></div><div id="note">Loading radar…</div>
<div id="top" class="bar">
 <button data-l="radar" class="on">Rain/snow</button><button data-l="temp">Temp</button>
 <button data-l="wind">Wind</button><button data-l="clouds">Clouds</button></div>
<button id="me" aria-label="Back to my location">◎</button>
<div id="badge"></div>
<div id="bottom" class="bar">
 <div id="chips"></div>
 <div id="key"><span>Light</span><span class="ramp"></span><span>Heavy</span><span id="bolt">⚡ Lightning, last 10 min</span></div>
 <div class="row"><button id="play">❚❚</button><input id="slider" type="range" min="0" max="9" step="1">
 <div id="time"></div></div></div>
<div id="legend" class="bar"><span id="credit"></span><img id="legimg"></div>
<script>
var twelve=$twelve, miles=$miles, fahr=$fahr, card=$card, covered=$covered;
var here=[${fmt(c.latitude)},${fmt(c.longitude)}];
function pref(k,d){try{var v=localStorage.getItem('radar.'+k);return v==null?d:JSON.parse(v)}catch(e){return d}}
function save(k,v){try{localStorage.setItem('radar.'+k,JSON.stringify(v))}catch(e){}}
var opt=card?{hours:1,lightning:true,warnings:false,rings:true,stations:false}
 :{hours:pref('hours',1),lightning:pref('lightning',true),warnings:pref('warnings',false),rings:pref('rings',true),stations:pref('stations',true)};
// RainViewer's free tiles stop at zoom 7, so outside Environment Canada's radar start wider.
var zoom=covered?8:6;
var map=L.map('map',{zoomControl:false,attributionControl:!card,dragging:!card,touchZoom:!card,scrollWheelZoom:!card,
 doubleClickZoom:!card,boxZoom:!card,keyboard:!card}).setView(here,zoom);
// OpenStreetMap's own tiles: CARTO's free base map now needs an API key.
L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png',{maxZoom:12,
 attribution:'© OpenStreetMap contributors · Radar © Environment Canada, RainViewer'}).addTo(map);
map.createPane('extras');map.getPane('extras').style.zIndex=450;
map.createPane('rings');map.getPane('rings').style.zIndex=460;map.getPane('rings').style.pointerEvents='none';
L.circleMarker(here,{radius:7,color:'#fff',weight:2,fillColor:'#ffc752',fillOpacity:1,pane:'rings'}).addTo(map);
var WMS='https://geo.weather.gc.ca/geomet';
var models={temp:['HRDPS.CONTINENTAL_TT','Temperature at 2 m'],wind:['HRDPS.CONTINENTAL_UU','Wind speed at 10 m'],clouds:['HRDPS.CONTINENTAL_NT','Cloud cover']};
var extras={lightning:['Lightning_2.5km_Density',0.95],warnings:['Current-Alerts',0.4]};
var frames=[],layers=[],idx=0,hold=0,playing=true,mode='radar',modelLayer=null,extraLayers={},ringLayer=null;
if(card){['top','bottom','me'].forEach(function(id){document.getElementById(id).style.display='none'})}
else document.getElementById('badge').style.display='none';
if(!covered)document.getElementById('top').style.display='none';
document.getElementById('me').style.top=covered?'72px':'12px';
function fmtTime(d){var h=d.getHours(),m=('0'+d.getMinutes()).slice(-2);
 if(!twelve)return ('0'+h).slice(-2)+':'+m; var ap=h<12?'am':'pm';h=h%12||12;return h+':'+m+' '+ap;}
// GeoMet publishes a frame every 6 minutes, a few minutes late, and keeps three hours.
// Three hours shows every second frame so the loop stays short.
// latestKnown: GeoMet's newest published frame (sent in from the app), so a late radar's loop
// ends at a frame that exists rather than at blank ones.
var latestKnown=null;
function recent(hours){var six=360e3,now=Date.now(),latest=Math.floor((now-540e3)/six)*six,step=hours>1?2*six:six,
 n=hours>1?Math.floor((hours*3600e3-six)/step)+1:10,a=[],oldest=now-3*3600e3+six;
 if(latestKnown&&latestKnown<=now+60e3&&now-latestKnown<3*3600e3)latest=latestKnown;
 for(var i=n-1;i>=0;i--){var t=latest-i*step;if(t>=oldest)a.push({time:new Date(t)});}return a;}
function setLatest(ms){if(latestKnown===ms)return;latestKnown=ms;if(covered)load();}
function latestPast(){for(var i=frames.length-1;i>=0;i--)if(!frames[i].forecast)return i;return Math.max(0,frames.length-1);}
// From the clock, so a late radar's newest frame doesn't read "Now".
function rel(f){var m=Math.round((f.time-Date.now())/60000);return Math.abs(m)<=2?'Now':m<0?(-m)+' min ago':'in '+m+' min';}
function makeLayer(f){
 if(f.template)return L.tileLayer(f.template,{opacity:0,maxNativeZoom:7,maxZoom:12});
 return L.tileLayer.wms(WMS,{layers:f.layers||'RADAR_1KM_RRAI,RADAR_1KM_RSNO',format:'image/png',transparent:true,version:'1.3.0',
  time:f.time.toISOString().split('.')[0]+'Z',opacity:0});}
function build(){layers.forEach(function(l){map.removeLayer(l)});layers=frames.map(function(f){var l=makeLayer(f);l.addTo(map);return l;});
 var s=document.getElementById('slider');s.max=Math.max(frames.length-1,1);idx=latestPast();hold=0;
 document.getElementById('note').style.display=frames.length?'none':'block';
 if(!frames.length)document.getElementById('note').textContent='No radar for this area right now.';
 if(frames.length)show(idx);}
function show(i){idx=i;layers.forEach(function(l,j){l.setOpacity(j==i&&mode=='radar'?0.75:0)});document.getElementById('slider').value=i;
 var f=frames[i],r=rel(f);
 document.getElementById('time').innerHTML=fmtTime(f.time)+'<span id="rel" class="'+(f.forecast?'fc':'')+'">'+r+'</span>';
 var b=document.getElementById('badge');b.textContent=(f.forecast?'⟳ ':'')+fmtTime(f.time)+' · '+r;b.className=f.forecast?'fc':'';}
var rv=null;
function load(){
 if(covered){
  var past=recent(opt.hours);
  var latest=past.length?past[past.length-1].time.getTime():Date.now();
  var ahead=[1,2,3,4,5].map(function(k){return{time:new Date(latest+k*720e3),forecast:true,layers:'Radar_1km_RainPrecipRate-Extrapolation'}});
  frames=past.concat(ahead);build();return;
 }
 frames=[];build();
 fetch('https://api.rainviewer.com/public/weather-maps.json').then(function(r){return r.json()}).then(function(m){
  function conv(list,fc){return (list||[]).map(function(f){return{time:new Date(f.time*1000),forecast:fc,template:m.host+f.path+'/256/{z}/{x}/{y}/2/1_1.png'}})}
  frames=conv(m.radar&&m.radar.past,false).concat(conv(m.radar&&m.radar.nowcast,true));build();
 }).catch(function(){build();});}
// One frame every half second; linger on "now" and on the last frame before starting over.
setInterval(function(){if(!playing||mode!='radar'||frames.length<2)return;var lp=latestPast();
 if((idx==lp||idx>=frames.length-1)&&hold<3){hold++;return;}hold=0;show(idx>=frames.length-1?0:idx+1)},500);
function setExtras(){Object.keys(extras).forEach(function(k){var want=covered&&mode=='radar'&&opt[k];
 if(want&&!extraLayers[k])extraLayers[k]=L.tileLayer.wms(WMS,{layers:extras[k][0],format:'image/png',transparent:true,version:'1.3.0',
  opacity:extras[k][1],pane:'extras'}).addTo(map);
 if(!want&&extraLayers[k]){map.removeLayer(extraLayers[k]);delete extraLayers[k];}});
 document.getElementById('bolt').style.display=extraLayers.lightning?'inline':'none';}
// Rings around your spot: 10, 25 and 50 km, or 5, 15 and 30 miles.
var ringLabels=[];
// Hide ring labels that would sit on top of each other (or of your spot) at this zoom.
function spaceLabels(){var mid=map.latLngToContainerPoint(here).y,last=0;ringLabels.forEach(function(m){
 var up=mid-map.latLngToContainerPoint(m.getLatLng()).y,show=up>=22&&up-last>=22,el=m.getElement();
 if(el)el.style.display=show?'':'none';if(show)last=up;});}
map.on('zoomend',spaceLabels);
function setRings(){if(ringLayer){map.removeLayer(ringLayer);ringLayer=null;}ringLabels=[];if(!opt.rings)return;
 var radii=miles?[[5*1609.344,'5 mi'],[15*1609.344,'15 mi'],[30*1609.344,'30 mi']]:[[10e3,'10 km'],[25e3,'25 km'],[50e3,'50 km']];
 ringLayer=L.layerGroup(radii.map(function(r){
  var circle=L.circle(here,{radius:r[0],color:'#fff',weight:1.5,opacity:.85,dashArray:'6 5',fill:false,pane:'rings',interactive:false});
  var top=[here[0]+r[0]/111000,here[1]];
  var label=L.marker(top,{pane:'rings',interactive:false,icon:L.divIcon({className:'',html:'<span class="ring">'+r[1]+'</span>',iconSize:null,iconAnchor:[18,9]})});
  ringLabels.push(label);return L.layerGroup([circle,label]);})).addTo(map);spaceLabels();}
function chips(){var el=document.getElementById('chips'),h='';
 if(covered){[1,3].forEach(function(n){h+='<button class="chip'+(opt.hours==n?' on':'')+'" data-h="'+n+'">'+n+' h</button>'});
  h+='<button class="chip'+(opt.lightning?' on':'')+'" data-o="lightning">⚡ Lightning</button>';
  h+='<button class="chip'+(opt.warnings?' on':'')+'" data-o="warnings">⚠ Warnings</button>';}
 h+='<button class="chip'+(opt.rings?' on':'')+'" data-o="rings">◎ Rings</button>';
 h+='<button class="chip'+(opt.stations?' on':'')+'" data-o="stations">⌂ Stations</button>';el.innerHTML=h;
 el.querySelectorAll('[data-h]').forEach(function(b){b.onclick=function(){opt.hours=+b.dataset.h;save('hours',opt.hours);chips();load();}});
 el.querySelectorAll('[data-o]').forEach(function(b){b.onclick=function(){var k=b.dataset.o;opt[k]=!opt[k];save(k,opt[k]);chips();setExtras();setRings();setStations();}});}
var pwsLayer=null,pwsData=null;
function drawStations(list){
 if(pwsLayer){map.removeLayer(pwsLayer);pwsLayer=null;}
 if(!opt.stations||!list||!list.length)return;
 var ms=[];
 list.forEach(function(st){
  if(st.lat==null||st.lon==null||st.temperature==null)return;
  var t=Math.round(fahr?(st.temperature*9/5+32):st.temperature)+'°';
  var tip='<b>'+t+'</b>';
  if(st.humidity!=null)tip+=' · '+Math.round(st.humidity)+'% RH';
  if(st.rain_1h!=null&&st.rain_1h>0)tip+=' · '+st.rain_1h.toFixed(1)+' mm/h';
  var mk=L.marker([st.lat,st.lon],{icon:L.divIcon({className:'',html:'<span class="pws">'+t+'</span>',iconSize:null,iconAnchor:[16,10]})});
  mk.bindPopup(tip);ms.push(mk);
 });
 pwsLayer=L.layerGroup(ms).addTo(map);
}
function setStations(){
 if(!opt.stations){if(pwsLayer){map.removeLayer(pwsLayer);pwsLayer=null;}return;}
 if(pwsData){drawStations(pwsData);return;}
 fetch('https://weather-relay.khanofmilton.ca/v1/netatmo?lat='+here[0]+'&lon='+here[1])
  .then(function(r){return r.json()}).then(function(d){pwsData=(d&&d.stations)||[];drawStations(pwsData);}).catch(function(){});
}
chips();load();setExtras();setRings();setStations();
document.getElementById('me').onclick=function(){map.setView(here,zoom)};
// Redraw at the right size if the view changes size after loading.
window.addEventListener('resize',function(){map.invalidateSize()});
if(window.ResizeObserver)new ResizeObserver(function(){map.invalidateSize()}).observe(document.getElementById('map'));
setTimeout(function(){map.invalidateSize();map.setView(here,zoom);
 var r=document.getElementById('map').getBoundingClientRect();
 console.log('radar map '+r.width+'x'+r.height+' leaflet css '+(getComputedStyle(map.getPane('tilePane')).position));},600);
var tileErrors=0;map.eachLayer(function(l){if(l.on)l.on('tileerror',function(e){if(tileErrors++<3)console.log('tile error '+(e.tile&&e.tile.src))})});
document.getElementById('play').onclick=function(){playing=!playing;this.textContent=playing?'❚❚':'▶';};
document.getElementById('slider').oninput=function(){playing=false;document.getElementById('play').textContent='▶';show(+this.value)};
document.querySelectorAll('#top button').forEach(function(b){b.onclick=function(){
 document.querySelectorAll('#top button').forEach(function(x){x.classList.remove('on')});b.classList.add('on');mode=b.dataset.l;
 if(modelLayer){map.removeLayer(modelLayer);modelLayer=null;}
 var radar=mode=='radar';document.getElementById('bottom').style.display=radar?'block':'none';
 document.getElementById('legend').style.display=radar?'none':'block';
 setExtras();
 if(radar){if(frames.length)show(idx);return;}
 layers.forEach(function(l){l.setOpacity(0)});
 var m=models[mode];modelLayer=L.tileLayer.wms(WMS,{layers:m[0],format:'image/png',transparent:true,version:'1.3.0',opacity:0.6}).addTo(map);
 document.getElementById('credit').textContent=m[1]+', Environment Canada HRDPS model, latest hour.';
 document.getElementById('legimg').src=WMS+'?service=WMS&version=1.3.0&request=GetLegendGraphic&layer='+m[0]+'&format=image/png&sld_version=1.1.0';
}});
</script></body></html>
"""

private fun fmt(d: Double) = String.format(Locale.US, "%.4f", d)
