/*
 * BMLibrarian Lite - Biomedical Literature Research Tool
 * Copyright (C) 2024-2025 Dr Horst Herb
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

package com.bmlibrarian.factchecker.data.remote.europepmc

import android.util.Log
import com.bmlibrarian.factchecker.domain.model.RetrievalShortfall
import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.nullable
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonDecoder

/**
 * Europe PMC search response.
 */
@Serializable
data class EuropePMCSearchResponse(
    /** Total number of matching articles. */
    val hitCount: Int? = null,
    /** Cursor for next page of results. */
    val nextCursorMark: String? = null,
    /** List of results. */
    val resultList: EuropePMCResultList? = null
)

/**
 * Container for Europe PMC results.
 */
@Serializable
data class EuropePMCResultList(
    /**
     * The page's records, null where a record could not be decoded.
     *
     * Decoded one record at a time ([LossyArticleListSerializer]), so a damaged
     * record costs itself, not the page, and is counted rather than lost.
     */
    @Serializable(with = LossyArticleListSerializer::class)
    val result: List<EuropePMCArticle?>? = null
)

/** Log tag for records a Europe PMC page held that did not decode. */
private const val LOSSY_DECODE_TAG = "EuropePMCModels"

/**
 * Decodes a result list record by record, keeping a null for each record that fails.
 *
 * Decoding the list as a whole would fail the entire page on one record of an
 * unexpected shape. A value that is not a JSON array still fails, since then
 * the answer itself cannot be read.
 */
object LossyArticleListSerializer : KSerializer<List<EuropePMCArticle?>> {

    private val listSerializer = ListSerializer(EuropePMCArticle.serializer().nullable)

    override val descriptor: SerialDescriptor = listSerializer.descriptor

    /**
     * Decode each record on its own.
     *
     * @param decoder A JSON decoder
     * @return The records, null for each that did not decode
     * @throws SerializationException if the value is not a JSON array, or the format is not JSON
     */
    override fun deserialize(decoder: Decoder): List<EuropePMCArticle?> {
        val input = decoder as? JsonDecoder ?: throw SerializationException("Europe PMC results decode from JSON only")
        val records = input.decodeJsonElement() as? JsonArray
            ?: throw SerializationException("resultList.result is not a list")
        val failures = mutableListOf<String>()
        val decoded = records.map { record ->
            try {
                input.json.decodeFromJsonElement(EuropePMCArticle.serializer(), record)
            } catch (e: SerializationException) {
                failures += e.javaClass.simpleName
                null
            } catch (e: IllegalArgumentException) {
                failures += e.javaClass.simpleName
                null
            }
        }
        if (failures.isNotEmpty()) {
            // The classes only: a decoding error's message quotes the record
            val byClass = failures.groupingBy { it }.eachCount().entries.joinToString { "${it.key} x${it.value}" }
            Log.w(LOSSY_DECODE_TAG, "${failures.size} of ${records.size} Europe PMC records did not decode ($byClass)")
        }
        return decoded
    }

    /**
     * Encode the records as a JSON array.
     *
     * @param encoder The encoder
     * @param value The records
     */
    override fun serialize(encoder: Encoder, value: List<EuropePMCArticle?>) {
        listSerializer.serialize(encoder, value)
    }
}

/**
 * Article from Europe PMC API.
 */
