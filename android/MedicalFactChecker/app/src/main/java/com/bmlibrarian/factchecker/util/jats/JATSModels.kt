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

package com.bmlibrarian.factchecker.util.jats

import com.bmlibrarian.factchecker.util.Constants

/**
 * Errors that can occur during JATS XML parsing.
 */
sealed class JATSParseError : Exception() {
    /**
     * XML parsing failed with an underlying error.
     *
     * @param reason Description of why parsing failed.
     */
    data class ParsingFailed(val reason: String) : JATSParseError() {
        override val message: String = "Failed to parse JATS XML: $reason"
    }

    /**
     * No content was found in the XML.
     */
    data object NoContent : JATSParseError() {
        override val message: String = "No content found in JATS XML"
    }

    /**
     * Invalid or unsupported XML structure.
     *
     * @param reason Description of the structural issue.
     */
    data class InvalidStructure(val reason: String) : JATSParseError() {
        override val message: String = "Invalid JATS XML structure: $reason"
    }
}

/**
 * Parsed author information from a JATS article.
 *
 * @param surname Author's surname/family name.
 * @param givenNames Author's given names (first name, middle names).
 * @param affiliations Author's affiliations.
 */
data class JATSAuthorInfo(
    val surname: String,
    val givenNames: String,
    val affiliations: List<String> = emptyList()
) {
    /**
     * Formatted full name (given names + surname).
     */
    val fullName: String
        get() = if (givenNames.isEmpty()) surname else "$givenNames $surname"
}

/**
 * Parsed abstract section from a JATS article.
 *
 * @param title Section title (e.g., "Background", "Methods").
 * @param content Section content.
 */
data class JATSAbstractSection(
    val title: String,
    val content: String
)

/**
 * Parsed body section from a JATS article.
 *
 * @param title Section title.
 * @param paragraphs Paragraphs in the section.
 * @param subsections Nested subsections.
 */
data class JATSBodySection(
    val title: String,
    val paragraphs: List<String>,
    val subsections: List<JATSBodySection> = emptyList()
)

/**
 * Parsed figure information from a JATS article.
 *
 * @param id Figure ID (for cross-references).
 * @param label Figure label (e.g., "Figure 1").
 * @param caption Figure caption text.
 * @param graphicUrl URL or path to the figure graphic.
 */
data class JATSFigureInfo(
    val id: String,
    val label: String,
    val caption: String,
    val graphicUrl: String?
)

/**
 * Parsed table information from a JATS article.
 *
 * @param id Table ID (for cross-references).
 * @param label Table label (e.g., "Table 1").
 * @param caption Table caption text.
 * @param markdownContent Table content as markdown table format.
 */
data class JATSTableInfo(
    val id: String,
    val label: String,
    val caption: String,
    val markdownContent: String
)

/**
 * Parsed reference information from a JATS article.
 *
 * @param id Reference ID (for cross-references).
 * @param label Reference label (e.g., "1", "2").
 * @param citation Raw citation text.
 * @param authors List of author names.
 * @param articleTitle Article title.
 * @param source Journal name.
 * @param year Publication year.
 * @param volume Volume number.
 * @param issue Issue number.
 * @param firstPage First page.
 * @param lastPage Last page.
 * @param doi Digital Object Identifier.
 * @param pmid PubMed ID.
 */
data class JATSReferenceInfo(
    val id: String,
    val label: String,
    val citation: String,
    val authors: List<String>,
    val articleTitle: String,
    val source: String,
    val year: String,
    val volume: String,
    val issue: String,
    val firstPage: String,
    val lastPage: String,
    val doi: String,
    val pmid: String
) {
    /**
     * Format the reference as a complete citation string.
     */
    val formattedCitation: String
        get() {
            val parts = mutableListOf<String>()

            // Authors
            if (authors.isNotEmpty()) {
                if (authors.size <= Constants.JATS_MAX_AUTHORS_BEFORE_ET_AL) {
                    parts.add(authors.joinToString(", "))
                } else {
                    parts.add("${authors[0]}, ${authors[1]}, et al.")
                }
            }

            // Article title
            if (articleTitle.isNotEmpty()) {
                parts.add(articleTitle)
            }

            // Journal name (italicized in markdown)
            if (source.isNotEmpty()) {
                parts.add("*$source*")
            }

            // Year
            if (year.isNotEmpty()) {
                parts.add("($year)")
            }

            // Volume and pages
            var volumeInfo = ""
            if (volume.isNotEmpty()) {
                volumeInfo = volume
                if (issue.isNotEmpty()) {
                    volumeInfo += "($issue)"
                }
            }
            if (firstPage.isNotEmpty()) {
                if (volumeInfo.isNotEmpty()) {
                    volumeInfo += ":"
                }
                volumeInfo += firstPage
                if (lastPage.isNotEmpty()) {
                    volumeInfo += "-$lastPage"
                }
            }
            if (volumeInfo.isNotEmpty()) {
                parts.add(volumeInfo)
            }

            // DOI
            if (doi.isNotEmpty()) {
                parts.add("doi:$doi")
            }

            // If we have structured data, use it; otherwise fall back to raw citation
            return if (parts.isEmpty()) citation else parts.joinToString(". ")
        }
}

/**
 * Complete parsed JATS article data.
 *
 * @param title Article title.
 * @param authors Article authors.
 * @param journal Journal name.
 * @param volume Volume number.
 * @param issue Issue number.
 * @param pages Page range.
 * @param year Publication year.
 * @param doi Digital Object Identifier.
 * @param pmcId PubMed Central ID.
 * @param pmid PubMed ID.
 * @param abstractSections Abstract sections.
 * @param bodySections Body sections.
 * @param figures Figures.
 * @param tables Tables.
 * @param references References.
 */
data class JATSArticle(
    val title: String,
    val authors: List<JATSAuthorInfo>,
    val journal: String,
    val volume: String,
    val issue: String,
    val pages: String,
    val year: String,
    val doi: String,
    val pmcId: String,
    val pmid: String,
    val abstractSections: List<JATSAbstractSection>,
    val bodySections: List<JATSBodySection>,
    val figures: List<JATSFigureInfo>,
    val tables: List<JATSTableInfo>,
    val references: List<JATSReferenceInfo>
)
