#!/usr/bin/env bash
# Runs inside the emulator job: installs the APK, puts the phone in Milton and saves screenshots.
set -x
PKG=com.khanweather.app
A="timeout 60 adb"
mkdir -p shots
shot() { timeout 30 adb exec-out screencap -p > "shots/$1.png" || rm -f "shots/$1.png"; }
$A install -r KhanWeather.apk
$A shell pm grant $PKG android.permission.ACCESS_FINE_LOCATION
$A shell pm grant $PKG android.permission.ACCESS_COARSE_LOCATION
$A shell pm grant $PKG android.permission.POST_NOTIFICATIONS || true
$A shell settings put secure location_mode 3 || true
for i in 1 2 3; do $A emu geo fix -79.8774 43.5183; sleep 2; done
$A shell am start -n $PKG/.MainActivity
sleep 40
$A emu geo fix -79.8774 43.5183
shot android-main-1
for i in 2 3 4 5; do
  $A shell input swipe 540 1800 540 700 600
  sleep 4
  shot android-main-$i
done
# The home-screen widgets, drawn in the app from the same saved forecast.
$A shell am start -S -n $PKG/.MainActivity --ez widgetPreview true
sleep 10
shot android-widgets
timeout 30 adb logcat -d 2>/dev/null | grep -iE "khanweather|AndroidRuntime|FATAL" | tail -80 > shots/logcat.txt || true
ls -l shots
