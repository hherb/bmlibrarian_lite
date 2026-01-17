# Full-Text Retrieval

This document describes the cross-platform algorithm for retrieving full-text articles from multiple sources with a fallback chain.

## Overview

Not all biomedical articles have freely available full text. We implement a fallback chain to maximize availability:

1. **Europe PMC XML** - Best quality, machine-readable JATS format
2. **Unpaywall PDF** - Open access PDFs via API
3. **DOI Resolution** - Fall back to publisher website

## Retrieval Priority

| Source | Format | Quality | Coverage |
|--------|--------|---------|----------|
| Europe PMC XML | JATS XML | Excellent (structured) | ~5M articles with full XML |
| Unpaywall | PDF URL | Good (requires parsing) | ~30M open access articles |
| DOI Resolution | Web URL | Variable | Nearly all articles with DOI |

## Europe PMC Full-Text XML

### Availability Check

Check if an article has full text in Europe PMC:

```pseudocode
function has_fulltext_xml(article: Article) -> bool:
    # From search results
    return article.in_pmc == "Y" or article.in_epmc == "Y"

    # Or check via API
    info = europepmc.get_article_info(pmid=article.pmid)
    return info and info.has_fulltext_xml
```

### Retrieval

```pseudocode
const EUROPEPMC_FULLTEXT_URL = "https://www.ebi.ac.uk/europepmc/webservices/rest/{pmcid}/fullTextXML"

async function fetch_fulltext_xml(pmc_id: string) -> string | null:
    # Normalize PMC ID
    normalized = normalize_pmc_id(pmc_id)

    url = EUROPEPMC_FULLTEXT_URL.replace("{pmcid}", normalized)

    try:
        response = await http_get(url, headers={"Accept": "application/xml"})

        if response.status == 404:
            return null  # Not available

        response.raise_for_status()
        return response.text

    except HttpError as e:
        if is_retryable(e):
            return await retry_with_backoff(() => fetch_fulltext_xml(pmc_id))
        throw e
```

### Parsing

Use the JATS parser (see [jats_parsing.md](jats_parsing.md)):

```pseudocode
function parse_fulltext(xml: string, pmc_id: string) -> FullTextContent:
    parser = JATSParser(xml, known_pmc_id=pmc_id)

    # Choose output format
    html = parser.parse_to_html()    # Better for complex tables
    markdown = parser.parse_to_markdown()  # Simpler display
    article = parser.parse_to_article()    # Structured data

    return FullTextContent(
        html=html,
        markdown=markdown,
        figures=article.figures,
        tables=article.tables,
        references=article.references
    )
```

## Unpaywall PDF

### API Details

```
GET https://api.unpaywall.org/v2/{doi}?email={your_email}
```

**Required:** Include your email for identification.

### Response Structure

```json
{
  "doi": "10.1234/example",
  "is_oa": true,
  "best_oa_location": {
    "url_for_pdf": "https://example.com/article.pdf",
    "url": "https://example.com/article",
    "host_type": "publisher",
    "license": "cc-by"
  },
  "oa_locations": [...]
}
```

### Retrieval

```pseudocode
const UNPAYWALL_API_URL = "https://api.unpaywall.org/v2"

async function fetch_unpaywall_pdf_url(doi: string, email: string) -> string | null:
    if not doi:
        return null

    url = f"{UNPAYWALL_API_URL}/{encode_uri_component(doi)}?email={email}"

    try:
        response = await http_get(url)

        if response.status == 404:
            return null  # DOI not found

        response.raise_for_status()
        data = response.json()

        # Check if open access
        if not data.is_oa:
            return null

        # Get best PDF URL
        best_location = data.best_oa_location
        if best_location and best_location.url_for_pdf:
            return best_location.url_for_pdf

        # Fall back to any PDF URL
        for location in data.oa_locations:
            if location.url_for_pdf:
                return location.url_for_pdf

        return null

    except HttpError:
        return null  # Don't fail hard on Unpaywall errors
```

