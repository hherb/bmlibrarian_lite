@file:OptIn(ExperimentalSerializationApi::class)

package com.bmlibrarian.factchecker.domain.transparency

import java.time.Instant
import java.util.UUID
import kotlinx.serialization.EncodeDefault
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.Serializable

// The value types a transparency analysis produces, ported from the Swift
// `TransparencyModels.swift` (BioMedLit). Every type serializes in the JSON
// shape Swift's synthesized `Codable` writes — the same camelCase keys, enum raw
// values, uppercase UUID strings and whole-second ISO-8601 dates — so a result
// stored on one platform reads on the other. `@EncodeDefault` keeps every
// non-optional field in the output whatever the caller's `Json` configuration,
// because Swift's decoder rejects an object missing one.

/** A new identifier in the form Swift's `UUID().uuidString` produces (uppercase). */
internal fun newTransparencyId(): String = UUID.randomUUID().toString().uppercase()

/**
 * A study funder and its industry classification.
 *
 * @property id Unique identifier (uppercase UUID string, as Swift writes it).
 * @property name Name of the funding organisation.
 * @property funderDOI CrossRef Funder Registry DOI, if known (e.g. "10.13039/100004319" for Pfizer).
 * @property awardNumbers Grant or award numbers for this funder.
 * @property isIndustry Whether this funder is classified as industry.
 * @property confidence Confidence (0.0-1.0) of the classification.
 */
@Serializable
data class FunderInfo(
    @EncodeDefault val id: String = newTransparencyId(),
    val name: String,
    val funderDOI: String? = null,
    @EncodeDefault val awardNumbers: List<String> = emptyList(),
    @EncodeDefault val isIndustry: Boolean = false,
    @EncodeDefault val confidence: Double = 0.0,
)

/**
 * A clinical-trial registration from ClinicalTrials.gov or another registry.
 *
 * @property id Unique identifier (uppercase UUID string).
 * @property registry Registry name (e.g. "ClinicalTrials.gov").
 * @property registrationId Registration identifier (e.g. "NCT01234567").
 * @property title Official title of the registered trial.
 * @property sponsorClass Sponsor class from the registry (e.g. "INDUSTRY", "NIH").
 * @property leadSponsor Name of the lead sponsor.
 * @property resultsPosted Whether results have been posted to the registry.
 * @property completionDate Completion date of the trial.
 * @property primaryOutcomesRegistered Primary outcome measures as registered.
 * @property secondaryOutcomesRegistered Secondary outcome measures as registered.
 */
@Serializable
data class TrialRegistration(
    @EncodeDefault val id: String = newTransparencyId(),
    val registry: String,
    val registrationId: String,
    val title: String? = null,
    val sponsorClass: String? = null,
    val leadSponsor: String? = null,
    @EncodeDefault val resultsPosted: Boolean = false,
    @Serializable(with = Iso8601InstantSerializer::class) val completionDate: Instant? = null,
    @EncodeDefault val primaryOutcomesRegistered: List<String> = emptyList(),
    @EncodeDefault val secondaryOutcomesRegistered: List<String> = emptyList(),
)

/**
 * Result of analysing a conflict-of-interest statement.
 *
 * @property statement The COI statement text, if found.
 * @property hasIndustryTies Whether industry ties were detected.
 * @property disclosedRelationships Disclosed relationships (e.g. "pfizer").
 * @property confidence Confidence (0.0-1.0) of the analysis.
 */
@Serializable
data class COIAnalysisResult(
    val statement: String? = null,
    @EncodeDefault val hasIndustryTies: Boolean = false,
    @EncodeDefault val disclosedRelationships: List<String> = emptyList(),
    @EncodeDefault val confidence: Double = 0.0,
) {
    /**
     * Whether a non-empty COI statement is available.
     *
     * An empty statement counts as missing, matching Python (`if not coi_info.statement`).
     */
    val hasStatement: Boolean
        get() = !statement.isNullOrEmpty()

    companion object {
        /** Empty result when no COI statement is available. */
        val NOT_AVAILABLE: COIAnalysisResult = COIAnalysisResult()
    }
}
