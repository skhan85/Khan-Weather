#!/usr/bin/env bash
# Runs inside the emulator job: installs the APK, puts the phone in Milton and saves screenshots.
set -x
PKG=com.khanweather.app
mkdir -p shots
adb install -r KhanWeather.apk
adb shell pm grant $PKG android.permission.ACCESS_FINE_LOCATION
adb shell pm grant $PKG android.permission.ACCESS_COARSE_LOCATION
adb shell pm grant $PKG android.permission.POST_NOTIFICATIONS || true
adb shell settings put secure location_mode 3 || true
adb emu geo fix -79.8774 43.5183
sleep 2
# Google Maps or another app asking for location wakes the fused provider; this gets a first fix in.
adb shell am start -a android.intent.action.VIEW -d "geo:43.5183,-79.8774" >/dev/null 2>&1 || true
sleep 5
adb emu geo fix -79.8774 43.5183
adb shell am force-stop com.google.android.apps.maps || true
adb shell am start -n $PKG/.MainActivity
sleep 45
adb emu geo fix -79.8774 43.5183
adb exec-out screencap -p > shots/android-main-1.png
for i in 2 3 4 5; do
  adb shell input swipe 540 1900 540 500 400
  sleep 3
  adb exec-out screencap -p > shots/android-main-$i.png
done
# Widget preview screen
adb shell am start -S -n $PKG/.MainActivity --ez widgetPreview true
sleep 8
adb exec-out screencap -p > shots/android-widgets.png
adb logcat -d | grep -iE "khanweather|AndroidRuntime" | tail -80 > shots/logcat.txt || true
ls -l shots
