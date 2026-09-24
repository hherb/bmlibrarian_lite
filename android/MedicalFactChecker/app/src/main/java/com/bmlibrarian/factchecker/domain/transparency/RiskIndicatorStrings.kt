package com.bmlibrarian.factchecker.domain.transparency

/**
 * Canonical risk-of-bias indicator strings shown to a reader.
 *
 * Byte-identical to the Python reference (`RISK_INDICATOR_*` in
 * `study_transparency_analyzer.py`) and the Swift `RiskIndicatorStrings`.
 */
object RiskIndicatorStrings {

    /** Industry funding was detected. */
    const val INDUSTRY_FUNDING: String = "Industry funding detected"

    /** Industry funding combined with restricted/unavailable data. */
    const val INDUSTRY_RESTRICTED_DATA: String = "Industry-funded with restricted data access"

    /** Trial results were due but not posted to ClinicalTrials.gov. */
    const val RESULTS_NOT_POSTED: String = "Trial results not posted to ClinicalTrials.gov"

    /** Authors disclosed industry financial ties in the COI statement. */
    const val INDUSTRY_TIES_DISCLOSED: String = "Authors have disclosed industry financial ties"

    /** Industry funding was routed through an institutional intermediary. */
    const val INSTITUTIONAL_INTERMEDIARY: String =
        "Industry funding routed through institutional intermediaries"

    /** No conflict of interest statement was found. */
    const val MISSING_COI_STATEMENT: String = "No conflict of interest statement found"

    /** Warning: industry funding was detected and no COI statement was found. */
    const val FUNDING_WITHOUT_COI_STATEMENT: String = "Industry funding detected but no COI statement found"

    /** A sharing statement exists but the data is effectively unavailable. */
    const val DATA_EFFECTIVELY_UNAVAILABLE: String =
        "Data effectively unavailable despite sharing statement"

    /** Data access is restricted (e.g. request/approval required). */
    const val DATA_ACCESS_RESTRICTED: String = "Data access restricted"

    /** Reported outcomes deviate from registered outcomes. */
    const val OUTCOME_SWITCHING: String = "Outcome switching detected"

    /** Industry ties combined with restricted or unavailable data. */
    const val COMBINED_INDUSTRY_DATA: String =
        "Industry ties combined with restricted/unavailable data"

    /** The study appears to be a clinical trial but no registration was found. */
    const val MISSING_TRIAL_REGISTRATION: String = "Clinical trial without detected registration"
}