### PDF Downloading and Caching

```pseudocode
async function download_and_cache_pdf(
    url: string,
    article_id: string
) -> string:  # Returns local file path
    cache_dir = get_cache_directory()
    filename = f"{article_id}.pdf"
    filepath = cache_dir / filename

    # Check cache
    if file_exists(filepath):
        return filepath

    # Download
    response = await http_get(url)
    response.raise_for_status()

    # Verify it's a PDF
    if not response.content.startswith(b"%PDF"):
        throw InvalidPDFError("Response is not a valid PDF")

    # Save to cache
    write_file(filepath, response.content)

    return filepath
```

## DOI Resolution

### Publisher Website URL

As a last resort, construct a URL to the publisher:

```pseudocode
const DOI_RESOLVER_URL = "https://doi.org"

function get_doi_url(doi: string) -> string | null:
    if not doi:
        return null

    # Clean DOI
    clean_doi = doi.strip()
    if clean_doi.startswith("https://doi.org/"):
        return clean_doi
    if clean_doi.startswith("doi:"):
        clean_doi = clean_doi[4:]

    return f"{DOI_RESOLVER_URL}/{clean_doi}"
```

## Fallback Chain Implementation

```pseudocode
enum FullTextSource:
    EUROPE_PMC_XML
    UNPAYWALL_PDF
    DOI_PUBLISHER
    CACHED

enum FullTextResult:
    EuropePMC(html: string, markdown: string)
    Unpaywall(pdf_url: string)
    DOI(web_url: string)
    Cached(file_path: string)
    Unavailable

async function fetch_fulltext(
    pmc_id: string | null,
    doi: string | null,
    pmid: string | null,
    email: string
) -> FullTextResult:

    # 1. Check cache first
    cache_key = pmc_id or doi or pmid
    if cache_key:
        cached_path = check_cache(cache_key)
        if cached_path:
            return FullTextResult.Cached(cached_path)

    # 2. Try Europe PMC XML (best quality)
    if pmc_id:
        xml = await fetch_fulltext_xml(pmc_id)
        if xml:
            content = parse_fulltext(xml, pmc_id)
            return FullTextResult.EuropePMC(
                html=content.html,
                markdown=content.markdown
            )

    # 3. Try Unpaywall (open access PDF)
    if doi:
        pdf_url = await fetch_unpaywall_pdf_url(doi, email)
        if pdf_url:
            return FullTextResult.Unpaywall(pdf_url)

    # 4. Fall back to DOI resolver
    if doi:
        web_url = get_doi_url(doi)
        if web_url:
            return FullTextResult.DOI(web_url)

    # 5. No full text available
    return FullTextResult.Unavailable
```

## User Interface Considerations

### Display by Source Type

```pseudocode
function display_fulltext(result: FullTextResult):
    match result:
        case EuropePMC(html, markdown):
            # Render HTML in web view for best table support
            display_html(html)
            # Or render markdown for simpler display
            display_markdown(markdown)

        case Unpaywall(pdf_url):
            # Download and display PDF
            local_path = await download_and_cache_pdf(pdf_url, article_id)
            display_pdf(local_path)

        case DOI(web_url):
            # Open in browser
            open_external_url(web_url)

        case Cached(file_path):
            if file_path.endswith(".pdf"):
                display_pdf(file_path)
            else:
                content = read_file(file_path)
                display_html(content)

        case Unavailable:
            show_message("Full text not available")
```

### Source Indicators

Show users which source provided the full text:

```pseudocode
function get_source_badge(source: FullTextSource) -> Badge:
    match source:
        case EUROPE_PMC_XML:
            return Badge(
                text="Full Text",
                color="green",
                tooltip="JATS XML from Europe PMC"
            )
        case UNPAYWALL_PDF:
            return Badge(
                text="Open Access",
                color="blue",
                tooltip="PDF via Unpaywall"
            )
        case DOI_PUBLISHER:
            return Badge(
                text="Publisher",
                color="gray",
                tooltip="Link to publisher website"
            )
        case CACHED:
            return Badge(
                text="Cached",
                color="gray",
                tooltip="Locally cached content"
            )
```

