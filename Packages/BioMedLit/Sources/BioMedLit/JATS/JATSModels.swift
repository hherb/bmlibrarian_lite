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

// MARK: - Public Types

/// Errors that can occur during JATS XML parsing.
public enum JATSParseError: LocalizedError, Sendable {
    /// XML parsing failed with an underlying error.
    case parsingFailed(String)

    /// No content was found in the XML.
    case noContent

    /// Invalid or unsupported XML structure.
    case invalidStructure(String)

    /// The parser instance had already been used.
    ///
    /// `JATSXMLParser` holds one `XMLParser` built from the data it was given, so
    /// it parses once. Without this case the second call reported
    /// `parsingFailed("Unknown parsing error")` — a consumed `XMLParser` exposes
    /// no error of its own — which named neither the cause nor the remedy.
    case alreadyParsed

    public var errorDescription: String? {
        switch self {
        case .parsingFailed(let reason):
            return "Failed to parse JATS XML: \(reason)"
        case .noContent:
            return "No content found in JATS XML"
        case .invalidStructure(let reason):
            return "Invalid JATS XML structure: \(reason)"
        case .alreadyParsed:
            return "This JATSXMLParser has already parsed its data; "
                + "construct a new one for each parse"
        }
    }
}

/// Parsed author information from a JATS article.
public struct JATSAuthorInfo: Sendable, Equatable {
    /// Author's surname/family name.
    public let surname: String

    /// Author's given names (first name, middle names).
    public let givenNames: String

    /// Author's affiliations.
    public let affiliations: [String]

    public init(surname: String, givenNames: String, affiliations: [String] = []) {
        self.surname = surname
        self.givenNames = givenNames
        self.affiliations = affiliations
    }

    /// Formatted full name (given names + surname).
    public var fullName: String {
        if givenNames.isEmpty {
            return surname
        }
        return "\(givenNames) \(surname)"
    }
}

/// Parsed body section from a JATS article.
public struct JATSBodySection: Sendable, Equatable {
    /// Section title.
    public let title: String

    /// Paragraphs in the section.
    public let paragraphs: [String]

    /// Nested subsections.
    public let subsections: [JATSBodySection]

    public init(title: String, paragraphs: [String], subsections: [JATSBodySection] = []) {
        self.title = title
        self.paragraphs = paragraphs
        self.subsections = subsections
    }
}

/// Parsed figure information from a JATS article.
public struct JATSFigureInfo: Sendable, Equatable {
    /// Figure ID (for cross-references).
    public let id: String

    /// Figure label (e.g., "Figure 1").
    public let label: String

    /// Figure caption text.
    public let caption: String

    /// URL or path to the figure graphic.
    public let graphicURL: String?

    /// Footnote paragraphs from `<table-wrap-foot>` or a figure `<fn>`.
    ///
    /// Kept separate from ``caption`` because the two say different things: the
    /// caption names the exhibit, while footnotes carry abbreviation expansions,
    /// significance markers and per-table funding notes. The rendered table does
    /// not reproduce them, so dropping them lost content the transparency
    /// analysis reads.
    public let footnotes: [String]

    /// Creates parsed figure information.
    ///
    /// - Parameters:
    ///   - id: Figure ID used for cross-references.
    ///   - label: Figure label, for example "Figure 1".
    ///   - caption: Caption text.
    ///   - graphicURL: URL or path to the graphic, if the figure has one.
    ///   - footnotes: Footnote paragraphs; defaults to none.
    public init(
        id: String,
        label: String,
        caption: String,
        graphicURL: String?,
        footnotes: [String] = []
    ) {
        self.id = id
        self.label = label
        self.caption = caption
        self.graphicURL = graphicURL
        self.footnotes = footnotes
    }
}

/// Parsed table information from a JATS article.
public struct JATSTableInfo: Sendable, Equatable {
    /// Table ID (for cross-references).
    public let id: String

    /// Table label (e.g., "Table 1").
    public let label: String

    /// Table caption text.
    public let caption: String

    /// Table content as markdown table format.
    public let markdownContent: String

    /// Footnote paragraphs from `<table-wrap-foot>` or a figure `<fn>`.
    ///
    /// Kept separate from ``caption`` because the two say different things: the
    /// caption names the exhibit, while footnotes carry abbreviation expansions,
    /// significance markers and per-table funding notes. The rendered table does
    /// not reproduce them, so dropping them lost content the transparency
    /// analysis reads.
    public let footnotes: [String]

