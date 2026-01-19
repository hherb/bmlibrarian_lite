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

import android.util.Log
import org.xmlpull.v1.XmlPullParser
import org.xmlpull.v1.XmlPullParserFactory
import java.io.ByteArrayInputStream
import java.io.InputStreamReader

/**
 * Parser for converting JATS (Journal Article Tag Suite) XML to markdown and HTML.
 *
 * JATS is the standard XML format used by Europe PMC and many other
 * biomedical literature databases. This parser handles:
 * - Article metadata (title, authors, journal, dates)
 * - Abstract with labeled sections
 * - Full article body with nested sections
 * - Figures and tables (with captions)
 * - References and citations
 * - Inline formatting (bold, italic, subscript, superscript)
 * - Lists (ordered and unordered)
 *
 * Usage:
 * ```kotlin
 * val parser = JATSXMLParser(xmlData)
 * val markdown = parser.parseToMarkdown()
 * // or
 * val html = parser.parseToHTML()
 * ```
 *
 * @param xmlData Raw JATS XML data as ByteArray.
 * @param knownPmcId Optional PMC ID if known from external source (e.g., search results).
 *                   Used for building figure URLs when the XML doesn't contain the PMC ID.
 */
class JATSXMLParser(
    private val xmlData: ByteArray,
    knownPmcId: String? = null
) {
    companion object {
        private const val TAG = "JATSXMLParser"
        private const val MAX_HEADING_LEVEL = 6
        private const val MAX_AUTHORS_BEFORE_ET_AL = 3
        private const val MIN_PMID_LENGTH = 7
        private const val EUROPE_PMC_FIGURE_BASE_URL = "https://europepmc.org/articles"

        /** Elements that accumulate their own text content. */
        private val TEXT_ACCUMULATING_ELEMENTS = setOf(
            "p", "title", "article-title", "abstract", "sec",
            "surname", "given-names", "journal-title", "volume", "issue",
            "fpage", "lpage", "year", "article-id", "label",
            "mixed-citation", "element-citation", "caption",
            "bold", "b", "italic", "i", "sub", "sup", "monospace", "code",
            "xref", "ext-link", "uri", "email", "named-content",
            "list-item", "def", "term", "kwd", "alt-title",
            "inline-formula", "disp-formula", "tex-math",
            "source", "person-group", "pub-id", "collab"
        )

        /** Inline elements that should merge text with parent. */
        private val INLINE_ELEMENTS = setOf(
            "bold", "b", "italic", "i", "sub", "sup", "monospace", "code",
            "xref", "ext-link", "uri", "email", "named-content",
            "inline-formula"
        )

        private val FIGURE_EXTENSIONS = listOf(".jpg", ".gif", ".png")
    }

    // MARK: - Parsed Content

    private var title = ""
    private val authors = mutableListOf<JATSAuthorInfo>()
    private var journal = ""
    private var volume = ""
    private var issue = ""
    private var pages = ""
    private var year = ""
    private var doi = ""
    private var pmcId = knownPmcId?.let { if (it.startsWith("PMC")) it else "PMC$it" } ?: ""
    private var pmid = ""
    private val abstractSections = mutableListOf<JATSAbstractSection>()
    private val bodySections = mutableListOf<JATSBodySection>()
    private val figures = mutableListOf<JATSFigureInfo>()
    private val tables = mutableListOf<JATSTableInfo>()
    private val references = mutableListOf<JATSReferenceInfo>()

    // MARK: - Parsing State

    private val elementStack = mutableListOf<String>()
    private val textStack = mutableListOf("")

    // Article metadata state
    private var inFront = false
    private var inArticleMeta = false
    private var inContribGroup = false
    private var inContrib = false
    private var inAff = false

    // Abstract state
    private var inAbstract = false
    private var currentAbstractTitle = ""
    private val currentAbstractText = mutableListOf<String>()

    // Body and back matter state
    private var inBody = false
    private var inBack = false
    private val sectionStack = mutableListOf<SectionBuilder>()

    // Figure/Table state
    private var inFigure = false
    private var inTableWrap = false
    private var currentFigure: FigureBuilder? = null
    private var currentTable: TableBuilder? = null

    // Reference state
    private var inRefList = false
    private var inRef = false
    private var inRefCitation = false
    private var inRefPersonGroup = false
    private var currentReference: ReferenceBuilder? = null

    // Article ID tracking
    private var currentArticleIdType: String? = null

    // Author state
    private var currentAuthor: AuthorBuilder? = null

    // Cross-reference state
    private var currentXrefType: String? = null
    private var currentXrefRid: String? = null

    // MARK: - Text Stack Helpers

    private val currentText: String
        get() = textStack.lastOrNull() ?: ""

    private fun appendText(text: String) {
        if (textStack.isNotEmpty()) {
            textStack[textStack.lastIndex] = textStack.last() + text
        }
    }

    private fun pushTextBuffer() {
        textStack.add("")
    }

    private fun popTextBuffer(mergeWithParent: Boolean = false): String {
        if (textStack.size <= 1) {
            val text = textStack.firstOrNull() ?: ""
            if (textStack.isNotEmpty()) {
                textStack[0] = ""
            }
            return text
        }

        val text = textStack.removeAt(textStack.lastIndex)
        if (mergeWithParent && text.isNotEmpty() && textStack.isNotEmpty()) {
            textStack[textStack.lastIndex] = textStack.last() + text
        }
        return text
    }

    // MARK: - Public API

    /**
     * Parse the XML and return markdown-formatted content.
     *
     * @return Markdown string representation of the article.
     * @throws JATSParseError if parsing fails.
     */
    @Throws(JATSParseError::class)
    fun parseToMarkdown(): String {
        parse()
        val markdown = buildMarkdown()
        if (markdown.isBlank()) {
            throw JATSParseError.NoContent
        }
        return markdown
    }

    /**
     * Parse the XML and return HTML-formatted content.
     *
     * HTML output provides better table rendering and semantic structure
     * compared to markdown.
     *
     * @return HTML string representation of the article (body content only, no wrapper).
     * @throws JATSParseError if parsing fails.
     */
    @Throws(JATSParseError::class)
    fun parseToHTML(): String {
        parse()
        val html = buildHTML()
        if (html.isBlank()) {
            throw JATSParseError.NoContent
        }
        return html
    }

    /**
     * Parse the XML and return the structured article data.
     *
     * @return JATSArticle containing all parsed data.
     * @throws JATSParseError if parsing fails.
     */
    @Throws(JATSParseError::class)
    fun parseToArticle(): JATSArticle {
        parse()
        return JATSArticle(
            title = title,
            authors = authors.toList(),
            journal = journal,
            volume = volume,
            issue = issue,
            pages = pages,
            year = year,
            doi = doi,
            pmcId = pmcId,
            pmid = pmid,
            abstractSections = abstractSections.toList(),
            bodySections = bodySections.toList(),
            figures = figures.toList(),
            tables = tables.toList(),
            references = references.toList()
        )
    }

    // MARK: - XML Parsing

    @Throws(JATSParseError::class)
    private fun parse() {
        try {
            val factory = XmlPullParserFactory.newInstance()
            factory.isNamespaceAware = false
            val parser = factory.newPullParser()
            parser.setInput(InputStreamReader(ByteArrayInputStream(xmlData), Charsets.UTF_8))

            var eventType = parser.eventType
            while (eventType != XmlPullParser.END_DOCUMENT) {
                when (eventType) {
                    XmlPullParser.START_TAG -> handleStartElement(parser)
                    XmlPullParser.TEXT -> handleCharacters(parser.text ?: "")
                    XmlPullParser.END_TAG -> handleEndElement(parser.name)
                }
                eventType = parser.next()
            }
        } catch (e: JATSParseError) {
            throw e
        } catch (e: Exception) {
            Log.e(TAG, "JATS XML parse error: ${e.message}")
            throw JATSParseError.ParsingFailed(e.message ?: "Unknown parsing error")
        }
    }

    private fun handleStartElement(parser: XmlPullParser) {
        val elementName = parser.name
        elementStack.add(elementName)

        if (elementName in TEXT_ACCUMULATING_ELEMENTS) {
            pushTextBuffer()
        }

        when (elementName) {
            // Document structure
            "front" -> inFront = true
            "article-meta" -> inArticleMeta = true
            "contrib-group" -> inContribGroup = true
            "contrib" -> {
                if (parser.getAttributeValue(null, "contrib-type") == "author") {
                    inContrib = true
                    currentAuthor = AuthorBuilder()
                }
            }
            "aff" -> inAff = true
            "abstract" -> {
                inAbstract = true
                currentAbstractTitle = ""
                currentAbstractText.clear()
            }
            "body" -> inBody = true
            "back" -> inBack = true
            "sec" -> sectionStack.add(SectionBuilder())
            "fig" -> {
                inFigure = true
                currentFigure = FigureBuilder().apply {
                    id = parser.getAttributeValue(null, "id") ?: ""
                }
            }
            "graphic" -> {
                if (inFigure) {
                    val href = parser.getAttributeValue(null, "xlink:href")
                        ?: parser.getAttributeValue(null, "href")
                        ?: parser.getAttributeValue(null, "xlink-href")
                    if (href != null) {
                        currentFigure?.graphicHref = href
                    }
                }
            }
            "table-wrap" -> {
                inTableWrap = true
                currentTable = TableBuilder().apply {
                    id = parser.getAttributeValue(null, "id") ?: ""
                }
            }
            "thead" -> currentTable?.startHeader()
            "tbody" -> currentTable?.startBody()
            "tr" -> currentTable?.startRow()
            "th" -> {
                val colspan = parser.getAttributeValue(null, "colspan")?.toIntOrNull() ?: 1
                currentTable?.startCell(isHeader = true, colspan = colspan)
            }
            "td" -> {
                val colspan = parser.getAttributeValue(null, "colspan")?.toIntOrNull() ?: 1
                currentTable?.startCell(isHeader = false, colspan = colspan)
            }
            "list" -> {
                if (inTableWrap) {
                    val listType = parser.getAttributeValue(null, "list-type") ?: ""
                    currentTable?.startList(ordered = listType.startsWith("order"))
                }
            }
            "list-item" -> currentTable?.startListItem()
            "ref-list" -> inRefList = true
            "ref" -> {
                inRef = true
                currentReference = ReferenceBuilder().apply {
                    id = parser.getAttributeValue(null, "id") ?: ""
                }
            }
            "mixed-citation", "element-citation" -> {
                if (inRef) inRefCitation = true
            }
            "person-group" -> {
                if (inRefCitation) inRefPersonGroup = true
            }
            "article-id" -> {
                currentArticleIdType = parser.getAttributeValue(null, "pub-id-type")
            }
            "xref" -> {
                currentXrefType = parser.getAttributeValue(null, "ref-type")
                currentXrefRid = parser.getAttributeValue(null, "rid")
            }
        }
    }

    private fun handleCharacters(text: String) {
        appendText(text)
        if (inTableWrap) {
            currentTable?.appendCellText(text)
        }
    }

    private fun handleEndElement(elementName: String) {
        // Pop text buffer if this was a text-accumulating element
        val elementText: String
        if (elementName in TEXT_ACCUMULATING_ELEMENTS) {
            val isInlineElement = elementName in INLINE_ELEMENTS
            val isFigureOrTableXref = elementName == "xref" &&
                    (currentXrefType in listOf("fig", "figure", "table", "table-wrap"))
            elementText = popTextBuffer(mergeWithParent = isInlineElement && !isFigureOrTableXref)
        } else {
            elementText = currentText
        }

        val text = elementText.trim()
        val normalizedText = normalizeWhitespace(elementText)

        elementStack.removeLastOrNull()

        when (elementName) {
            // Document structure
            "front" -> inFront = false
            "article-meta" -> inArticleMeta = false
            "contrib-group" -> inContribGroup = false
            "contrib" -> {
                if (inContrib) {
                    currentAuthor?.build()?.let { authors.add(it) }
                }
                inContrib = false
                currentAuthor = null
            }
            "aff" -> inAff = false

            // Metadata fields
            "journal-title" -> {
                if (inFront) journal = text
            }
            "article-id" -> {
                val parent = elementStack.lastOrNull()
                if (parent == "article-meta" || inFront) {
                    val idType = currentArticleIdType
                    if (idType != null) {
                        when (idType.lowercase()) {
                            "doi" -> doi = text
                            "pmc", "pmcid" -> pmcId = normalizePmcId(text)
                            "pmid", "pubmed" -> pmid = text
                            else -> classifyArticleIdByPattern(text)
                        }
                    } else {
                        classifyArticleIdByPattern(text)
                    }
                    currentArticleIdType = null
                }
            }

            // Abstract
            "abstract" -> {
                if (currentAbstractText.isNotEmpty()) {
                    val content = currentAbstractText.joinToString(" ")
                    abstractSections.add(JATSAbstractSection(currentAbstractTitle, content))
                }
                inAbstract = false
            }
            "title" -> {
                if (inAbstract) {
                    if (currentAbstractText.isNotEmpty()) {
                        val content = currentAbstractText.joinToString(" ")
                        abstractSections.add(JATSAbstractSection(currentAbstractTitle, content))
                        currentAbstractText.clear()
                    }
                    currentAbstractTitle = text
                } else if (sectionStack.isNotEmpty()) {
                    sectionStack.last().title = normalizedText
                }
            }
            "p" -> {
                when {
                    inAbstract && normalizedText.isNotEmpty() -> {
                        currentAbstractText.add(normalizedText)
                    }
                    (inBody || inBack) && sectionStack.isNotEmpty() -> {
                        sectionStack.last().paragraphs.add(normalizedText)
                    }
                    inFigure -> {
                        currentFigure?.let { it.caption += normalizedText }
                    }
                    inTableWrap -> {
                        currentTable?.let { it.caption += normalizedText }
                    }
                }
            }

            // Body and back matter sections
            "body" -> inBody = false
            "back" -> inBack = false
            "sec" -> {
                sectionStack.removeLastOrNull()?.let { builder ->
                    val section = builder.build()
                    if (sectionStack.isEmpty()) {
                        bodySections.add(section)
                    } else {
                        sectionStack.last().subsections.add(section)
                    }
                }
            }

            // Figures
            "fig" -> {
                currentFigure?.build()?.let { figures.add(it) }
                inFigure = false
                currentFigure = null
            }
            "label" -> {
                when {
                    inFigure -> currentFigure?.label = text
                    inTableWrap -> currentTable?.label = text
                    inRef -> currentReference?.label = text
                }
            }

            // Tables
            "thead" -> currentTable?.endHeader()
            "tbody" -> currentTable?.endBody()
            "tr" -> currentTable?.endRow()
            "th", "td" -> currentTable?.endCell()
            "list" -> currentTable?.endList()
            "list-item" -> currentTable?.endListItem()
            "table-wrap" -> {
                currentTable?.build()?.let { tables.add(it) }
                inTableWrap = false
                currentTable = null
            }

            // References
            "ref-list" -> inRefList = false
            "ref" -> {
                currentReference?.finishCurrentAuthor()
                currentReference?.build()?.let { references.add(it) }
                inRef = false
                inRefCitation = false
                inRefPersonGroup = false
                currentReference = null
            }
            "mixed-citation", "element-citation" -> {
                if (inRef) {
                    currentReference?.citation = normalizedText
                    inRefCitation = false
                }
            }
            "person-group" -> {
                if (inRefCitation) {
                    currentReference?.finishCurrentAuthor()
                    inRefPersonGroup = false
                }
            }
            "surname" -> {
                when {
                    inRefPersonGroup -> currentReference?.currentAuthorSurname = text
                    inContrib -> currentAuthor?.surname = text
                }
            }
            "given-names" -> {
                when {
                    inRefPersonGroup -> currentReference?.currentAuthorGivenNames = text
                    inContrib -> currentAuthor?.givenNames = text
                }
            }
            "name" -> {
                if (inRefPersonGroup) {
                    currentReference?.finishCurrentAuthor()
                }
            }
            "collab" -> {
                if (inRefCitation && text.isNotEmpty()) {
                    currentReference?.authors?.add(text)
                }
            }
            "article-title" -> {
                when {
                    inRefCitation -> currentReference?.articleTitle = normalizedText
                    inFront && inArticleMeta -> title = normalizedText
                }
            }
            "source" -> {
                if (inRefCitation) currentReference?.source = text
            }
            "year" -> {
                when {
                    inRefCitation -> currentReference?.year = text
                    inFront && inArticleMeta && year.isEmpty() -> year = text
                }
            }
            "volume" -> {
                when {
                    inRefCitation -> currentReference?.volume = text
                    inFront && inArticleMeta -> volume = text
                }
            }
            "issue" -> {
                when {
                    inRefCitation -> currentReference?.issue = text
                    inFront && inArticleMeta -> issue = text
                }
            }
            "fpage" -> {
                when {
                    inRefCitation -> currentReference?.firstPage = text
                    inFront && inArticleMeta && pages.isEmpty() -> pages = text
                }
            }
            "lpage" -> {
                when {
                    inRefCitation -> currentReference?.lastPage = text
                    inFront && inArticleMeta && pages.isNotEmpty() && text.isNotEmpty() -> {
                        pages += "-$text"
                    }
                }
            }
            "pub-id" -> {
                if (inRefCitation) {
                    when {
                        text.startsWith("10.") -> currentReference?.doi = text
                        text.all { it.isDigit() } && text.length >= MIN_PMID_LENGTH -> {
                            currentReference?.pmid = text
                        }
                    }
                }
            }

            // Cross-references
            "xref" -> {
                val refType = currentXrefType
                val rid = currentXrefRid
                if (refType != null && rid != null) {
                    when (refType) {
                        "fig", "figure" -> {
                            val linkText = text.ifEmpty { "Figure" }
                            appendText("[$linkText](#$rid)")
                        }
                        "table", "table-wrap" -> {
                            val linkText = text.ifEmpty { "Table" }
                            appendText("[$linkText](#$rid)")
                        }
                    }
                }
                currentXrefType = null
                currentXrefRid = null
            }
        }
    }

    // MARK: - Markdown Builder

    private fun buildMarkdown(): String {
        val lines = mutableListOf<String>()

        // Title
        if (title.isNotEmpty()) {
            lines.add("# $title")
            lines.add("")
        }

        // Authors
        if (authors.isNotEmpty()) {
            val authorString = formatAuthors()
            lines.add("**Authors:** $authorString")
            lines.add("")
        }

        // Journal info
        val journalInfo = formatJournalInfo()
        if (journalInfo.isNotEmpty()) {
            lines.add(journalInfo)
            lines.add("")
        }

        // Identifiers
        val identifiers = formatIdentifiers()
        if (identifiers.isNotEmpty()) {
            lines.add(identifiers)
            lines.add("")
        }

        // Abstract
        if (abstractSections.isNotEmpty()) {
            lines.add("## Abstract")
            lines.add("")
            for (section in abstractSections) {
                if (section.title.isNotEmpty()) {
                    lines.add("**${section.title}:** ${section.content}")
                } else {
                    lines.add(section.content)
                }
                lines.add("")
            }
        }

        // Body sections
        for (section in bodySections) {
            lines.addAll(formatBodySection(section, level = 2))
        }

        // Figures
        if (figures.isNotEmpty()) {
            lines.add("## Figures")
            lines.add("")
            for ((index, figure) in figures.withIndex()) {
                val figNum = figure.label.ifEmpty { "Figure ${index + 1}" }
                val anchorId = figure.id.ifEmpty { "fig${index + 1}" }
                lines.add("<!-- anchor:$anchorId -->")
                lines.add("")
                lines.add("### $figNum")
                lines.add("")
                if (figure.graphicUrl != null) {
                    val fullUrl = buildFigureUrl(figure.graphicUrl)
                    lines.add("![Figure]($fullUrl)")
                    lines.add("")
                }
                if (figure.caption.isNotEmpty()) {
                    lines.add(figure.caption)
                    lines.add("")
                }
            }
        }

        // Tables
        if (tables.isNotEmpty()) {
            lines.add("## Tables")
            lines.add("")
            for ((index, table) in tables.withIndex()) {
                val tableNum = table.label.ifEmpty { "Table ${index + 1}" }
                val anchorId = table.id.ifEmpty { "table${index + 1}" }
                lines.add("<!-- anchor:$anchorId -->")
                lines.add("")
                lines.add("### $tableNum")
                if (table.caption.isNotEmpty()) {
                    lines.add("")
                    lines.add(table.caption)
                }
                lines.add("")
                if (table.markdownContent.isNotEmpty()) {
                    lines.add(table.markdownContent)
                    lines.add("")
                }
            }
        }

        // References
        if (references.isNotEmpty()) {
            lines.add("## References")
            lines.add("")
            for ((index, ref) in references.withIndex()) {
                val refNum = ref.label.ifEmpty { (index + 1).toString() }
                lines.add("$refNum. ${ref.formattedCitation}")
            }
            lines.add("")
        }

        return lines.joinToString("\n")
    }

    private fun formatAuthors(): String {
        val authorNames = authors.map { author ->
            if (author.givenNames.isEmpty()) {
                author.surname
            } else {
                "${author.givenNames} ${author.surname}"
            }
        }

        return if (authorNames.size <= MAX_AUTHORS_BEFORE_ET_AL) {
            authorNames.joinToString(", ")
        } else {
            "${authorNames.take(MAX_AUTHORS_BEFORE_ET_AL).joinToString(", ")} et al."
        }
    }

    private fun formatJournalInfo(): String {
        val parts = mutableListOf<String>()

        if (journal.isNotEmpty()) {
            parts.add("*$journal*")
        }

        val volumeInfo = buildString {
            if (volume.isNotEmpty()) {
                append(volume)
            }
            if (issue.isNotEmpty()) {
                append("($issue)")
            }
            if (pages.isNotEmpty()) {
                append(": $pages")
            }
        }
        if (volumeInfo.isNotEmpty()) {
            parts.add(volumeInfo)
        }

        if (year.isNotEmpty()) {
            parts.add("($year)")
        }

        return parts.joinToString(" ")
    }

    private fun formatIdentifiers(): String {
        val ids = mutableListOf<String>()

        if (doi.isNotEmpty()) {
            ids.add("DOI: $doi")
        }
        if (pmcId.isNotEmpty()) {
            ids.add("PMC: $pmcId")
        }
        if (pmid.isNotEmpty()) {
            ids.add("PMID: $pmid")
        }

        return ids.joinToString(" | ")
    }

    private fun buildFigureUrl(path: String): String {
        // If already a full URL, return as-is
        if (path.startsWith("http://") || path.startsWith("https://")) {
            return path
        }

        // If path already has an image extension, keep it
        val hasExtension = FIGURE_EXTENSIONS.any { path.lowercase().endsWith(it) }

        // Europe PMC figure URL pattern
        if (pmcId.isNotEmpty()) {
            val normalizedPmcId = normalizePmcId(pmcId)
            val baseUrl = "$EUROPE_PMC_FIGURE_BASE_URL/$normalizedPmcId/bin/$path"
            return if (!hasExtension) "$baseUrl.jpg" else baseUrl
        }

        // Return path as-is if we can't build a full URL
        return path
    }

    private fun formatBodySection(section: JATSBodySection, level: Int): List<String> {
        val lines = mutableListOf<String>()
        val headingPrefix = "#".repeat(minOf(level, MAX_HEADING_LEVEL))

        if (section.title.isNotEmpty()) {
            lines.add("$headingPrefix ${section.title}")
            lines.add("")
        }

        for (paragraph in section.paragraphs) {
            if (paragraph.isNotEmpty()) {
                lines.add(paragraph)
                lines.add("")
            }
        }

        for (subsection in section.subsections) {
            lines.addAll(formatBodySection(subsection, level + 1))
        }

        return lines
    }

    // MARK: - HTML Builder

    private fun buildHTML(): String {
        val html = mutableListOf<String>()

        // Title
        if (title.isNotEmpty()) {
            html.add("<h1>${escapeHtml(title)}</h1>")
        }

        // Authors
        if (authors.isNotEmpty()) {
            val authorString = formatAuthors()
            html.add("<p class=\"authors\"><strong>Authors:</strong> ${escapeHtml(authorString)}</p>")
        }

        // Journal info
        val journalInfo = formatJournalInfoHtml()
        if (journalInfo.isNotEmpty()) {
            html.add("<p class=\"journal-info\">$journalInfo</p>")
        }

        // Identifiers
        val identifiers = formatIdentifiersHtml()
        if (identifiers.isNotEmpty()) {
            html.add("<p class=\"identifiers\">$identifiers</p>")
        }

        // Abstract
        if (abstractSections.isNotEmpty()) {
            html.add("<h2>Abstract</h2>")
            for (section in abstractSections) {
                if (section.title.isNotEmpty()) {
                    html.add("<p><strong>${escapeHtml(section.title)}:</strong> ${escapeHtml(section.content)}</p>")
                } else {
                    html.add("<p>${escapeHtml(section.content)}</p>")
                }
            }
        }

        // Body sections
        for (section in bodySections) {
            html.addAll(formatBodySectionHtml(section, level = 2))
        }

        // Figures
        if (figures.isNotEmpty()) {
            html.add("<h2>Figures</h2>")
            for ((index, figure) in figures.withIndex()) {
                val figNum = figure.label.ifEmpty { "Figure ${index + 1}" }
                val anchorId = figure.id.ifEmpty { "fig${index + 1}" }

                html.add("<figure id=\"${escapeHtml(anchorId)}\">")
                if (figure.graphicUrl != null) {
                    val fullUrl = buildFigureUrl(figure.graphicUrl)
                    html.add("  <img src=\"${escapeHtml(fullUrl)}\" alt=\"${escapeHtml(figNum)}\" loading=\"lazy\">")
                }
                html.add("  <figcaption>")
                html.add("    <strong>${escapeHtml(figNum)}</strong>")
                if (figure.caption.isNotEmpty()) {
                    html.add("    <p>${escapeHtml(figure.caption)}</p>")
                }
                html.add("  </figcaption>")
                html.add("</figure>")
            }
        }

        // Tables
        if (tables.isNotEmpty()) {
            html.add("<h2>Tables</h2>")
            for ((index, table) in tables.withIndex()) {
                val tableNum = table.label.ifEmpty { "Table ${index + 1}" }
                val anchorId = table.id.ifEmpty { "table${index + 1}" }

                html.add("<div class=\"table-container\" id=\"${escapeHtml(anchorId)}\">")
                html.add("  <h3>${escapeHtml(tableNum)}</h3>")
                if (table.caption.isNotEmpty()) {
                    html.add("  <p class=\"table-caption\">${escapeHtml(table.caption)}</p>")
                }
                html.add(buildHtmlTable(table))
                html.add("</div>")
            }
        }

        // References
        if (references.isNotEmpty()) {
            html.add("<h2>References</h2>")
            html.add("<ol class=\"references\">")
            for (ref in references) {
                html.add("  <li id=\"ref-${escapeHtml(ref.id)}\">${formatReferenceHtml(ref)}</li>")
            }
            html.add("</ol>")
        }

        return html.joinToString("\n")
    }

    private fun formatJournalInfoHtml(): String {
        val parts = mutableListOf<String>()

        if (journal.isNotEmpty()) {
            parts.add("<em>${escapeHtml(journal)}</em>")
        }

        val volumeInfo = buildString {
            if (volume.isNotEmpty()) {
                append(volume)
            }
            if (issue.isNotEmpty()) {
                append("($issue)")
            }
            if (pages.isNotEmpty()) {
                append(": $pages")
            }
        }
        if (volumeInfo.isNotEmpty()) {
            parts.add(escapeHtml(volumeInfo))
        }

        if (year.isNotEmpty()) {
            parts.add("(${escapeHtml(year)})")
        }

        return parts.joinToString(" ")
    }

    private fun formatIdentifiersHtml(): String {
        val ids = mutableListOf<String>()

        if (doi.isNotEmpty()) {
            ids.add("DOI: <a href=\"https://doi.org/${escapeHtml(doi)}\">${escapeHtml(doi)}</a>")
        }
        if (pmcId.isNotEmpty()) {
            val pmcNum = if (pmcId.startsWith("PMC")) pmcId.drop(3) else pmcId
            ids.add("PMC: <a href=\"https://europepmc.org/article/PMC/${escapeHtml(pmcNum)}\">${escapeHtml(pmcId)}</a>")
        }
        if (pmid.isNotEmpty()) {
            ids.add("PMID: <a href=\"https://pubmed.ncbi.nlm.nih.gov/${escapeHtml(pmid)}/\">${escapeHtml(pmid)}</a>")
        }

        return ids.joinToString(" | ")
    }

    private fun formatBodySectionHtml(section: JATSBodySection, level: Int): List<String> {
        val html = mutableListOf<String>()
        val headingLevel = minOf(level, MAX_HEADING_LEVEL)

        if (section.title.isNotEmpty()) {
            html.add("<h$headingLevel>${escapeHtml(section.title)}</h$headingLevel>")
        }

        for (paragraph in section.paragraphs) {
            if (paragraph.isNotEmpty()) {
                val htmlParagraph = convertInlineLinksToHtml(paragraph)
                html.add("<p>$htmlParagraph</p>")
            }
        }

        for (subsection in section.subsections) {
            html.addAll(formatBodySectionHtml(subsection, level + 1))
        }

        return html
    }

    private fun buildHtmlTable(table: JATSTableInfo): String {
        val tableRows = parseMarkdownTableRows(table.markdownContent)
        if (tableRows.isEmpty()) {
            return "  <p><em>Table content unavailable</em></p>"
        }

        val html = mutableListOf<String>()
        html.add("  <table>")

        val hasHeader = tableRows.size > 1
        if (hasHeader) {
            html.add("    <thead>")
            html.add("      <tr>")
            for (cell in tableRows[0]) {
                html.add("        <th>${escapeHtml(cell)}</th>")
            }
            html.add("      </tr>")
            html.add("    </thead>")
        }

        val bodyRows = if (hasHeader) tableRows.drop(1) else tableRows
        if (bodyRows.isNotEmpty()) {
            html.add("    <tbody>")
            for (row in bodyRows) {
                html.add("      <tr>")
                for (cell in row) {
                    html.add("        <td>${escapeHtml(cell)}</td>")
                }
                html.add("      </tr>")
            }
            html.add("    </tbody>")
        }

        html.add("  </table>")
        return html.joinToString("\n")
    }

    private fun parseMarkdownTableRows(markdown: String): List<List<String>> {
        val rows = mutableListOf<List<String>>()

        for (line in markdown.lines()) {
            val trimmed = line.trim()

            // Skip empty lines and separator lines
            if (trimmed.isEmpty()) continue
            if (trimmed.all { it == '|' || it == '-' || it == ':' || it == ' ' }) continue

            var content = trimmed
            if (content.startsWith("|")) content = content.drop(1)
            if (content.endsWith("|")) content = content.dropLast(1)

            val cells = content.split("|").map { part ->
                part.trim().replace("\\|", "|")
            }

            if (cells.isNotEmpty()) {
                rows.add(cells)
            }
        }

        return rows
    }

    private fun formatReferenceHtml(ref: JATSReferenceInfo): String {
        val parts = mutableListOf<String>()

        // Authors
        if (ref.authors.isNotEmpty()) {
            if (ref.authors.size <= MAX_AUTHORS_BEFORE_ET_AL) {
                parts.add(escapeHtml(ref.authors.joinToString(", ")))
            } else {
                val firstAuthors = ref.authors.take(MAX_AUTHORS_BEFORE_ET_AL - 1).joinToString(", ")
                parts.add(escapeHtml("$firstAuthors, et al."))
            }
        }

        // Article title
        if (ref.articleTitle.isNotEmpty()) {
            parts.add(escapeHtml(ref.articleTitle))
        }

        // Journal name (italicized)
        if (ref.source.isNotEmpty()) {
            parts.add("<em>${escapeHtml(ref.source)}</em>")
        }

        // Year
        if (ref.year.isNotEmpty()) {
            parts.add("(${escapeHtml(ref.year)})")
        }

        // Volume and pages
        var volumeInfo = ""
        if (ref.volume.isNotEmpty()) {
            volumeInfo = ref.volume
            if (ref.issue.isNotEmpty()) {
                volumeInfo += "(${ref.issue})"
            }
        }
        if (ref.firstPage.isNotEmpty()) {
            if (volumeInfo.isNotEmpty()) {
                volumeInfo += ":"
            }
            volumeInfo += ref.firstPage
            if (ref.lastPage.isNotEmpty()) {
                volumeInfo += "-${ref.lastPage}"
            }
        }
        if (volumeInfo.isNotEmpty()) {
            parts.add(escapeHtml(volumeInfo))
        }

        // DOI link
        if (ref.doi.isNotEmpty()) {
            parts.add("<a href=\"https://doi.org/${escapeHtml(ref.doi)}\">doi:${escapeHtml(ref.doi)}</a>")
        }

        return if (parts.isEmpty()) escapeHtml(ref.citation) else parts.joinToString(". ")
    }

    private fun convertInlineLinksToHtml(text: String): String {
        val result = StringBuilder()
        var remaining = text

        while (true) {
            val bracketStart = remaining.indexOf('[')
            if (bracketStart == -1) {
                result.append(escapeHtml(remaining))
                break
            }

            result.append(escapeHtml(remaining.substring(0, bracketStart)))

            // Find closing bracket
            var depth = 0
            var bracketEnd = -1
            for (i in bracketStart until remaining.length) {
                when (remaining[i]) {
                    '[' -> depth++
                    ']' -> {
                        depth--
                        if (depth == 0) {
                            bracketEnd = i
                            break
                        }
                    }
                }
            }

            if (bracketEnd == -1 || bracketEnd + 1 >= remaining.length || remaining[bracketEnd + 1] != '(') {
                result.append("[")
                remaining = remaining.substring(bracketStart + 1)
                continue
            }

            val linkText = remaining.substring(bracketStart + 1, bracketEnd)
            val parenEnd = remaining.indexOf(')', bracketEnd + 1)
            if (parenEnd == -1) {
                result.append("[${escapeHtml(linkText)}]")
                remaining = remaining.substring(bracketEnd + 1)
                continue
            }

            val href = remaining.substring(bracketEnd + 2, parenEnd)
            result.append("<a href=\"${escapeHtml(href)}\">${escapeHtml(linkText)}</a>")
            remaining = remaining.substring(parenEnd + 1)
        }

        return result.toString()
    }

    // MARK: - Helper Methods

    private fun normalizeWhitespace(text: String): String {
        return text.split(Regex("\\s+")).filter { it.isNotEmpty() }.joinToString(" ")
    }

    private fun normalizePmcId(id: String): String {
        return if (id.startsWith("PMC")) id else "PMC$id"
    }

    private fun classifyArticleIdByPattern(text: String) {
        when {
            text.startsWith("10.") -> doi = text
            text.startsWith("PMC") -> pmcId = text
            text.all { it.isDigit() } && text.length >= MIN_PMID_LENGTH -> {
                if (pmid.isEmpty()) pmid = text
            }
        }
    }

    private fun escapeHtml(text: String): String {
        return text
            .replace("&", "&amp;")
            .replace("<", "&lt;")
            .replace(">", "&gt;")
            .replace("\"", "&quot;")
            .replace("'", "&#39;")
    }
}

