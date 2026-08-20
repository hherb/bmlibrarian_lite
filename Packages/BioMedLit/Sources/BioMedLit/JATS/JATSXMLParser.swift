// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2025 Dr Horst Herb
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

import Foundation

/// Parser for converting JATS (Journal Article Tag Suite) XML to markdown and HTML.
///
/// JATS is the standard XML format used by Europe PMC and many other
/// biomedical literature databases. This parser handles:
/// - Article metadata (title, authors, journal, dates)
/// - Abstract with labeled sections
/// - Full article body with nested sections
/// - Figures and tables (with captions)
/// - References and citations
/// - Inline formatting (bold, italic, subscript, superscript)
/// - Lists (ordered and unordered)
///
/// Usage:
/// ```swift
/// let parser = JATSXMLParser(data: xmlData)
/// let markdown = try parser.parseToMarkdown()
/// // or
/// let html = try parser.parseToHTML()
/// ```
public final class JATSXMLParser: NSObject {
    // MARK: - Properties

    private let parser: XMLParser
    private var parseError: Error?

    // MARK: - Parsed Content

    private var title = ""
    private var authors: [JATSAuthorInfo] = []
    private var journal = ""
    private var volume = ""
    private var issue = ""
    private var pages = ""
    private var year = ""
    private var doi = ""
    private var pmcId = ""
    private var pmid = ""

    /// Whether ``doi`` came from an explicit `pub-id-type="doi"`.
    ///
    /// A `<front>` carries several ids, and the ones with no recognised type
    /// fall through to pattern matching. Without this, SAGE's `publisher-id` —
    /// the DOI with its slash replaced by an underscore — overwrote the real one
    /// simply by appearing later in the document.
    private var doiIsAuthoritative = false

    /// Whether ``pmcId`` came from a caller-supplied id or `pub-id-type="pmc"`/`"pmcid"`.
    ///
    /// PMC emits `pmcid-ver` (the canonical id plus a version suffix) right after
    /// `pmcid`; only the first is the id anything else can be looked up by.
    private var pmcIdIsAuthoritative = false
    private var abstractSections: [JATSAbstractSection] = []
    private var bodySections: [JATSBodySection] = []
    private var figures: [JATSFigureInfo] = []
    private var tables: [JATSTableInfo] = []
    private var references: [JATSReferenceInfo] = []

    // MARK: - Parsing State

    private var elementStack: [String] = []

    /// Stack of text buffers for nested elements.
    /// Each text-accumulating element pushes its own buffer.
    private var textStack: [String] = [""]

    /// Elements that accumulate their own text content.
    private let textAccumulatingElements: Set<String> = [
        "p", "title", "article-title", "abstract", "sec",
        "surname", "given-names", "journal-title", "volume", "issue",
        "fpage", "lpage", "year", "article-id", "label",
        "mixed-citation", "element-citation", "caption",
        "bold", "b", "italic", "i", "sub", "sup", "monospace", "code",
        "xref", "ext-link", "uri", "email", "named-content",
        "list-item", "def", "term", "kwd", "alt-title",
        "inline-formula", "disp-formula", "tex-math",
        // Reference elements
        "source", "article-title", "person-group", "pub-id", "collab"
    ]

    // Article metadata state
    private var inFront = false
    private var inArticleMeta = false
    private var inContribGroup = false

    /// `content-type` of the enclosing `<contrib-group>`, lowercased.
    ///
    /// JATS allows the contributor role to be declared once on the group instead
    /// of on every `<contrib>`. PLOS uses that form — `<contrib-group
    /// content-type="author">` with bare `<contrib>` children — so requiring
    /// `contrib-type="author"` on the child dropped every author it publishes.
    private var currentContribGroupType: String?
    private var inContrib = false
    private var inAff = false

    // Abstract state
    private var inAbstract = false
    private var currentAbstractLabel = ""
    private var currentAbstractTitle = ""
    private var currentAbstractText: [String] = []

    // Body and back matter state
    private var inBody = false
    private var inBack = false
    private var sectionStack: [SectionBuilder] = []

    /// Pending prose from an unsectioned `<body>`.
    ///
    /// `<sec>` is optional in JATS: a `<body>` may hold `<p>` directly. Without
    /// this, `case "p"` required a non-empty `sectionStack` and every word of
    /// such an article was silently dropped (bmlib issue #30).
    private var implicitBodySection: SectionBuilder?

    // Figure/Table state
    private var inFigure = false
    private var inTableWrap = false

    /// How deep the parser is inside `<sub-article>` / `<response>` elements.
    ///
    /// JATS lets either carry a complete `<front>`/`<article-meta>` and `<body>`
    /// of its own. PLOS deposits its whole peer-review history that way — one
    /// sub-article per round, each with its own DOI, title, authors and prose —
    /// so without this the last of each silently replaced the real article's, and
    /// hundreds of paragraphs of reviewer correspondence landed in `bodySections`
    /// where scoring, citation extraction and the transparency regexes then read
    /// them as article text.
    ///
    /// A depth rather than a flag: JATS permits a sub-article inside a
    /// sub-article, and a flag cleared by the inner `</sub-article>` would let the
    /// remainder of the outer one back in.
    private var subArticleDepth = 0

    /// Whether the parser is currently inside a sub-article or response.
    private var inSubArticle: Bool { subArticleDepth > 0 }

    /// Whether the parser is inside a `<caption>`.
    ///
    /// `<caption>` carries `<title>` and `<p>` — the same element names a
    /// section uses. Routing them on `inFigure`/`sectionStack` alone renamed the
    /// enclosing `<sec>` after the figure and spilled caption prose into the
    /// article text, so the enclosing `<caption>` decides instead.
    private var inCaption = false
    private var currentFigure: FigureBuilder?
    private var currentTable: TableBuilder?

    // Reference state
    private var inRefList = false
    private var inRef = false
    private var inRefCitation = false
    private var inRefPersonGroup = false
    private var currentReference: ReferenceBuilder?

    // Article ID tracking
    private var currentArticleIdType: String?

