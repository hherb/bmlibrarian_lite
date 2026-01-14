# Phase 1: Full-Text Service & Model Extensions

This document details the implementation of the `FullTextService` actor and `Document` model extensions for full-text retrieval.

---

## Goals

1. Extend `Document` model to store full-text content
2. Create `FullTextService` actor with fallback chain
3. Implement Europe PMC XML retrieval and conversion
4. Implement Unpaywall PDF lookup
5. Implement DOI resolution fallback

---

## 1. Document Model Extensions

### File: `Sources/Models/Document.swift`

Add the following properties to the `Document` model:

```swift
// MARK: - Full Text

/// The full text content (markdown format for XML sources, nil for PDF-only).
var fullTextContent: String?

/// URL to the locally cached PDF file, if available.
var fullTextPDFPath: String?

/// Source of the full text (for display and debugging).
var fullTextSource: String?  // "europepmc", "unpaywall", "doi"

/// When the full text was fetched.
var fullTextFetchedAt: Date?

/// True if full text fetch was attempted but no source was available.
var fullTextUnavailable: Bool = false
```

### Computed Properties

```swift
/// Whether full text is available for this document.
var hasFullText: Bool {
    fullTextContent != nil || fullTextPDFPath != nil
}

/// Whether we've already tried to fetch full text (success or failure).
var fullTextAttempted: Bool {
    fullTextFetchedAt != nil || fullTextUnavailable
}

/// Display name for the full text source.
var fullTextSourceDisplay: String? {
    guard let source = fullTextSource else { return nil }
    switch source {
    case "europepmc": return "Europe PMC"
    case "unpaywall": return "Unpaywall"
    case "doi": return "Publisher"
    default: return source.capitalized
    }
}
```

---

## 2. Full-Text Source Enum

### File: `Sources/Models/FullTextSource.swift` (new file)

```swift
//
//  FullTextSource.swift
//  MedicalFactChecker
//
//  Represents the source of retrieved full text.
//

import Foundation

/// Source from which full text was retrieved.
enum FullTextSource: String, Codable {
    case europePMC = "europepmc"
    case unpaywall = "unpaywall"
    case doi = "doi"
    case cached = "cached"

    /// Human-readable display name.
    var displayName: String {
        switch self {
        case .europePMC: return "Europe PMC"
        case .unpaywall: return "Unpaywall"
        case .doi: return "Publisher"
        case .cached: return "Cached"
        }
    }

    /// Icon name for the source.
    var iconName: String {
        switch self {
        case .europePMC: return "building.columns"
        case .unpaywall: return "lock.open"
        case .doi: return "link"
        case .cached: return "arrow.down.circle"
        }
    }
}

/// Result of a full-text retrieval attempt.
struct FullTextResult {
    /// The content type retrieved.
    enum ContentType {
        case markdown(String)    // Europe PMC XML converted to markdown
        case pdfURL(URL)         // URL to downloadable PDF
        case webURL(URL)         // Fallback URL to open in browser
    }

    let content: ContentType
    let source: FullTextSource

    /// Whether this result can be displayed in-app.
    var canDisplayInApp: Bool {
        switch content {
        case .markdown, .pdfURL:
            return true
        case .webURL:
            return false
        }
    }
}
```

---

## 3. Full-Text Service

### File: `Sources/Services/FullTextService.swift` (new file)

