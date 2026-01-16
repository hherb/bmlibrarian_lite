# Europe PMC and PubMed API Integration Guide

This document captures lessons learned from implementing Europe PMC and PubMed integrations in the macOS app. Use this as a reference when implementing the same functionality in Kotlin (Android) or Python (desktop).

## Table of Contents

1. [Search API Overview](#search-api-overview)
2. [Query Formatting](#query-formatting)
3. [Pagination](#pagination)
4. [Full Text Retrieval](#full-text-retrieval)
5. [JATS XML Parsing](#jats-xml-parsing)
6. [Figure/Image Handling](#figureimage-handling)
7. [Table Extraction](#table-extraction)
8. [Reference Parsing](#reference-parsing)
9. [Error Handling](#error-handling)
10. [Rate Limiting](#rate-limiting)

---

## Search API Overview

### Europe PMC REST API

**Base URL:** `https://www.ebi.ac.uk/europepmc/webservices/rest`

**Key Endpoints:**
- Search: `GET /search?query={query}&format={json|xml}&pageSize={n}&cursorMark={cursor}`
- Full Text XML: `GET /{pmcId}/fullTextXML`

**No API key required** - Europe PMC is free and open.

### PubMed E-utilities

**Base URL:** `https://eutils.ncbi.nlm.nih.gov/entrez/eutils/`

**Key Endpoints:**
- Search: `esearch.fcgi?db=pubmed&term={query}&retmax={n}&retstart={offset}`
- Fetch: `efetch.fcgi?db=pubmed&id={pmids}&rettype=xml`

**Recommended:** Include `email` parameter for identification. API key optional but increases rate limits.

---

## Query Formatting

### Europe PMC Query Syntax

Europe PMC uses a Lucene-like query syntax:

```
# Field searches
TITLE:"machine learning"
TITLE_ABS:"artificial intelligence"
AUTH:"Smith J"
JOURNAL:"Nature"

# Boolean operators (uppercase)
diabetes AND treatment
cancer OR tumor
heart NOT failure

# Filters
HAS_ABSTRACT:Y           # Only articles with abstracts
SRC:MED                  # PubMed source only
SRC:PPR                  # Preprints only
NOT SRC:PPR              # Exclude preprints

# Date filters
FIRST_PDATE:[2020 TO 2024]
PUB_YEAR:2023
```

**Important:** The `RELEVANCE desc` sort parameter was **deprecated in late 2025**. Europe PMC now defaults to relevance sorting - do NOT include sort parameters.

### Building Queries

```swift
// Always add these filters for quality results:
var query = userQuery
if !includePreprints {
    query += " NOT SRC:PPR"
}
if !query.uppercased().contains("HAS_ABSTRACT") {
    query += " AND HAS_ABSTRACT:Y"
}
```

---

## Pagination

### Europe PMC: Cursor-Based Pagination

Europe PMC uses cursor-based pagination which is more reliable for large result sets:

```json
// Request
GET /search?query=...&pageSize=25&cursorMark=*

// Response includes:
{
  "hitCount": 12345,
  "nextCursorMark": "AoJ4c2NvcmUBFjEuMjM0NTY3ODkwMTIzNDU2Nzg5MA==",
  "resultList": { "result": [...] }
}
```

**Key points:**
- Initial request uses `cursorMark=*`
- Subsequent requests use `nextCursorMark` from previous response
- When `nextCursorMark` equals the current cursor or is null, no more results
- Maximum of ~10,000 results accessible via pagination

### PubMed: Offset-Based Pagination

```
GET esearch.fcgi?db=pubmed&term=...&retmax=100&retstart=0
GET esearch.fcgi?db=pubmed&term=...&retmax=100&retstart=100
```

**Limitation:** Maximum offset is 9999.

---

## Full Text Retrieval

### Europe PMC Full Text XML

**Endpoint:** `https://www.ebi.ac.uk/europepmc/webservices/rest/{pmcId}/fullTextXML`

```swift
// Normalize PMC ID (ensure "PMC" prefix)
let normalizedId = pmcId.hasPrefix("PMC") ? pmcId : "PMC\(pmcId)"
let url = "https://www.ebi.ac.uk/europepmc/webservices/rest/\(normalizedId)/fullTextXML"
```

**Response:** JATS XML (Journal Article Tag Suite) format.

### Fallback Chain

Implement a fallback chain for full text retrieval:

1. **Europe PMC XML** - Best quality, machine-readable
2. **Unpaywall PDF** - Open access PDFs via `https://api.unpaywall.org/v2/{doi}?email={email}`
3. **DOI Resolution** - Open `https://doi.org/{doi}` in browser

---

## JATS XML Parsing

### Document Structure

```xml
<article>
  <front>
    <journal-meta>...</journal-meta>
    <article-meta>
      <article-id pub-id-type="pmcid">4255432</article-id>
      <article-id pub-id-type="pmid">25427578</article-id>
      <article-id pub-id-type="doi">10.1186/s13023-014-0170-0</article-id>
      <title-group><article-title>...</article-title></title-group>
      <contrib-group>...</contrib-group>
      <abstract>...</abstract>
    </article-meta>
  </front>
  <body>
    <sec>...</sec>
  </body>
  <back>
    <ref-list>...</ref-list>
  </back>
</article>
```

### Article ID Extraction

**Critical:** Use the `pub-id-type` attribute to classify IDs:

```swift
case "article-id":
    let idType = attributes["pub-id-type"]
    switch idType?.lowercased() {
    case "doi":
        doi = text
    case "pmc", "pmcid":
        pmcId = text
    case "pmid", "pubmed":
        pmid = text
    default:
        // Fall back to pattern matching
        classifyByPattern(text)
    }
```

**Pattern matching fallback:**
- Starts with `10.` → DOI
- Starts with `PMC` → PMC ID
- All numeric, 7+ digits → PMID

### Abstract Parsing

Europe PMC returns structured abstracts with HTML tags:

```xml
<abstract>
  <h4>Background</h4>
  <p>Background text...</p>
  <h4>Methods</h4>
  <p>Methods text...</p>
</abstract>
```

**Convert to markdown:**
```swift
// Convert <h4>Section</h4> to **Section:**
let sectionPattern = "<h4>([^<]+)</h4>"
result = regex.replace(in: result, with: "\n\n**$1:** ")

// Convert <p> tags to paragraph breaks
result = result.replacingOccurrences(of: "<p>", with: "\n\n")
result = result.replacingOccurrences(of: "</p>", with: "")
```

---

## Figure/Image Handling

### XML Structure

```xml
<fig id="Fig1">
  <label>Figure 1</label>
  <caption><p>Caption text...</p></caption>
  <graphic xlink:href="13023_2014_170_Fig1_HTML" id="MO1"/>
</fig>
```

### URL Construction

**Critical lesson:** The `xlink:href` attribute contains the filename **WITHOUT the extension**.

**Working URL pattern:** `https://europepmc.org/articles/PMC{id}/bin/{filename}.{ext}`

**Non-working URL patterns:**
- `https://www.ncbi.nlm.nih.gov/pmc/articles/PMC{id}/bin/{filename}` → Returns 403 Forbidden
- `https://pmc.ncbi.nlm.nih.gov/articles/PMC{id}/bin/{filename}` → Returns 403 Forbidden

### Extension Handling

Since the XML doesn't include extensions, try multiple formats:

```swift
let extensions = [".jpg", ".gif", ".png"]

// Build URLs to try
var urlsToTry = [baseURL + ".jpg"]  // Default to jpg
for ext in extensions {
    if !urlsToTry.contains(baseURL + ext) {
        urlsToTry.append(baseURL + ext)
    }
}

// Try each until one succeeds with HTTP 200
for url in urlsToTry {
    let response = try await fetch(url)
    if response.statusCode == 200 {
        return response.data
    }
}
```

### Code Example

```swift
private func buildFigureURL(_ path: String) -> String {
    // If already a full URL, return as-is
    if path.hasPrefix("http://") || path.hasPrefix("https://") {
        return path
    }

    // Check if path already has an extension
    let hasExtension = [".gif", ".jpg", ".jpeg", ".png", ".svg"]
        .contains { path.lowercased().hasSuffix($0) }

    // Use europepmc.org (NOT ncbi.nlm.nih.gov)
    if !pmcId.isEmpty {
        let normalizedPMCId = pmcId.hasPrefix("PMC") ? pmcId : "PMC\(pmcId)"
        let baseURL = "https://europepmc.org/articles/\(normalizedPMCId)/bin/\(path)"

        // Add .jpg as default if no extension
        if !hasExtension {
            return baseURL + ".jpg"
        }
        return baseURL
    }

    return path
}
```

---

## Table Extraction

### XML Structure Variations

JATS tables can have several different structures. Here are the main patterns encountered:

**Standard structure with `<th>` in `<thead>`:**
```xml
<table-wrap id="Tab1">
  <label>Table 1</label>
  <caption><p>Table caption...</p></caption>
  <table frame="hsides" rules="groups">
    <thead>
      <tr>
        <th>Column 1</th>
        <th>Column 2</th>
      </tr>
    </thead>
    <tbody>
      <tr>
        <td>Data 1</td>
        <td>Data 2</td>
      </tr>
    </tbody>
  </table>
</table-wrap>
```

**Non-standard: `<td>` inside `<thead>` (seen in PMC7542412):**
```xml
<thead>
  <tr valign="top">
    <td colspan="2" rowspan="1">Characteristic</td>
    <td rowspan="1" colspan="1">Description</td>
  </tr>
</thead>
```

**Complex cells with nested lists (seen in PMC11817335):**
```xml
<th>Outcomes<list list-type="order">
  <list-item><p>Sleep</p></list-item>
  <list-item><p>Others</p></list-item>
</list></th>
```

**Tables without `<thead>`/`<tbody>` wrappers:**
```xml
<table>
  <tr><th>Header 1</th><th>Header 2</th></tr>
  <tr><td>Data 1</td><td>Data 2</td></tr>
</table>
```

### Common Problems and Solutions

#### Problem 1: Tables using `<td>` inside `<thead>`

Some JATS documents use `<td>` elements instead of `<th>` within the `<thead>` section. If you only check for `<th>` to identify header rows, these headers will be placed in the body section.

**Solution:** Mark rows as headers if they're inside `<thead>` regardless of whether they contain `<th>` or `<td>`:

```swift
mutating func startCell(isHeader: Bool = false, colspan: Int = 1) {
    inCell = true
    // Mark as header row if explicitly a <th> cell OR if we're inside <thead>
    if isHeader || inHeader {
        currentRowHasHeaderCells = true
    }
}
```

#### Problem 2: Colspan attributes not handled

Tables with merged cells (`colspan` attributes) will have misaligned columns if colspan isn't handled.

**Solution:** Track colspan and add empty cells to fill the span:

```swift
// Track colspan for current cell
var currentColspan = 1

mutating func startCell(isHeader: Bool = false, colspan: Int = 1) {
    inCell = true
    currentColspan = max(1, colspan)
    // ...
}

mutating func endCell() {
    if inCell {
        currentRow.append(normalizedContent)

        // Add empty cells for colspan > 1
        for _ in 1..<currentColspan {
            currentRow.append("")
        }
    }
    currentColspan = 1
    // ...
}
```

Parse the colspan attribute when starting a cell:
```swift
case "th":
    let colspan = Int(attributeDict["colspan"] ?? "1") ?? 1
    currentTable?.startCell(isHeader: true, colspan: colspan)
case "td":
    let colspan = Int(attributeDict["colspan"] ?? "1") ?? 1
    currentTable?.startCell(isHeader: false, colspan: colspan)
```

#### Problem 3: Nested lists inside table cells

Cell content can include `<list>` elements with `<list-item>` children. Without special handling, text from all nested elements concatenates without separation (e.g., "OutcomesSleepOthers" instead of "Outcomes; 1. Sleep; 2. Others").

**Solution:** Track list state within cells and add markers:

```swift
// List tracking for proper formatting
var inList = false
var listType: ListType = .unordered
var listItemNumber = 0
var pendingListItem = false

enum ListType { case ordered, unordered }

mutating func startList(ordered: Bool) {
    if inCell {
        inList = true
        listType = ordered ? .ordered : .unordered
        listItemNumber = 0
    }
}

mutating func startListItem() {
    if inCell && inList {
        listItemNumber += 1
        pendingListItem = true
    }
}

mutating func appendCellText(_ text: String) {
    if inCell {
        let normalized = text.replacingOccurrences(of: "\n", with: " ")

        // Add list marker when we hit content after starting a list item
        if pendingListItem && !normalized.trimmingCharacters(in: .whitespaces).isEmpty {
            if !currentCellText.trimmingCharacters(in: .whitespaces).isEmpty {
                currentCellText += "; "  // Separator between items
            }
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
```

Handle list elements in the parser:
```swift
case "list":
    if inTableWrap {
        let listTypeAttr = attributeDict["list-type"] ?? ""
        let isOrdered = listTypeAttr.hasPrefix("order")  // "order" or "ordered"
        currentTable?.startList(ordered: isOrdered)
    }
case "list-item":
    if inTableWrap {
        currentTable?.startListItem()
    }
```

#### Problem 4: Tables without `<thead>` wrapper

Some tables have `<th>` cells but no `<thead>` element wrapping them. The first row with `<th>` cells should be treated as a header.

**Solution:** Track if the current row contains any `<th>` cells:

```swift
var currentRowHasHeaderCells = false

mutating func startRow() {
    currentRow = []
    currentRowHasHeaderCells = false
}

mutating func endRow() {
    if inRow && !currentRow.isEmpty {
        // If in explicit <thead> OR row has <th> cells and we haven't started <tbody> yet
        if inHeader || (currentRowHasHeaderCells && !inBody && headerRows.isEmpty) {
            headerRows.append(currentRow)
        } else {
            bodyRows.append(currentRow)
        }
    }
    currentRowHasHeaderCells = false
}
```

### Complete TableBuilder Example

```swift
struct TableBuilder {
    var headerRows: [[String]] = []
    var bodyRows: [[String]] = []
    var currentRow: [String] = []
    var currentCellText = ""
    var inHeader = false
    var inBody = false
    var inRow = false
    var inCell = false

    // Track header cells without <thead> wrapper
    var currentRowHasHeaderCells = false

    // Track colspan
    var currentColspan = 1

    // List tracking for nested lists in cells
    var inList = false
    var listType: ListType = .unordered
    var listItemNumber = 0
    var pendingListItem = false

    enum ListType { case ordered, unordered }

    mutating func startHeader() { inHeader = true; inBody = false }
    mutating func endHeader() { inHeader = false }
    mutating func startBody() { inBody = true; inHeader = false }
    mutating func endBody() { inBody = false }

    mutating func startRow() {
        inRow = true
        currentRow = []
        currentRowHasHeaderCells = false
    }

    mutating func endRow() {
        if inRow && !currentRow.isEmpty {
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
        if isHeader || inHeader {
            currentRowHasHeaderCells = true
        }
    }

    mutating func endCell() {
        if inCell {
            let normalized = currentCellText
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
                .replacingOccurrences(of: "|", with: "\\|")
            currentRow.append(normalized)

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
        if inCell { inList = false }
    }

    mutating func startListItem() {
        if inCell && inList {
            listItemNumber += 1
            pendingListItem = true
        }
    }

    mutating func endListItem() {
        if inCell { pendingListItem = false }
    }

    mutating func appendCellText(_ text: String) {
        if inCell {
            let normalized = text.replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")

            if pendingListItem && !normalized.trimmingCharacters(in: .whitespaces).isEmpty {
                if !currentCellText.trimmingCharacters(in: .whitespaces).isEmpty {
                    currentCellText += "; "
                }
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
}
```

### HTML vs Markdown Output

For complex tables with colspan/rowspan or nested content, **HTML rendering is recommended** over markdown. Markdown tables don't support:
- Cell spanning (colspan/rowspan)
- Nested lists or complex formatting within cells
- Multiple header rows

Consider generating both formats and preferring HTML in the viewer:

```swift
func parseToHTML() throws -> String {
    // Parse to HTML for better table rendering
}

func parseToMarkdown() throws -> String {
    // Fallback for simpler display contexts
}
```

Use WKWebView or similar HTML renderer for displaying the content with proper table support.

---

## Reference Parsing

### XML Structure

```xml
<ref id="CR1">
  <label>1</label>
  <element-citation publication-type="journal">
    <person-group person-group-type="author">
      <name><surname>Smith</surname><given-names>John</given-names></name>
      <name><surname>Doe</surname><given-names>Jane</given-names></name>
    </person-group>
    <article-title>Article title here</article-title>
    <source>Journal Name</source>
    <year>2023</year>
    <volume>45</volume>
    <issue>3</issue>
    <fpage>123</fpage>
    <lpage>145</lpage>
    <pub-id pub-id-type="doi">10.1234/example</pub-id>
    <pub-id pub-id-type="pmid">12345678</pub-id>
  </element-citation>
</ref>
```

### Parsing Strategy

Track author names across `<name>` elements within `<person-group>`:

```swift
struct ReferenceBuilder {
    var authors: [String] = []
    var currentAuthorSurname = ""
    var currentAuthorGivenNames = ""

    mutating func finishCurrentAuthor() {
        if !currentAuthorSurname.isEmpty {
            let name = currentAuthorGivenNames.isEmpty
                ? currentAuthorSurname
                : "\(currentAuthorGivenNames) \(currentAuthorSurname)"
            authors.append(name)
            currentAuthorSurname = ""
            currentAuthorGivenNames = ""
        }
    }
}

// Call finishCurrentAuthor() when closing </name> element
```

### Citation Formatting

```swift
var formattedCitation: String {
    var parts: [String] = []

    // Authors (et al. for >3 authors)
    if authors.count <= 3 {
        parts.append(authors.joined(separator: ", "))
    } else {
        parts.append("\(authors[0]), \(authors[1]), et al.")
    }

    // Article title
    if !articleTitle.isEmpty { parts.append(articleTitle) }

    // Journal (italicized in markdown)
    if !source.isEmpty { parts.append("*\(source)*") }

    // Year
    if !year.isEmpty { parts.append("(\(year))") }

    // Volume, issue, pages
    var volumeInfo = volume
    if !issue.isEmpty { volumeInfo += "(\(issue))" }
    if !firstPage.isEmpty {
        volumeInfo += ":\(firstPage)"
        if !lastPage.isEmpty { volumeInfo += "-\(lastPage)" }
    }
    if !volumeInfo.isEmpty { parts.append(volumeInfo) }

    // DOI
    if !doi.isEmpty { parts.append("doi:\(doi)") }

    return parts.joined(separator: ". ")
}
```

---

## Error Handling

### Retryable Errors

Implement exponential backoff with retry for these HTTP status codes:

| Code | Meaning | Action |
|------|---------|--------|
| 429 | Rate Limited | Retry with backoff |
| 500 | Internal Server Error | Retry with backoff |
| 502 | Bad Gateway | Retry with backoff |
| 503 | Service Unavailable | Retry with backoff |
| 504 | Gateway Timeout | Retry with backoff |

### Non-Retryable Errors

| Code | Meaning | Action |
|------|---------|--------|
| 400 | Bad Request | Fix query, don't retry |
| 404 | Not Found | No full text available |
| 401/403 | Unauthorized | Check credentials |

### Retry Configuration

```swift
// For server errors, use aggressive retry
let serverErrorConfig = RetryConfiguration(
    maxAttempts: 5,
    initialDelay: 5.0,      // seconds
    maxDelay: 60.0,         // seconds
    backoffMultiplier: 2.0,
    jitterFactor: 0.2       // ±20% randomization
)

// Retry sequence: 5s → 10s → 20s → 40s → 60s
```

### Implementing Retryable Errors

```swift
protocol RetryableError: Error {
    var isRetryable: Bool { get }
}

enum EuropePMCError: Error, RetryableError {
    case searchFailed(statusCode: Int)
    case rateLimited
    case parseError(String)

    static let retryableStatusCodes: Set<Int> = [429, 500, 502, 503, 504]

    var isRetryable: Bool {
        switch self {
        case .searchFailed(let statusCode):
            return Self.retryableStatusCodes.contains(statusCode)
        case .rateLimited:
            return true
        case .parseError:
            return false
        }
    }
}
```

---

## Rate Limiting

### Europe PMC Limits

- No official rate limit documented
- Recommended: 10 requests/second maximum
- Use cursor pagination to minimize requests

### PubMed E-utilities Limits

- Without API key: 3 requests/second
- With API key: 10 requests/second
- Register for API key at: https://www.ncbi.nlm.nih.gov/account/

### Best Practices

1. **Add delays between requests:** 100-200ms minimum
2. **Use batch fetching:** Fetch multiple PMIDs in one efetch call
3. **Cache results:** Store fetched metadata and full text locally
4. **Implement exponential backoff:** For 429/5xx errors
5. **Don't retry indefinitely:** Cap at 5 attempts maximum

---

## JSON Response Structure

### Europe PMC Search Response

```json
{
  "version": "6.7",
  "hitCount": 12345,
  "nextCursorMark": "...",
  "resultList": {
    "result": [
      {
        "id": "25427578",
        "source": "MED",
        "pmid": "25427578",
        "pmcid": "PMC4255432",
        "doi": "10.1186/s13023-014-0170-0",
        "title": "Article title...",
        "authorString": "Bell SA, Tudur Smith C.",
        "authorList": {
          "author": [
            {"fullName": "Bell SA", "firstName": "Stuart A", "lastName": "Bell"}
          ]
        },
        "journalTitle": "Orphanet Journal of Rare Diseases",
        "journalInfo": {
          "journal": {
            "title": "Orphanet Journal of Rare Diseases",
            "medlineAbbreviation": "Orphanet J Rare Dis"
          }
        },
        "pubYear": "2014",
        "firstPublicationDate": "2014-11-26",
        "abstractText": "Abstract with possible <h4>section</h4> tags...",
        "isOpenAccess": "Y",
        "inPMC": "Y",
        "hasPDF": "Y"
      }
    ]
  }
}
```

### Handling Missing Fields

**Important:** The `resultList.result` array may be `null` or missing entirely when no results are found:

```swift
struct EPMCResultList: Codable {
    let result: [EPMCResult]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Handle null or missing result array
        result = try container.decodeIfPresent([EPMCResult].self, forKey: .result) ?? []
    }
}
```

---

## Quick Reference

### URLs

| Service | URL |
|---------|-----|
| Europe PMC Search | `https://www.ebi.ac.uk/europepmc/webservices/rest/search` |
| Europe PMC Full Text | `https://www.ebi.ac.uk/europepmc/webservices/rest/{pmcId}/fullTextXML` |
| Europe PMC Figures | `https://europepmc.org/articles/PMC{id}/bin/{filename}.{ext}` |
| PubMed Search | `https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi` |
| PubMed Fetch | `https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi` |
| Unpaywall | `https://api.unpaywall.org/v2/{doi}?email={email}` |
| DOI Resolution | `https://doi.org/{doi}` |

### Common Pitfalls

1. **Don't use NCBI URLs for figures** - Returns 403, use europepmc.org instead
2. **Don't include sort parameters** - Europe PMC deprecated them in late 2025
3. **Handle missing JSON fields** - `resultList.result` can be null
4. **Add file extensions to figure URLs** - XML `xlink:href` doesn't include them
5. **Use `pub-id-type` attribute** - Don't rely solely on pattern matching for IDs
6. **Track table header vs body state** - Otherwise all rows become body rows
7. **Finish authors on `</name>` close** - Not on `</person-group>` close
8. **Implement retry for 5xx errors** - Europe PMC can return 503 during maintenance
9. **Handle `<td>` inside `<thead>`** - Some documents use `<td>` instead of `<th>` for headers
10. **Handle colspan attributes** - Merged cells need empty placeholders to maintain column alignment
11. **Handle nested `<list>` elements in cells** - Lists inside table cells need proper formatting with separators
12. **Prefer HTML for complex tables** - Markdown tables can't represent colspan/rowspan or nested content
13. **Handle tables without `<thead>` wrapper** - First row with `<th>` cells should be detected as header
