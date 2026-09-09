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

## Content Kind

A retrieval that hands back text must say what the text actually is, because
a caller that scores or analyses a document as an article body must not be
handed an abstract instead, and a caller that displays a document must be
able to tell recovered PDF prose from a real article body. Four kinds, one
raw string each, shared verbatim across every platform so a stored value
means the same thing everywhere it is read:

```pseudocode
enum ContentKind:
    FULLTEXT  = "fulltext"   # a JATS document that had a <body>
    ABSTRACT  = "abstract"   # a body-less JATS rendering — no article text
    EXTRACTED = "extracted"  # prose recovered from a PDF
    NONE      = "none"       # no text, only a link
```

These four strings are a persisted, cross-platform contract, not an internal
enum. Pin them as literal strings in tests, in both directions, and never
round-trip a stored value through a language's own enum-from-string
machinery — that would make a case rename agree with itself and pin nothing.

### Deciding "has a body"

Europe PMC serves full JATS XML for records deposited *abstract-only* — a
`<front>` and a `<back>` with no `<body>` at all — and that XML parses and
renders successfully: it has a title and an abstract, so "did parsing produce
any content" is not the right question. The right one is whether the parse
found a body:

```pseudocode
function has_body(parsed: ParsedArticle) -> bool:
    return parsed.body_paragraph_count > 0

content_kind = has_body(parsed) ? FULLTEXT : ABSTRACT
```

**The trap this predicate exists to avoid**: `body_paragraph_count` must be a
count of prose paragraphs found *inside* `<body>`, not a test of whether any
body *sections* were collected. Back-matter sections (acknowledgements,
appendices) land in the same section collection true body sections do, so a
deposit with `<front>` and `<back>` but no `<body>` would still report a
non-empty section collection — and reading that as "has a body" would report
`FULLTEXT` for exactly the deposit this kind exists to catch. bmlib states
this rule at `bmlib/fulltext/jats_parser.py:1463` and defines
`has_body = body_paragraph_count > 0`; the Swift port mirrors it verbatim.

Both implementations accept the same consequence of counting paragraphs
rather than sections: a `<body>` holding only figures or tables, with no
prose paragraph, reports `has_body = false` — no body, even though there is
a `<body>` element. That is deliberate, not an oversight — this kind answers
"is there article prose", not "is there a `<body>` tag".

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
        references=article.references,
        content_kind=parser.produced_body ? FULLTEXT : ABSTRACT
    )
```

`produced_body` is read from the parser instance that produced the HTML —
both parsers read the same bytes, so which one is asked is a question of
which instance is authoritative, not of which answer is right. See
[Content Kind](#content-kind) for what `produced_body` means and the trap in
computing it.

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
    filepath = cache_dir / f"{article_id}.pdf"

    # Check cache — validated, not a bare existence check. See
    # "Cache Read Validation" below for why and what it catches.
    cached = get_cached_pdf_path(article_id)
    if cached:
        return cached

    # Download
    response = await http_get(url)
    response.raise_for_status()

    # Verify it's a PDF
    if not response.content.startswith(b"%PDF"):
        throw InvalidPDFError("Response is not a valid PDF")

    # Save to cache. Atomic: write to a temp file in the same directory, then
    # rename over the target. A disk that fills mid-write fails the write and
    # throws, rather than leaving a truncated file at the target path that
    # decodes fine and gets served as complete forever.
    write_file_atomic(filepath, response.content)

    return filepath
```

### Cache Read Validation

A cache entry can be corrupted by something outside `download_and_cache_pdf`
entirely — an interrupted restore, a sync conflict or eviction, a file
written by an older build with a different format. The write path above
checks the magic bytes on the way in; the read path must check them again on
the way out, or a corrupted entry is served as the article's full text
indefinitely, since nothing downstream re-validates a path it already has.

