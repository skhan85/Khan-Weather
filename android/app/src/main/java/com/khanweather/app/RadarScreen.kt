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
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.khanweather.core.Coordinate
import com.khanweather.core.DistanceUnit
import com.khanweather.core.UnitSettings
import java.util.Locale

/**
 * Environment Canada radar (last 1 or 3 hours, looping, plus RainViewer's short nowcast when it
 * has one), lightning, warnings and distance rings, and HRDPS temperature, wind and cloud maps,
 * drawn with Leaflet in a WebView. Outside Canada and the US, RainViewer's worldwide radar.
 */
@Composable
fun RadarScreen(center: Coordinate) {
    RadarWebView(center, card = false, Modifier.fillMaxSize())
}

/** The main screen's small looping radar. Tapping it opens the full map. */
@Composable
fun RadarCard(center: Coordinate, onOpen: () -> Unit) {
    Column {
        Box(Modifier.fillMaxWidth().height(210.dp).clip(RoundedCornerShape(12.dp))) {
            RadarWebView(center, card = true, Modifier.matchParentSize())
            // Over the map, so a tap opens the full radar instead of panning the little one.
            Box(Modifier.matchParentSize().clickable(onClick = onOpen))
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
private fun RadarWebView(center: Coordinate, card: Boolean, modifier: Modifier) {
    val twelve = Prefs.clock != "twentyFourHour"
    val miles = UnitSettings.current.distance == DistanceUnit.mi
    AndroidView(modifier = modifier, factory = { ctx ->
        WebView(ctx).apply {
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.userAgentString = settings.userAgentString + " KhanWeather-Android"
            webViewClient = WebViewClient()
            // The map's JavaScript messages and errors go to logcat (tag KhanWeatherRadar).
            webChromeClient = object : android.webkit.WebChromeClient() {
                override fun onConsoleMessage(m: android.webkit.ConsoleMessage): Boolean {
                    android.util.Log.i("KhanWeatherRadar", "${m.messageLevel()} ${m.message()} (line ${m.lineNumber()})")
                    return true
                }
            }
            setBackgroundColor(android.graphics.Color.parseColor("#1b2636"))
            val html = radarHtml(center, twelve, miles, card, radarCovers(center))
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
    })
}

private fun radarHtml(c: Coordinate, twelve: Boolean, miles: Boolean, card: Boolean, covered: Boolean) = """
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
 #bottom{bottom:16px}
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
 #legend{bottom:16px;display:none;font-size:12px}
 #legend img{max-height:150px;display:block;margin-top:6px;background:#fff;border-radius:6px}
 #me{position:absolute;right:12px;z-index:1000;width:40px;height:40px;border:0;border-radius:20px;background:rgba(20,24,32,.86);color:#ffc752;font-size:20px}
 #badge{position:absolute;top:8px;left:8px;z-index:1000;color:#fff;font-size:12px;font-weight:700;padding:4px 8px;border-radius:10px;background:rgba(0,0,0,.55);font-variant-numeric:tabular-nums}
 #badge.fc{background:rgba(255,140,0,.85)}
 .ring{color:#fff;font-size:11px;font-weight:700;background:rgba(0,0,0,.55);border-radius:6px;padding:1px 5px;white-space:nowrap}
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
var twelve=$twelve, miles=$miles, card=$card, covered=$covered;
var here=[${fmt(c.latitude)},${fmt(c.longitude)}];
function pref(k,d){try{var v=localStorage.getItem('radar.'+k);return v==null?d:JSON.parse(v)}catch(e){return d}}
function save(k,v){try{localStorage.setItem('radar.'+k,JSON.stringify(v))}catch(e){}}
var opt=card?{hours:1,lightning:true,warnings:false,rings:true}
 :{hours:pref('hours',1),lightning:pref('lightning',true),warnings:pref('warnings',false),rings:pref('rings',true)};
// RainViewer's free tiles stop at zoom 7, so outside Environment Canada's radar start wider.
var zoom=covered?8:6;
var map=L.map('map',{zoomControl:false,attributionControl:!card,dragging:!card,touchZoom:!card,scrollWheelZoom:!card,
 doubleClickZoom:!card,boxZoom:!card,keyboard:!card}).setView(here,zoom);
L.tileLayer('https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}{r}.png',{maxZoom:12,subdomains:'abcd',
 attribution:'© OpenStreetMap, © CARTO · Radar © Environment Canada, RainViewer'}).addTo(map);
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
function recent(hours){var six=360e3,latest=Math.floor((Date.now()-540e3)/six)*six,step=hours>1?2*six:six,
 n=hours>1?Math.floor((hours*3600e3-six)/step)+1:10,a=[];
 for(var i=n-1;i>=0;i--)a.push({time:new Date(latest-i*step)});return a;}
function latestPast(){for(var i=frames.length-1;i>=0;i--)if(!frames[i].forecast)return i;return Math.max(0,frames.length-1);}
function rel(f){var m=Math.round((f.time-frames[latestPast()].time)/60000);return m==0?'Now':m<0?(-m)+' min ago':'in '+m+' min';}
function makeLayer(f){
 if(f.template)return L.tileLayer(f.template,{opacity:0,maxNativeZoom:7,maxZoom:12});
 return L.tileLayer.wms(WMS,{layers:'RADAR_1KM_RRAI,RADAR_1KM_RSNO',format:'image/png',transparent:true,version:'1.3.0',
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
 frames=covered?recent(opt.hours):[];build();
 fetch('https://api.rainviewer.com/public/weather-maps.json').then(function(r){return r.json()}).then(function(m){
  function conv(list,fc){return (list||[]).map(function(f){return{time:new Date(f.time*1000),forecast:fc,template:m.host+f.path+'/256/{z}/{x}/{y}/2/1_1.png'}})}
  var past=conv(m.radar&&m.radar.past,false),ahead=conv(m.radar&&m.radar.nowcast,true);
  if(!covered){frames=past.concat(ahead);build();return;}
  var latest=frames.length?frames[frames.length-1].time.getTime():0;
  ahead=ahead.filter(function(f){return f.time.getTime()>latest});
  if(ahead.length){frames=frames.concat(ahead);build();}}).catch(function(){if(!covered)build();});}
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
 h+='<button class="chip'+(opt.rings?' on':'')+'" data-o="rings">◎ Rings</button>';el.innerHTML=h;
 el.querySelectorAll('[data-h]').forEach(function(b){b.onclick=function(){opt.hours=+b.dataset.h;save('hours',opt.hours);chips();load();}});
 el.querySelectorAll('[data-o]').forEach(function(b){b.onclick=function(){var k=b.dataset.o;opt[k]=!opt[k];save(k,opt[k]);chips();setExtras();setRings();}});}
chips();load();setExtras();setRings();
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