// MARK: - Internal Builder Types

/**
 * Builder for author information during parsing.
 */
private class AuthorBuilder {
    var surname = ""
    var givenNames = ""
    var affiliations = mutableListOf<String>()

    fun build(): JATSAuthorInfo? {
        if (surname.isEmpty()) return null
        return JATSAuthorInfo(
            surname = surname,
            givenNames = givenNames,
            affiliations = affiliations.toList()
        )
    }
}

/**
 * Builder for body sections during parsing.
 */
private class SectionBuilder {
    var title = ""
    val paragraphs = mutableListOf<String>()
    val subsections = mutableListOf<JATSBodySection>()

    fun build(): JATSBodySection {
        return JATSBodySection(
            title = title,
            paragraphs = paragraphs.toList(),
            subsections = subsections.toList()
        )
    }
}

/**
 * Builder for figure information during parsing.
 */
private class FigureBuilder {
    var id = ""
    var label = ""
    var caption = ""
    var graphicHref = ""

    fun build(): JATSFigureInfo {
        return JATSFigureInfo(
            id = id,
            label = label,
            caption = caption,
            graphicUrl = graphicHref.ifEmpty { null }
        )
    }
}

/**
 * Builder for table information during parsing.
 */
private class TableBuilder {
    var id = ""
    var label = ""
    var caption = ""
    val headerRows = mutableListOf<List<String>>()
    val bodyRows = mutableListOf<List<String>>()
    private var currentRow = mutableListOf<String>()
    private var currentCellText = ""
    private var inHeader = false
    private var inBody = false
    private var inRow = false
    private var inCell = false
    private var currentRowHasHeaderCells = false
    private var currentColspan = 1
    private var inList = false
    private var listIsOrdered = false
    private var listItemNumber = 0
    private var pendingListItem = false