    // Author state
    private var currentAuthor: AuthorBuilder?
    private var currentAffiliations: [String: String] = [:]  // id -> text

    // Inline formatting state
    private var inlineFormattingStack: [InlineFormat] = []

    // Cross-reference state (for figure/table links)
    private var currentXrefType: String?
    private var currentXrefRid: String?

    // MARK: - Initialization

    /// Initialize the parser with XML data.
    ///
    /// - Parameters:
    ///   - data: Raw JATS XML data.
    ///   - knownPMCId: Optional PMC ID if known from external source (e.g., search results).
    ///                 Used for building figure URLs when the XML doesn't contain the PMC ID.
    public init(data: Data, knownPMCId: String? = nil) {
        self.parser = XMLParser(data: data)
        // Pre-populate PMC ID if provided
        if let knownId = knownPMCId, !knownId.isEmpty {
            self.pmcId = knownId.hasPrefix("PMC") ? knownId : "PMC\(knownId)"
            self.pmcIdIsAuthoritative = true
        }
        super.init()
        parser.delegate = self
    }

    // MARK: - Text Stack Helpers

    /// Get the current accumulated text.
    private var currentText: String {
        textStack.last ?? ""
    }

    /// Append text to the current buffer.
    private func appendText(_ text: String) {
        guard !textStack.isEmpty else { return }
        textStack[textStack.count - 1] += text
    }

    /// Push a new text buffer for a nested element.
    private func pushTextBuffer() {
        textStack.append("")
    }

    /// Pop and return the text buffer, merging it with parent if needed.
    private func popTextBuffer(mergeWithParent: Bool = false) -> String {
        guard textStack.count > 1 else {
            let text = textStack.first ?? ""
            if !textStack.isEmpty {
                textStack[0] = ""
            }
            return text
        }

        let text = textStack.removeLast()

        if mergeWithParent && !text.isEmpty && !textStack.isEmpty {
            textStack[textStack.count - 1] += text
        }

        return text
    }

    // MARK: - Public API

    /// Parse the XML and return markdown-formatted content.
    ///
    /// - Returns: Markdown string representation of the article.
    /// - Throws: `JATSParseError` if parsing fails.
    public func parseToMarkdown() throws -> String {
        guard parser.parse() else {
            let errorMessage = parseError?.localizedDescription
                ?? parser.parserError?.localizedDescription
                ?? "Unknown parsing error"
            throw JATSParseError.parsingFailed(errorMessage)
        }

        let markdown = buildMarkdown()
        if markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw JATSParseError.noContent
        }

