package com.bmlibrarian.factchecker.domain.model

import androidx.compose.ui.graphics.Color
import com.bmlibrarian.factchecker.ui.theme.Disabled
import com.bmlibrarian.factchecker.ui.theme.VerdictLikelyRefuted
import com.bmlibrarian.factchecker.ui.theme.VerdictLikelySupported
import com.bmlibrarian.factchecker.ui.theme.VerdictRefuted
import com.bmlibrarian.factchecker.ui.theme.VerdictSupported
import com.bmlibrarian.factchecker.ui.theme.VerdictUnclear

/**
 * Evidence verdict for a fact check.
 *
 * Represents the overall assessment of whether scientific evidence
 * supports or refutes the user's claim.
 * Mirrors iOS Verdict enum for cross-platform consistency.
 *
 * @property displayName Human-readable name for UI display
 * @property color The associated color for visual indication
 */
enum class Verdict(val displayName: String, val color: Color) {
    /** Evidence strongly supports the claim. */
    SUPPORTED("Supported", VerdictSupported),

    /** Evidence somewhat supports the claim. */
    LIKELY_SUPPORTED("Likely Supported", VerdictLikelySupported),

    /** Evidence is unclear or insufficient. */
    UNCLEAR("Unclear", VerdictUnclear),

    /** Evidence somewhat contradicts the claim. */
    LIKELY_REFUTED("Likely Refuted", VerdictLikelyRefuted),

    /** Evidence strongly contradicts the claim. */
    REFUTED("Refuted", VerdictRefuted);

    companion object {
        /**
         * Parse verdict from LLM response string.
         *
         * Handles various common phrasings and normalizes to enum values.
         * Returns UNCLEAR for unrecognized input to fail safely.
         *
         * @param value The verdict string from LLM response
         * @return The corresponding Verdict enum value
         */
        fun fromString(value: String): Verdict {
            return when (value.lowercase().trim()) {
                "supported", "true", "confirmed" -> SUPPORTED
                "likely supported", "probably true", "likely_supported" -> LIKELY_SUPPORTED
                "unclear", "uncertain", "insufficient evidence", "inconclusive" -> UNCLEAR
                "likely refuted", "probably false", "likely_refuted" -> LIKELY_REFUTED
                "refuted", "false", "disproven" -> REFUTED
                else -> UNCLEAR
            }
        }

        /**
         * Get color for a verdict value, with fallback for null.
         *
         * @param verdict The verdict to get color for, or null
         * @return The verdict color or disabled color if null
         */
        fun colorFor(verdict: Verdict?): Color = verdict?.color ?: Disabled
    }
}
