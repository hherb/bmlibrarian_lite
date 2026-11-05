# Europe PMC and PubMed API Integration Guide

This document captures lessons learned from implementing Europe PMC and PubMed integrations, first in the macOS app (the Swift snippets come from it). Use it as a reference when implementing the same functionality on any platform. Where a rule below is enforced, the Python desktop (`src/bmlibrarian_lite/`) is the reference implementation.

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
11. [JSON Response Structure](#json-response-structure)
12. [Quick Reference](#quick-reference)

---

## Search API Overview

### Europe PMC REST API

**Base URL:** `https://www.ebi.ac.uk/europepmc/webservices/rest`

**Key Endpoints:**
- Search: `GET /search?query={query}&format={json|xml}&pageSize={n}&cursorMark={cursor}`
- Full Text XML: `GET /{pmcId}/fullTextXML` (a preprint, which has no PMC ID, is asked under its `PPR` record ID; Python: `europepmc.fulltext_accession`)

Python's search sends `format=json`, `resultType=core` (`EUROPEPMC_RESULT_TYPE`)
and pages of 100 (`EUROPEPMC_SEARCH_PAGE_SIZE`), and appends
`AND HAS_ABSTRACT:Y` and, unless preprints are asked for, `AND (NOT SRC:PPR)`
(`EuropePMCClient._build_search_query`).

**No API key required** - Europe PMC is free and open.

### PubMed E-utilities

**Base URL:** `https://eutils.ncbi.nlm.nih.gov/entrez/eutils/`

**Key Endpoints** (parameters shown are sent as a POST body; see below):
- Search: `esearch.fcgi` with `db=pubmed&term={query}&retmax={n}&retstart={offset}`
- Search: Python also sends `retmode=json`; above 1,000 results
  (`HISTORY_SERVER_THRESHOLD`) it asks with `usehistory=y` and lists the PMIDs
  through `WebEnv`/`query_key`
- Fetch: `efetch.fcgi` with `db=pubmed&id={pmids}&retmode=xml`, up to 200 PMIDs
  per request (`DEFAULT_BATCH_SIZE`)

**Recommended:** Include `email` parameter for identification. API key optional but increases rate limits.

**Never put the API key in a URL.** Send E-utilities parameters as a
form-encoded POST body, which NCBI accepts on `esearch` and `efetch`,
history-server (`WebEnv`/`query_key`) requests and `api_key` included. A query
string is part of the URL, and a URL is what HTTP error text
(`requests.HTTPError`, `ConnectionError`, `URLError`'s `userInfo`), HTTP
logging (urllib3 at DEBUG, OkHttp's `HttpLoggingInterceptor`) and any code
that logs the request URL itself print. In Python a routine 429 carried the key
into batch transparency exports (#196); BioMedLit's `PubMedService` logged the
URL as a public value in release builds, and Android's debug builds wrote it to
logcat (#243).

**Treat a redirect as a failed request; never follow it.** A 307 or 308
re-sends the POST body, key included, to whatever host it names; a 301, 302 or
303 re-sends the request as a GET without its parameters, which NCBI answers
as a search for nothing. Not even a redirect to an NCBI host is followed: these
endpoints never legitimately redirect, following a 301, 302 or 303 can never
give a correct answer, and a same-host redirect can still downgrade to
`http://` and carry the key in cleartext.

**Never log, persist or display the body of a failed E-utilities answer.**
NCBI's HTTP 400 for a bad key repeats the key in its body (checked live). Every
port builds its errors from the status code, and at most the reason phrase.

Where each platform enforces these rules, and the test that pins them:

| Platform | POST body | Redirect refused | Test |
|----------|-----------|------------------|------|
| Python | `post(data=…)` in both NCBI clients (`self._session.post` in `PubMedSearchClient`, on a session with `mount_politely`; `session.post` in the transparency analyzer's `PubMedClient`) | `allow_redirects=False`, raise on `is_redirect` | `tests/test_ncbi_api_key_confinement.py` |
| Swift | `EutilsRequest.post` | `RedirectRefusingTaskDelegate`, passed per task | `PubMedCredentialConfinementTests` |
| Android | `@FormUrlEncoded` + `@Field` on `PubMedApi` | `pubMedHttpClient`: `followRedirects(false)` on a client derived for PubMed only, since Unpaywall and PDF links need redirects | `PubMedCredentialConfinementTest` |

On Android, `pubMedHttpClient` also drops Retrofit's `Invocation` tag before any
interceptor runs. The tag holds the call's arguments, the key among them, and
OkHttp's `Request.toString()` prints it. On Android the key is read by
`PubMedService` itself, from `NcbiCredentialSource`, never passed by callers:
every workflow call site used to omit it, so the saved key never reached NCBI. A
400 is a failed search of kind `http_status` 400, whose advice tells the user to
check a saved key (#252).

The ports differ in a few places. Python is the reference, so align a port with
it, or record the difference here:

| Case | Python | Swift | Android |
|------|--------|-------|---------|
| Which 3xx is refused | 301, 302, 303, 307, 308 with a `Location` header (`is_redirect`) | every 3xx | every 3xx |
| Refused redirect retried? | yes, like every HTTP error in `_make_request` | no (`redirect_refused` is not retryable) | no (`SourceRequestException`, `redirect_refused`) |
| A 429 that outlasts the retries | `SourceRequestError` (`http_status`, 429) | as Python (`SourceRequestError`) | `SourceRequestException` (`http_status`, 429) |
| What counts as "no key" | an empty string | an empty string | a blank string, whitespace included |
| esearch answer without a usable `count` | `SourceRequestError` (`malformed_response`); an `ERROR` field is `service_error` | as Python | as Python |
| A failed search in a search of both providers | proceeds on the other provider and records a shortfall | as Python | as Python |
| Retries | each HTTP request (`_make_request`) | each HTTP request (`send`, `requestPage`) | each request with the reading of its answer: esearch and efetch on their own, so a failed fetch does not search again |
| A cancelled request | not applicable (synchronous) | `CancellationError`, never a shortfall: the user's doing, not the source's | the coroutine's cancellation |

**A failed source is not an empty one.** What counts as a failed request, what
a search does with one, and how the reader is told are specified in
`doc/cross_platform/search_failure_reporting.md`.

### PMIDs Sent to Either API

**Read a caller's PMID once, and send only canonical digits.** Europe PMC's
`ext_id:{pmid} src:med` query finds nothing for a padded `0033301246` where
`33301246` finds the paper, so a padded PMID read as "Europe PMC holds no
record"; and nothing required digits, so `"1 OR 2"` widened the query past its
`src:med` guard (bmlib#470, bmlib#472, bmlib#478). Python's
`identifiers.canonical_pmid` strips whitespace and leading zeros, takes ASCII
digits only (not all zeros), reads `PMC` plus digits as a PMC ID given as the
PMID, and refuses anything else; `read_caller_ids` logs a refused value and
goes on as though no PMID had been given. The rules are shared through
`doc/cross_platform/fulltext_parity/pmid_canonical.json`.

**Take a record's identifiers from the record asked about.** An efetch
`PubmedArticle` carries its own IDs at `PubmedData/ArticleIdList`, but every
cited paper in `PubmedData/ReferenceList` has an `ArticleIdList` too, so a
`.//ArticleId` search can return a cited paper's PMC ID and DOI (bmlib#474).
`pubmed.record_ids.own_article_ids` reads the fixed path only, and
`record_for_pmid` selects the record by its own `MedlineCitation/PMID`,
compared without leading zeros, never by position: efetch answers
`id=0033301246` with `<PMID>33301246</PMID>`.

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
- When `nextCursorMark` equals the current cursor, is null, or is `*`, no more
  results; a page holding no result ends the cursor too
- **No offset cap.** The cursor ends only once every hit was sent (checked live
  2026-09-15), so a search reaching the end before `hitCount` records arrived
  has lost the rest — it is not a cap being hit. An earlier note here claimed a
  ~10,000 limit; it did not survive checking, and reading it as one would
  report every long search as incomplete.
- An **unknown or expired `cursorMark`** answers HTTP 200 with only a version
  field, `{"version":"6.9"}` (checked live 2026-09-14): no `hitCount`, no
  `resultList`. That is an answer that cannot be read, not a search that matched
  nothing.

### PubMed: Offset-Based Pagination

```
POST esearch.fcgi   body: db=pubmed&term=...&retmax=100&retstart=0
POST esearch.fcgi   body: db=pubmed&term=...&retmax=100&retstart=100
```

**Limitation:** PubMed lists only the first 9,999 records of a search, so
`retstart` can be at most 9998 (checked live 2026-09-15: `retstart=9900&retmax=100`
lists 99 PMIDs, and `retstart=9999` answers with an `ERROR`). A page counted
against 10,000 reads its honest last page as incomplete.

**Advance by the PMIDs consumed, not the articles parsed.** efetch returns only
`PubmedArticle` records as articles, so a batch holding a `PubmedBookArticle`
(a StatPearls chapter, say) yields fewer articles than PMIDs. Advancing by the
article count re-requests PMIDs already fetched, and a last batch that parsed to
nothing is requested again on every "fetch more". BioMedLit's `SearchResult`
reports `nextOffset` as the position after the PMIDs consumed, and `nil` when
there is no next page (the last match, the offset cap, or no usable count).
Android's `PubMedSearchResult.nextOffset` is `offset + max(expected, listed)`,
where `expected` is what the page should have listed,
`min(batch, count − offset, 9999 − offset)`: PMIDs a page left unlisted are
recorded as missing rather than asked for again.

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

**Only open-access text is served, and a closed-access article is a 500, not
a 404** (#432; steady on 2026-09-28 and 2026-09-30). Being held (`inPMC` or
`inEPMC` in the search result) is not enough. Ask only when the record does
not state that Europe PMC lacks the article (`inPMC=N` and `inEPMC=N`) and
does not state `isOpenAccess=N` (Python: `europepmc.offers_fulltext_xml`).
A missing or unreadable flag is not a stated no, so the fetch is made.

**Swift and Android do not apply this rule yet: they ask `fullTextXML` for
every accession (#450).** In the apps a closed-access article therefore
spends every retry on the 500 and can never reach an established absence.

Measured with `scripts/europepmc_xml_survey.py` over 761 records, kept in
`doc/developer/europepmc_xml_survey/` so the figures can be re-derived (the
survey's `analyse` prints them; `tests/test_europepmc_xml_survey.py` pins
the rule's score):

| Records | Served (200) |
|---------|--------------|
| PMC, `isOpenAccess=Y` | 160 of 160 (one without a `<body>`) |
| PMC, `isOpenAccess=N` (publisher deposits and author manuscripts) | 1 of 320 (`PMC9391270`) |
| Preprints published 2019–2022 (153 marked open access) | 0 of 160 |
| Preprints published 2025–2026 | 79 of 120: all 64 whose text arrived in 2026, 15 of 56 from 2025 |

Plus one PMC record outside Europe PMC's own index (`PMC7617708`, open access,
served), the only one the `pmc-not-epmc` stratum found.

- **The rule loses two texts** in the sample: `PMC9391270`, marked closed
  access and served anyway, and `PPR1051747`, a preprint served before its
  record said Europe PMC holds it (#454). Both fall to the PDF tiers.
- **Preprints are held to the same rule at no cost.** No preprint published
  since 2024 is marked closed access (0, against 9,665 open, on 2026-10-01).
  The 1,090 that are were published 2019–23, when open-access preprints answer
  500 as well (15 of 15 each way for 2023, probed live 2026-10-01).
- **No search field cleanly separates a served preprint from a 500.** The date
  its text arrived comes closest: every preprint whose text arrived in 2026
  was served and none from before 2025, but 41 of 56 from 2025 answered 500.
  All 194 records the rule still asks in vain are preprints, so a `PPR`
  accession's 500 is asked once, not retried (#451).
- **The licence and the URL list's `OA` availability code both misclassify**
  (10 and 4 served texts skipped).
- **A nonexistent ID is also a 500** (`PMC99999999`, `PPR99999999`, probed
  live 2026-10-01), so a 404 from `fullTextXML` is rare in practice.

### Fallback Chain

The desktop's chain (`fulltext_discovery.FulltextDiscoverer`, with the PDF
steps in `pdf_discovery.PDFDiscoverer`), in order:

1. **Cached full-text markdown.** A file an earlier converter wrote is not
   served: Europe PMC is asked again and the file rewritten (#420).
2. **Europe PMC XML** (`fullTextXML`), unless the record rules it out
   (`offers_fulltext_xml`, above).
3. **PMC's open-data bucket** (`pmc_open_data.PmcOpenDataClient`), when a PMC
   ID is known (one Europe PMC resolved counts): the same JATS from the
   public S3 bucket `pmc-oa-opendata` (a listing of `metadata/{PMCID}.`, the
   newest version's metadata record, then its XML), including the author manuscripts `fullTextXML` answers 500 for (#480).
4. **Europe PMC's PDF render**, when the record lists a free PDF of Europe
   PMC's own (`site` `Europe_PMC`, availability code `OA` or `F`).
5. **A cached PDF**, read only if it carries the article's title; one that
   does not is set aside (`pdf_library_check.py`, #541).
6. **The PDF download**, unless the caller passed `skip_pdf`:
   - **Elsevier's Article API** first, for a `10.1016/` DOI and only with the
     user's key (`elsevier_api.py`; the key travels in `X-ELS-APIKey`, an
     institutional token in `X-ELS-Insttoken`, never in the URL);
   - then PMC's PDF links (by PMC ID, or a PMID through NCBI's ID converter),
     **Unpaywall**'s PDFs (`https://api.unpaywall.org/v2/{doi}?email={email}`),
     publisher patterns and the **direct DOI download**, open-access copies
     first. **OpenAlex**'s PDFs that Unpaywall did not name (`openalex.py`)
     are asked for once, before the first copy that is not open access, or at
     once when nothing else was found;
   - **CORE's extracted text** (`core_api.py`, only with a CORE key and a DOI)
     at each exit that obtained no PDF, and after a PDF that yields no text.

A downloaded PDF is checked whole, before it replaces the cached file, for the
article's title on its first page with text (`pdf_title_check.py`, #532,
#546); one that does not carry it is set aside as `<pdf>.mismatch`, the next
source is tried, and the reader is told how to keep it (`bmll keep-pdf`). A
PDF whose host answered with a bot wall's challenge page (`bot_walls.py`) is recorded as `CHALLENGED`, not as the
host's answer; Unpaywall's and OpenAlex's are queued for the desktop's browser
rescue (`doc/developer/browser_rescue.md`). The cross-platform algorithm, and
where the apps differ, is `doc/cross_platform/fulltext_retrieval.md`.

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
| 404 | Not Found | The resource is not there. For `fullTextXML`, rarely seen: closed access and a nonexistent ID both answer 500 (see above) |
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

That is Swift's `RetryConfiguration.serverError`. In Python the Europe PMC and
PDF sessions retry `RETRYABLE_HTTP_STATUSES` (the five above) three times
(`EUROPEPMC_MAX_RETRIES`, `POLITE_MAX_THROTTLE_RETRIES`), and
`mount_politely` moves those statuses off urllib3's `Retry` into `PoliteAdapter`, so every attempt goes through the
host's pacing and a status that outlasts the retries is handed back, not
raised. `PubMedSearchClient._make_request` runs its own loop instead (three
attempts, 1 s doubling), with the adapter retrying nothing.

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

- **Stated limit: 10 requests/second (500/minute), per IP** — from EBI staff
  on the Europe PMC developer forum. Treat this as the published figure.
- **Observed 2026-09-21:** two back-to-back `fullTextXML` fetches of a large
  article (~150 KB, ~17 s each) were followed by sustained 503s with no
  `Retry-After`, for up to ~70 s.
- **Not reproducible on re-check the same day**: four rapid `search` calls
  and three rapid `fullTextXML` calls all returned HTTP 200. So the 503s
  above are best read as load-shedding under slow, large, concurrent
  transfers, **not** as a hard "two requests per second" limit, and not as
  evidence that the published 10/s is fiction.
- We pace it at **1 request/second** anyway, with adaptive backoff beneath
  that: it is well inside the published limit, it costs this client nothing
  at the volumes it works at, and it removes the load-shedding case
  entirely. See `doc/cross_platform/polite_request_pacing.md`.
- Use cursor pagination to minimize requests

### PubMed E-utilities Limits

- Without API key: 3 requests/second
- With API key: 10 requests/second
- Register for API key at: https://www.ncbi.nlm.nih.gov/account/

### How Python Paces

Each client's session (Europe PMC, both NCBI clients, PDF discovery, PMC's
bucket, OpenAlex, CORE, Elsevier, Crossref) is mounted with
`polite_session.mount_politely`, which paces each attempt through `rate_limit.limiter_for(host)`: one limiter per
host, shared process-wide, so threads and clients do not each get a budget.
The ceilings are `POLITE_RATE_CEILINGS`: E-utilities 3/s (10/s with a key,
`NCBI_RATE_WITH_API_KEY_PER_SECOND`), `www.ebi.ac.uk` 1/s, PMC's open-data
bucket 5/s, OpenAlex 10/s, Unpaywall 5/s, CORE 0.4/s, Elsevier 2/s, and 1/s for
a host not listed. A 429 or 503 penalises the host: its interval doubles, up to
one request per 30 s, and a `Retry-After` is honoured up to 300 s
(`POLITE_MAX_PENALTY_SECONDS`); every ten successful answers after a penalty
earn the rate back by halves. Loopback is never paced. The contract is
`doc/cross_platform/polite_request_pacing.md`.

### Best Practices

1. **Pace per host, not per client:** one shared limiter per host, as above
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
| PMC open-data bucket | `https://pmc-oa-opendata.s3.amazonaws.com/?list-type=2&prefix=metadata/{PMCID}.` |
| Unpaywall | `https://api.unpaywall.org/v2/{doi}?email={email}` |
| OpenAlex | `https://api.openalex.org/works/doi:{doi}?select=locations&mailto={email}` |
| Elsevier Article API | `https://api.elsevier.com/content/article/doi/{doi}` (key in `X-ELS-APIKey`) |
| CORE | `https://api.core.ac.uk/v3/search/works/?q=doi:"{doi}"&limit=3` (key as `Authorization: Bearer`) |
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