    fun startHeader() {
        inHeader = true
        inBody = false
    }

    fun endHeader() {
        inHeader = false
    }

    fun startBody() {
        inBody = true
        inHeader = false
    }

    fun endBody() {
        inBody = false
    }

    fun startRow() {
        inRow = true
        currentRow = mutableListOf()
        currentRowHasHeaderCells = false
    }

    fun endRow() {
        if (inRow && currentRow.isNotEmpty()) {
            if (inHeader || (currentRowHasHeaderCells && !inBody && headerRows.isEmpty())) {
                headerRows.add(currentRow.toList())
            } else {
                bodyRows.add(currentRow.toList())
            }
        }
        inRow = false
        currentRow = mutableListOf()
        currentRowHasHeaderCells = false
    }

    fun startCell(isHeader: Boolean = false, colspan: Int = 1) {
        inCell = true
        currentCellText = ""
        currentColspan = maxOf(1, colspan)
        inList = false
        listItemNumber = 0
        pendingListItem = false
        if (isHeader || inHeader) {
            currentRowHasHeaderCells = true
        }
    }

    fun endCell() {
        if (inCell) {
            val normalized = currentCellText
                .split(Regex("\\s+"))
                .filter { it.isNotEmpty() }
                .joinToString(" ")
                .replace("|", "\\|")
            currentRow.add(normalized)

            // Add empty cells for colspan > 1
            repeat(currentColspan - 1) {
                currentRow.add("")
            }
        }
        inCell = false
        currentCellText = ""
        currentColspan = 1
        inList = false
        listItemNumber = 0
        pendingListItem = false
    }

