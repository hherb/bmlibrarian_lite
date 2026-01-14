//
//  JATSXMLParser.swift
//  MedicalFactChecker
//
//  Parser for JATS XML format used by Europe PMC.
//

import Foundation

/// Errors that can occur during JATS XML parsing.
enum JATSXMLParserError: LocalizedError, Sendable {
    case parsingFailed(String)
    case emptyContent

    var errorDescription: String? {
        switch self {
        case .parsingFailed(let reason):
            return "Failed to parse JATS XML: \(reason)"
        case .emptyContent:
            return "No content extracted from XML"
        }
    }
}

/// Parser for converting JATS XML to markdown.
///
/// JATS (Journal Article Tag Suite) is the XML format used by PubMed Central
/// and Europe PMC for full-text articles. This parser extracts the article
/// structure and converts it to readable markdown.
final class JATSXMLParser: NSObject, XMLParserDelegate {
    // MARK: - Constants

    /// Maximum number of authors to display before using "et al."
    private static let maxAuthorsBeforeEtAl = 3

    /// Maximum markdown heading level (h1-h6).
    private static let maxHeadingLevel = 6

    // MARK: - Properties

    private let parser: XMLParser
    private var sections: [String] = []

    // State tracking
    private var currentElement = ""
    private var currentText = ""
    private var inBody = false
    private var inSection = false
    private var inAbstract = false
    private var inParagraph = false
    private var inBiblioRef = false
    private var sectionLevel = 0

    // Metadata
    private var title = ""
    private var authors: [String] = []
    private var currentAuthorSurname = ""
    private var journal = ""
    private var year = ""
    private var abstract = ""

    // Current section content
    private var currentSectionTitle = ""
    private var currentSectionContent: [String] = []

    /// Initialize with XML data.
    ///
    /// - Parameter data: The JATS XML data to parse.
    init(data: Data) {
        self.parser = XMLParser(data: data)
        super.init()
        parser.delegate = self
    }

    /// Parse XML and return markdown string.
    ///
    /// - Returns: The article content as markdown.
    /// - Throws: JATSXMLParserError if parsing fails.
    func parseToMarkdown() throws -> String {
        guard parser.parse() else {
            let errorMessage = parser.parserError?.localizedDescription ?? "Unknown error"
            throw JATSXMLParserError.parsingFailed(errorMessage)
        }

        let markdown = buildMarkdown()
        if markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw JATSXMLParserError.emptyContent
        }

        return markdown
    }

    // MARK: - XMLParserDelegate

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName

        switch elementName {
        case "article-title":
            currentText = ""
        case "surname":
            currentText = ""
        case "given-names":
            currentText = ""
        case "journal-title":
            currentText = ""
        case "year":
            currentText = ""
        case "abstract":
            inAbstract = true
            currentText = ""
        case "body":
            inBody = true
        case "sec":
            inSection = true
            sectionLevel += 1
        case "title":
            if inSection {
                currentText = ""
            }
        case "p":
            inParagraph = true
            currentText = ""
        case "italic", "i":
            currentText += "*"
        case "bold", "b":
            currentText += "**"
        case "sup":
            currentText += "^"
        case "sub":
            currentText += "_"
        case "xref":
            // Handle citations/references inline (only for bibliography refs)
            if attributeDict["ref-type"] == "bibr" {
                inBiblioRef = true
                currentText += "["
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch elementName {
        case "article-title":
            title = text
        case "surname":
            currentAuthorSurname = text
        case "given-names":
            // Combine surname and given names
            if !currentAuthorSurname.isEmpty {
                authors.append("\(currentAuthorSurname), \(text)")
                currentAuthorSurname = ""
            }
        case "name":
            // Handle case where only surname is present
            if !currentAuthorSurname.isEmpty {
                authors.append(currentAuthorSurname)
                currentAuthorSurname = ""
            }
        case "journal-title":
            journal = text
        case "year":
            if year.isEmpty {
                year = text
            }
        case "abstract":
            abstract = text
            inAbstract = false
        case "body":
            inBody = false
        case "sec":
            // Flush current section
            if !currentSectionTitle.isEmpty || !currentSectionContent.isEmpty {
                let headingLevel = min(sectionLevel + 1, Self.maxHeadingLevel)
                let prefix = String(repeating: "#", count: headingLevel)
                if !currentSectionTitle.isEmpty {
                    sections.append("\(prefix) \(currentSectionTitle)")
                }
                sections.append(contentsOf: currentSectionContent)
                sections.append("")
            }
            currentSectionTitle = ""
            currentSectionContent = []
            sectionLevel = max(0, sectionLevel - 1)
            inSection = sectionLevel > 0
        case "title":
            if inSection && inBody {
                currentSectionTitle = text
            }
        case "p":
            if inBody && !text.isEmpty {
                currentSectionContent.append(text)
                currentSectionContent.append("")
            } else if inAbstract && !text.isEmpty {
                currentText = text + " "
            }
            inParagraph = false
        case "italic", "i":
            currentText += "*"
        case "bold", "b":
            currentText += "**"
        case "sup":
            currentText += ""  // End superscript
        case "sub":
            currentText += ""  // End subscript
        case "xref":
            // Only close bracket for bibliography references
            if inBiblioRef {
                currentText += "]"
                inBiblioRef = false
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        print("[JATSXMLParser] Parse error: \(parseError.localizedDescription)")
    }

    // MARK: - Markdown Builder

    private func buildMarkdown() -> String {
        var lines: [String] = []

        // Title
        if !title.isEmpty {
            lines.append("# \(title)")
            lines.append("")
        }

        // Metadata
        if !authors.isEmpty {
            let authorList = authors.prefix(Self.maxAuthorsBeforeEtAl).joined(separator: ", ")
            let suffix = authors.count > Self.maxAuthorsBeforeEtAl ? " et al." : ""
            lines.append("**Authors:** \(authorList)\(suffix)")
        }
        if !journal.isEmpty || !year.isEmpty {
            var meta: [String] = []
            if !journal.isEmpty { meta.append("*\(journal)*") }
            if !year.isEmpty { meta.append("(\(year))") }
            lines.append(meta.joined(separator: " "))
        }
        if !authors.isEmpty || !journal.isEmpty || !year.isEmpty {
            lines.append("")
        }

        // Abstract
        if !abstract.isEmpty {
            lines.append("## Abstract")
            lines.append("")
            lines.append(abstract)
            lines.append("")
        }

        // Body sections
        lines.append(contentsOf: sections)

        return lines.joined(separator: "\n")
    }
}