        return markdown
    }

    /// Parse the XML and return HTML-formatted content.
    ///
    /// HTML output provides better table rendering and semantic structure
    /// compared to markdown.
    ///
    /// - Returns: HTML string representation of the article (body content only, no wrapper).
    /// - Throws: `JATSParseError` if parsing fails.
    public func parseToHTML() throws -> String {
        guard parser.parse() else {
            let errorMessage = parseError?.localizedDescription
                ?? parser.parserError?.localizedDescription
                ?? "Unknown parsing error"
            throw JATSParseError.parsingFailed(errorMessage)
        }

        let html = buildHTML()
        if html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw JATSParseError.noContent
        }

        return html
    }

    /// Parse the XML and return the structured article data.
    ///
    /// - Returns: `JATSArticle` containing all parsed data.
    /// - Throws: `JATSParseError` if parsing fails.
    public func parseToArticle() throws -> JATSArticle {
        guard parser.parse() else {
            let errorMessage = parseError?.localizedDescription
                ?? parser.parserError?.localizedDescription
                ?? "Unknown parsing error"
            throw JATSParseError.parsingFailed(errorMessage)
        }

        return JATSArticle(
            title: title,
            authors: authors,
            journal: journal,
            volume: volume,
            issue: issue,
            pages: pages,
            year: year,
            doi: doi,
            pmcId: pmcId,
            pmid: pmid,
            abstractSections: abstractSections,
            bodySections: bodySections,
            figures: figures,
            tables: tables,
            references: references
        )
    }

    // MARK: - Markdown Builder

    /// Build the final markdown string from parsed content.
    private func buildMarkdown() -> String {
        var lines: [String] = []

        // Title
        if !title.isEmpty {
            lines.append("# \(title)")
            lines.append("")
        }

        // Authors
        if !authors.isEmpty {
            let authorString = formatAuthors()
            lines.append("**Authors:** \(authorString)")
            lines.append("")
        }

        // Journal info
        let journalInfo = formatJournalInfo()
        if !journalInfo.isEmpty {
            lines.append(journalInfo)
            lines.append("")
        }

        // Identifiers
        let identifiers = formatIdentifiers()
        if !identifiers.isEmpty {
            lines.append(identifiers)
            lines.append("")
        }

        // Abstract
        if !abstractSections.isEmpty {
            lines.append("## Abstract")
            lines.append("")
            for section in abstractSections {
                if !section.title.isEmpty {
                    lines.append("**\(section.title):** \(section.content)")
                } else {
                    lines.append(section.content)
                }
                lines.append("")
            }
        }

        // Body sections
        for section in bodySections {
            lines.append(contentsOf: formatBodySection(section, level: 2))
        }

        // Figures
        if !figures.isEmpty {
            lines.append("## Figures")
            lines.append("")
            for (index, figure) in figures.enumerated() {
                let figNum = figure.label.isEmpty ? "Figure \(index + 1)" : figure.label
                // Add anchor for linking from xrefs - blank line needed for parser to detect
                let anchorId = figure.id.isEmpty ? "fig\(index + 1)" : figure.id
                lines.append("<!-- anchor:\(anchorId) -->")
                lines.append("")
                lines.append("### \(figNum)")
                lines.append("")
                // Include figure image if URL is available
                if let graphicURL = figure.graphicURL {
                    // Build full URL for Europe PMC graphics
                    let fullURL = buildFigureURL(graphicURL)
                    lines.append("![Figure](\(fullURL))")
                    lines.append("")
                }
                if !figure.caption.isEmpty {
                    lines.append(figure.caption)
                    lines.append("")
                }
            }
        }

        // Tables
        if !tables.isEmpty {
            lines.append("## Tables")
            lines.append("")
            for (index, table) in tables.enumerated() {
                let tableNum = table.label.isEmpty ? "Table \(index + 1)" : table.label
                // Add anchor for linking from xrefs - blank line needed for parser to detect
                let anchorId = table.id.isEmpty ? "table\(index + 1)" : table.id
                lines.append("<!-- anchor:\(anchorId) -->")
                lines.append("")
                lines.append("### \(tableNum)")
                if !table.caption.isEmpty {
                    lines.append("")
                    lines.append(table.caption)
                }
                lines.append("")
                // Include markdown table content if available
                if !table.markdownContent.isEmpty {
                    lines.append(table.markdownContent)
                    lines.append("")
                }
            }
        }

        // References
        if !references.isEmpty {
            lines.append("## References")
            lines.append("")
            for (index, ref) in references.enumerated() {
                let refNum = ref.label.isEmpty ? String(index + 1) : ref.label
                // Use formatted citation with full structured data
                lines.append("\(refNum). \(ref.formattedCitation)")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    /// Format authors for display.
    private func formatAuthors() -> String {
        let authorNames = authors.map { author -> String in
            var name = author.surname
            if !author.givenNames.isEmpty {
                name = "\(author.givenNames) \(name)"
            }
            return name
        }

        let maxAuthors = BioMedLitConstants.maxAuthorsBeforeEtAl
        if authorNames.count <= maxAuthors {
            return authorNames.joined(separator: ", ")
        } else {
            let firstAuthors = authorNames.prefix(maxAuthors).joined(separator: ", ")
            return "\(firstAuthors) et al."
        }
    }

    /// Format journal information.
    private func formatJournalInfo() -> String {
        var parts: [String] = []

        if !journal.isEmpty {
            parts.append("*\(journal)*")
        }

        var volumeInfo: [String] = []
        if !volume.isEmpty {
            volumeInfo.append(volume)
        }
        if !issue.isEmpty {
            volumeInfo.append("(\(issue))")
        }
        if !pages.isEmpty {
            volumeInfo.append(": \(pages)")
        }
        if !volumeInfo.isEmpty {
            parts.append(volumeInfo.joined())
        }

        if !year.isEmpty {
            parts.append("(\(year))")
        }

        return parts.joined(separator: " ")
    }

    /// Format document identifiers.
    private func formatIdentifiers() -> String {
        var ids: [String] = []

        if !doi.isEmpty {
            ids.append("DOI: \(doi)")
        }
        if !pmcId.isEmpty {
            ids.append("PMC: \(pmcId)")
        }
        if !pmid.isEmpty {
            ids.append("PMID: \(pmid)")
        }

        return ids.joined(separator: " | ")
    }

    /// Build a complete URL for a figure graphic.
    ///
    /// Europe PMC graphics use relative paths like "13023_2014_170_Fig1_HTML"
    /// which need to be prefixed with the base URL. The XML often doesn't include
    /// the file extension, so we build a URL pattern that the viewer can try
    /// with different extensions (.gif, .jpg).
    ///
    /// - Parameter path: The graphic path or href from the XML.
    /// - Returns: Complete URL string for the figure (without extension if unknown).
    private func buildFigureURL(_ path: String) -> String {
        // If already a full URL, return as-is
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            return path
        }

        // If path already has an image extension, keep it
        let hasExtension = [".gif", ".jpg", ".jpeg", ".png", ".svg"]
            .contains { path.lowercased().hasSuffix($0) }

        // Europe PMC figure URL pattern
        // Use europepmc.org which properly serves images (NCBI returns 403)
        // Pattern: https://europepmc.org/articles/PMC{id}/bin/{filename}
        if !pmcId.isEmpty {
            let normalizedPMCId = pmcId.hasPrefix("PMC") ? pmcId : "PMC\(pmcId)"
            let baseURL = "https://europepmc.org/articles/\(normalizedPMCId)/bin/\(path)"

            // If no extension, add .jpg as default (most common)
            // AsyncFigureView will try other extensions if this fails
            if !hasExtension {
                return baseURL + ".jpg"
            }
            return baseURL
        }

        // Return path as-is if we can't build a full URL
        return path
    }

    /// Format a body section recursively.
    private func formatBodySection(_ section: JATSBodySection, level: Int) -> [String] {
        var lines: [String] = []
        let headingPrefix = String(repeating: "#", count: min(level, BioMedLitConstants.maxHeadingLevel))

        if !section.title.isEmpty {
            lines.append("\(headingPrefix) \(section.title)")
            lines.append("")
        }

        for paragraph in section.paragraphs {
            if !paragraph.isEmpty {
                lines.append(paragraph)
                lines.append("")
            }
        }

        for subsection in section.subsections {
            lines.append(contentsOf: formatBodySection(subsection, level: level + 1))
        }

        return lines
    }

    // MARK: - HTML Builder

    /// Build the final HTML string from parsed content.
    ///
    /// Generates semantic HTML with proper table structure, figure elements,
    /// and anchor IDs for navigation.
    private func buildHTML() -> String {
        var html: [String] = []

        // Title
        if !title.isEmpty {
            html.append("<h1>\(escapeHTML(title))</h1>")
        }

        // Authors
        if !authors.isEmpty {
            let authorString = formatAuthors()
            html.append("<p class=\"authors\"><strong>Authors:</strong> \(escapeHTML(authorString))</p>")
        }

        // Journal info
        let journalInfo = formatJournalInfoHTML()
        if !journalInfo.isEmpty {
            html.append("<p class=\"journal-info\">\(journalInfo)</p>")
        }

        // Identifiers
        let identifiers = formatIdentifiersHTML()
        if !identifiers.isEmpty {
            html.append("<p class=\"identifiers\">\(identifiers)</p>")
        }

        // Abstract
        if !abstractSections.isEmpty {
            html.append("<h2>Abstract</h2>")
            for section in abstractSections {
                if !section.title.isEmpty {
                    html.append("<p><strong>\(escapeHTML(section.title)):</strong> \(escapeHTML(section.content))</p>")
                } else {
                    html.append("<p>\(escapeHTML(section.content))</p>")
                }
            }
        }

        // Body sections
        for section in bodySections {
            html.append(contentsOf: formatBodySectionHTML(section, level: 2))
        }

        // Figures
        if !figures.isEmpty {
            html.append("<h2>Figures</h2>")
            for (index, figure) in figures.enumerated() {
                let figNum = figure.label.isEmpty ? "Figure \(index + 1)" : figure.label
                let anchorId = figure.id.isEmpty ? "fig\(index + 1)" : figure.id

                html.append("<figure id=\"\(escapeHTML(anchorId))\">")
                if let graphicURL = figure.graphicURL {
                    let fullURL = buildFigureURL(graphicURL)
                    // Use onerror to try alternative extensions
                    html.append("  <img src=\"\(escapeHTML(fullURL))\" alt=\"\(escapeHTML(figNum))\" " +
                        "onerror=\"this.onerror=null; tryAlternativeExtensions(this);\" loading=\"lazy\">")
                }
                html.append("  <figcaption>")
                html.append("    <strong>\(escapeHTML(figNum))</strong>")
                if !figure.caption.isEmpty {
                    html.append("    <p>\(escapeHTML(figure.caption))</p>")
                }
                html.append("  </figcaption>")
                html.append("</figure>")
            }
        }

        // Tables
        if !tables.isEmpty {
            html.append("<h2>Tables</h2>")
            for (index, table) in tables.enumerated() {
                let tableNum = table.label.isEmpty ? "Table \(index + 1)" : table.label
                let anchorId = table.id.isEmpty ? "table\(index + 1)" : table.id

                html.append("<div class=\"table-container\" id=\"\(escapeHTML(anchorId))\">")
                html.append("  <h3>\(escapeHTML(tableNum))</h3>")
                if !table.caption.isEmpty {
                    html.append("  <p class=\"table-caption\">\(escapeHTML(table.caption))</p>")
                }
                // Build HTML table from rows
                html.append(buildHTMLTable(table))
                html.append("</div>")
            }
        }

        // References
        if !references.isEmpty {
            html.append("<h2>References</h2>")
            html.append("<ol class=\"references\">")
            for ref in references {
                html.append("  <li id=\"ref-\(escapeHTML(ref.id))\">\(formatReferenceHTML(ref))</li>")
            }
            html.append("</ol>")
        }

        return html.joined(separator: "\n")
    }

    /// Format journal information as HTML.
    private func formatJournalInfoHTML() -> String {
        var parts: [String] = []

        if !journal.isEmpty {
            parts.append("<em>\(escapeHTML(journal))</em>")
        }

        var volumeInfo: [String] = []
        if !volume.isEmpty {
            volumeInfo.append(volume)
        }
        if !issue.isEmpty {
            volumeInfo.append("(\(issue))")
        }
        if !pages.isEmpty {
            volumeInfo.append(": \(pages)")
        }
        if !volumeInfo.isEmpty {
            parts.append(escapeHTML(volumeInfo.joined()))
        }

        if !year.isEmpty {
            parts.append("(\(escapeHTML(year)))")
        }

        return parts.joined(separator: " ")
    }

    /// Format document identifiers as HTML.
    private func formatIdentifiersHTML() -> String {
        var ids: [String] = []

        if !doi.isEmpty {
            ids.append("DOI: <a href=\"https://doi.org/\(escapeHTML(doi))\">\(escapeHTML(doi))</a>")
        }
        if !pmcId.isEmpty {
            let pmcNum = pmcId.hasPrefix("PMC") ? String(pmcId.dropFirst(3)) : pmcId
            ids.append("PMC: <a href=\"https://europepmc.org/article/PMC/\(escapeHTML(pmcNum))\">\(escapeHTML(pmcId))</a>")
        }
        if !pmid.isEmpty {
            ids.append("PMID: <a href=\"https://pubmed.ncbi.nlm.nih.gov/\(escapeHTML(pmid))/\">\(escapeHTML(pmid))</a>")
        }

        return ids.joined(separator: " | ")
    }

    /// Format a body section recursively as HTML.
    private func formatBodySectionHTML(_ section: JATSBodySection, level: Int) -> [String] {
        var html: [String] = []
        let headingLevel = min(level, BioMedLitConstants.maxHeadingLevel)

        if !section.title.isEmpty {
            html.append("<h\(headingLevel)>\(escapeHTML(section.title))</h\(headingLevel)>")
        }

        for paragraph in section.paragraphs {
            if !paragraph.isEmpty {
                // Convert markdown-style links to HTML links
                let htmlParagraph = convertInlineLinksToHTML(paragraph)
                html.append("<p>\(htmlParagraph)</p>")
            }
        }

        for subsection in section.subsections {
            html.append(contentsOf: formatBodySectionHTML(subsection, level: level + 1))
        }

        return html
    }

    /// Build an HTML table from TableInfo.
    private func buildHTMLTable(_ table: JATSTableInfo) -> String {
        var html: [String] = []

        // Parse the markdown table back into rows for HTML generation
        // This is a workaround since we currently store markdown format
        let tableRows = parseMarkdownTableRows(table.markdownContent)

        guard !tableRows.isEmpty else {
            return "<p><em>Table content unavailable</em></p>"
        }

        html.append("  <table>")

        // First row is header if we have more than one row
        let hasHeader = tableRows.count > 1
        if hasHeader {
            html.append("    <thead>")
            html.append("      <tr>")
            for cell in tableRows[0] {
                html.append("        <th>\(escapeHTML(cell))</th>")
            }
            html.append("      </tr>")
            html.append("    </thead>")
        }

        // Body rows
        let bodyRows = hasHeader ? Array(tableRows.dropFirst()) : tableRows
        if !bodyRows.isEmpty {
            html.append("    <tbody>")
            for row in bodyRows {
                html.append("      <tr>")
                for cell in row {
                    html.append("        <td>\(escapeHTML(cell))</td>")
                }
                html.append("      </tr>")
            }
            html.append("    </tbody>")
        }

        html.append("  </table>")
        return html.joined(separator: "\n")
    }

    /// Parse markdown table content back into rows.
    private func parseMarkdownTableRows(_ markdown: String) -> [[String]] {
        var rows: [[String]] = []

        let lines = markdown.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip empty lines and separator lines (| --- | --- |)
            if trimmed.isEmpty { continue }
            if trimmed.allSatisfy({ $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }) { continue }

            // Parse cells from pipe-separated line
            var cells: [String] = []
            var content = trimmed

            // Remove leading/trailing pipes
            if content.hasPrefix("|") { content = String(content.dropFirst()) }
            if content.hasSuffix("|") { content = String(content.dropLast()) }

            // Split by pipe and trim
            let parts = content.components(separatedBy: "|")
            for part in parts {
                // Unescape any escaped pipes
                let cell = part.trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "\\|", with: "|")
                cells.append(cell)
            }

            if !cells.isEmpty {
                rows.append(cells)
            }
        }

        return rows
    }

    /// Format a reference as HTML.
    private func formatReferenceHTML(_ ref: JATSReferenceInfo) -> String {
        var parts: [String] = []

        // Authors
        let maxAuthors = BioMedLitConstants.maxAuthorsBeforeEtAl
        if !ref.authors.isEmpty {
            if ref.authors.count <= maxAuthors {
                parts.append(escapeHTML(ref.authors.joined(separator: ", ")))
            } else {
                let firstAuthors = ref.authors.prefix(maxAuthors - 1).joined(separator: ", ")
                parts.append(escapeHTML("\(firstAuthors), et al."))
            }
        }

        // Article title
        if !ref.articleTitle.isEmpty {
            parts.append(escapeHTML(ref.articleTitle))
        }

        // Journal name (italicized)
        if !ref.source.isEmpty {
            parts.append("<em>\(escapeHTML(ref.source))</em>")
        }

        // Year
        if !ref.year.isEmpty {
            parts.append("(\(escapeHTML(ref.year)))")
        }

        // Volume and pages
        var volumeInfo = ""
        if !ref.volume.isEmpty {
            volumeInfo = ref.volume
            if !ref.issue.isEmpty {
                volumeInfo += "(\(ref.issue))"
            }
        }
        if !ref.firstPage.isEmpty {
            if !volumeInfo.isEmpty {
                volumeInfo += ":"
            }
            volumeInfo += ref.firstPage
            if !ref.lastPage.isEmpty {
                volumeInfo += "-\(ref.lastPage)"
            }
        }
        if !volumeInfo.isEmpty {
            parts.append(escapeHTML(volumeInfo))
        }

        // DOI link
        if !ref.doi.isEmpty {
            parts.append("<a href=\"https://doi.org/\(escapeHTML(ref.doi))\">doi:\(escapeHTML(ref.doi))</a>")
        }

        if parts.isEmpty {
            return escapeHTML(ref.citation)
        }

        return parts.joined(separator: ". ")
    }

    /// Convert markdown-style anchor links to HTML links.
    ///
    /// Converts `[text](#anchor)` to `<a href="#anchor">text</a>`.
    private func convertInlineLinksToHTML(_ text: String) -> String {
        var result = ""
        var remaining = text

        // Pattern: [link text](#anchor-id)
        while let bracketStart = remaining.firstIndex(of: "[") {
            // Add text before the bracket
            result += escapeHTML(String(remaining[..<bracketStart]))

            // Find closing bracket
            var depth = 0
            var bracketEnd: String.Index?
            var index = bracketStart

            while index < remaining.endIndex {
                if remaining[index] == "[" {
                    depth += 1
                } else if remaining[index] == "]" {
                    depth -= 1
                    if depth == 0 {
                        bracketEnd = index
                        break
                    }
                }
                index = remaining.index(after: index)
            }

            guard let bracketEnd = bracketEnd,
                  remaining.index(after: bracketEnd) < remaining.endIndex,
                  remaining[remaining.index(after: bracketEnd)] == "(" else {
                // Not a valid link, add the bracket and continue
                result += "["
                remaining = String(remaining[remaining.index(after: bracketStart)...])
                continue
            }

            let linkText = String(remaining[remaining.index(after: bracketStart)..<bracketEnd])

            // Find the href
            let parenStart = remaining.index(after: bracketEnd)
            guard let parenEnd = remaining[parenStart...].firstIndex(of: ")") else {
                result += "[\(escapeHTML(linkText))]"
                remaining = String(remaining[remaining.index(after: bracketEnd)...])
                continue
            }

            let href = String(remaining[remaining.index(after: parenStart)..<parenEnd])
            result += "<a href=\"\(escapeHTML(href))\">\(escapeHTML(linkText))</a>"
            remaining = String(remaining[remaining.index(after: parenEnd)...])
        }

        // Add any remaining text
        result += escapeHTML(remaining)

        return result
    }

    /// Escape HTML special characters.
    private func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

