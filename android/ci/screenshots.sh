#!/usr/bin/env bash
# Runs inside the emulator job: installs the APK, puts the phone in Milton and saves screenshots.
set -x
PKG=com.khanweather.app
A="timeout 60 adb"
mkdir -p shots
# The slow CI emulator often shows "Pixel Launcher isn't responding" over everything.
# Hide system error dialogs, and if one still shows, tap its "Wait" button.
dismiss() {
  timeout 20 adb shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1 || return 0
  local xy
  xy=$(timeout 10 adb shell cat /sdcard/ui.xml 2>/dev/null | grep -oE 'text="(Wait|Close app)"[^>]*bounds="\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]"' | head -1 \
    | sed -E 's/.*bounds="\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]".*/\1 \2 \3 \4/' | awk '{print int(($1+$3)/2), int(($2+$4)/2)}')
  if [ -n "$xy" ]; then $A shell input tap $xy; sleep 2; fi
}
shot() { dismiss; timeout 30 adb exec-out screencap -p > "shots/$1.png" || rm -f "shots/$1.png"; }
$A shell settings put global hide_error_dialogs 1 || true
$A shell pm disable-user --user 0 com.google.android.apps.nexuslauncher || true
sleep 15
dismiss
$A install -r KhanWeather.apk
$A shell pm grant $PKG android.permission.ACCESS_FINE_LOCATION
$A shell pm grant $PKG android.permission.ACCESS_COARSE_LOCATION
$A shell pm grant $PKG android.permission.POST_NOTIFICATIONS || true
$A shell settings put secure location_mode 3 || true
for i in 1 2 3; do $A emu geo fix -79.8774 43.5183; sleep 2; done
$A shell am start -n $PKG/.MainActivity
sleep 25
# First launch asks which units to use.
shot android-units-question
$A shell am start -S -n $PKG/.MainActivity --es units canadian
sleep 30
$A emu geo fix -79.8774 43.5183
shot android-main-1
for i in 2 3 4 5; do
  dismiss
  $A shell input swipe 540 1800 540 700 600
  sleep 4
  shot android-main-$i
done
# The same screen in US units.
$A shell am start -S -n $PKG/.MainActivity --es units us
sleep 30
shot android-main-us
$A shell input swipe 540 1800 540 700 600
sleep 4
shot android-main-us-2
$A shell am start -S -n $PKG/.MainActivity --es units canadian
sleep 5
# "What's it doing now?": the picker, then the Now card after a "Drizzle" report.
$A shell am start -S -n $PKG/.MainActivity --ez showReportSheet true
sleep 30
shot android-report-picker
$A shell am start -S -n $PKG/.MainActivity --es demoReport drizzle
sleep 30
shot android-reported-drizzle
$A shell am start -S -n $PKG/.MainActivity --es units canadian
sleep 5
# The home-screen widgets, drawn in the app from the same saved forecast.
$A shell am start -S -n $PKG/.MainActivity --ez widgetPreview true
sleep 10
shot android-widgets
# The full radar map: loop, lightning and rings.
$A shell am start -S -n $PKG/.MainActivity --ez radarScreen true
sleep 30
shot android-radar
timeout 30 adb logcat -d -s KhanWeatherRadar 2>/dev/null | tail -40 > shots/radar-log.txt || true
timeout 30 adb logcat -d 2>/dev/null | grep -iE "khanweather|AndroidRuntime|FATAL" | tail -80 > shots/logcat.txt || true
ls -l shots
