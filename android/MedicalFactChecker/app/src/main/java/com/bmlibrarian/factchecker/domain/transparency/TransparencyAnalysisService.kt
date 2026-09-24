package com.bmlibrarian.factchecker.domain.transparency

import android.util.Log
import com.bmlibrarian.factchecker.data.remote.transparency.ClinicalTrialsService
import com.bmlibrarian.factchecker.data.remote.transparency.CrossRefService
import com.bmlibrarian.factchecker.data.remote.transparency.describeFailure
import kotlinx.coroutines.CancellationException

/**
 * Why a transparency analysis could not start. Messages are those of the Swift
 * `TransparencyAnalysisError`.
 */
sealed class TransparencyAnalysisException(message: String) : Exception(message) {
    /** Neither a DOI nor a PMID was given. */
    class NoIdentifiers : TransparencyAnalysisException("Must provide either DOI or PMID for analysis")

    /** The analysis failed for the stated reason. */
    class AnalysisFailure(val reason: String) : TransparencyAnalysisException("Analysis failed: $reason")
}

/**
 * Analyses one study's transparency: funding, trial registration, conflicts of
 * interest and data availability, combined into a scored [TransparencyResult].
 *
 * Ported from the Swift `TransparencyAnalysisService` (BioMedLit), step for step,
 * except that the PubMed metadata lookup is injected ([ArticleMetadataLookup]).
 *
 * **A failed request is logged and the analysis continues, as in Swift.** A
 * failed CrossRef or ClinicalTrials.gov lookup — unlike a 404, which is the
 * source's answer — is also recorded in `warnings`, so an unchecked funder list
 * or registration does not read as an absent one, and a missing registration is
 * reported only when the registry answered for every cited trial. A failed
 * PubMed lookup is only logged; [TransparencyResult.dataSourcesUsed] records
 * which sources *did* answer.
 *
 * @param metadataLookup PubMed metadata by PMID.
 * @param crossRefService CrossRef client (work metadata and funders).
 * @param clinicalTrialsService ClinicalTrials.gov client (trial registrations).
 */
