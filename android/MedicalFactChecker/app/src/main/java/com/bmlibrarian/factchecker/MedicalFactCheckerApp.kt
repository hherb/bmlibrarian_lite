package com.bmlibrarian.factchecker

import android.app.Application
import dagger.hilt.android.HiltAndroidApp

/**
 * Application class for MedicalFactChecker.
 *
 * This is the entry point for the Android application and is annotated with
 * @HiltAndroidApp to enable Hilt dependency injection throughout the app.
 * Hilt generates the necessary Dagger components at compile time.
 */
@HiltAndroidApp
class MedicalFactCheckerApp : Application() {

    override fun onCreate() {
        super.onCreate()
        // App-wide initialization can be added here
        // Note: Avoid heavy work on main thread - use WorkManager for background init
    }
}
