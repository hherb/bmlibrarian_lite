package com.bmlibrarian.factchecker.domain.transparency

import java.time.Instant
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder

/**
 * Complete transparency analysis of one article.
 *
 * Ported from the Swift `TransparencyResult` (BioMedLit). Serialized (see
 * [TransparencyResultSerializer] and [TransparencyJson]) as the JSON object
 * Swift's `Codable` writes with the `.iso8601` date strategy — the keys are the
 * property names below. Three fields were added after results were first stored, so they
 * decode as null when absent and those results still load: [analyzerVersion],
 * [fullTextSearched] and [sourcesUnreachable]. Unknown keys are ignored.
 *
 * @property id Unique identifier (uppercase UUID string).
 * @property doi Digital Object Identifier.
 * @property pmid PubMed identifier.
 * @property pmcid PubMed Central identifier.
 * @property title Article title.
 * @property journal Journal name.
 * @property publicationDate Publication date.
 * @property authors Author names.
 * @property sponsorType Primary sponsor type classification.
 * @property funders Identified funders.
 * @property industryFundingDetected Whether industry funding was detected.
 * @property industryFundingConfidence Confidence (0.0-1.0) of the industry-funding detection.
 * @property trialRegistrations Clinical trial registrations found.
 * @property resultsCompliance Results posting compliance status.
 * @property coiAnalysis Conflict-of-interest analysis.
 * @property dataAvailability Data availability analysis.
 * @property outcomeSwitchingDetected Whether outcome switching was detected.
 * @property outcomeSwitchingDetails Details of detected outcome discrepancies.
 * @property transparencyScore Overall transparency score (0-100).
 * @property riskLevel Risk level classification.
 * @property riskIndicators Identified risk indicators.
 * @property analysisTimestamp When the analysis was performed.
 * @property dataSourcesUsed Data sources that returned a record (see [TransparencyConstants.PUBMED_SOURCE_NAME] etc.).
 * @property warnings Non-fatal warnings encountered during analysis.
 * @property analyzerVersion Version of the analyzer that produced this result; null for
 *   results stored before versioning existed. Defaults to the current version, as in Swift —
 *   pass null only to represent a pre-versioning result.
 * @property fullTextSearched Whether the article's full text was given to the analysis.
 *   COI and data-availability statements are looked for only in the full text, so a reader
 *   must be able to tell "the article has no statement" from "there was no text to look in".
 *   Null when not recorded (results stored before the field existed): then it is unknown,
 *   and must be reported as unknown.
 * @property sourcesUnreachable Whether a source the analysis needed (PubMed, CrossRef,
 *   ClinicalTrials.gov) failed or answered unreadably, as opposed to answering that it holds
 *   no such record. The finding then rests on less than the full record — a CrossRef outage
 *   reads exactly like a study with no funders — so it is provisional ([isProvisional]) and
 *   re-analysed rather than kept as final (#385; Python's `sources_unreachable`). Null only for
 *   results stored before it was recorded, all of which are stale anyway; the constructor
 *   defaults it to false, so a result built here always records it.
 * @property errors Errors encountered during analysis. Nothing in [TransparencyAnalysisService]
 *   writes it: an unreadable source is recorded in [warnings] and [sourcesUnreachable]. It stays
 *   a required key because an older build reading a synced or stored result — this app's
 *   earlier [TransparencyResultJson], or Swift's synthesized `Codable` — fails to decode one
 *   without it.
 */
@Serializable(with = TransparencyResultSerializer::class)
data class TransparencyResult(
    val id: String = newTransparencyId(),
    val doi: String? = null,
    val pmid: String? = null,
    val pmcid: String? = null,
    val title: String? = null,
    val journal: String? = null,
    val publicationDate: Instant? = null,
    val authors: List<String> = emptyList(),
    val sponsorType: SponsorType = SponsorType.UNKNOWN,
    val funders: List<FunderInfo> = emptyList(),
    val industryFundingDetected: Boolean = false,
    val industryFundingConfidence: Double = 0.0,
    val trialRegistrations: List<TrialRegistration> = emptyList(),
    val resultsCompliance: ResultsComplianceStatus = ResultsComplianceStatus.UNKNOWN,
    val coiAnalysis: COIAnalysisResult = COIAnalysisResult.NOT_AVAILABLE,
    val dataAvailability: DataAvailabilityResult = DataAvailabilityResult.NOT_STATED,
    val outcomeSwitchingDetected: Boolean = false,
    val outcomeSwitchingDetails: List<String> = emptyList(),
    val transparencyScore: Int = 0,
    val riskLevel: TransparencyRiskLevel = TransparencyRiskLevel.UNKNOWN,
    val riskIndicators: List<String> = emptyList(),
    val analysisTimestamp: Instant = Instant.now(),
    val dataSourcesUsed: List<String> = emptyList(),
    val warnings: List<String> = emptyList(),
    val errors: List<String> = emptyList(),
    val analyzerVersion: Int? = TransparencyConstants.ANALYZER_VERSION,
    val fullTextSearched: Boolean? = null,
    val sourcesUnreachable: Boolean? = false,
) {
    /**
     * Whether this result was produced by an older analyzer than the current one.
     *
     * Strictly older, not merely different: results sync between devices, so a
     * device on an older build can receive a result stamped with a *newer*
     * version, and treating that as stale would offer a re-analysis that
     * overwrites the better result. A result with no version predates
     * versioning and is stale.
     */
    val isStale: Boolean
        get() = analyzerVersion == null || analyzerVersion < TransparencyConstants.ANALYZER_VERSION

    /** Whether a source the analysis needed could not be read ([sourcesUnreachable]). */
    val isProvisional: Boolean
        get() = sourcesUnreachable == true

    /** Whether a build newer than this one produced the result. */
    val isFromNewerAnalyzer: Boolean
        get() = analyzerVersion != null && analyzerVersion > TransparencyConstants.ANALYZER_VERSION

    /**
     * Whether the result should be analysed again rather than kept: stale, or provisional and
     * this build's own to replace.
     *
     * Python's `_needs_analysis`: `may_replace_stored` and not `is_final`. A provisional
     * result stamped with the current version was otherwise final forever, so a transient
     * outage became a permanent finding (#385). A newer
     * build's result is never replaced, provisional or not: this build's answer would be the
     * older analyzer's (Python's `may_replace_stored`, #374).
     */
    val needsReanalysis: Boolean
        get() = isStale || (isProvisional && !isFromNewerAnalyzer)
}