// MARK: - XMLParserDelegate

extension JATSXMLParser: XMLParserDelegate {
    // MARK: - Contributor Helpers

    /// Whether a `<contrib>` is an author.
    ///
    /// An explicit `contrib-type` decides on its own — that is the contributor's
    /// own claim, and it must be able to say "editor" inside a group of authors.
    /// A `<contrib>` carrying none inherits the group: an author group, or a
    /// `<contrib-group>` with no `content-type` at all, which JATS treats as
    /// authors by convention.
    ///
    /// - Parameter attributes: Attributes of the `<contrib>` element.
    /// - Returns: True if this contributor should be collected as an author.
    private func isAuthorContrib(_ attributes: [String: String]) -> Bool {
        if let type = attributes["contrib-type"]?.lowercased() {
            return type == "author"
        }
        guard let groupType = currentContribGroupType else { return true }
        return groupType == "author" || groupType == "authors"
    }

    // MARK: - Section and Caption Helpers

    /// Append caption prose to whichever of the figure or table is open.
    ///
    /// A `<caption>` carries a `<title>` lead and one or more `<p>` elements,
    /// which arrive in document order, so they are joined with a single space
    /// into the one `caption` string the models expose.
    ///
    /// - Parameter text: Whitespace-normalised text of the caption child element.
    private func appendCaptionText(_ text: String) {
        guard !text.isEmpty else { return }

        if inFigure {
            guard currentFigure != nil else { return }
            if !(currentFigure?.caption.isEmpty ?? true) {
                currentFigure?.caption += " "
            }
            currentFigure?.caption += text
        } else if inTableWrap {
            guard currentTable != nil else { return }
            if !(currentTable?.caption.isEmpty ?? true) {
                currentTable?.caption += " "
            }
            currentTable?.caption += text
        }
    }

