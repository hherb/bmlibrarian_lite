package com.bmlibrarian.factchecker.domain.transparency

import kotlinx.serialization.json.JsonObject

/**
 * How [FundingAnalyzer.classifyFunder] classified one funder.
 *
 * @property isIndustry Whether the funder is classified as industry.
 * @property confidence Confidence (0.0-1.0), which names the layer that decided (see [FundingAnalyzer]).
 */
data class FunderClassification(val isIndustry: Boolean, val confidence: Double)

/**
 * Whether a set of funders includes industry, and how sure that is.
 *
 * @property detected True if any funder is industry.
 * @property confidence The highest confidence among the industry funders; 0.0 when none.
 */
data class IndustryFundingStatus(val detected: Boolean, val confidence: Double)

/**
 * Pure functions classifying study funders and sponsor types.
 *
 * Ported from the Swift `FundingAnalyzer` (BioMedLit). The confidence each
 * classification layer reports is pinned by the shared contract
 * `sponsor_patterns.json` (`confidences`), and the industry boundary is measured
 * against `funder_names.json`; both are asserted by this platform's tests.
 */
object FundingAnalyzer {

    /** Confidence of a known industry funder DOI match. */
    private const val KNOWN_FUNDER_CONFIDENCE: Double = 1.0

    /** Confidence of a government pattern match. */
    private const val GOVERNMENT_PATTERN_CONFIDENCE: Double = 0.85

    /** Confidence of an academic pattern match. */
    private const val ACADEMIC_PATTERN_CONFIDENCE: Double = 0.80

    /** Confidence of a funder-name stem or whole-word match. */
    private const val INDUSTRY_NAME_CONFIDENCE: Double = 0.75

    /** Confidence when nothing matched. */
    private const val UNKNOWN_CONFIDENCE: Double = 0.30

    /** The sponsor class ClinicalTrials.gov reports for an industry sponsor. */
    private const val INDUSTRY_SPONSOR_CLASS: String = "INDUSTRY"

    /**
     * Classify a single funder as industry or not.
     *
     * Layers, first match wins:
     *  1. a known industry funder DOI (highest confidence);
     *  2. government, then academic, name patterns — these outrank corporate
     *     suffixes ("Department of Veterans Affairs" is not a company);
     *  3. the calibrated funder-name stems and whole words.
     *
     * Layer 3, with the brand list (#394), scores precision 0.958 / recall 0.657
     * on the shared labelled corpus, against 0.455 / 0.167 for the substring
     * matcher it replaced.
     *
     * @param name Funder name.
     * @param doi CrossRef Funder Registry DOI, if known (e.g. "10.13039/100004319").
     * @return The classification and its confidence.
     */
    fun classifyFunder(name: String, doi: String? = null): FunderClassification {
        if (doi != null && KnownIndustryFunders.isIndustryFunder(doi)) {
            return FunderClassification(isIndustry = true, confidence = KNOWN_FUNDER_CONFIDENCE)
        }

        val nameLower = name.lowercase()

        if (TransparencyRegex.anyMatch(IndustryPatterns.governmentPatterns, nameLower)) {
            return FunderClassification(isIndustry = false, confidence = GOVERNMENT_PATTERN_CONFIDENCE)
        }
        if (TransparencyRegex.anyMatch(IndustryPatterns.academicPatterns, nameLower)) {
            return FunderClassification(isIndustry = false, confidence = ACADEMIC_PATTERN_CONFIDENCE)
        }
        if (matchesIndustryName(nameLower)) {
            return FunderClassification(isIndustry = true, confidence = INDUSTRY_NAME_CONFIDENCE)
        }
        return FunderClassification(isIndustry = false, confidence = UNKNOWN_CONFIDENCE)
    }

    /**
     * Whether a lowercased funder name carries an industry stem or whole-word marker.
     *
     * The single predicate behind both funder sources (CrossRef `funder[].name`
     * and PubMed `<Grant><Agency>`). Deliberately not applied to COI prose; see
     * [IndustryPatterns.industryKeywords].
     */
    private fun matchesIndustryName(nameLower: String): Boolean =
        IndustryPatterns.funderNameStems.any { nameLower.contains(it) } ||
            TransparencyRegex.anyMatch(IndustryPatterns.funderNameWords, nameLower) ||
            matchesIndustryBrand(nameLower)