    /// Creates parsed table information.
    ///
    /// - Parameters:
    ///   - id: Table ID used for cross-references.
    ///   - label: Table label, for example "Table 1".
    ///   - caption: Caption text.
    ///   - markdownContent: The table body rendered as a markdown table.
    ///   - footnotes: Footnote paragraphs; defaults to none.
    public init(
        id: String,
        label: String,
        caption: String,
        markdownContent: String,
        footnotes: [String] = []
    ) {
        self.id = id
        self.label = label
        self.caption = caption
        self.markdownContent = markdownContent
        self.footnotes = footnotes
    }
}

/// Parsed reference information from a JATS article.
public struct JATSReferenceInfo: Sendable, Equatable {
    /// Reference ID (for cross-references).
    public let id: String

    /// Reference label (e.g., "1", "2").
    public let label: String

    /// Raw citation text.
    public let citation: String

    /// Structured reference fields.
    public let authors: [String]
    public let articleTitle: String
    public let source: String  // Journal name
    public let year: String
    public let volume: String
    public let issue: String
    public let firstPage: String
    public let lastPage: String
    public let doi: String
    public let pmid: String

    public init(
        id: String,
        label: String,
        citation: String,
        authors: [String],
        articleTitle: String,
        source: String,
        year: String,
        volume: String,
        issue: String,
        firstPage: String,
        lastPage: String,
        doi: String,
        pmid: String
    ) {
        self.id = id
        self.label = label
        self.citation = citation
        self.authors = authors
        self.articleTitle = articleTitle
        self.source = source
        self.year = year
        self.volume = volume
        self.issue = issue
        self.firstPage = firstPage
        self.lastPage = lastPage
        self.doi = doi
        self.pmid = pmid
    }