/**
 * The stored JSON form of a [TransparencyResult].
 *
 * A separate class because the JSON and the constructor disagree on one
 * default: a missing `analyzerVersion` key means a pre-versioning result and
 * must decode as null, while [TransparencyResult]'s constructor stamps the
 * current version as Swift's initializer does. The non-optional fields have no
 * default here, so they are always written and required on read — exactly the
 * contract Swift's synthesized `Codable` enforces.
 */
@Serializable
internal class TransparencyResultJson(
    val id: String,
    val doi: String? = null,
    val pmid: String? = null,
    val pmcid: String? = null,
    val title: String? = null,
    val journal: String? = null,
    @Serializable(with = Iso8601InstantSerializer::class) val publicationDate: Instant? = null,
    val authors: List<String>,
    val sponsorType: SponsorType,
    val funders: List<FunderInfo>,
    val industryFundingDetected: Boolean,
    val industryFundingConfidence: Double,
    val trialRegistrations: List<TrialRegistration>,
    val resultsCompliance: ResultsComplianceStatus,
    val coiAnalysis: COIAnalysisResult,
    val dataAvailability: DataAvailabilityResult,
    val outcomeSwitchingDetected: Boolean,
    val outcomeSwitchingDetails: List<String>,
    val transparencyScore: Int,
    val riskLevel: TransparencyRiskLevel,
    val riskIndicators: List<String>,
    @Serializable(with = Iso8601InstantSerializer::class) val analysisTimestamp: Instant,
    val dataSourcesUsed: List<String>,
    val warnings: List<String>,
    val errors: List<String>,
    val analyzerVersion: Int? = null,
    val fullTextSearched: Boolean? = null,
    val sourcesUnreachable: Boolean? = null,
)

/** Serializes a [TransparencyResult] through its stored JSON form ([TransparencyResultJson]). */
object TransparencyResultSerializer : KSerializer<TransparencyResult> {

    private val delegate: KSerializer<TransparencyResultJson> = TransparencyResultJson.serializer()

    override val descriptor: SerialDescriptor = delegate.descriptor

    override fun serialize(encoder: Encoder, value: TransparencyResult) {
        encoder.encodeSerializableValue(
            delegate,
            TransparencyResultJson(
                id = value.id,
                doi = value.doi,
                pmid = value.pmid,
                pmcid = value.pmcid,
                title = value.title,
                journal = value.journal,
                publicationDate = value.publicationDate,
                authors = value.authors,
                sponsorType = value.sponsorType,
                funders = value.funders,
                industryFundingDetected = value.industryFundingDetected,
                industryFundingConfidence = value.industryFundingConfidence,
                trialRegistrations = value.trialRegistrations,
                resultsCompliance = value.resultsCompliance,
                coiAnalysis = value.coiAnalysis,
                dataAvailability = value.dataAvailability,
                outcomeSwitchingDetected = value.outcomeSwitchingDetected,
                outcomeSwitchingDetails = value.outcomeSwitchingDetails,
                transparencyScore = value.transparencyScore,
                riskLevel = value.riskLevel,
                riskIndicators = value.riskIndicators,
                analysisTimestamp = value.analysisTimestamp,
                dataSourcesUsed = value.dataSourcesUsed,
                warnings = value.warnings,
                errors = value.errors,
                analyzerVersion = value.analyzerVersion,
                fullTextSearched = value.fullTextSearched,
                sourcesUnreachable = value.sourcesUnreachable,
            ),
        )
    }

    override fun deserialize(decoder: Decoder): TransparencyResult {
        val stored = decoder.decodeSerializableValue(delegate)
        return TransparencyResult(
            id = stored.id,
            doi = stored.doi,
            pmid = stored.pmid,
            pmcid = stored.pmcid,
            title = stored.title,
            journal = stored.journal,
            publicationDate = stored.publicationDate,
            authors = stored.authors,
            sponsorType = stored.sponsorType,
            funders = stored.funders,
            industryFundingDetected = stored.industryFundingDetected,
            industryFundingConfidence = stored.industryFundingConfidence,
            trialRegistrations = stored.trialRegistrations,
            resultsCompliance = stored.resultsCompliance,
            coiAnalysis = stored.coiAnalysis,
            dataAvailability = stored.dataAvailability,
            outcomeSwitchingDetected = stored.outcomeSwitchingDetected,
            outcomeSwitchingDetails = stored.outcomeSwitchingDetails,
            transparencyScore = stored.transparencyScore,
            riskLevel = stored.riskLevel,
            riskIndicators = stored.riskIndicators,
            analysisTimestamp = stored.analysisTimestamp,
            dataSourcesUsed = stored.dataSourcesUsed,
            warnings = stored.warnings,
            errors = stored.errors,
            analyzerVersion = stored.analyzerVersion,
            fullTextSearched = stored.fullTextSearched,
            sourcesUnreachable = stored.sourcesUnreachable,
        )
    }
}