    /// Emit any pending unsectioned `<body>` prose as a body section.
    ///
    /// Called when a real `<sec>` opens and again at `</body>`, so loose
    /// paragraphs keep their position in document order. The section carries no
    /// title — JATS gave it none, and inventing one would put a heading in the
    /// rendered article that the publisher never wrote.
    private func flushImplicitBodySection() {
        guard let pending = implicitBodySection else { return }
        bodySections.append(pending.build())
        implicitBodySection = nil
    }

    public func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        elementStack.append(elementName)

        // Push a new text buffer for text-accumulating elements
        if textAccumulatingElements.contains(elementName) {
            pushTextBuffer()
        }

        // Sub-article content belongs to the sub-article, not to this one. The
        // stack and the text buffers above are still maintained, so the two stay
        // balanced across the skipped region and `</sub-article>` lands correctly.
        if elementName == "sub-article" || elementName == "response" {
            subArticleDepth += 1
            return
        }
        guard !inSubArticle else { return }

        switch elementName {
        // Document structure
        case "front":
            inFront = true
        case "article-meta":
            inArticleMeta = true
        case "contrib-group":
            inContribGroup = true
            currentContribGroupType = attributeDict["content-type"]?.lowercased()
        case "contrib":
            if isAuthorContrib(attributeDict) {
                inContrib = true
                currentAuthor = AuthorBuilder()
            }
        case "aff":
            inAff = true
            if let id = attributeDict["id"] {
                currentAffiliations[id] = ""
            }
        case "abstract":
            inAbstract = true
            currentAbstractLabel = attributeDict["abstract-type"] ?? ""
            currentAbstractTitle = ""
            currentAbstractText = []
        case "body":
            inBody = true
        case "back":
            inBack = true
        case "sec":
            // An <abstract> may be structured with <sec>. Those belong to the
            // abstract, which has its own accumulator — pushing a builder for them
            // appended an empty section to bodySections at every </sec>, ahead of
            // the real ones. The pop below carries the same guard, so the stack
            // stays balanced.
            if !inAbstract {
                // Flush first, so prose that preceded this <sec> becomes its own
                // body section rather than being folded in after the sectioned content.
                flushImplicitBodySection()
                let builder = SectionBuilder()
                sectionStack.append(builder)
            }
        case "caption":
            inCaption = true
        case "fig":
            inFigure = true
            currentFigure = FigureBuilder()
            currentFigure?.id = attributeDict["id"] ?? ""
        case "graphic":
            // Extract graphic URL from xlink:href attribute
            if inFigure {
                let href = attributeDict["xlink:href"]
                    ?? attributeDict["href"]
                    ?? attributeDict["xlink-href"]
                if let href = href {
                    currentFigure?.graphicHref = href
                }
            }
        case "table-wrap":
            inTableWrap = true
            currentTable = TableBuilder()
            currentTable?.id = attributeDict["id"] ?? ""
        case "thead":
            if inTableWrap {
                currentTable?.startHeader()
            }
        case "tbody":
            if inTableWrap {
                currentTable?.startBody()
            }
        case "tr":
            if inTableWrap {
                currentTable?.startRow()
            }
        case "th":
            if inTableWrap {
                let colspan = Int(attributeDict["colspan"] ?? "1") ?? 1
                currentTable?.startCell(isHeader: true, colspan: colspan)
            }
        case "td":
            if inTableWrap {
                let colspan = Int(attributeDict["colspan"] ?? "1") ?? 1
                currentTable?.startCell(isHeader: false, colspan: colspan)
            }
        case "list":
            if inTableWrap {
                // Check if ordered list (list-type="order" or "ordered")
                let listTypeAttr = attributeDict["list-type"] ?? ""
                let isOrdered = listTypeAttr.hasPrefix("order")
                currentTable?.startList(ordered: isOrdered)
            }
        case "list-item":
            if inTableWrap {
                currentTable?.startListItem()
            }
        case "ref-list":
            inRefList = true
        case "ref":
            inRef = true
            currentReference = ReferenceBuilder()
            currentReference?.id = attributeDict["id"] ?? ""
        case "mixed-citation", "element-citation":
            if inRef {
                inRefCitation = true
            }
        case "person-group":
            if inRefCitation {
                inRefPersonGroup = true
            }
        case "name":
            // Start of an author name within reference - handled in didEndElement
            break
        case "pub-id":
            // Handled in didEndElement with pub-id-type attribute
            break
        case "article-id":
            // Capture the pub-id-type attribute for proper ID classification
            currentArticleIdType = attributeDict["pub-id-type"]

        // Inline formatting
        case "bold", "b":
            inlineFormattingStack.append(.bold)
        case "italic", "i":
            inlineFormattingStack.append(.italic)
        case "sub":
            inlineFormattingStack.append(.subscript)
        case "sup":
            inlineFormattingStack.append(.superscript)
        case "monospace", "code":
            inlineFormattingStack.append(.monospace)

        // Cross-references (figure/table links)
        case "xref":
            currentXrefType = attributeDict["ref-type"]
            currentXrefRid = attributeDict["rid"]

        default:
            break
        }
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        appendText(string)
        // Also append to table cell if we're in a table cell
        if inTableWrap {
            currentTable?.appendCellText(string)
        }
    }

    public func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        // Pop text buffer if this was a text-accumulating element
        let elementText: String
        if textAccumulatingElements.contains(elementName) {
            // Inline elements merge their text with parent, EXCEPT for xrefs
            // to figures/tables which we handle specially (replacing text with link)
            let isInlineElement = isInlineTextElement(elementName)
            let isFigureOrTableXref = elementName == "xref" &&
                (currentXrefType == "fig" || currentXrefType == "figure" ||
                 currentXrefType == "table" || currentXrefType == "table-wrap")
            elementText = popTextBuffer(mergeWithParent: isInlineElement && !isFigureOrTableXref)
        } else {
            elementText = currentText
        }

        let text = elementText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedText = normalizeWhitespace(elementText)

        defer {
            _ = elementStack.popLast()
        }

        // See didStartElement. Handled before the guard, or `</sub-article>` would
        // be skipped by the very depth it is supposed to clear.
        if elementName == "sub-article" || elementName == "response" {
            subArticleDepth = max(0, subArticleDepth - 1)
            return
        }
        guard !inSubArticle else { return }

        switch elementName {
        // Document structure
        case "front":
            inFront = false
        case "article-meta":
            inArticleMeta = false
        case "contrib-group":
            inContribGroup = false
            currentContribGroupType = nil
        case "contrib":
            if inContrib, let author = currentAuthor?.build() {
                authors.append(author)
            }
            inContrib = false
            currentAuthor = nil
        case "aff":
            inAff = false

        // Metadata fields
        case "journal-title":
            if inFront {
                journal = text
            }
        case "article-id":
            if let parent = elementStack.dropLast().last {
                if parent == "article-meta" || inFront {
                    // Use the pub-id-type attribute if available
                    if let idType = currentArticleIdType {
                        switch idType.lowercased() {
                        case "doi":
                            doi = text
                            doiIsAuthoritative = true
                        case "pmc", "pmcid":
                            // A caller-supplied id wins: the two should agree, and
                            // if they do not, the caller knows which article it asked for.
                            if pmcId.isEmpty {
                                pmcId = text
                            }
                            pmcIdIsAuthoritative = true
                        case "pmcid-ver", "pmcaid", "pmcaiid":
                            // PMC-related but not the canonical id: `pmcid-ver` carries a
                            // version suffix, `pmcaid`/`pmcaiid` are PMC's internal numeric
                            // article ids. Recognised so they do not reach pattern matching,
                            // where the first would replace the canonical PMC ID and the
                            // others would be mistaken for a PMID.
                            break
                        case "pmid", "pubmed":
                            pmid = text
                        default:
                            // Fall back to pattern matching
                            classifyArticleIdByPattern(text)
                        }
                    } else {
                        // No type attribute, use pattern matching
                        classifyArticleIdByPattern(text)
                    }
                    currentArticleIdType = nil
                }
            }

        // Abstract
        case "abstract":
            if !currentAbstractText.isEmpty {
                let content = currentAbstractText.joined(separator: " ")
                abstractSections.append(JATSAbstractSection(
                    title: currentAbstractTitle,
                    content: content
                ))
            }
            inAbstract = false
        case "title":
            if inFigure || inTableWrap {
                // <caption><title> is the caption's lead, not a section heading —
                // but it is the same element name as one, so without this it
                // would rename the enclosing <sec> after the figure.
                if inCaption {
                    appendCaptionText(normalizedText)
                }
            } else if inAbstract {
                // If we had previous content, save it before starting new section
                if !currentAbstractText.isEmpty {
                    let content = currentAbstractText.joined(separator: " ")
                    abstractSections.append(JATSAbstractSection(
                        title: currentAbstractTitle,
                        content: content
                    ))
                    currentAbstractText = []
                }
                currentAbstractTitle = text
            } else if !sectionStack.isEmpty {
                sectionStack[sectionStack.count - 1].title = normalizedText
            }
        case "p":
            if inFigure || inTableWrap {
                // Figure and table internals, tested before every prose branch
                // because a <fig> or <table-wrap> usually sits inside a <sec>:
                // asking about the section first would blank the caption and
                // reprint it as article prose. Only <caption> content is kept —
                // cell and footnote <p> is furniture the rendered table already
                // carries, and letting it through would duplicate it into the prose.
                if inCaption {
                    appendCaptionText(normalizedText)
                }
            } else if inAbstract {
                if !normalizedText.isEmpty {
                    currentAbstractText.append(normalizedText)
                }
            } else if (inBody || inBack), !sectionStack.isEmpty {
                // Capture paragraphs in both body and back matter sections
                sectionStack[sectionStack.count - 1].paragraphs.append(normalizedText)
            } else if inBody, !normalizedText.isEmpty {
                // An unsectioned <body> child. Empty paragraphs are dropped rather
                // than opening a section, so a <body> holding nothing but
                // whitespace stays body-less.
                if implicitBodySection == nil {
                    implicitBodySection = SectionBuilder()
                }
                implicitBodySection?.paragraphs.append(normalizedText)
            }

        // Body and back matter sections
        case "body":
            flushImplicitBodySection()
            inBody = false
        case "back":
            inBack = false
        case "sec":
            // Guarded to match the push in didStartElement — see the comment there.
            // `</sec>` inside an abstract fires before `</abstract>` clears the flag,
            // so the two guards see the same state.
            if !inAbstract, let builder = sectionStack.popLast() {
                let section = builder.build()
                if sectionStack.isEmpty {
                    bodySections.append(section)
                } else {
                    sectionStack[sectionStack.count - 1].subsections.append(section)
                }
            }

        // Figures
        case "fig":
            if let figure = currentFigure?.build() {
                figures.append(figure)
            }
            inFigure = false
            currentFigure = nil
        case "label":
            if inFigure {
                currentFigure?.label = text
            } else if inTableWrap {
                currentTable?.label = text
            } else if inRef {
                currentReference?.label = text
            }
        case "caption":
            inCaption = false

        // Tables
        case "thead":
            if inTableWrap {
                currentTable?.endHeader()
            }
        case "tbody":
            if inTableWrap {
                currentTable?.endBody()
            }
        case "tr":
            if inTableWrap {
                currentTable?.endRow()
            }
        case "th", "td":
            if inTableWrap {
                currentTable?.endCell()
            }
        case "list":
            if inTableWrap {
                currentTable?.endList()
            }
        case "list-item":
            if inTableWrap {
                currentTable?.endListItem()
            }
        case "table-wrap":
            if let table = currentTable?.build() {
                tables.append(table)
            }
            inTableWrap = false
            currentTable = nil

        // References
        case "ref-list":
            inRefList = false
        case "ref":
            // Finish any pending author
            currentReference?.finishCurrentAuthor()
            if let reference = currentReference?.build() {
                references.append(reference)
            }
            inRef = false
            inRefCitation = false
            inRefPersonGroup = false
            currentReference = nil
        case "mixed-citation", "element-citation":
            if inRef {
                currentReference?.citation = normalizedText
                inRefCitation = false
            }
        case "person-group":
            if inRefCitation {
                // Finish any pending author when exiting person-group
                currentReference?.finishCurrentAuthor()
                inRefPersonGroup = false
            }
        case "surname":
            if inRefPersonGroup {
                currentReference?.currentAuthorSurname = text
            } else if inContrib {
                currentAuthor?.surname = text
            }
        case "given-names":
            if inRefPersonGroup {
                currentReference?.currentAuthorGivenNames = text
            } else if inContrib {
                currentAuthor?.givenNames = text
            }
        case "name":
            // Complete one author when closing <name> element
            if inRefPersonGroup {
                currentReference?.finishCurrentAuthor()
            }
        case "collab":
            // Collaborative author (organization name)
            if inRefCitation && !text.isEmpty {
                currentReference?.authors.append(text)
            }
        case "article-title":
            if inRefCitation {
                currentReference?.articleTitle = normalizedText
            } else if inFront && inArticleMeta {
                title = normalizedText
            }
        case "source":
            if inRefCitation {
                currentReference?.source = text
            }
        case "year":
            if inRefCitation {
                currentReference?.year = text
            } else if inFront && inArticleMeta && year.isEmpty {
                year = text
            }
        case "volume":
            if inRefCitation {
                currentReference?.volume = text
            } else if inFront && inArticleMeta {
                volume = text
            }
        case "issue":
            if inRefCitation {
                currentReference?.issue = text
            } else if inFront && inArticleMeta {
                issue = text
            }
        case "fpage":
            if inRefCitation {
                currentReference?.firstPage = text
            } else if inFront && inArticleMeta && pages.isEmpty {
                pages = text
            }
        case "lpage":
            if inRefCitation {
                currentReference?.lastPage = text
            } else if inFront && inArticleMeta && !pages.isEmpty && !text.isEmpty {
                pages += "-\(text)"
            }
        case "pub-id":
            if inRefCitation {
                // Determine type from content pattern since we don't have attribute access here
                if text.hasPrefix("10.") {
                    currentReference?.doi = text
                } else if text.allSatisfy({ $0.isNumber }) && text.count >= 7 {
                    currentReference?.pmid = text
                }
            }

        // Inline formatting - these merge with parent, nothing else to do
        case "bold", "b":
            _ = inlineFormattingStack.popLast()
        case "italic", "i":
            _ = inlineFormattingStack.popLast()
        case "sub":
            _ = inlineFormattingStack.popLast()
        case "sup":
            _ = inlineFormattingStack.popLast()
        case "monospace", "code":
            _ = inlineFormattingStack.popLast()

        // Cross-references - convert figure/table refs to anchor links
        case "xref":
            if let refType = currentXrefType, let rid = currentXrefRid {
                // Convert to markdown anchor link for figures and tables
                switch refType {
                case "fig", "figure":
                    // Format: [Figure 1](#fig-id)
                    let linkText = text.isEmpty ? "Figure" : text
                    let anchorLink = "[\(linkText)](#\(rid))"
                    appendText(anchorLink)
                case "table", "table-wrap":
                    // Format: [Table 1](#table-id)
                    let linkText = text.isEmpty ? "Table" : text
                    let anchorLink = "[\(linkText)](#\(rid))"
                    appendText(anchorLink)
                default:
                    // Other ref types (bibr, aff, etc.) - just use the text
                    break
                }
            }
            currentXrefType = nil
            currentXrefRid = nil

        // ext-link and other inline elements - already merged with parent
        case "ext-link", "uri", "email", "named-content":
            break

        default:
            break
        }
    }

    public func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = parseError
        BioMedLitLib.logger?.error("JATS XML parse error: \(parseError.localizedDescription)", category: .parsing)
    }

    // MARK: - Helper Methods

    /// Check if an element is an inline text element that should merge with parent.
    ///
    /// - Parameter elementName: The element name to check.
    /// - Returns: True if the element's text should be merged with its parent.
    private func isInlineTextElement(_ elementName: String) -> Bool {
        switch elementName {
        case "bold", "b", "italic", "i", "sub", "sup", "monospace", "code",
             "xref", "ext-link", "uri", "email", "named-content",
             "inline-formula":
            return true
        default:
            return false
        }
    }

    /// Normalize whitespace in text (collapse multiple spaces/newlines).
    private func normalizeWhitespace(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Classify an article ID by its content pattern when type attribute is unavailable.
    private func classifyArticleIdByPattern(_ text: String) {
        if text.hasPrefix("10.") {
            // A DOI is a `10.NNNN` prefix *and* a slash. Without the shape check
            // any id starting "10." is taken as one — which is how SAGE's
            // `publisher-id`, the DOI with the slash replaced by an underscore,
            // became the stored DOI for every article it publishes.
            guard !doiIsAuthoritative, text.contains("/") else { return }
            doi = text
        } else if text.hasPrefix("PMC") {
            guard !pmcIdIsAuthoritative else { return }
            pmcId = text
        } else if text.allSatisfy({ $0.isNumber }) && text.count >= BioMedLitConstants.minPMIDLength {
            // Pure numeric ID - could be PMID or PMC ID
            // Store in both if empty (PMC ID detection takes priority for figures)
            if pmid.isEmpty {
                pmid = text
            }
        }
    }
}