```pseudocode
function get_cached_pdf_path(article_id: string) -> string | null:
    filepath = cache_dir / f"{article_id}.pdf"
    if not file_exists(filepath):
        return null

    head = read_bytes(filepath, count=4)
    if head == b"%PDF":
        return filepath

    # Quarantine, don't delete: a ".corrupt" name lets an operator inspect
    # the bad entry, and moving it out of the way — rather than leaving it
    # under the real name — is what lets the *next* fetch re-download.
    # Leaving it in place would instead hide a freshly cached PDF behind it,
    # and the article would re-download on every call for good.
    quarantine_path = filepath + ".corrupt"
    try:
        if file_exists(quarantine_path):
            delete_file(quarantine_path)
        move_file(filepath, quarantine_path)
    except Error as e:
        log_error(f"could not quarantine corrupt cache entry for {article_id}: {e}")
        # Best-effort: a rename that itself fails must not turn a
        # recoverable cache miss into a thrown error.

    return null
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

# Every result carries content_kind alongside its specific content (see
# "Content Kind" above), and a PDF-sourced result additionally carries
# whatever downloading and extraction recovered.
enum FullTextResult:
    EuropePMC(html: string, markdown: string, content_kind: ContentKind)
    PDF(pdf_url: string, content_kind: ContentKind,
        extracted_text: string | null, local_pdf_path: string | null)
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

    # A body-less Europe PMC rendering, held here until every later tier has
    # had its turn. null when none was seen. See "Abstract Holdback" below.
    held_abstract: FullTextResult | null = null

    # 2. Try Europe PMC XML (best quality)
    if pmc_id:
        xml = await fetch_fulltext_xml(pmc_id)
        if xml:
            content = parse_fulltext(xml, pmc_id)
            result = FullTextResult.EuropePMC(
                html=content.html,
                markdown=content.markdown,
                content_kind=content.content_kind
            )
            if content.content_kind == ABSTRACT:
                held_abstract = result
            else:
                return result   # FULLTEXT — nothing beats it

    # 3. Try a free PDF tier (Europe PMC's own render, then Unpaywall).
    #    Each is tried in turn; a tier "has" a PDF as soon as it has a URL —
    #    see "Abstract Holdback" for why that distinction matters.
    for find_pdf_url in [find_europe_pmc_pdf_url, () => fetch_unpaywall_pdf_url(doi, email)]:
        pdf_url = await find_pdf_url()
        if pdf_url:
            local_path, text = await download_and_extract(pdf_url, cache_key)
            if text == null and held_abstract != null:
                continue   # this tier gave nothing; keep the abstract, try the next
            return FullTextResult.PDF(
                pdf_url=pdf_url,
                content_kind=(text == null) ? NONE : EXTRACTED,
                extracted_text=text,
                local_pdf_path=local_path
            )

    # 4. The held abstract, if nothing better arrived.
    if held_abstract != null:
        return held_abstract

    # 5. Fall back to DOI resolver
    if doi:
        web_url = get_doi_url(doi)
        if web_url:
            return FullTextResult.DOI(web_url)

    # 6. No full text available
    return FullTextResult.Unavailable
```

### Abstract Holdback

An abstract-only Europe PMC rendering (`content_kind == ABSTRACT`) must not
be returned as soon as it is found. Returning it immediately makes it beat
every remaining tier, so an open-access PDF of the same paper becomes
unreachable and the abstract is cached and analysed as though it were the
article. Instead, hold it in a local and let the PDF tiers run; only return
it at the end, if nothing better arrived.

No web URL rides along on the held abstract. Resolve the publisher or PubMed
link from the identifiers already available — the same resolution every
other case falls back to — rather than carrying a second copy of it on the
result, which would give a caller two sources for one link and a reason for
them to disagree.

**A PDF tier counts as a success as soon as it has a URL.** Downloading and
extracting the PDF that URL points to can still fail — a 404, a server
error, a scanned page with no recoverable text — and that failure must not
be read as "this tier found nothing": the tier found a URL, it just could
not turn it into text. Concretely: if extraction yields no text (`text ==
null`) and an abstract is already held, move on to the next tier rather than
returning a bare-link PDF result that would discard the abstract already in
hand. If extraction yields no text and *no* abstract is held, still return
the PDF result — `content_kind = NONE`, but the URL is real and worth
offering.

### Cancellation

An ordinary download or extraction failure — a 404, a server error, a file
the PDF library cannot open — leaves the reader the URL and the chain moves
on, exactly as in "Abstract Holdback" above. A **cancellation** is not an
ordinary failure and must not be swallowed the same way:

```pseudocode
async function download_and_extract(
    url: string,
    cache_key: string
) -> (local_path: string | null, text: string | null):
    try:
        path = await download_and_cache_pdf(url, cache_key)
    except Cancelled:
        raise Cancelled   # propagate — do not fall through to (null, null)
    except Error:
        return (null, null)   # ordinary failure: the tier's URL still stands

    extraction = extract_text(path)
    if not extraction.success or extraction.char_count == 0:
        return (path, null)   # file is cached; nothing usable was recovered

    return (path, extraction.text)
```

A cancelled fetch must never be cached as the article's full text. If
cancellation fell through like an ordinary failure, the caller that
cancelled the operation could still receive a normal, non-throwing,
link-only result — and have it written to storage as though the fetch had
completed, which contradicts the guarantee that cancelling a fetch leaves no
trace.

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

        case PDF(pdf_url, content_kind, extracted_text, local_pdf_path):
            # Display prefers the document even when content_kind == EXTRACTED:
            # extracted text has no figures, tables or layout, so it is what
            # analysis reads (below), not what the reader is shown.
            path = local_pdf_path or await download_and_cache_pdf(pdf_url, article_id)
            display_pdf(path)

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
                return (FullTextResult.PDF(pdf_url, ...), errors)
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