    /**
     * Whether a lowercased funder name names a known company, and not its foundation (#394).
     *
     * @param nameLower The funder name, already lowercased.
     * @return True if an [IndustryPatterns.funderBrandPatterns] entry matches and no
     *   [IndustryPatterns.foundationMarkerPatterns] entry does.
     */
    internal fun matchesIndustryBrand(nameLower: String): Boolean =
        TransparencyRegex.anyMatch(IndustryPatterns.funderBrandPatterns, nameLower) &&
            !TransparencyRegex.anyMatch(IndustryPatterns.foundationMarkerPatterns, nameLower)

    /**
     * Create a classified [FunderInfo] from raw funder data.
     *
     * @param name Funder name.
     * @param doi CrossRef Funder Registry DOI, if known.
     * @param awardNumbers Grant or award numbers.
     * @return The funder with its industry classification.
     */
    fun createFunderInfo(
        name: String,
        doi: String? = null,
        awardNumbers: List<String> = emptyList(),
    ): FunderInfo {
        val classification = classifyFunder(name, doi)
        return FunderInfo(
            name = name,
            funderDOI = doi,
            awardNumbers = awardNumbers,
            isIndustry = classification.isIndustry,
            confidence = classification.confidence,
        )
    }

    /**
     * The overall sponsor type of a set of funders.
     *
     * [SponsorType.INDUSTRY] if every funder is industry; [SponsorType.MIXED] if
     * some are; otherwise [SponsorType.GOVERNMENT] if any funder's name matches a
     * government pattern, else [SponsorType.ACADEMIC] if any matches an academic
     * one, else [SponsorType.NONPROFIT]. [SponsorType.UNKNOWN] when there are no funders.
     *
     * @param funders Classified funders.
     * @return The sponsor type.
     */
    fun determineSponsorType(funders: List<FunderInfo>): SponsorType {
        if (funders.isEmpty()) return SponsorType.UNKNOWN

        val industryFunders = funders.filter { it.isIndustry }
        val nonIndustryFunders = funders.filter { !it.isIndustry }

        if (industryFunders.isNotEmpty() && nonIndustryFunders.isEmpty()) return SponsorType.INDUSTRY
        if (industryFunders.isNotEmpty()) return SponsorType.MIXED

        val hasGovernment = nonIndustryFunders.any {
            TransparencyRegex.anyMatch(IndustryPatterns.governmentPatterns, it.name.lowercase())
        }
        if (hasGovernment) return SponsorType.GOVERNMENT

        val hasAcademic = nonIndustryFunders.any {
            TransparencyRegex.anyMatch(IndustryPatterns.academicPatterns, it.name.lowercase())
        }
        return if (hasAcademic) SponsorType.ACADEMIC else SponsorType.NONPROFIT
    }

    /**
     * Whether any funder is industry, with the highest industry confidence.
     *
     * @param funders Classified funders.
     * @return The status; `(false, 0.0)` when there is no industry funder.
     */
    fun industryFundingStatus(funders: List<FunderInfo>): IndustryFundingStatus {
        val industryFunders = funders.filter { it.isIndustry }
        if (industryFunders.isEmpty()) return IndustryFundingStatus(detected = false, confidence = 0.0)
        return IndustryFundingStatus(detected = true, confidence = industryFunders.maxOf { it.confidence })
    }

    /**
     * Classify the funders of a CrossRef work's `funder` array.
     *
     * Each entry is read as Swift reads it: `name` must be a string (entries
     * without one are skipped), `DOI` is used only when a string, and `award` is
     * used only when every element is a string.
     *
     * @param crossRefFunders The `funder` entries, already known to be JSON objects; null for none.
     * @return The classified funders, in source order.
     */
    fun parseCrossRefFunders(crossRefFunders: List<JsonObject>?): List<FunderInfo> {
        if (crossRefFunders == null) return emptyList()
        return crossRefFunders.mapNotNull { funder ->
            val name = JsonCasts.string(funder["name"]) ?: return@mapNotNull null
            val doi = JsonCasts.string(funder["DOI"])
            val awards = JsonCasts.stringList(funder["award"]) ?: emptyList()
            createFunderInfo(name = name, doi = doi, awardNumbers = awards)
        }
    }

