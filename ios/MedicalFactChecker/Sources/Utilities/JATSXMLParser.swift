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
///
/// Uses a stack-based text accumulation approach to properly handle inline
/// elements like `<xref>`, `<italic>`, `<bold>`, etc. without losing surrounding text.
final class JATSXMLParser: NSObject, XMLParserDelegate {
    // MARK: - Constants

    /// Maximum number of authors to display before using "et al."
    private static let maxAuthorsBeforeEtAl = 3

    /// Maximum markdown heading level (h1-h6).
    private static let maxHeadingLevel = 6

    // MARK: - Properties

    private let parser: XMLParser
    private var sections: [String] = []

    // Text stack for proper inline element handling
    private var textStack: [String] = [""]

    /// Elements that accumulate their own text content.
    private let textAccumulatingElements: Set<String> = [
        "article-title", "surname", "given-names", "journal-title", "year",
        "abstract", "title", "p",
        "italic", "i", "bold", "b", "sup", "sub", "xref", "ext-link"
    ]

    /// Inline elements that should merge text back to parent.
    private let inlineElements: Set<String> = [
        "italic", "i", "bold", "b", "sup", "sub", "xref", "ext-link"
    ]

    // State tracking
    private var currentElement = ""
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

    // MARK: - Text Stack Helpers

    /// Get the current accumulated text.
    private var currentText: String {
        get { textStack.last ?? "" }
        set {
            if !textStack.isEmpty {
                textStack[textStack.count - 1] = newValue
            }
        }
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

    /// Pop and return the text buffer, optionally merging with parent.
    private func popTextBuffer(mergeWithParent: Bool = false) -> String {
        guard textStack.count > 1 else {
            let text = textStack.first ?? ""
            if !textStack.isEmpty {
                textStack[0] = ""
            }
            return text
        }

        let text = textStack.removeLast()

        if mergeWithParent && !textStack.isEmpty {
            textStack[textStack.count - 1] += text
        }

        return text
    }

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

        // Push text buffer for text-accumulating elements
        if textAccumulatingElements.contains(elementName) {
            pushTextBuffer()
        }

        switch elementName {
        case "abstract":
            inAbstract = true
        case "body":
            inBody = true
        case "sec":
            inSection = true
            sectionLevel += 1
        case "p":
            inParagraph = true
        case "italic", "i":
            appendText("*")
        case "bold", "b":
            appendText("**")
        case "sup":
            appendText("^")
        case "sub":
            appendText("_")
        case "xref":
            // Handle citations/references inline (only for bibliography refs)
            if attributeDict["ref-type"] == "bibr" {
                inBiblioRef = true
                appendText("[")
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        appendText(string)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        // Handle inline formatting closers before popping
        switch elementName {
        case "italic", "i":
            appendText("*")
        case "bold", "b":
            appendText("**")
        case "xref":
            if inBiblioRef {
                appendText("]")
                inBiblioRef = false
            }
        default:
            break
        }

        // Pop text buffer if this was a text-accumulating element
        let elementText: String
        if textAccumulatingElements.contains(elementName) {
            let isInline = inlineElements.contains(elementName)
            elementText = popTextBuffer(mergeWithParent: isInline)
        } else {
            elementText = currentText
        }

        let text = elementText.trimmingCharacters(in: .whitespacesAndNewlines)

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
                // For abstract, accumulate paragraphs
                if !abstract.isEmpty {
                    abstract += " "
                }
                abstract += text
            }
            inParagraph = false
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
