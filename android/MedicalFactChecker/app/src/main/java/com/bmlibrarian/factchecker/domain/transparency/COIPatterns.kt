package com.bmlibrarian.factchecker.domain.transparency

/**
 * Regex patterns for conflict-of-interest analysis.
 *
 * Transcribed string-for-string from the Swift `COIPatterns` (BioMedLit). All
 * are matched through [TransparencyRegex] (case-insensitive, lowercased text).
 */
object COIPatterns {

    /** Patterns indicating an explicit "no conflicts" declaration. */
    val noConflictPatterns: List<String> = listOf(
        """no (?:potential )?conflict""",
        """nothing to (?:disclose|declare)""",
        """no (?:competing|financial) interest""",
        """no relationship""",
        """none (?:declared|to declare)""",
    )

    /** Patterns for extracting disclosed relationships; capture group 1 holds the entity name(s). */
    val relationshipPatterns: List<String> = listOf(
        """(?:received|reports?|has|have) (?:grants?|funding|honoraria|fees?|payments?) from ([^.;]+)""",
        """(?:consultant|advisory board|speaker) for ([^.;]+)""",
        """employee of ([^.;]+)""",
        """(?:stock|shares?|equity) in ([^.;]+)""",
    )

    /**
     * Industry funding routed through institutional intermediaries.
     *
     * Detects the disclosure where industry money flows to a university or
     * institution rather than to the author ("funding to the University of X
     * (but no personal funding) from [pharma]"). Mirrors Python's
     * `INSTITUTIONAL_INTERMEDIARY_PATTERNS`.
     */
    val institutionalIntermediaryPatterns: List<String> = listOf(
        """(?:funding|grants?|support|contracts?)\s+(?:to|paid to)\s+(?:the\s+)?(?:university|institution|hospital)""",
        """(?:but\s+)?no personal (?:funding|payment|honorari)""",
        """(?:grants?|contracts?|funding)\s+(?:or\s+\w+\s+)?(?:to|paid to)\s+(?:his|her|their)\s+institution""",
        """(?:research\s+)?grant\s+support\s+through\b""",
        """salary\s+support\s+from\b""",
    )
}
