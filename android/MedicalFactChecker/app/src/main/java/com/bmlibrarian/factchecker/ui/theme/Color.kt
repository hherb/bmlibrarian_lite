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

import androidx.compose.ui.graphics.Color

/**
 * Color definitions for MedicalFactChecker theme.
 *
 * Colors are organized by category and match the iOS app for consistency.
 */

// ==================== Primary Colors ====================

/** Primary brand color - used for key UI elements and actions. */
val Primary = Color(0xFF1976D2)

/** Darker variant of primary - used for status bar and pressed states. */
val PrimaryVariant = Color(0xFF1565C0)

/** Text/icon color on primary backgrounds. */
val OnPrimary = Color.White

// ==================== Secondary Colors ====================

/** Secondary brand color - used for accents and secondary actions. */
val Secondary = Color(0xFF26A69A)

/** Darker variant of secondary. */
val SecondaryVariant = Color(0xFF00897B)

/** Text/icon color on secondary backgrounds. */
val OnSecondary = Color.White

// ==================== Background Colors ====================

/** Main background color for screens. */
val Background = Color(0xFFFAFAFA)

/** Surface color for cards, dialogs, and elevated components. */
val Surface = Color.White

/** Text color on background. */
val OnBackground = Color(0xFF212121)

/** Text color on surface. */
val OnSurface = Color(0xFF212121)

// ==================== Dark Theme Colors ====================

/** Dark theme background. */
val DarkBackground = Color(0xFF121212)

/** Dark theme surface. */
val DarkSurface = Color(0xFF1E1E1E)

/** Dark theme text on background. */
val DarkOnBackground = Color.White

/** Dark theme text on surface. */
val DarkOnSurface = Color.White

// ==================== Verdict Colors ====================

/** Evidence strongly supports the claim. */
val VerdictSupported = Color(0xFF4CAF50)

/** Evidence somewhat supports the claim. */
val VerdictLikelySupported = Color(0xFF8BC34A)

/** Evidence is unclear or insufficient. */
val VerdictUnclear = Color(0xFFFFEB3B)

/** Evidence somewhat contradicts the claim. */
val VerdictLikelyRefuted = Color(0xFFFF9800)

/** Evidence strongly contradicts the claim. */
val VerdictRefuted = Color(0xFFF44336)

// ==================== Relevance Score Colors (1-5 scale) ====================

/** Score 1 - Very low relevance. */
val Score1 = Color(0xFFE57373)

/** Score 2 - Low relevance. */
val Score2 = Color(0xFFFFB74D)

/** Score 3 - Moderate relevance. */
val Score3 = Color(0xFFFFD54F)

/** Score 4 - High relevance. */
val Score4 = Color(0xFFAED581)

/** Score 5 - Very high relevance. */
val Score5 = Color(0xFF81C784)

// ==================== Utility Colors ====================

/** Error state color. */
val Error = Color(0xFFD32F2F)

/** Text/icon color on error backgrounds. */
val OnError = Color.White

/** Warning state color. */
val Warning = Color(0xFFFF9800)

/** Success state color. */
val Success = Color(0xFF4CAF50)

/** Disabled state color. */
val Disabled = Color(0xFFBDBDBD)

/** Outline color for borders and dividers. */
val Outline = Color(0xFFE0E0E0)

// ==================== Helper Functions ====================

/**
 * Returns the color for a given relevance score.
 *
 * @param score The relevance score (1-5)
 * @return The corresponding color
 */
fun scoreColor(score: Int): Color {
    return when (score) {
        1 -> Score1
        2 -> Score2
        3 -> Score3
        4 -> Score4
        5 -> Score5
        else -> Disabled
    }
}

/**
 * Returns the color for a given verdict.
 *
 * @param verdict The verdict string
 * @return The corresponding color
 */
fun verdictColor(verdict: String): Color {
    return when (verdict.lowercase()) {
        "supported" -> VerdictSupported
        "likely supported", "likely_supported" -> VerdictLikelySupported
        "unclear", "insufficient evidence" -> VerdictUnclear
        "likely refuted", "likely_refuted" -> VerdictLikelyRefuted
        "refuted" -> VerdictRefuted
        else -> Disabled
    }
}