class TransparencyAnalysisService(
    private val metadataLookup: ArticleMetadataLookup,
    private val crossRefService: CrossRefService,
    private val clinicalTrialsService: ClinicalTrialsService,
) {

    /**
     * Analyse a study.
     *
     * Steps, as in Swift: PubMed metadata (when a PMID is given), then CrossRef
     * metadata and funders (when a DOI is given or PubMed supplied one); sponsor
     * type and industry funding from the funders; trial registrations for NCT IDs
     * found in the *title*; the COI and data-availability statements, looked for
     * only in [fullText]; and the funding/COI and missing-registration warnings.
     *
     * @param doi Digital Object Identifier (optional if [pmid] is given).
     * @param pmid PubMed ID (optional if [doi] is given). **Must be one the caller
     *   established as a PubMed ID**, not an article's primary identifier passed
     *   through: it is looked up on PubMed and the answer's title, journal,
     *   authors and DOI are adopted as this article's, so a Europe PMC accession —
     *   a bare decimal indistinguishable from a PMID — would file an unrelated
     *   article's funding and conflicts under this one (Swift #212).
     * @param fullText The article's full text, if available. Recorded in
     *   [TransparencyResult.fullTextSearched]: true only when it is non-blank.
     * @return The scored result.
     * @throws TransparencyAnalysisException.NoIdentifiers if neither identifier is given.
     */
    suspend fun analyze(doi: String? = null, pmid: String? = null, fullText: String? = null): TransparencyResult {
        if (doi == null && pmid == null) throw TransparencyAnalysisException.NoIdentifiers()

        val builder = TransparencyResultBuilder(doi = doi, pmid = pmid)
        // Recorded so a report can tell a statement the article lacks from one
        // there was no text to look for: both statement analyses read full text only.
        builder.fullTextSearched = fullText?.isNotBlank() == true

        Log.i(TAG, "Starting transparency analysis for DOI: ${doi ?: "nil"}, PMID: ${pmid ?: "nil"}")

        fetchBasicMetadata(builder)
        analyzeFunders(builder)
        fetchTrialInfo(builder)
        analyzeCoi(builder, fullText)
        analyzeDataAvailability(builder, fullText)
        checkDiscrepancies(builder)

        val result = builder.build()
        Log.i(
            TAG,
            "Transparency analysis complete: score=${result.transparencyScore}, risk=${result.riskLevel.rawValue}",
        )
        return result
    }

    /**
     * Step 1: PubMed metadata (by PMID), then CrossRef metadata and funders (by DOI).
     *
     * PubMed's DOI is adopted when the caller gave none, so a PubMed failure also
     * loses the CrossRef lookup — and with it every funder.
     */
    private suspend fun fetchBasicMetadata(builder: TransparencyResultBuilder) {
        val pmid = builder.pmid
        if (pmid != null) {
            try {
                val article = metadataLookup.lookup(pmid)
                if (article != null) {
                    builder.title = article.title
                    builder.journal = article.journal
                    builder.authors = article.authors
                    builder.pmcid = article.pmcid
                    if (builder.doi == null) builder.doi = article.doi
                    builder.dataSourcesUsed = builder.dataSourcesUsed + TransparencyConstants.PUBMED_SOURCE_NAME
                    Log.d(TAG, "PubMed metadata retrieved for PMID: $pmid")
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.w(TAG, "PubMed fetch failed for PMID $pmid: ${describeFailure(e)}")
            }
        }

        val doi = builder.doi ?: return
        try {
            val work = crossRefService.getWork(doi) ?: return
            builder.dataSourcesUsed = builder.dataSourcesUsed + TransparencyConstants.CROSSREF_SOURCE_NAME
            if (builder.title == null) builder.title = crossRefService.extractTitle(work)
            if (builder.journal == null) builder.journal = crossRefService.extractJournal(work)
            if (builder.authors.isEmpty()) builder.authors = crossRefService.extractAuthors(work)
            if (builder.publicationDate == null) builder.publicationDate = crossRefService.extractPublicationDate(work)
            builder.funders = FundingAnalyzer.mergeFunders(builder.funders, crossRefService.extractFunders(work))
            Log.d(TAG, "CrossRef metadata retrieved for DOI: $doi")
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            // A 404 returns null above; anything thrown is a failed lookup, which must not
            // read as a study with no funders.
            builder.warnings = builder.warnings + TransparencyConstants.CROSSREF_UNREACHABLE_WARNING
            Log.w(TAG, "CrossRef fetch failed for DOI $doi: ${describeFailure(e)}")
        }
    }

    /** Step 2: sponsor type and industry-funding status from the funders collected so far. */
    private fun analyzeFunders(builder: TransparencyResultBuilder) {
        builder.sponsorType = FundingAnalyzer.determineSponsorType(builder.funders)
        val status = FundingAnalyzer.industryFundingStatus(builder.funders)
        builder.industryFundingDetected = status.detected
        builder.industryFundingConfidence = status.confidence
        Log.d(
            TAG,
            "Funding analysis: sponsorType=${builder.sponsorType}, " +
                "industryDetected=${status.detected}, confidence=${status.confidence}",
        )
    }

    /**
     * Step 3: trial registrations for the NCT IDs in the title.
     *
     * An industry sponsor class sets industry funding and refines the sponsor
     * type; results compliance is checked for the first registration found.
     */
    private suspend fun fetchTrialInfo(builder: TransparencyResultBuilder) {
        val nctIds = builder.title?.let { TrialComplianceAnalyzer.extractNCTIds(it) } ?: emptyList()
        if (nctIds.isEmpty()) {
            Log.d(TAG, "No NCT IDs found in article")
            return
        }
        Log.d(TAG, "Found ${nctIds.size} NCT ID(s): ${nctIds.joinToString(", ")}")

        // The registration counts as assessed only if the registry answered for every trial:
        // a failed or unreadable lookup leaves the list empty for a reason not the study's.
        var everyTrialAnswered = true
        for (nctId in nctIds) {
            try {
                val study = clinicalTrialsService.getStudy(nctId)
                if (study == null) {
                    builder.warnings = builder.warnings + TrialComplianceAnalyzer.registryHasNoRecordWarning(nctId)
                    continue
                }
                val registration = clinicalTrialsService.extractTrialInfo(study)
                if (registration == null) {
                    everyTrialAnswered = false
                    builder.warnings = builder.warnings + TrialComplianceAnalyzer.unreadableRegistryRecordWarning(nctId)
                    continue
                }

                builder.trialRegistrations = builder.trialRegistrations + registration
                if (TransparencyConstants.CLINICAL_TRIALS_REGISTRY_NAME !in builder.dataSourcesUsed) {
                    builder.dataSourcesUsed =
                        builder.dataSourcesUsed + TransparencyConstants.CLINICAL_TRIALS_REGISTRY_NAME
                }

                if (TrialComplianceAnalyzer.isIndustrySponsor(registration.sponsorClass)) {
                    builder.industryFundingDetected = true
                    builder.sponsorType = FundingAnalyzer.updateSponsorType(builder.sponsorType, registration.sponsorClass)
                }
                Log.d(TAG, "Trial info retrieved for $nctId: sponsor=${registration.leadSponsor ?: "unknown"}")
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                everyTrialAnswered = false
                builder.warnings = builder.warnings + TrialComplianceAnalyzer.registryUnreachableWarning(nctId)
                Log.w(TAG, "ClinicalTrials.gov fetch failed for $nctId: ${describeFailure(e)}")
            }
        }
        builder.trialRegistrationAssessed = everyTrialAnswered

        builder.trialRegistrations.firstOrNull()?.let { firstTrial ->
            builder.resultsCompliance = TrialComplianceAnalyzer.checkResultsCompliance(
                trial = firstTrial,
                publicationDate = builder.publicationDate,
            )
        }
    }

    /** Step 4: the COI statement, from the full text only. */
    private fun analyzeCoi(builder: TransparencyResultBuilder, fullText: String?) {
        val coiStatement = fullText?.let { FullTextSections.extractCoi(it) }
        builder.coiAnalysis = COIAnalyzer.analyze(coiStatement)
        Log.d(
            TAG,
            "COI analysis: hasStatement=${coiStatement != null}, " +
                "hasIndustryTies=${builder.coiAnalysis.hasIndustryTies}",
        )
    }

    /** Step 5: the data-availability statement, from the full text only. */
    private fun analyzeDataAvailability(builder: TransparencyResultBuilder, fullText: String?) {
        val dataStatement = fullText?.let { FullTextSections.extractDataAvailability(it) }
        builder.dataAvailability = DataAvailabilityAnalyzer.analyze(dataStatement)
        Log.d(TAG, "Data availability analysis: level=${builder.dataAvailability.disclosureLevel}")
    }

    /** Step 6: the funding/COI discrepancy and missing-registration warnings. */
    private fun checkDiscrepancies(builder: TransparencyResultBuilder) {
        COIAnalyzer.checkFundingCOIDiscrepancy(builder.coiAnalysis, builder.industryFundingDetected)?.let {
            builder.warnings = builder.warnings + it
            Log.d(TAG, "Discrepancy detected: $it")
        }
        TrialComplianceAnalyzer.checkMissingRegistration(
            builder.title,
            builder.trialRegistrations,
            builder.trialRegistrationAssessed,
        )?.let {
            builder.warnings = builder.warnings + it
            Log.d(TAG, "Missing registration warning: $it")
        }
    }

    companion object {
        private const val TAG = "TransparencyAnalysis"
        private const val AUTHOR_SEPARATOR = ", "

        /**
         * Split a comma-separated author string into names, as Swift's service does
         * with PubMed's author string. For [ArticleMetadataLookup] adapters whose
         * client returns authors as one string.
         *
         * @param authors Authors separated by ", ".
         * @return The trimmed, non-empty names.
         */
        fun formatAuthorsToList(authors: String): List<String> =
            authors.split(AUTHOR_SEPARATOR).map { it.trim(' ', '\t') }.filter { it.isNotEmpty() }
    }
}
