//
//  JATSXMLParser.swift
//  MedicalFactChecker
//
//  Comprehensive parser for JATS XML format used by Europe PMC.
//  Converts JATS XML to markdown format for display.
//

import Foundation

/// Errors that can occur during JATS XML parsing.
enum JATSParseError: LocalizedError {
    /// XML parsing failed with an underlying error.
    case parsingFailed(String)

    /// No content was found in the XML.
    case noContent

    /// Invalid or unsupported XML structure.
    case invalidStructure(String)

    var errorDescription: String? {
        switch self {
        case .parsingFailed(let reason):
            return "Failed to parse JATS XML: \(reason)"
        case .noContent:
            return "No content found in JATS XML"
        case .invalidStructure(let reason):
            return "Invalid JATS XML structure: \(reason)"
        }
    }
}

/// Parser for converting JATS (Journal Article Tag Suite) XML to markdown.
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
/// ```
final class JATSXMLParser: NSObject {
    // MARK: - Properties

    private let parser: XMLParser
    private var parseError: Error?

    // MARK: - Parsed Content

    private var title = ""
    private var authors: [AuthorInfo] = []
    private var journal = ""
    private var volume = ""
    private var issue = ""
    private var pages = ""
    private var year = ""
    private var doi = ""
    private var pmcId = ""
    private var pmid = ""
    private var abstractSections: [AbstractSection] = []
    private var bodySections: [BodySection] = []
    private var figures: [FigureInfo] = []
    private var tables: [TableInfo] = []
    private var references: [ReferenceInfo] = []

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
    private var inContrib = false
    private var inAff = false

    // Abstract state
    private var inAbstract = false
    private var currentAbstractLabel = ""
    private var currentAbstractTitle = ""
    private var currentAbstractText: [String] = []

    // Body state
    private var inBody = false
    private var sectionStack: [SectionBuilder] = []