```swift
//
//  FullTextService.swift
//  MedicalFactChecker
//
//  Service for retrieving full text with fallback chain.
//

import Foundation

/// Errors that can occur during full-text retrieval.
enum FullTextError: LocalizedError {
    case noIdentifiers
    case networkError(Error)
    case noFullTextAvailable
    case pdfDownloadFailed
    case xmlParseError(String)

    var errorDescription: String? {
        switch self {
        case .noIdentifiers:
            return "Document has no DOI or PMC ID for full-text lookup"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .noFullTextAvailable:
            return "No full text available from any source"
        case .pdfDownloadFailed:
            return "Failed to download PDF"
        case .xmlParseError(let reason):
            return "Failed to parse XML: \(reason)"
        }
    }
}

/// Service for retrieving full-text articles with fallback chain.
///
/// Fallback order:
/// 1. Europe PMC XML (preferred - machine-readable, high quality)
/// 2. Unpaywall PDF (open access PDFs)
/// 3. DOI resolution (opens in browser)
actor FullTextService {
    // MARK: - Configuration

    private let europePMCBaseURL = "https://www.ebi.ac.uk/europepmc/webservices/rest"
    private let unpaywallBaseURL = "https://api.unpaywall.org/v2"
    private let email: String
    private let session: URLSession

    // MARK: - Initialization

    init(email: String) {
        self.email = email

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120  // Longer for PDF downloads
        self.session = URLSession(configuration: config)
    }

    /// Create service from app settings.
    static func create(from settings: AppSettings) -> FullTextService {
        let email = settings.ncbiEmail.isEmpty ? "user@example.com" : settings.ncbiEmail
        return FullTextService(email: email)
    }

    // MARK: - Main Entry Point

    /// Attempt to retrieve full text for a document.
    ///
    /// Tries sources in order: Europe PMC XML → Unpaywall PDF → DOI website
    ///
    /// - Parameters:
    ///   - pmcId: PubMed Central ID (e.g., "PMC1234567")
    ///   - doi: Digital Object Identifier
    ///   - pmid: PubMed ID (for fallback URL)
    /// - Returns: Full text result with content and source
    /// - Throws: FullTextError if all sources fail
    func fetchFullText(
        pmcId: String?,
        doi: String?,
        pmid: String
    ) async throws -> FullTextResult {
        // Try Europe PMC first (best quality)
        if let pmcId = pmcId {
            do {
                let markdown = try await fetchEuropePMCXML(pmcId: pmcId)
                return FullTextResult(content: .markdown(markdown), source: .europePMC)
            } catch {
                print("[FullText] Europe PMC failed for \(pmcId): \(error)")
            }
        }

        // Try Unpaywall (open access PDFs)
        if let doi = doi {
            do {
                let pdfURL = try await fetchUnpaywallPDF(doi: doi)
                return FullTextResult(content: .pdfURL(pdfURL), source: .unpaywall)
            } catch {
                print("[FullText] Unpaywall failed for \(doi): \(error)")
            }
        }

        // Fallback to DOI or PubMed URL
        if let doi = doi, let url = URL(string: "https://doi.org/\(doi)") {
            return FullTextResult(content: .webURL(url), source: .doi)
        }

        // Final fallback: PubMed page
        if let url = URL(string: "https://pubmed.ncbi.nlm.nih.gov/\(pmid)/") {
            return FullTextResult(content: .webURL(url), source: .doi)
        }

        throw FullTextError.noFullTextAvailable
    }

    // MARK: - Europe PMC XML

    /// Fetch full-text XML from Europe PMC and convert to markdown.
    private func fetchEuropePMCXML(pmcId: String) async throws -> String {
        // Normalize PMC ID
        let normalizedId = pmcId.hasPrefix("PMC") ? pmcId : "PMC\(pmcId)"

        let url = URL(string: "\(europePMCBaseURL)/\(normalizedId)/fullTextXML")!
        var request = URLRequest(url: url)
        request.setValue("application/xml", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw FullTextError.networkError(URLError(.badServerResponse))
        }

        if httpResponse.statusCode == 404 {
            throw FullTextError.noFullTextAvailable
        }

        guard httpResponse.statusCode == 200 else {
            throw FullTextError.networkError(URLError(.badServerResponse))
        }

        // Parse XML and convert to markdown
        return try parseJATSXMLToMarkdown(data)
    }

    /// Parse JATS XML to markdown format.
    private func parseJATSXMLToMarkdown(_ data: Data) throws -> String {
        let parser = JATSXMLParser(data: data)
        return try parser.parseToMarkdown()
    }

    // MARK: - Unpaywall

    /// Fetch open access PDF URL from Unpaywall.
    private func fetchUnpaywallPDF(doi: String) async throws -> URL {
        guard let encodedDOI = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw FullTextError.noIdentifiers
        }

        let url = URL(string: "\(unpaywallBaseURL)/\(encodedDOI)?email=\(email)")!

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw FullTextError.noFullTextAvailable
        }

        // Parse Unpaywall response
        let result = try JSONDecoder().decode(UnpaywallResponse.self, from: data)

        // Try best OA location first, then any OA location
        if let bestOA = result.bestOaLocation,
           let urlString = bestOA.urlForPdf ?? bestOA.url,
           let pdfURL = URL(string: urlString) {
            return pdfURL
        }

        // Try other OA locations
        for location in result.oaLocations ?? [] {
            if let urlString = location.urlForPdf ?? location.url,
               let pdfURL = URL(string: urlString) {
                return pdfURL
            }
        }

        throw FullTextError.noFullTextAvailable
    }
}

// MARK: - Unpaywall Response Types

private struct UnpaywallResponse: Codable {
    let bestOaLocation: OALocation?
    let oaLocations: [OALocation]?

    enum CodingKeys: String, CodingKey {
        case bestOaLocation = "best_oa_location"
        case oaLocations = "oa_locations"
    }
}

private struct OALocation: Codable {
    let url: String?
    let urlForPdf: String?

    enum CodingKeys: String, CodingKey {
        case url
        case urlForPdf = "url_for_pdf"
    }
}
```

---

## 4. JATS XML Parser

### File: `Sources/Utilities/JATSXMLParser.swift` (new file)