    fun startList(ordered: Boolean) {
        if (inCell) {
            inList = true
            listIsOrdered = ordered
            listItemNumber = 0
        }
    }

    fun endList() {
        if (inCell) {
            inList = false
        }
    }

    fun startListItem() {
        if (inCell && inList) {
            listItemNumber++
            pendingListItem = true
        }
    }

    fun endListItem() {
        if (inCell) {
            pendingListItem = false
        }
    }

    fun appendCellText(text: String) {
        if (!inCell) return

        val normalized = text.replace("\n", " ").replace("\r", " ")

        // Add list marker when hitting content after list-item start
        if (pendingListItem && normalized.trim().isNotEmpty()) {
            if (currentCellText.trim().isNotEmpty()) {
                currentCellText += "; "
            }
            currentCellText += if (listIsOrdered) "$listItemNumber. " else "• "
            pendingListItem = false
        }

        currentCellText += normalized
    }

    fun build(): JATSTableInfo {
        return JATSTableInfo(
            id = id,
            label = label,
            caption = caption,
            markdownContent = buildMarkdownTable()
        )
    }

    private fun buildMarkdownTable(): String {
        if (headerRows.isEmpty() && bodyRows.isEmpty()) {
            return ""
        }

        val lines = mutableListOf<String>()
        val columnCount = maxOf(
            headerRows.firstOrNull()?.size ?: 0,
            bodyRows.firstOrNull()?.size ?: 0
        )
        if (columnCount == 0) return ""

        // Add header rows
        if (headerRows.isNotEmpty()) {
            for (row in headerRows) {
                val paddedRow = padRow(row, columnCount)
                lines.add("| ${paddedRow.joinToString(" | ")} |")
            }
            val separator = List(columnCount) { "---" }
            lines.add("| ${separator.joinToString(" | ")} |")
        } else {
            val emptyHeader = List(columnCount) { "" }
            lines.add("| ${emptyHeader.joinToString(" | ")} |")
            val separator = List(columnCount) { "---" }
            lines.add("| ${separator.joinToString(" | ")} |")
        }

        // Add body rows
        for (row in bodyRows) {
            val paddedRow = padRow(row, columnCount)
            lines.add("| ${paddedRow.joinToString(" | ")} |")
        }

        return lines.joinToString("\n")
    }