@Serializable
data class EuropePMCArticle(
    /** Internal Europe PMC ID. */
    val id: String? = null,
    /** Source database (MED, PMC, PPR, etc.). */
    val source: String? = null,
    /** PubMed ID. */
    val pmid: String? = null,
    /** PubMed Central ID (with PMC prefix). */
    val pmcid: String? = null,
    /** Digital Object Identifier. */
    val doi: String? = null,
    /** Article title. */
    val title: String? = null,
    /** Author string (comma-separated). */
    val authorString: String? = null,
    /** List of individual authors. */
    val authorList: AuthorList? = null,
    /** Journal title. */
    val journalTitle: String? = null,
    /** Journal ISSN. */
    val journalIssn: String? = null,
    /** Publication date string. */
    val pubDate: String? = null,
    /** Publication year. */
    val pubYear: String? = null,
    /** Abstract text. */
    val abstractText: String? = null,
    /** Affiliation string. */
    val affiliation: String? = null,
    /** Whether article is open access. */
    val isOpenAccess: String? = null,
    /** Open access status (e.g., "Open Access"). */
    @SerialName("openAccessStatus")
    val openAccessStatus: String? = null,
    /** Whether full text is available in Europe PMC. */
    val inEPMC: String? = null,
    /** Whether full text is in PMC. */
    val inPMC: String? = null,
    /** Citation count. */
    val citedByCount: Int? = null,
    /** First publication date. */
    val firstPublicationDate: String? = null,
    /** Language of article. */
    val language: String? = null,
    /** Publication type. */
    val pubTypeList: PubTypeList? = null,
    /** MeSH heading list. */
    val meshHeadingList: MeshHeadingList? = null,
    /** Keyword list. */
    val keywordList: KeywordList? = null,
    /** Whether PDF is available. */
    val hasPDF: String? = null,
    /** Full-text URL list with free PDF render URLs. */
    val fullTextUrlList: FullTextUrlList? = null
)

/**
 * Container for author list.
 */
@Serializable
data class AuthorList(
    val author: List<Author>? = null
)

/**
 * Individual author.
 */
@Serializable
data class Author(
    val fullName: String? = null,
    val firstName: String? = null,
    val lastName: String? = null,
    val initials: String? = null,
    val affiliation: String? = null
)

/**
 * Container for publication types.
 */
@Serializable
data class PubTypeList(
    val pubType: List<String>? = null
)

/**
 * Container for MeSH headings.
 */
@Serializable
data class MeshHeadingList(
    val meshHeading: List<MeshHeading>? = null
)

/**
 * MeSH heading entry.
 */
@Serializable
data class MeshHeading(
    val descriptorName: String? = null,
    val majorTopic_YN: String? = null,
    val meshQualifierList: MeshQualifierList? = null
)

/**
 * Container for MeSH qualifiers.
 */
@Serializable
data class MeshQualifierList(
    val meshQualifier: List<MeshQualifier>? = null
)

/**
 * MeSH qualifier entry.
 */
@Serializable
data class MeshQualifier(
    val qualifierName: String? = null,
    val majorTopic_YN: String? = null
)

/**
 * Container for keywords.
 */
@Serializable
data class KeywordList(
    val keyword: List<String>? = null
)

/**
 * Container for full-text URL list from Europe PMC API.
 */
@Serializable
data class FullTextUrlList(
    val fullTextUrl: List<FullTextUrlEntry>? = null
)

/**
 * Individual full-text URL entry from Europe PMC API.
 *
 * Contains document format, availability, and URL for accessing
 * different versions of the article (PDF, HTML, DOI).
 */
@Serializable
data class FullTextUrlEntry(
    /** Document format (e.g., "pdf", "html", "doi"). */
    val documentStyle: String? = null,
    /** Hosting site (e.g., "Europe_PMC", "DOI"). */
    val site: String? = null,
    /** URL to the document. */
    val url: String? = null,
    /** Availability status (e.g., "Free", "Subscription required"). */
    val availability: String? = null
)

/**
 * One page of a Europe PMC search that answered.
 *
 * A search that failed is never one of these: [EuropePMCService.search] returns
 * a [com.bmlibrarian.factchecker.domain.model.SourceRequestException] instead.
 * What a search that answered still failed to retrieve is in [shortfalls].
 */
data class EuropePMCSearchResult(
    /** The readable articles, each with a title. */
    val articles: List<EuropePMCArticle>,
    /** Total number of results for the query. */
    val totalResults: Int,
    /** Cursor for next page of results (null if no more results). */
    val nextCursor: String?,
    /** Whether there are more results available. */
    val hasMore: Boolean,
    /** Every record this page held, readable or not: what the next page's count starts from. */
    val resultsReceived: Int,
    /** What this page failed to retrieve: records a cursor ended before, and unreadable records. */
    val shortfalls: List<RetrievalShortfall>
)