```swift
//
//  JATSXMLParser.swift
//  MedicalFactChecker
//
//  Parser for JATS XML format used by Europe PMC.
//

import Foundation

/// Parser for converting JATS XML to markdown.
final class JATSXMLParser: NSObject, XMLParserDelegate {
    private let parser: XMLParser
    private var sections: [String] = []

    // State tracking
    private var currentElement = ""
    private var currentText = ""
    private var inBody = false
    private var inSection = false
    private var inAbstract = false
    private var inParagraph = false
    private var sectionLevel = 0

    // Metadata
    private var title = ""
    private var authors: [String] = []
    private var journal = ""
    private var year = ""
    private var abstract = ""

    // Current section content
    private var currentSectionTitle = ""
    private var currentSectionContent: [String] = []

    init(data: Data) {
        self.parser = XMLParser(data: data)
        super.init()
        parser.delegate = self
    }

    /// Parse XML and return markdown string.
    func parseToMarkdown() throws -> String {
        guard parser.parse() else {
            throw FullTextError.xmlParseError(parser.parserError?.localizedDescription ?? "Unknown error")
        }
        return buildMarkdown()
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
        case "surname", "given-names":
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
        case "italic":
            currentText += "*"
        case "bold":
            currentText += "**"
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
            authors.append(text)
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
                let prefix = String(repeating: "#", count: min(sectionLevel + 1, 6))
                if !currentSectionTitle.isEmpty {
                    sections.append("\(prefix) \(currentSectionTitle)")
                }
                sections.append(contentsOf: currentSectionContent)
                sections.append("")
            }
            currentSectionTitle = ""
            currentSectionContent = []
            sectionLevel = max(0, sectionLevel - 1)
            inSection = false
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
        case "italic":
            currentText += "*"
        case "bold":
            currentText += "**"
        default:
            break
        }
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
            let authorList = authors.prefix(3).joined(separator: ", ")
            let suffix = authors.count > 3 ? " et al." : ""
            lines.append("**Authors:** \(authorList)\(suffix)")
        }
        if !journal.isEmpty || !year.isEmpty {
            var meta: [String] = []
            if !journal.isEmpty { meta.append("*\(journal)*") }
            if !year.isEmpty { meta.append("(\(year))") }
            lines.append(meta.joined(separator: " "))
        }
        lines.append("")

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
```

---

## 5. Integration Points

### AppSettings Extension

Add to `AppSettings.swift`:

```swift
// Note: Reuse ncbiEmail for Unpaywall API (per user decision #3a)
// No new settings needed for this phase
```

### Constants (optional)

If needed, add to a constants file:

```swift
enum FullTextConstants {
    static let europePMCBaseURL = "https://www.ebi.ac.uk/europepmc/webservices/rest"
    static let unpaywallBaseURL = "https://api.unpaywall.org/v2"
    static let requestTimeoutSeconds: TimeInterval = 30
    static let downloadTimeoutSeconds: TimeInterval = 120
}
```

---

## 6. Testing Checklist

### Unit Tests

- [ ] `FullTextService.fetchFullText` with valid PMC ID returns markdown
- [ ] `FullTextService.fetchFullText` with valid DOI returns PDF URL
- [ ] `FullTextService.fetchFullText` with no identifiers returns web URL
- [ ] `JATSXMLParser` correctly extracts title, abstract, and body
- [ ] `JATSXMLParser` handles nested sections correctly
- [ ] `JATSXMLParser` preserves italic/bold formatting
- [ ] Unpaywall response parsing handles missing fields

### Integration Tests

- [ ] Europe PMC returns XML for known open-access PMC ID
- [ ] Unpaywall returns PDF URL for known open-access DOI
- [ ] Fallback chain progresses correctly when sources fail

### Test PMC IDs

```
PMC7614751 - Known Europe PMC article with full text
PMC10767826 - Europe PMC 2023 paper (has full text)
```

### Test DOIs

```
10.1371/journal.pone.0303005 - PLOS ONE (open access)
10.1093/nar/gkad894 - NAR Database issue (open access)
```

---

## 7. Error Handling

| Error | User Message | Recovery |
|-------|--------------|----------|
| No identifiers | "This document has no DOI or PMC ID" | Show PubMed link |
| Network error | "Network error. Please try again." | Offer retry button |
| No full text | "Full text not available" | Show "Open in Browser" |
| XML parse error | "Failed to process document" | Fall through to Unpaywall |
| PDF download fail | "Failed to download PDF" | Show web URL |

---

## 8. Files to Create/Modify

### New Files
- `Sources/Models/FullTextSource.swift`
- `Sources/Services/FullTextService.swift`
- `Sources/Utilities/JATSXMLParser.swift`

### Modified Files
- `Sources/Models/Document.swift` (add full-text properties)

---

## 9. Estimated Effort

| Task | Complexity | Notes |
|------|------------|-------|
| Document model extensions | Low | Simple property additions |
| FullTextSource enum | Low | Straightforward enum |
| FullTextService actor | Medium | Multiple API integrations |
| JATSXMLParser | Medium | XML parsing with state machine |
| Unit tests | Medium | Mock network responses |

**Total estimated complexity: Medium**

---

## Next Phase

After completing this phase, proceed to **Phase 2: Full-Text UI** (`02-fulltext-ui.md`) to implement the user interface components.
