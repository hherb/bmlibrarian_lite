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

package com.bmlibrarian.factchecker.ui.theme

import android.app.Activity
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalView
import androidx.core.view.WindowCompat

/**
 * Light color scheme for MedicalFactChecker.
 *
 * Used when device is in light mode or user preference is light theme.
 */
private val LightColorScheme = lightColorScheme(
    primary = Primary,
    onPrimary = OnPrimary,
    primaryContainer = Primary.copy(alpha = 0.1f),
    onPrimaryContainer = Primary,
    secondary = Secondary,
    onSecondary = OnSecondary,
    secondaryContainer = Secondary.copy(alpha = 0.1f),
    onSecondaryContainer = Secondary,
    background = Background,
    onBackground = OnBackground,
    surface = Surface,
    onSurface = OnSurface,
    surfaceVariant = Background,
    onSurfaceVariant = OnSurface.copy(alpha = 0.7f),
    error = Error,
    onError = OnError,
    outline = Outline
)

/**
 * Dark color scheme for MedicalFactChecker.
 *
 * Used when device is in dark mode or user preference is dark theme.
 */
private val DarkColorScheme = darkColorScheme(
    primary = Primary,
    onPrimary = OnPrimary,
    primaryContainer = Primary.copy(alpha = 0.2f),
    onPrimaryContainer = Primary,
    secondary = Secondary,
    onSecondary = OnSecondary,
    secondaryContainer = Secondary.copy(alpha = 0.2f),
    onSecondaryContainer = Secondary,
    background = DarkBackground,
    onBackground = DarkOnBackground,
    surface = DarkSurface,
    onSurface = DarkOnSurface,
    surfaceVariant = DarkSurface,
    onSurfaceVariant = DarkOnSurface.copy(alpha = 0.7f),
    error = Error,
    onError = OnError,
    outline = Outline.copy(alpha = 0.5f)
)

/**
 * MedicalFactChecker theme wrapper.
 *
 * Applies the appropriate color scheme based on system dark mode setting
 * and configures the status bar appearance.
 *
 * @param darkTheme Whether to use dark theme (defaults to system setting)
 * @param content The composable content to wrap with the theme
 */
@Composable
fun MedicalFactCheckerTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit
) {
    val colorScheme = if (darkTheme) DarkColorScheme else LightColorScheme

    val view = LocalView.current
    if (!view.isInEditMode) {
        SideEffect {
            val window = (view.context as Activity).window
            window.statusBarColor = colorScheme.primary.toArgb()
            WindowCompat.getInsetsController(window, view).isAppearanceLightStatusBars = !darkTheme
        }
    }

    MaterialTheme(
        colorScheme = colorScheme,
        typography = Typography,
        content = content
    )
}