    /// Format the reference as a complete citation string.
    public var formattedCitation: String {
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

/// Complete parsed JATS article data.
public struct JATSArticle: Sendable {
    /// Article title.
    public let title: String

    /// Article authors.
    public let authors: [JATSAuthorInfo]

    /// Journal name.
    public let journal: String

    /// Volume number.
    public let volume: String

    /// Issue number.
    public let issue: String

    /// Page range.
    public let pages: String

    /// Publication year.
    public let year: String

    /// Digital Object Identifier.
    public let doi: String

    /// PubMed Central ID.
    public let pmcId: String

    /// PubMed ID.
    public let pmid: String

    /// Abstract sections.
    public let abstractSections: [JATSAbstractSection]

    /// Body sections.
    public let bodySections: [JATSBodySection]

    /// Figures.
    public let figures: [JATSFigureInfo]

    /// Tables.
    public let tables: [JATSTableInfo]

    /// References.
    public let references: [JATSReferenceInfo]

    public init(
        title: String,
        authors: [JATSAuthorInfo],
        journal: String,
        volume: String,
        issue: String,
        pages: String,
        year: String,
        doi: String,
        pmcId: String,
        pmid: String,
        abstractSections: [JATSAbstractSection],
        bodySections: [JATSBodySection],
        figures: [JATSFigureInfo],
        tables: [JATSTableInfo],
        references: [JATSReferenceInfo]
    ) {
        self.title = title
        self.authors = authors
        self.journal = journal
        self.volume = volume
        self.issue = issue
        self.pages = pages
        self.year = year
        self.doi = doi
        self.pmcId = pmcId
        self.pmid = pmid
        self.abstractSections = abstractSections
        self.bodySections = bodySections
        self.figures = figures
        self.tables = tables
        self.references = references
    }
}

/// Parsed abstract section.
public struct JATSAbstractSection: Sendable, Equatable {
    /// Section title (e.g., "Background", "Methods").
    public let title: String

    /// Section content.
    public let content: String

    public init(title: String, content: String) {
        self.title = title
        self.content = content
    }
}

// MARK: - Internal Builder Types

/// Builder for author information during parsing.
struct AuthorBuilder {
    var surname = ""
    var givenNames = ""
    var affiliations: [String] = []

    func build() -> JATSAuthorInfo? {
        guard !surname.isEmpty else { return nil }
        return JATSAuthorInfo(
            surname: surname,
            givenNames: givenNames,
            affiliations: affiliations
        )
    }
}

/// Builder for body sections during parsing.
struct SectionBuilder {
    var title = ""
    var paragraphs: [String] = []
    var subsections: [JATSBodySection] = []

    func build() -> JATSBodySection {
        JATSBodySection(
            title: title,
            paragraphs: paragraphs,
            subsections: subsections
        )
    }
}

/// How suitable a `<graphic>` is as the one image shown for its figure.
///
/// A figure commonly carries several `<graphic>` — of the 959 survey figures
/// carrying one at all, 507 (52.9%) end on a thumbnail — and `graphicURL` holds
/// exactly one, so the parser has to choose. Ranking them lets the best deposit
/// win whatever order the publisher wrote them in (#161), which matters because
/// the two multi-graphic conventions disagree about order: a thumbnail is
/// deposited last, an archival master first.
enum GraphicSuitability: Int, Comparable {
    /// An archival master — TIFF or EPS. `<alternatives>` deposits one ahead of
    /// the web derivative, and no WebKit view can render it.
    case archival = 0

    /// A reduced-size copy of another `<graphic>` in the same figure. Renders,
    /// but is not the image the figure is about.
    case thumbnail = 1

    /// A full-size, web-renderable image, or one the deposit says nothing about.
    case full = 2

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Assembly of a footnote from its `<fn>` marker and its prose.
enum JATSFootnote {
    /// Separates a footnote's marker from its prose.
    ///
    /// An em dash rather than ". " because a marker is as often a symbol as a
    /// letter, and `"*. "` reads as a typo where `"* — "` does not.
    static let markerSeparator = " — "

    /// Join a footnote's `<fn>` marker to its prose.
    ///
    /// - Parameters:
    ///   - marker: The `<fn>`'s own `<label>` — "a", "b", "*" — or empty.
    ///   - text: The footnote prose.
    /// - Returns: The prose, prefixed by the marker when there is one.
    static func join(_ marker: String, to text: String) -> String {
        marker.isEmpty ? text : "\(marker)\(markerSeparator)\(text)"
    }
}

/// Builder for figure information during parsing.
struct FigureBuilder {
    var id = ""
    var label = ""
    var caption = ""
    var graphicHref = ""
    /// How good a fit `graphicHref` is, or `nil` while no `<graphic>` has been
    /// accepted.
    ///
    /// Held so a lesser deposit can be given up the moment a better one arrives,
    /// whichever order the publisher wrote them in (#161).
    var graphicSuitability: GraphicSuitability?
    var footnotes: [String] = []
    /// The `<label>` of the `<fn>` currently open, held until its prose arrives.
    ///
    /// The marker is not decoration: `<sup>` is flattened into the surrounding
    /// cell text, so a table body reads `12.3a` and the footnote it points at has
    /// to say which one it is (#157).
    var pendingFootnoteLabel = ""

    /// Accept a `<graphic>` if it beats the one already held.
    ///
    /// Strictly better, so the *first* deposit wins among equals — the rule the
    /// publishers that deposit two full images rely on.
    ///
    /// - Parameters:
    ///   - href: The graphic's href.
    ///   - suitability: How good a fit it is.
    mutating func offerGraphic(_ href: String, suitability: GraphicSuitability) {
        guard !href.isEmpty else { return }
        if let held = graphicSuitability, suitability <= held { return }
        graphicHref = href
        graphicSuitability = suitability
    }

    /// Append footnote prose, carrying any pending `<fn>` marker onto it.
    ///
    /// - Parameter text: Whitespace-normalised text of the footnote paragraph.
    mutating func appendFootnote(_ text: String) {
        footnotes.append(JATSFootnote.join(pendingFootnoteLabel, to: text))
        pendingFootnoteLabel = ""
    }

    func build() -> JATSFigureInfo {
        JATSFigureInfo(
            id: id,
            label: label,
            caption: caption,
            graphicURL: graphicHref.isEmpty ? nil : graphicHref,
            footnotes: footnotes
        )
    }
}

/// Builder for table information during parsing.
struct TableBuilder {
    var id = ""
    var label = ""
    var caption = ""
    var footnotes: [String] = []
    /// The `<label>` of the `<fn>` currently open, held until its prose arrives.
    ///
    /// See `FigureBuilder.pendingFootnoteLabel`: the marker is referenced by cell
    /// text that survives into the rendered table, so dropping it leaves the
    /// reader with `12.3a` and no way to tell which footnote `a` is (#157).
    var pendingFootnoteLabel = ""
    var headerRows: [[String]] = []
    var bodyRows: [[String]] = []
    var currentRow: [String] = []
    var currentCellText = ""
    var inHeader = false
    var inBody = false
    var inRow = false
    var inCell = false

    // Track if current row has <th> cells (for tables without <thead>)
    var currentRowHasHeaderCells = false

    // List tracking for proper formatting
    var inList = false
    var listType: ListType = .unordered
    var listItemNumber = 0
    var pendingListItem = false

    // Track colspan for current cell
    var currentColspan = 1

    enum ListType {
        case ordered
        case unordered
    }

    /// Append footnote prose, carrying any pending `<fn>` marker onto it.
    ///
    /// - Parameter text: Whitespace-normalised text of the footnote paragraph.
    mutating func appendFootnote(_ text: String) {
        footnotes.append(JATSFootnote.join(pendingFootnoteLabel, to: text))
        pendingFootnoteLabel = ""
    }

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
        currentRowHasHeaderCells = false
    }

    mutating func endRow() {
        if inRow && !currentRow.isEmpty {
            // If in explicit header OR row has <th> cells and we haven't started body yet
            if inHeader || (currentRowHasHeaderCells && !inBody && headerRows.isEmpty) {
                headerRows.append(currentRow)
            } else {
                bodyRows.append(currentRow)
            }
        }
        inRow = false
        currentRow = []
        currentRowHasHeaderCells = false
    }

    mutating func startCell(isHeader: Bool = false, colspan: Int = 1) {
        inCell = true
        currentCellText = ""
        currentColspan = max(1, colspan)
        inList = false
        listItemNumber = 0
        pendingListItem = false
        // Mark as header row if explicitly a <th> cell OR if we're inside <thead>
        if isHeader || inHeader {
            currentRowHasHeaderCells = true
        }
    }

    mutating func endCell() {
        if inCell {
            // Normalize cell content: collapse all whitespace to single spaces
            // and escape pipe characters that would break table formatting
            let normalized = currentCellText
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
                .replacingOccurrences(of: "|", with: "\\|")
            currentRow.append(normalized)

            // Add empty cells for colspan > 1
            for _ in 1..<currentColspan {
                currentRow.append("")
            }
        }
        inCell = false
        currentCellText = ""
        currentColspan = 1
        inList = false
        listItemNumber = 0
        pendingListItem = false
    }

    mutating func startList(ordered: Bool) {
        if inCell {
            inList = true
            listType = ordered ? .ordered : .unordered
            listItemNumber = 0
        }
    }

    mutating func endList() {
        if inCell {
            inList = false
        }
    }

    mutating func startListItem() {
        if inCell && inList {
            listItemNumber += 1
            pendingListItem = true
        }
    }

    mutating func endListItem() {
        if inCell {
            pendingListItem = false
        }
    }

    mutating func appendCellText(_ text: String) {
        if inCell {
            // Normalize whitespace within cell text to prevent line breaks
            // that would corrupt the markdown table format
            let normalized = text.replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")

            // If we have a pending list item and there's actual content, add the marker
            if pendingListItem && !normalized.trimmingCharacters(in: .whitespaces).isEmpty {
                // Add separator if there's existing content
                if !currentCellText.trimmingCharacters(in: .whitespaces).isEmpty {
                    currentCellText += "; "
                }
                // Add list marker
                switch listType {
                case .ordered:
                    currentCellText += "\(listItemNumber). "
                case .unordered:
                    currentCellText += "• "
                }
                pendingListItem = false
            }

            currentCellText += normalized
        }
    }

    func build() -> JATSTableInfo {
        JATSTableInfo(
            id: id,
            label: label,
            caption: caption,
            markdownContent: buildMarkdownTable(),
            footnotes: footnotes
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

/// Builder for reference information during parsing.
struct ReferenceBuilder {
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

    func build() -> JATSReferenceInfo {
        JATSReferenceInfo(
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

/// Inline formatting types used during parsing.
enum InlineFormat {
    case bold
    case italic
    case `subscript`
    case superscript
    case monospace
}
