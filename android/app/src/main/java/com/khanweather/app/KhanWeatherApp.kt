package com.khanweather.app

import android.app.Application

class KhanWeatherApp : Application() {
    override fun onCreate() {
        super.onCreate()
        Prefs.init(this)
        TimeText.is24hSystem = android.text.format.DateFormat.is24HourFormat(this)
        Notifier.createChannels(this)
    }
}
