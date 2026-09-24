package com.bmlibrarian.factchecker.domain.transparency

import kotlinx.serialization.Serializable

/**
 * The shared labelled funder corpus, `funder_names.json` (bmlib issue #36).
 *
 * 816 real CrossRef and PubMed funder names, 417 of them hand-labelled
 * `industry` / `not_industry` / `ambiguous`. Ambiguous names carry a reason and
 * are excluded from every measurement.
 */
internal object FunderCorpus {

    @Serializable
    data class Entry(val name: String, val source: String, val label: String, val reason: String? = null)

    @Serializable
    private data class Corpus(val entries: List<Entry>)

    /** Every labelled entry, in file order. */
    val entries: List<Entry> by lazy {
        ParityFixtures.json.decodeFromString(Corpus.serializer(), ParityFixtures.read("funder_names.json")).entries
    }

    /** What [FundingAnalyzer.classifyFunder] got right and wrong over the non-ambiguous entries. */
    data class Composition(
        val truePositives: Set<String>,
        val falsePositives: Set<String>,
        val falseNegatives: Set<String>,
    )

    /** Run the real classifier over every non-ambiguous entry. */
    fun classify(): Composition {
        val truePositives = mutableSetOf<String>()
        val falsePositives = mutableSetOf<String>()
        val falseNegatives = mutableSetOf<String>()
        for (entry in entries.filter { it.label != "ambiguous" }) {
            val flagged = FundingAnalyzer.classifyFunder(entry.name).isIndustry
            val gold = entry.label == "industry"
            when {
                flagged && gold -> truePositives.add(entry.name)
                flagged -> falsePositives.add(entry.name)
                gold -> falseNegatives.add(entry.name)
            }
        }
        return Composition(truePositives, falsePositives, falseNegatives)
    }
}