    /**
     * Classify funders from PubMed grant entries (`agency` / `grant_id`).
     *
     * @param grants Grant maps; entries whose agency is null or empty are skipped. Null for none.
     * @return The classified funders, in source order.
     */
    fun parsePubMedGrants(grants: List<Map<String, String?>>?): List<FunderInfo> {
        if (grants == null) return emptyList()
        return grants.mapNotNull { grant ->
            val agency = grant["agency"]
            if (agency.isNullOrEmpty()) return@mapNotNull null
            val awardNumbers = grant["grant_id"]?.let { listOf(it) } ?: emptyList()
            createFunderInfo(name = agency, awardNumbers = awardNumbers)
        }
    }

    /**
     * Merge funder lists from several sources, dropping duplicates.
     *
     * Funders are duplicates when their names match case-insensitively; the one
     * with the higher confidence is kept. Unlike Swift, which returns a
     * dictionary's values in no defined order, the result here is in the order
     * each name was first seen.
     *
     * @param funderLists The lists to merge.
     * @return One funder per name.
     */
    fun mergeFunders(vararg funderLists: List<FunderInfo>): List<FunderInfo> {
        val fundersByName = LinkedHashMap<String, FunderInfo>()
        for (list in funderLists) {
            for (funder in list) {
                val key = funder.name.lowercase()
                val existing = fundersByName[key]
                if (existing == null || funder.confidence > existing.confidence) {
                    fundersByName[key] = funder
                }
            }
        }
        return fundersByName.values.toList()
    }

    /**
     * Refine a sponsor type with a ClinicalTrials.gov sponsor class.
     *
     * An industry trial sponsor turns an unknown sponsor type into industry, and
     * a government/academic/non-profit one into mixed.
     *
     * @param currentType The sponsor type from the funding analysis.
     * @param trialSponsorClass The trial's sponsor class (e.g. "INDUSTRY", "NIH"), or null.
     * @return The refined sponsor type.
     */
    fun updateSponsorType(currentType: SponsorType, trialSponsorClass: String?): SponsorType {
        val sponsorClass = trialSponsorClass?.uppercase() ?: return currentType
        val isTrialIndustry = sponsorClass == INDUSTRY_SPONSOR_CLASS
        return when (currentType) {
            SponsorType.UNKNOWN -> if (isTrialIndustry) SponsorType.INDUSTRY else currentType
            SponsorType.GOVERNMENT, SponsorType.ACADEMIC, SponsorType.NONPROFIT ->
                if (isTrialIndustry) SponsorType.MIXED else currentType
            SponsorType.INDUSTRY, SponsorType.MIXED -> currentType
        }
    }

    /**
     * A one-line summary of a funding analysis for display.
     *
     * @param funders Classified funders.
     * @param sponsorType Their sponsor type.
     * @return The summary.
     */
    fun formatSummary(funders: List<FunderInfo>, sponsorType: SponsorType): String {
        if (funders.isEmpty()) return "No funding information available"

        val industryCount = funders.count { it.isIndustry }
        val totalCount = funders.size

        return when (sponsorType) {
            SponsorType.INDUSTRY -> "Industry-funded ($industryCount funder${plural(industryCount)})"
            SponsorType.MIXED ->
                "Mixed funding ($industryCount industry, ${totalCount - industryCount} non-industry)"
            SponsorType.GOVERNMENT -> "Government-funded ($totalCount funder${plural(totalCount)})"
            SponsorType.ACADEMIC -> "Academic-funded ($totalCount funder${plural(totalCount)})"
            SponsorType.NONPROFIT -> "Non-profit funded ($totalCount funder${plural(totalCount)})"
            SponsorType.UNKNOWN -> "Funding source unknown"
        }
    }

    /** The plural suffix for [count] items: "" for one, "s" otherwise. */
    private fun plural(count: Int): String = if (count == 1) "" else "s"
}
