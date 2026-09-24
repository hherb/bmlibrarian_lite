package com.bmlibrarian.factchecker.domain.transparency

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Classification of a study's primary funding source.
 *
 * Raw values match the Swift `SponsorType` so stored JSON reads on both platforms.
 */
@Serializable
enum class SponsorType(val rawValue: String, val displayName: String) {
    /** Industry-funded (pharmaceutical, biotech, medical device companies). */
    @SerialName("industry")
    INDUSTRY("industry", "Industry"),

    /** Government-funded (NIH, NSF, CDC, etc.). */
    @SerialName("government")
    GOVERNMENT("government", "Government"),

    /** Academic institution-funded. */
    @SerialName("academic")
    ACADEMIC("academic", "Academic"),

    /** Non-profit organisation-funded. */
    @SerialName("nonprofit")
    NONPROFIT("nonprofit", "Non-Profit"),

    /** Multiple funding source types. */
    @SerialName("mixed")
    MIXED("mixed", "Mixed"),

    /** Funding source could not be determined. */
    @SerialName("unknown")
    UNKNOWN("unknown", "Unknown"),
}

/**
 * ClinicalTrials.gov results-posting compliance (FDAAA: typically 12 months after completion).
 *
 * Raw values match the Swift `ResultsComplianceStatus`.
 */
@Serializable
enum class ResultsComplianceStatus(val rawValue: String, val displayName: String) {
    /** Results posted within the compliance deadline. */
    @SerialName("compliant")
    COMPLIANT("compliant", "Compliant"),

    /** Results posted, but after the deadline. */
    @SerialName("late")
    LATE("late", "Late"),

    /** Results not posted despite being required. */
    @SerialName("missing")
    MISSING("missing", "Missing"),

    /** Results posting not required (e.g. not an applicable trial). */
    @SerialName("not_required")
    NOT_REQUIRED("not_required", "Not Required"),

    /** Compliance status could not be determined. */
    @SerialName("unknown")
    UNKNOWN("unknown", "Unknown"),
}

/**
 * Transparency risk level for display.
 *
 * Raw values match the Swift `TransparencyRiskLevel`.
 *
 * @property colorName The colour name the Swift badge uses ("green", "orange", "red", "gray").
 * @property shortLabel Short label for compact displays such as badges.
 * @property fullLabel Full label for tooltips and detailed displays.
 */
@Serializable
enum class TransparencyRiskLevel(
    val rawValue: String,
    val colorName: String,
    val shortLabel: String,
    val fullLabel: String,
) {
    /** Low risk - good transparency practices. */
    @SerialName("low")
    LOW("low", "green", "Low", "Low Risk"),

    /** Medium risk - some transparency concerns. */
    @SerialName("medium")
    MEDIUM("medium", "orange", "Med", "Medium Risk"),

    /** High risk - significant transparency issues. */
    @SerialName("high")
    HIGH("high", "red", "High", "High Risk"),

    /** Risk level could not be determined. */
    @SerialName("unknown")
    UNKNOWN("unknown", "gray", "?", "Unknown"),
}
