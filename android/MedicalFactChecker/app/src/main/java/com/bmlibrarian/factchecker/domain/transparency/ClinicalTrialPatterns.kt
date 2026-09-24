package com.bmlibrarian.factchecker.domain.transparency

/**
 * Patterns for clinical-trial detection and registration identifiers.
 *
 * Transcribed from the Swift `ClinicalTrialPatterns` (BioMedLit).
 */
object ClinicalTrialPatterns {

    /** Keywords suggesting a study is a clinical trial, matched as substrings of the lowercased title. */
    val trialKeywords: List<String> = listOf(
        "trial",
        "randomized",
        "randomised",
        "rct",
        "phase i",
        "phase ii",
        "phase iii",
        "phase iv",
    )

    /**
     * ClinicalTrials.gov registration number: NCT followed by exactly 8 digits.
     *
     * The lookarounds reject IDs embedded in longer tokens, such as
     * `NCT1234567890` (too many digits) or `SOMENCT12345678`.
     */
    const val NCT_ID_PATTERN: String = """(?<![A-Za-z0-9])NCT\d{8}(?!\d)"""

    /** Registry names that indicate trial registration. */
    val registryNames: Set<String> = linkedSetOf(
        "ClinicalTrials.gov",
        "ISRCTN",
        "EudraCT",
        "ACTRN",
        "ChiCTR",
        "CTRI",
        "DRKS",
        "IRCT",
        "JPRN",
        "NTR",
        "PACTR",
        "REBEC",
        "RPCEC",
        "SLCTR",
        "TCTR",
    )
}