## Error Handling

```pseudocode
async function fetch_fulltext_resilient(
    pmc_id: string | null,
    doi: string | null,
    pmid: string | null,
    email: string
) -> (FullTextResult, list[Error]):
    errors = []

    # Try Europe PMC
    if pmc_id:
        try:
            xml = await fetch_fulltext_xml(pmc_id)
            if xml:
                content = parse_fulltext(xml, pmc_id)
                return (FullTextResult.EuropePMC(...), errors)
        except Error as e:
            errors.append(("Europe PMC", e))

    # Try Unpaywall
    if doi:
        try:
            pdf_url = await fetch_unpaywall_pdf_url(doi, email)
            if pdf_url:
                return (FullTextResult.Unpaywall(pdf_url), errors)
        except Error as e:
            errors.append(("Unpaywall", e))

    # Try DOI
    if doi:
        web_url = get_doi_url(doi)
        if web_url:
            return (FullTextResult.DOI(web_url), errors)

    return (FullTextResult.Unavailable, errors)
```

## Caching Strategy

### Cache Structure

```
~/.bmlibrarian_lite/cache/
├── fulltext/
│   ├── pmc-1234567.html     # Parsed Europe PMC content
│   ├── pmc-1234567.md       # Markdown version
│   └── doi-10.1234_example.pdf  # Downloaded PDFs
└── metadata/
    └── cache_index.json     # Cache metadata
```

### Cache Index

```json
{
  "entries": {
    "pmc-1234567": {
      "source": "europe_pmc",
      "fetched_at": "2024-01-15T10:30:00Z",
      "files": ["fulltext/pmc-1234567.html", "fulltext/pmc-1234567.md"],
      "size_bytes": 125430
    }
  },
  "total_size_bytes": 52428800,
  "max_size_bytes": 104857600
}
```

### Cache Eviction

```pseudocode
const MAX_CACHE_SIZE_BYTES = 100 * 1024 * 1024  # 100 MB

function evict_if_needed():
    index = load_cache_index()

    while index.total_size_bytes > MAX_CACHE_SIZE_BYTES:
        # Evict oldest entry
        oldest = min(index.entries, key=lambda e: e.fetched_at)
        for file in oldest.files:
            delete_file(file)
        index.total_size_bytes -= oldest.size_bytes
        del index.entries[oldest.id]

    save_cache_index(index)
```

## Configuration Constants

```pseudocode
# API endpoints
const EUROPEPMC_FULLTEXT_URL = "https://www.ebi.ac.uk/europepmc/webservices/rest/{pmcid}/fullTextXML"
const UNPAYWALL_API_URL = "https://api.unpaywall.org/v2"
const DOI_RESOLVER_URL = "https://doi.org"

# Timeouts
const FULLTEXT_REQUEST_TIMEOUT_SECONDS = 60
const PDF_DOWNLOAD_TIMEOUT_SECONDS = 120

# Cache
const MAX_CACHE_SIZE_BYTES = 100 * 1024 * 1024  # 100 MB
const CACHE_ENTRY_MAX_AGE_DAYS = 30

# Retry
const MAX_RETRIES = 3
const RETRY_BASE_DELAY_SECONDS = 1
```

## Platform-Specific Notes

### Python (Desktop)

- Use `requests` for HTTP
- Use `pathlib` for file paths
- Store cache in `~/.bmlibrarian_lite/cache/`

### Swift (iOS/macOS)

- Use `URLSession` for HTTP
- Use `FileManager` for file operations
- Store cache in app's Caches directory
- See `Packages/BioMedLit/Sources/BioMedLit/Services/FullTextService.swift`

### Kotlin (Android)

- Use OkHttp/Retrofit for HTTP
- Store cache in app's cache directory
- Consider using Room for cache metadata
