package com.bmlibrarian.factchecker.domain.transparency

/**
 * Known industry funder DOIs from the CrossRef Funder Registry.
 *
 * Maps registry DOIs to company names for major pharmaceutical, biotechnology
 * and medical device companies. A match is the highest-confidence layer of
 * [FundingAnalyzer.classifyFunder]. Transcribed from the Swift
 * `KnownIndustryFunders` (BioMedLit).
 */
object KnownIndustryFunders {

    /** CrossRef Funder Registry DOI -> company name. */
    val funderDOIs: Map<String, String> = linkedMapOf(
        "10.13039/100004319" to "Pfizer",
        "10.13039/100004325" to "AstraZeneca",
        "10.13039/100004326" to "Bayer",
        "10.13039/100004328" to "GlaxoSmithKline",
        "10.13039/100004330" to "Johnson & Johnson",
        "10.13039/100004331" to "Eli Lilly",
        "10.13039/100004334" to "Merck",
        "10.13039/100004336" to "Novartis",
        "10.13039/100004337" to "Novo Nordisk",
        "10.13039/100004339" to "Roche",
        "10.13039/100004341" to "Sanofi",
        "10.13039/100005564" to "Gilead Sciences",
        "10.13039/100006483" to "AbbVie",
        "10.13039/100006436" to "Celgene",
        "10.13039/100006928" to "Amgen",
        "10.13039/100007054" to "Bristol-Myers Squibb",
        "10.13039/100008272" to "Biogen",
        "10.13039/100008897" to "Boehringer Ingelheim",
        "10.13039/100009947" to "Takeda",
        "10.13039/100010877" to "UCB",
        "10.13039/100014476" to "Regeneron",
        "10.13039/100004344" to "Teva",
        "10.13039/100007723" to "Allergan",
        "10.13039/100004374" to "Medtronic",
        "10.13039/100004375" to "Boston Scientific",
        "10.13039/100007497" to "Abbott",
    )

    /**
     * Whether a funder DOI is a known industry funder.
     *
     * @param doi The CrossRef Funder Registry DOI, or null.
     * @return True if the DOI is in [funderDOIs].
     */
    fun isIndustryFunder(doi: String?): Boolean = doi != null && funderDOIs.containsKey(doi)

    /**
     * The company name for a funder DOI.
     *
     * @param doi The CrossRef Funder Registry DOI.
     * @return The company name, or null if the DOI is not known.
     */
    fun companyName(doi: String): String? = funderDOIs[doi]
}