    // Figure/Table state
    private var inFigure = false
    private var inTable = false
    private var inTableWrap = false
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
    init(data: Data, knownPMCId: String? = nil) {
        self.parser = XMLParser(data: data)
        // Pre-populate PMC ID if provided
        if let knownId = knownPMCId, !knownId.isEmpty {
            self.pmcId = knownId.hasPrefix("PMC") ? knownId : "PMC\(knownId)"
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
    func parseToMarkdown() throws -> String {
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
                // Add anchor for linking from xrefs
                let anchorId = figure.id.isEmpty ? "fig\(index + 1)" : figure.id
                lines.append("<!-- anchor:\(anchorId) -->")
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
                // Add anchor for linking from xrefs
                let anchorId = table.id.isEmpty ? "table\(index + 1)" : table.id
                lines.append("<!-- anchor:\(anchorId) -->")
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

        if authorNames.count <= 3 {
            return authorNames.joined(separator: ", ")
        } else {
            return "\(authorNames[0]), \(authorNames[1]), \(authorNames[2]) et al."
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
    private func formatBodySection(_ section: BodySection, level: Int) -> [String] {
        var lines: [String] = []
        let headingPrefix = String(repeating: "#", count: min(level, 6))

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
}

// MARK: - XMLParserDelegate

extension JATSXMLParser: XMLParserDelegate {
    func parser(
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

        switch elementName {
        // Document structure
        case "front":
            inFront = true
        case "article-meta":
            inArticleMeta = true
        case "contrib-group":
            inContribGroup = true
        case "contrib":
            if attributeDict["contrib-type"] == "author" {
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
        case "sec":
            let builder = SectionBuilder()
            sectionStack.append(builder)
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
        case "th", "td":
            if inTableWrap {
                currentTable?.startCell()
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

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        appendText(string)
        // Also append to table cell if we're in a table cell
        if inTableWrap {
            currentTable?.appendCellText(string)
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        // Pop text buffer if this was a text-accumulating element
        let elementText: String
        if textAccumulatingElements.contains(elementName) {
            // Inline elements merge their text with parent
            let isInlineElement = isInlineTextElement(elementName)
            elementText = popTextBuffer(mergeWithParent: isInlineElement)
        } else {
            elementText = currentText
        }

        let text = elementText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedText = normalizeWhitespace(elementText)

        defer {
            _ = elementStack.popLast()
        }

        switch elementName {
        // Document structure
        case "front":
            inFront = false
        case "article-meta":
            inArticleMeta = false
        case "contrib-group":
            inContribGroup = false
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
                        case "pmc", "pmcid":
                            pmcId = text
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
                abstractSections.append(AbstractSection(
                    title: currentAbstractTitle,
                    content: content
                ))
            }
            inAbstract = false
        case "title":
            if inAbstract {
                // If we had previous content, save it before starting new section
                if !currentAbstractText.isEmpty {
                    let content = currentAbstractText.joined(separator: " ")
                    abstractSections.append(AbstractSection(
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
            if inAbstract {
                if !normalizedText.isEmpty {
                    currentAbstractText.append(normalizedText)
                }
            } else if inBody, !sectionStack.isEmpty {
                sectionStack[sectionStack.count - 1].paragraphs.append(normalizedText)
            } else if inFigure {
                currentFigure?.caption += normalizedText
            } else if inTableWrap {
                currentTable?.caption += normalizedText
            }

        // Body sections
        case "body":
            inBody = false
        case "sec":
            if let builder = sectionStack.popLast() {
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
            // Caption content is handled in nested p elements
            break

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

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = parseError
        AppLogger.parsing.error("JATS XML parse error: \(parseError.localizedDescription)")
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
            doi = text
        } else if text.hasPrefix("PMC") {
            pmcId = text
        } else if text.allSatisfy({ $0.isNumber }) && text.count >= 7 {
            // Pure numeric ID - could be PMID or PMC ID
            // Store in both if empty (PMC ID detection takes priority for figures)
            if pmid.isEmpty {
                pmid = text
            }
        }
    }
}

// MARK: - Supporting Types

/// Inline formatting types.
private enum InlineFormat {
    case bold
    case italic
    case `subscript`
    case superscript
    case monospace
}

/// Parsed author information.
struct AuthorInfo {
    let surname: String
    let givenNames: String
    let affiliations: [String]
}

/// Builder for author information.
private struct AuthorBuilder {
    var surname = ""
    var givenNames = ""
    var affiliations: [String] = []

    func build() -> AuthorInfo? {
        guard !surname.isEmpty else { return nil }
        return AuthorInfo(
            surname: surname,
            givenNames: givenNames,
            affiliations: affiliations
        )
    }
}

/// Parsed abstract section.
private struct AbstractSection {
    let title: String
    let content: String
}

/// Parsed body section.
struct BodySection {
    let title: String
    let paragraphs: [String]
    let subsections: [BodySection]
}

/// Builder for body sections.
private struct SectionBuilder {
    var title = ""
    var paragraphs: [String] = []
    var subsections: [BodySection] = []

    func build() -> BodySection {
        BodySection(
            title: title,
            paragraphs: paragraphs,
            subsections: subsections
        )
    }
}

/// Parsed figure information.
struct FigureInfo {
    let id: String
    let label: String
    let caption: String
    /// URL or path to the figure graphic.
    let graphicURL: String?
}

/// Builder for figure information.
private struct FigureBuilder {
    var id = ""
    var label = ""
    var caption = ""
    var graphicHref = ""

    func build() -> FigureInfo {
        FigureInfo(
            id: id,
            label: label,
            caption: caption,
            graphicURL: graphicHref.isEmpty ? nil : graphicHref
        )
    }
}

/// Parsed table information.
struct TableInfo {
    let id: String
    let label: String
    let caption: String
    /// Table content as markdown table format.
    let markdownContent: String
}

/// Builder for table information.
private struct TableBuilder {
    var id = ""
    var label = ""
    var caption = ""
    var headerRows: [[String]] = []
    var bodyRows: [[String]] = []
    var currentRow: [String] = []
    var currentCellText = ""
    var inHeader = false
    var inBody = false
    var inRow = false
    var inCell = false

    mutating func startHeader() {
        inHeader = true
        inBody = false
    }

    mutating func endHeader() {
        inHeader = false
    }

    mutating func startBody() {
        inBody = true
        inHeader = false
    }

    mutating func endBody() {
        inBody = false
    }

    mutating func startRow() {
        inRow = true
        currentRow = []
    }

    mutating func endRow() {
        if inRow && !currentRow.isEmpty {
            if inHeader {
                headerRows.append(currentRow)
            } else {
                bodyRows.append(currentRow)
            }
        }
        inRow = false
        currentRow = []
    }

    mutating func startCell() {
        inCell = true
        currentCellText = ""
    }

    mutating func endCell() {
        if inCell {
            currentRow.append(currentCellText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        inCell = false
        currentCellText = ""
    }

    mutating func appendCellText(_ text: String) {
        if inCell {
            currentCellText += text
        }
    }

    func build() -> TableInfo {
        TableInfo(
            id: id,
            label: label,
            caption: caption,
            markdownContent: buildMarkdownTable()
        )
    }

    /// Convert table rows to markdown table format.
    private func buildMarkdownTable() -> String {
        guard !headerRows.isEmpty || !bodyRows.isEmpty else {
            return ""
        }

        var lines: [String] = []

        // Determine column count from header or body
        let columnCount = max(
            headerRows.first?.count ?? 0,
            bodyRows.first?.count ?? 0
        )
        guard columnCount > 0 else { return "" }

        // Add header rows
        if !headerRows.isEmpty {
            for row in headerRows {
                let paddedRow = padRow(row, to: columnCount)
                lines.append("| " + paddedRow.joined(separator: " | ") + " |")
            }
            // Add separator line after header
            let separator = Array(repeating: "---", count: columnCount)
            lines.append("| " + separator.joined(separator: " | ") + " |")
        } else {
            // No header - create empty header for valid markdown
            let emptyHeader = Array(repeating: "", count: columnCount)
            lines.append("| " + emptyHeader.joined(separator: " | ") + " |")
            let separator = Array(repeating: "---", count: columnCount)
            lines.append("| " + separator.joined(separator: " | ") + " |")
        }

        // Add body rows
        for row in bodyRows {
            let paddedRow = padRow(row, to: columnCount)
            lines.append("| " + paddedRow.joined(separator: " | ") + " |")
        }

        return lines.joined(separator: "\n")
    }

    /// Pad or truncate a row to the specified column count.
    private func padRow(_ row: [String], to count: Int) -> [String] {
        if row.count >= count {
            return Array(row.prefix(count))
        }
        return row + Array(repeating: "", count: count - row.count)
    }
}

/// Parsed reference information.
struct ReferenceInfo {
    let id: String
    let label: String
    let citation: String
    /// Structured reference fields for complete display.
    let authors: [String]
    let articleTitle: String
    let source: String  // Journal name
    let year: String
    let volume: String
    let issue: String
    let firstPage: String
    let lastPage: String
    let doi: String
    let pmid: String

    /// Format the reference as a complete citation string.
    var formattedCitation: String {
        var parts: [String] = []

        // Authors
        if !authors.isEmpty {
            if authors.count <= 3 {
                parts.append(authors.joined(separator: ", "))
            } else {
                parts.append("\(authors[0]), \(authors[1]), et al.")
            }
        }

        // Article title
        if !articleTitle.isEmpty {
            parts.append(articleTitle)
        }

        // Journal name (italicized in markdown)
        if !source.isEmpty {
            parts.append("*\(source)*")
        }

        // Year
        if !year.isEmpty {
            parts.append("(\(year))")
        }

        // Volume and pages
        var volumeInfo = ""
        if !volume.isEmpty {
            volumeInfo = volume
            if !issue.isEmpty {
                volumeInfo += "(\(issue))"
            }
        }
        if !firstPage.isEmpty {
            if !volumeInfo.isEmpty {
                volumeInfo += ":"
            }
            volumeInfo += firstPage
            if !lastPage.isEmpty {
                volumeInfo += "-\(lastPage)"
            }
        }
        if !volumeInfo.isEmpty {
            parts.append(volumeInfo)
        }

        // DOI
        if !doi.isEmpty {
            parts.append("doi:\(doi)")
        }

        // If we have structured data, use it; otherwise fall back to raw citation
        if parts.isEmpty {
            return citation
        }

        return parts.joined(separator: ". ")
    }
}

/// Builder for reference information.
private struct ReferenceBuilder {
    var id = ""
    var label = ""
    var citation = ""
    var authors: [String] = []
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
    var inPersonGroup = false

    mutating func finishCurrentAuthor() {
        if !currentAuthorSurname.isEmpty {
            var name = currentAuthorSurname
            if !currentAuthorGivenNames.isEmpty {
                name = "\(currentAuthorGivenNames) \(name)"
            }
            authors.append(name)
            currentAuthorSurname = ""
            currentAuthorGivenNames = ""
        }
    }

    func build() -> ReferenceInfo {
        ReferenceInfo(
            id: id,
            label: label,
            citation: citation,
            authors: authors,
            articleTitle: articleTitle,
            source: source,
            year: year,
            volume: volume,
            issue: issue,
            firstPage: firstPage,
            lastPage: lastPage,
            doi: doi,
            pmid: pmid
        )
    }
}
