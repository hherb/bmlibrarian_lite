/*
 * BMLibrarian Lite - Biomedical Literature Research Tool
 * Copyright (C) 2024-2025 Dr Horst Herb
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

package com.bmlibrarian.factchecker

import android.app.Application
import com.bmlibrarian.factchecker.util.retraction.RetractionService
import dagger.hilt.android.HiltAndroidApp
import javax.inject.Inject

/**
 * Application class for MedicalFactChecker.
 *
 * This is the entry point for the Android application and is annotated with
 * @HiltAndroidApp to enable Hilt dependency injection throughout the app.
 * Hilt generates the necessary Dagger components at compile time.
 */
@HiltAndroidApp
class MedicalFactCheckerApp : Application() {

    @Inject lateinit var retractionService: RetractionService

    override fun onCreate() {
        super.onCreate()
        // The Retraction Watch copy is refreshed off the main thread; no run waits for it
        retractionService.refreshInBackground()
        // Note: Avoid heavy work on main thread - use WorkManager for background init
    }
}
