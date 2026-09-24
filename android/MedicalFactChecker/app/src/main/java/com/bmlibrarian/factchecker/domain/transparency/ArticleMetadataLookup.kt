package com.bmlibrarian.factchecker.domain.transparency

/**
 * The PubMed metadata a transparency analysis adopts for an article.
 *
 * @property title Article title.
 * @property journal Journal name.
 * @property authors Author names, in order.
 * @property doi DOI, used to reach CrossRef when the caller supplied none.
 * @property pmcid PubMed Central identifier.
 */
data class ArticleMetadata(
    val title: String?,
    val journal: String?,
    val authors: List<String>,
    val doi: String?,
    val pmcid: String?,
)

/**
 * Looks up an article's PubMed metadata by PMID for [TransparencyAnalysisService].
 *
 * Injected so the app's own PubMed client can serve it. The contract matters,
 * because the service cannot tell the two cases apart otherwise:
 *  - return **null only when PubMed has no such article**;
 *  - **throw** when PubMed could not be asked (network, server, unreadable
 *    answer). The service logs the failure and continues without PubMed, as
 *    the Swift service does — but an adapter that turns a failure into null
 *    makes an outage indistinguishable from an absent record.
 */
fun interface ArticleMetadataLookup {
    /**
     * Look up one article.
     *
     * @param pmid A PubMed ID the caller established as one (see [TransparencyAnalysisService.analyze]).
     * @return The article's metadata, or null if PubMed has no such article.
     * @throws Exception if PubMed could not be asked.
     */
    suspend fun lookup(pmid: String): ArticleMetadata?
}
