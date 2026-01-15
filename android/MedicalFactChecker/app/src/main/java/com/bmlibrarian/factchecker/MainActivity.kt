package com.bmlibrarian.factchecker

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import com.bmlibrarian.factchecker.ui.navigation.AppNavigation
import com.bmlibrarian.factchecker.ui.theme.MedicalFactCheckerTheme
import dagger.hilt.android.AndroidEntryPoint

/**
 * Main activity for MedicalFactChecker.
 *
 * This is the single activity that hosts all Compose UI content.
 * Annotated with @AndroidEntryPoint to enable Hilt injection
 * into this activity and its composables.
 */
@AndroidEntryPoint
class MainActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MedicalFactCheckerTheme {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background
                ) {
                    AppNavigation()
                }
            }
        }
    }
}