    private fun padRow(row: List<String>, targetCount: Int): List<String> {
        return if (row.size >= targetCount) {
            row.take(targetCount)
        } else {
            row + List(targetCount - row.size) { "" }
        }
    }
}

/**
 * Builder for reference information during parsing.
 */
private class ReferenceBuilder {
    var id = ""
    var label = ""
    var citation = ""
    val authors = mutableListOf<String>()
    var currentAuthorSurname = ""
    var currentAuthorGivenNames = ""
    var articleTitle = ""
    var source = ""
    var year = ""
    var volume = ""
    var issue = ""
    var firstPage = ""
    var lastPage = ""
    var doi = ""
    var pmid = ""

    fun finishCurrentAuthor() {
        if (currentAuthorSurname.isNotEmpty()) {
            val name = if (currentAuthorGivenNames.isNotEmpty()) {
                "$currentAuthorGivenNames $currentAuthorSurname"
            } else {
                currentAuthorSurname
            }
            authors.add(name)
            currentAuthorSurname = ""
            currentAuthorGivenNames = ""
        }
    }

    fun build(): JATSReferenceInfo {
        return JATSReferenceInfo(
            id = id,
            label = label,
            citation = citation,
            authors = authors.toList(),
            articleTitle = articleTitle,
            source = source,
            year = year,
            volume = volume,
            issue = issue,
            firstPage = firstPage,
            lastPage = lastPage,
            doi = doi,
            pmid = pmid
        )
    }
}
