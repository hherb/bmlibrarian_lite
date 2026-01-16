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

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import dagger.hilt.android.testing.HiltAndroidRule
import dagger.hilt.android.testing.HiltAndroidTest
import org.junit.Before
import org.junit.Rule
import org.junit.Test

/**
 * Instrumented tests for MainActivity.
 *
 * These tests run on an Android device or emulator and verify
 * that the app launches correctly with Hilt DI.
 *
 * Uses custom HiltTestRunner configured in build.gradle.kts.
 */
@HiltAndroidTest
class MainActivityTest {

    @get:Rule(order = 0)
    val hiltRule = HiltAndroidRule(this)

    @get:Rule(order = 1)
    val composeRule = createAndroidComposeRule<MainActivity>()

    /**
     * Initialize Hilt injection before each test.
     */
    @Before
    fun setup() {
        hiltRule.inject()
    }

    /**
     * Verify that the app launches and displays the placeholder content.
     */
    @Test
    fun appLaunches_showsSetupComplete() {
        composeRule.onNodeWithText("MedicalFactChecker")
            .assertIsDisplayed()

        composeRule.onNodeWithText("Phase 1 Setup Complete")
            .assertIsDisplayed()
    }
}
