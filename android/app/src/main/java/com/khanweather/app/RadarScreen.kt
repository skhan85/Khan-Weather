package com.khanweather.app

import android.annotation.SuppressLint
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import com.khanweather.core.Coordinate
import java.util.Locale

/**
 * Environment Canada radar (last hour, looping, plus RainViewer's short nowcast when it has one)
 * and HRDPS temperature, wind and cloud maps, drawn with Leaflet in a WebView.
 */
@SuppressLint("SetJavaScriptEnabled")
@Composable
fun RadarScreen(center: Coordinate) {
    val twelve = Prefs.clock != "twentyFourHour"
    AndroidView(modifier = Modifier.fillMaxSize(), factory = { ctx ->
        WebView(ctx).apply {
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.userAgentString = settings.userAgentString + " KhanWeather-Android"
            webViewClient = WebViewClient()
            loadDataWithBaseURL("https://khanweather.local/", radarHtml(center, twelve), "text/html", "utf-8", null)
        }
    })
}

private fun radarHtml(c: Coordinate, twelve: Boolean) = """
<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
<link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css">
<script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
<style>
 html,body,#map{margin:0;height:100%;background:#1b2636;font-family:sans-serif}
 .bar{position:absolute;left:12px;right:12px;z-index:1000;background:rgba(20,24,32,.86);color:#fff;border-radius:14px;padding:10px 12px;box-sizing:border-box}
 #top{top:12px;display:flex;gap:6px;padding:6px}
 #top button{flex:1;border:0;border-radius:9px;padding:8px 0;background:transparent;color:#fff;font-size:14px;font-weight:600}
 #top button.on{background:#ffc752;color:#111}
 #bottom{bottom:16px;display:flex;align-items:center;gap:12px}
 #play{width:36px;height:36px;border:0;border-radius:18px;background:#ffc752;color:#111;font-size:16px;font-weight:700}
 #slider{flex:1;accent-color:#ffc752}
 #time{min-width:70px;text-align:right;font-size:14px;font-variant-numeric:tabular-nums}
 #fc{color:#ff9f40;font-size:11px;font-weight:800;display:block}
 #legend{bottom:16px;display:none;font-size:12px}
 #legend img{max-height:150px;display:block;margin-top:6px;background:#fff;border-radius:6px}
</style></head><body><div id="map"></div>
<div id="top" class="bar">
 <button data-l="radar" class="on">Rain/snow</button><button data-l="temp">Temp</button>
 <button data-l="wind">Wind</button><button data-l="clouds">Clouds</button></div>
<div id="bottom" class="bar"><button id="play">❚❚</button><input id="slider" type="range" min="0" max="9" step="1">
 <div id="time"></div></div>
<div id="legend" class="bar"><span id="credit"></span><img id="legimg"></div>
<script>
var twelve=$twelve;
var map=L.map('map',{zoomControl:false,attributionControl:true}).setView([${fmt(c.latitude)},${fmt(c.longitude)}],8);
L.tileLayer('https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}{r}.png',{maxZoom:12,subdomains:'abcd',
 attribution:'© OpenStreetMap, © CARTO · Radar © Environment Canada'}).addTo(map);
L.circleMarker([${fmt(c.latitude)},${fmt(c.longitude)}],{radius:7,color:'#fff',weight:2,fillColor:'#ffc752',fillOpacity:1}).addTo(map);
var WMS='https://geo.weather.gc.ca/geomet';
var models={temp:['HRDPS.CONTINENTAL_TT','Temperature at 2 m'],wind:['HRDPS.CONTINENTAL_UU','Wind speed at 10 m'],clouds:['HRDPS.CONTINENTAL_NT','Cloud cover']};
var frames=[],layers=[],idx=0,playing=true,mode='radar',modelLayer=null;
function fmtTime(d){var h=d.getHours(),m=('0'+d.getMinutes()).slice(-2);
 if(!twelve)return ('0'+h).slice(-2)+':'+m; var ap=h<12?'am':'pm';h=h%12||12;return h+':'+m+' '+ap;}
function recent(){var step=360e3,latest=Math.floor((Date.now()-540e3)/step)*step,a=[];
 for(var i=9;i>=0;i--)a.push({time:new Date(latest-i*step)});return a;}
function makeLayer(f){
 if(f.template)return L.tileLayer(f.template,{opacity:0,maxNativeZoom:7,maxZoom:12});
 return L.tileLayer.wms(WMS,{layers:'RADAR_1KM_RRAI,RADAR_1KM_RSNO',format:'image/png',transparent:true,version:'1.3.0',
  time:f.time.toISOString().split('.')[0]+'Z',opacity:0});}
function build(){layers.forEach(function(l){map.removeLayer(l)});layers=frames.map(function(f){var l=makeLayer(f);l.addTo(map);return l;});
 var s=document.getElementById('slider');s.max=Math.max(frames.length-1,1);idx=frames.length-1;show(idx);}
function show(i){idx=i;layers.forEach(function(l,j){l.setOpacity(j==i?0.75:0)});document.getElementById('slider').value=i;
 var f=frames[i];document.getElementById('time').innerHTML=fmtTime(f.time)+(f.template?'<span id="fc">FORECAST</span>':'');}
frames=recent();build();
fetch('https://api.rainviewer.com/public/weather-maps.json').then(function(r){return r.json()}).then(function(m){
 var now=(m.radar&&m.radar.nowcast)||[];var latest=frames[frames.length-1].time.getTime();
 var ahead=now.filter(function(f){return f.time*1000>latest}).map(function(f){return{time:new Date(f.time*1000),template:m.host+f.path+'/256/{z}/{x}/{y}/2/1_1.png'}});
 if(ahead.length){frames=frames.concat(ahead);build();}}).catch(function(){});
setInterval(function(){if(playing&&mode=='radar'&&frames.length)show((idx+1)%frames.length)},700);
document.getElementById('play').onclick=function(){playing=!playing;this.textContent=playing?'❚❚':'▶';};
document.getElementById('slider').oninput=function(){playing=false;document.getElementById('play').textContent='▶';show(+this.value)};
document.querySelectorAll('#top button').forEach(function(b){b.onclick=function(){
 document.querySelectorAll('#top button').forEach(function(x){x.classList.remove('on')});b.classList.add('on');mode=b.dataset.l;
 if(modelLayer){map.removeLayer(modelLayer);modelLayer=null;}
 var radar=mode=='radar';document.getElementById('bottom').style.display=radar?'flex':'none';
 document.getElementById('legend').style.display=radar?'none':'block';
 if(radar){show(idx);return;}
 layers.forEach(function(l){l.setOpacity(0)});
 var m=models[mode];modelLayer=L.tileLayer.wms(WMS,{layers:m[0],format:'image/png',transparent:true,version:'1.3.0',opacity:0.6}).addTo(map);
 document.getElementById('credit').textContent=m[1]+', Environment Canada HRDPS model, latest hour.';
 document.getElementById('legimg').src=WMS+'?service=WMS&version=1.3.0&request=GetLegendGraphic&layer='+m[0]+'&format=image/png&sld_version=1.1.0';
}});
</script></body></html>
"""

private fun fmt(d: Double) = String.format(Locale.US, "%.4f", d)
