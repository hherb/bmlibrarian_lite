package com.bmlibrarian.factchecker

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.test.ext.junit.runners.AndroidJUnit4
import dagger.hilt.android.testing.HiltAndroidRule
import dagger.hilt.android.testing.HiltAndroidTest
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Instrumented tests for MainActivity.
 *
 * These tests run on an Android device or emulator and verify
 * that the app launches correctly with Hilt DI.
 */
@HiltAndroidTest
@RunWith(AndroidJUnit4::class)
class MainActivityTest {

    @get:Rule(order = 0)
    val hiltRule = HiltAndroidRule(this)

    @get:Rule(order = 1)
    val composeRule = createAndroidComposeRule<MainActivity>()

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
