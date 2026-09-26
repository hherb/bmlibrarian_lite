package com.bmlibrarian.factchecker.domain.transparency

/**
 * Patterns for clinical-trial detection and registration identifiers.
 *
 * Transcribed from the Swift `ClinicalTrialPatterns` (BioMedLit).
 */
object ClinicalTrialPatterns {

    /**
     * What makes a title read as a clinical trial's, as regex fragments over the lowercased
     * title, each matched only as a whole word ([trialTitleRegex]).
     *
     * A bare substring test read "atrial fibrillation" as a trial (`trial`) and "myocardial
     * infarction" too (`rct`), raising "Clinical trial without detected registration" across
     * cardiology (#385). The shared contract is
     * `doc/cross_platform/transparency_parity/trial_title_patterns.json`, asserted from
     * Python, Swift and Kotlin — edit all four together.
     */
    val trialTitlePatterns: List<String> = listOf(
        """trials?""",
        """randomi[sz]ed""",
        """rcts?""",
        """phase\s+(?:i{1,3}|iv)[ab]?""",
    )

    /**
     * [trialTitlePatterns] as one whole-word alternation. The boundary is spelled out rather
     * than `\b` because Java, ICU and Python disagree on what a word character is outside ASCII.
     */
    val trialTitleRegex: Regex =
        Regex("""(?<![a-z0-9])(?:""" + trialTitlePatterns.joinToString("|") + """)(?![a-z0-9])""")

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
