# Full-Text Retrieval

This document describes the cross-platform algorithm for retrieving full-text articles from multiple sources with a fallback chain.

## Overview

Not all biomedical articles have freely available full text. We implement a fallback chain to maximize availability:

1. **Europe PMC XML** - Best quality, machine-readable JATS format
2. **PMC's open-data bucket** - The same JATS by PMC ID, including the author
   manuscripts Europe PMC does not serve (#480)
3. **Europe PMC's PDF render, then Elsevier's API, then every Unpaywall PDF, then OpenAlex's, then CORE's extracted text** - Open access copies (from
   Elsevier's API, any PDF the requestor is entitled to)
4. **DOI Resolution** - Fall back to publisher website

On the desktop, CORE's text comes after the direct DOI download (a PDF
fetched through the DOI resolver is one of `PDFDiscoverer`'s sources); in
the apps it comes before the DOI link, which they never download. Elsevier's
API is asked only for Elsevier's DOIs and only with the user's key (see
"Elsevier's Article API"); on Android only when Europe PMC offered no render
URL (#493).

## Retrieval Priority

| Source | Format | Quality | Coverage |
|--------|--------|---------|----------|
| Europe PMC XML | JATS XML | Excellent (structured) | ~5M articles with full XML |
| PMC open-data bucket | JATS XML | Excellent (structured) | PMC's open-access and author-manuscript collections, by PMC ID |
| Elsevier's API | PDF | Good (requires parsing) | Elsevier's articles (`10.1016/`) the requestor is entitled to, by DOI, with a key |
| Unpaywall | PDF URL | Good (requires parsing) | ~30M open access articles |
| OpenAlex | PDF URLs | Good (requires parsing) | locations Unpaywall does not list, by DOI |
| CORE | Plain text | Fair (no structure) | text CORE extracted from repository copies, by DOI, with a key |
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
    NONE      = "none"       # no text was recovered
```

`NONE` is not "there is no file". A PDF that downloaded and cached fine but
yielded no prose — a scan — is stored under `NONE` *with a real file on
disk*. Ask the retrieval's own local-path field, never the kind, when the
question is whether there is a document to open; reading `NONE` as
"link-only" is what sends a cached scan down the remote-URL branch, where a
`URL(string:)`-style parse turns an absolute path into a schemeless URL.

These four strings are a persisted, cross-platform contract, not an internal
enum. Pin them as literal strings in tests, in both directions. What that
rules out is asserting a case *against its own* `rawValue`, which would make
a rename agree with itself and pin nothing; decoding `"fulltext"` back to a
case and checking you got `FULLTEXT` is exactly the direction worth testing.

### Deciding "has a body"

Europe PMC serves full JATS XML for records deposited *abstract-only* — a
`<front>` and a `<back>` with no `<body>` at all (checked live on 2026-09-29:
`PMC9788864`, open access, answers 200 with an abstract and no `<body>`; a
*non-open-access* record gets a 500 instead, #432) — and that XML parses and
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
`FULLTEXT` for exactly the deposit this kind exists to catch. In bmlib the
rule is stated on the `implicit_body_section` slot's comment and applied
where `ParsedArticle` is built, both in `bmlib/fulltext/jats_parser.py`, as
`has_body = body_paragraph_count > 0`; the Swift port mirrors it verbatim as
`JATSXMLParser.producedBody`. Cited by symbol rather than line, because
cross-repository line numbers rot silently.

Both implementations accept the same consequence of counting paragraphs
rather than sections: a `<body>` holding only figures or tables, with no
prose paragraph, reports `has_body = false` — no body, even though there is
a `<body>` element. That is deliberate, not an oversight — this kind answers
"is there article prose", not "is there a `<body>` tag".

## Europe PMC Full-Text XML

### Availability Check

Check if an article has full text in Europe PMC:

```pseudocode
# Python only until #450: Swift and Android still ask for every accession.
function has_fulltext_xml(article: Article) -> bool:
    # From search results. Held is not enough: fullTextXML answers 500 for a
    # held but closed-access article (#432). Only a stated "N" is an answer,
    # for either question: a missing or unreadable flag asks.
    stated_not_held = article.in_pmc == "N" and article.in_epmc == "N"
    return not stated_not_held and article.is_open_access != "N"
```

Without a search record in hand, `europepmc.get_article_info(...)` returns
one whose `has_fulltext_xml` applies the same rule.

### Retrieval

The fetch has three outcomes, and one `null` for all of them is the defect
this shape exists to prevent (#429): a 404 is Europe PMC's answer (in
practice rare: text it will not serve and an ID it does not hold both answer
500, see below), while a
throttle, an outage, a timeout or a blank 200 is our failure to get one, and
the reader is told which.

```pseudocode
const EUROPEPMC_FULLTEXT_URL = "https://www.ebi.ac.uk/europepmc/webservices/rest/{accession}/fullTextXML"

# SERVED(xml) | ABSENT (the 404) | UNREACHABLE(failure of its real kind)
type FullTextXmlFetch

async function fetch_fulltext_xml(accession: string) -> FullTextXmlFetch:
    # "PMC123", "pmc123" and "123" become "PMC123"; a preprint's Europe PMC
    # record ID "PPR123" (any case) is kept, as preprints have no PMC ID.
    # ASCII digits only; anything else is refused and never sent -- it goes
    # into a URL path, and not asking is not an absence (#355).
    normalized = normalize_fulltext_accession(accession)
    if normalized is null:
        return UNREACHABLE(REQUEST_FAILED)

    url = EUROPEPMC_FULLTEXT_URL.replace("{accession}", normalized)

    try:
        # Retries and pacing live in the session; a 429 still throttled
        # after them is reported as HTTP 429, not as a bad answer.
        response = await http_get(url, headers={"Accept": "application/xml"})
        if response.status == 404:
            return ABSENT
        response.raise_for_status()
    except HttpError as e:
        return UNREACHABLE(failure_from(e))   # HTTP 429, 503, timeout, ...

    if response.text.strip() == "":
        return UNREACHABLE(INCOMPLETE_RESPONSE)   # told us nothing
    return SERVED(response.text)
```

`fullTextXML` serves open-access text only, and answers **HTTP 500** -- not
404 -- for an article Europe PMC holds but marks `isOpenAccess=N` (#432,
measured on 761 records; `doc/developer/europepmc_and_pubmed.md` has the
table). Europe PMC's search flags (`inEPMC`, `inPMC`) say the article is held,
not that its text is open. So:

- **Ask unless the record states that Europe PMC does not hold the article
  (`inPMC=N` and `inEPMC=N`) or that it is closed access (`isOpenAccess=N`)**
  (Python `offers_fulltext_xml`). A missing or unreadable flag is not a
  stated no, and the fetch is made. Preprints are held to the same rule at
  no cost: none published since 2024 is marked closed access, and in the
  years some are (2019–23), open-access preprints answer 500 as well (#451).
- **A preprint's 500 is asked once** (#451, all three platforms; Python
  `EUROPEPMC_PREPRINT_XML_UNRETRIED_STATUSES`). Preprints whose text arrived
  before 2025 all answer a *steady* 500, as do 41 of the 56 that arrived in
  2025 (survey: `doc/developer/europepmc_and_pubmed.md`), so each retry only
  repeats it and costs paced requests and backoff time. The 500 is still reported as `HTTP_STATUS 500`, so the chain is unchanged; the
  PDF tiers simply start sooner. A `PPR` accession's throttle (429/503) and
  gateway faults (502/504) keep the full retry budget, and **a PMC
  accession's 500 is still retried**: an open-access PMC article always
  served in the survey, so there a 500 is a fault. The price is that a
  transient 500 on a served preprint costs its XML for that attempt.
- **A record that states closed access is Europe PMC's answer about its own
  service** (maintainer's decision, 2026-09-30), as "not held" already was:
  no failure is recorded, the chain goes on to the PDF tiers (the Europe PMC
  PDF render first), and if every tier answers, the absence is established.
  The record can be wrong: 1 of 320 closed-access records was served anyway
  (`PMC9391270`), and a fresh preprint can be served before its record says
  it is held (`PPR1051747`, #454). Both fall to the PDF tiers, so if those
  answer without a copy the chain establishes an absence Europe PMC could
  have filled.
- **A 404 or 500 for an article the record called servable** is recorded as
  what we got, against Europe PMC, and not as the article's absence.

The apps do not read the record's flags yet: they ask for every accession,
and a 500 leaves Europe PMC's side unsettled (#450). So in the apps a
closed-access article spends every retry and can never reach an established
absence, where Python settles it once the PDF tiers answer.

**The apps (#434).** Swift (`FullTextService.fetchEuropePMCXML(accession:)` →
`FullTextXmlFetch`) and Android (`EuropePMCService.fetchFullTextXml` →
`FullTextXmlFetch`) follow the same three outcomes and accession rules
(`FullTextAccession`), and fetch a preprint by its `PPR` ID: the one the
identifier search found (Android's search must include preprints, which its
default filter drops). Swift also reads the document's own primary slot, but
only when that search *failed*: a search that answered "no such record" is
not second-guessed with a fetch that would almost certainly fail (Europe PMC
answers 500 for an ID it does not hold). Where Python keeps a lookup
record, the apps keep one fact, what Europe PMC's side of the chain got
instead of the article's text (a lost search, a failed fetch, or the 404), cleared when
a fetch is served. A chain that then finds nothing ends in
`FullTextError.absenceNotEstablished` (Swift) or
`FullTextResult.NotEstablished` (Android), never in the "no full text" answer
the callers record on the document for good. Its sentence uses #435's verbs:
"Europe PMC (HTTP 404 Not Found) did not serve it" for an HTTP answer, "could
not be asked (…)" for a throttle (429), any 5xx (#445) and every other kind; see
[search_failure_reporting.md](search_failure_reporting.md) for the predicate. On Swift the 404 raises no `FullTextDegradation`
(Europe PMC answered; see [jats_parsing.md](jats_parsing.md)), and a blank
200 is `europePMCUnreachable`, no longer a parse failure.

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

## PMC's Open-Data Bucket (#480)

PMC publishes its open-access and author-manuscript collections in the public
S3 bucket `pmc-oa-opendata`. Asked **after Europe PMC's `fullTextXML` returned no
text (a body-less deposit Europe PMC served counts as text on every platform:
Swift holds it back but does not ask the bucket, for parity with Python and
Kotlin, which have no content kind), by PMC ID only** (a preprint has none), and before Europe PMC's
PDF render. Service name: **"PMC's open-access collection"**; source
`pmc_open_data` in the apps (the desktop's `FulltextSourceType` spells it
`pmc_open_data_xml`, as it spells Europe PMC's `europepmc_xml`). Pinned by
`fulltext_parity/pmc_open_data.json`.

```pseudocode
# SERVED(xml) | ABSENT | UNREACHABLE(failure of its real kind)
function fetch_pmc_open_data(pmcid) -> PmcOpenDataFetch:
    listing = GET {base}/?list-type=2&prefix=metadata/{pmcid}.
    if listing.status != 200: return UNREACHABLE(http_status)
                                                       # a 404 included: S3 answers a prefix naming
                                                       # nothing with a 200; a 404 is NoSuchBucket
    key = latest_metadata_key(listing.body, pmcid)     # numeric max of .{N}.json, N ASCII digits
                                                       # raises on a body that is not an S3 listing
                                                       # (or not UTF-8), or that names this article
                                                       # only under versions it cannot read:
                                                       # UNREACHABLE(malformed_response)
    if key == null: return ABSENT                      # no version of this article listed
    record = GET {base}/{key}                          # 404 here: UNREACHABLE(404)
                                                       # not UTF-8, unparseable JSON or not an object:
                                                       # UNREACHABLE(malformed_response)
    if record.xml_url is missing or null: return ABSENT  # no XML named
    xml_url = https_url(record.xml_url)                # s3://pmc-oa-opendata/k?md5= -> https://…/k
    if xml_url == null: return UNREACHABLE(malformed_response)
                                                       # XML named where we cannot read (#486)
    xml = GET xml_url                                  # 404: UNREACHABLE(404); blank: incomplete_response
    return SERVED(xml)
```

The bucket serves its objects as `binary/octet-stream` with no charset, so
every body is decoded as UTF-8; a body that is not valid UTF-8 is
`malformed_response`. The served XML goes through the platform's JATS
converter, under the same rules as Europe PMC's (Swift's abstract holdback
included); XML whose conversion yields no text, or that the converter fails
on, is recorded as `malformed_response`, not an absence. Unlike Europe PMC's
own parse failure, which does not yet count (#436), the bucket's counts
towards "not established" on every platform. An unreachable bucket is recorded under
its service name, so a chain that then finds nothing has **not established**
an absence; in the apps the sentence names the bucket
(`not_established_sentence` rows). Paced at 5 requests per second. Only XML
is read: a record without `xml_url` is an answer, and the chain goes on to
the PDF tiers.

Only two answers are an absence: a listing that names no version of this PMC
ID, and a record whose `xml_url` is missing or null. A listing 404 is not one
of them: S3 answers a prefix that matches nothing with a 200 and `KeyCount` 0,
so a 404 is `NoSuchBucket` (or something in between), which says nothing about
the article. A 404 on the metadata record or on the XML *after the listing
named it* is **unreachable** too: the bucket is disagreeing with itself, and
that is a lookup that failed. An answer we cannot read (a version that is not
ASCII digits, an `xml_url` that is not this bucket's `s3://` URL) is
`malformed_response`, never an absence.

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
    "url": "https://example.com/article.pdf",
    "url_for_landing_page": "https://example.com/article",
    "host_type": "publisher",
    "license": "cc-by"
  },
  "oa_locations": [...]
}
```

### Retrieval

```pseudocode
const UNPAYWALL_API_URL = "https://api.unpaywall.org/v2"

# Every PDF the answer names, best location first (#480, stage B): the
# candidates "Tried sources (#480)" walks. Empty when it names none.
async function fetch_unpaywall_pdf_urls(doi: string, email: string) -> list[string]:
    if not doi:
        return []
    if not usable_email(email):       # blank, or the app's own placeholder,
        raise Unsettled(NOT_CONFIGURED)  # which Unpaywall refuses with 422 (#466)

    url = f"{UNPAYWALL_API_URL}/{encode_uri_component(doi)}?email={email}"

    try:
        response = await http_get(url)

        if response.status == 404:
            return []  # DOI not found

        response.raise_for_status()   # a 429, 500, 502, 503 or 504 is retried
                                      # first; any status of 400 or above but
                                      # 404 is Unsettled (#466); below 400 the
                                      # body is decoded
        data = response.json()

        pdf_urls = unpaywall_pdf_urls(data)   # every url_for_pdf, kept once
        if pdf_urls:
            return pdf_urls
        choice = choose_unpaywall_url(data)
        if choice.landing_page:
            match await read_landing_page(choice.landing_page):
                case Declared(pdf_url): return [pdf_url]
                case DeclaresNone: return []
                case Unreachable(failure): raise Unsettled(failure)
        return []

    except HttpError, Timeout, ConnectionError, UnreadableJson as e:
        # Not "no copy": Unpaywall did not settle it (see "Landing Pages")
        raise Unsettled(failure_of(e))
```

### Landing Pages (#464)

**A location's PDF is `url_for_pdf` and nothing else.** Unpaywall sets `url`
to `url_for_pdf` when it has one and to the landing page when it does not, so
`url_for_pdf ?? url` adds no PDF, only the landing page. The apps took it, and
PMID 40608933's repository landing page was downloaded as "the PDF", failed
the `%PDF` check, and was stored as an Unpaywall full text with no text in it.

When no location offers a `url_for_pdf`, the landing page is **read** for the
PDF it declares in a Highwire Press tag, which repositories (DSpace, EPrints)
and most publishers emit:

```html
<meta name="citation_pdf_url" content="https://repo.example.org/item/1/paper.pdf">
```

```pseudocode
# Pure; pinned by fulltext_parity/unpaywall_landing_page.json ("unpaywall_choice")
function choose_unpaywall_url(data) -> (pdf_url, landing_page):
    locations = [data.best_oa_location] + data.oa_locations   # objects only
    for location in locations:                 # first url_for_pdf, best first
        if present(location.url_for_pdf): return (trim(it), null)
    for location in locations:                 # else the first landing page
        page = present(location.url_for_landing_page) or present(location.url)
        if page: return (null, trim(page))
    return (null, null)                        # present() = non-blank string

# Pure; pinned by the same file ("citation_pdf_url")
function citation_pdf_url(html, page_url) -> string | null:
    for tag in regex_all(r"<meta\b[^>]*>", html, ignore_case):
        attrs = attributes(tag)   # names lower-cased; "..", '..' or bare values;
                                  # references decoded (see below); trimmed;
                                  # the first of a repeated name wins
        if lower(attrs.name) != "citation_pdf_url" or not attrs.content:
            continue              # property= is not name=
        url = resolve(page_url, attrs.content)   # RFC 3986, against the
        if url is None: continue                 # page served after redirects;
        if scheme(url) in {http, https}:         # an absolute URL kept as given,
            return url                           # one that will not parse skipped
    return null

# Pure; pinned by the same file ("character_references")
function decode_character_references(value) -> string:
    # Only references ending in ";": &#38; &#x26; and the five names
    # amp lt gt quot apos, matched with their case. Without the ";" it is
    # text, so a URL's bare &section= or &param= survives: Python's
    # html.unescape decoded HTML's legacy names written bare, turning them
    # into §ion= and ¶m=, which no browser does inside an attribute. Any
    # other name is left as written; a number naming no character (zero, a
    # surrogate, past U+10FFFF) becomes U+FFFD. One pass: &amp;amp; is &amp;.

# Pure; pinned by the same file ("landing_page_status")
function web_page_status_unsettled(status) -> bool:   # status >= 400
    return status >= 500 or status in {429, 408, 425}

async function read_landing_page(page_url) -> Declared | DeclaresNone | Unreachable:
    if page_url is not an absolute http(s) URL with a host:   # relative, ftp:,
        return Unreachable(REQUEST_FAILED)                     # file:, unparsable (#474)
    response = GET page_url, Accept: text/html,application/xhtml+xml,
               redirects followed, paced; a 429 or 5xx retried
    if the request or the body read failed: return Unreachable(failure)
    if status >= 400:
        return Unreachable(status) if web_page_status_unsettled(status) else DeclaresNone
    if "pdf" in content_type: return Declared(response.final_url)   # the page is the PDF
    if content_type and "html" not in content_type: return DeclaresNone
    body = first 2 MiB of the body, decoded by its declared charset, else UTF-8
    url = citation_pdf_url(body, response.final_url)
    return Declared(url) if url else DeclaresNone
```

One extra request, only for an article whose every Unpaywall location lacks a
PDF URL. The PDF found keeps Unpaywall's provenance and goes through the
ordinary download and extraction (and, in Python and Swift, the `%PDF` check;
Android has none). A "landing page" served as a PDF is a repository bitstream
link, taken as `_discover_doi_direct` takes a DOI that resolves to a PDF.

No body is read but an HTML page's (or one of no stated type), and that one only
up to 2 MiB: the tag sits in `<head>`, and a large file served as the page is
not downloaded to find out what it is. A landing page is a lookup, not research
content, so the cap loses no evidence (the maintainer's call; golden rule 13
guards the article text). A page that declares no charset is read as UTF-8, as the apps' HTTP clients read it; `requests`
would read an undeclared `text/html` page as ISO-8859-1 and garble a non-ASCII
PDF path.

Python reads the landing page only when Unpaywall offered neither a PDF URL nor
a PMC page to derive one from: a PMC render is the same article's PDF.

**A page that could not answer is not a page without a PDF.** A landing page
that could not be reached, whose body broke off, or that ended on a status
`web_page_status_unsettled` calls unsettled is `Unreachable`, by the rule #446
set for the publisher's page a DOI resolves to; any other 4xx, a page neither
HTML nor PDF, or a page without the tag is its answer (`DeclaresNone`).

- **Python** records `Unreachable` as a `SourceLookupFailure` under "the
  open-access copy's landing page", and an Unpaywall it could not ask under
  Unpaywall's own name; both reach the reader.
- **Swift** returns an `OpenAccessShortfall` (which lookup, and why) on the
  chain's fallback as `FullTextResult.openAccessShortfall`. The app reads it
  to keep a stored PDF link rather than trade it for that fallback
  (`FullTextAutoFetch.storedLinkKept`), so the next run tries again, and
  otherwise stores it on the document for the reader (below).
- **Android** raises `OpenAccessUnsettledException` carrying the
  `OpenAccessShortfall` inside the tier, logs it as a warning, and puts it on
  the DOI link it falls back to (`FullTextResult.DoiUrl.openAccessShortfall`).

#### An unsettled open-access copy (#466)

The reader of a fallback the chain settled on because Unpaywall, the landing
page it named, the PDF it named (#478), OpenAlex, the PDF OpenAlex named
(#480), CORE (#480, stage C) or Elsevier's API (#480, stage C2) could not
settle whether a free copy exists is told so.
Without it the publisher link reads exactly as one for an article with no free
copy at all.

**One sentence, Python's.** The notice is Python's
`analysis_failures.unestablished_access_clause` for that one lookup, and the
verb is #435's (`RequestFailure.is_answer`, `search_failure_reporting.md`):

- could not be asked: `"Unpaywall (the request timed out) could not be asked,
  so a freely available copy may exist. Whether this document is open access
  was not established."`
- answered without serving it: `"The open-access copy's landing page (HTTP 408
  Request Timeout) did not serve it, so whether this document is open access
  was not established."`
- not configured: `"Unpaywall (not configured) could not be asked, so a freely
  available copy may exist. Whether this document is open access was not
  established. Configuring Unpaywall would add an open-access route this search
  did not have."` Python records this as a `SourceLookupSkipped`
  (`NOT_CONFIGURED`), and `configuration_nudge` adds the last sentence.
- a configured keyed channel not asked: `"Elsevier's API (not available from
  this network) could not be asked, so a freely available copy may exist.
  Whether this document is open access was not established."` A
  `SourceLookupSkipped` too (`KEY_REFUSED`, `NETWORK_REFUSED`), with no
  configuration nudge: the channel is configured.

The source is named as Python records it, a leading "the" capitalised:

| `source` | Named | Python |
|---|---|---|
| `unpaywall` | Unpaywall | `SERVICE_UNPAYWALL` |
| `unpaywall_landing_page` | the open-access copy's landing page | `SERVICE_UNPAYWALL_LANDING_PAGE` |
| `unpaywall_pdf` | the open-access copy's PDF | `SERVICE_UNPAYWALL_PDF` |
| `openalex` | OpenAlex | `SERVICE_OPENALEX` |
| `openalex_pdf` | OpenAlex's copy | `SERVICE_OPENALEX_PDF` |
| `core` | CORE | `SERVICE_CORE` |
| `elsevier` | Elsevier's API | `SERVICE_ELSEVIER` |

A skip is named by its reason (Python's `LookupSkipReason`; only these are
stored by the apps):

| `skipped` | Told | Nudge | A stored one reads as |
|---|---|---|---|
| `not_configured` | not configured | yes | Unpaywall's, whatever source it names |
| `key_refused` | the key in the settings was refused | no | Elsevier's when the source it names is `elsevier`; CORE's otherwise (`core`, another source, or none) |
| `network_refused` | not available from this network | no | Elsevier's, whatever source it names |

The rows are `fulltext_parity/open_access_unsettled_notice.json`, read by all
three suites.

**Which answers leave it unsettled** is the same on all three platforms: from
Unpaywall, any status of 400 or above but 404 (a 408 or 403 is an answer, "did
not serve it"; a 501 or 520 could not be asked), a transport failure, an answer
that is empty or will not decode, and an unexpected error in the tier; from the
landing page, `Unreachable` above, including an address that is not an
absolute http(s) URL (`request_failed`: Python's `requests` refuses it with
`MissingSchema`, `InvalidSchema` or `InvalidURL`, #474).

**A PDF Unpaywall named that could not be obtained is refused** (#478, the
maintainer's call). The PDF is its `url_for_pdf`, or the one its landing page
declares. It is never offered as a link and never "no copy": the open-access
copy went unassessed, under its own source, **the open-access copy's PDF**
(`unpaywall_pdf`; Python `SERVICE_UNPAYWALL_PDF`), not Unpaywall's, which
answered. The failure is:

- `request_failed` for an address that is not an absolute http(s) URL with a
  host, which is never requested (Python's `requests` refuses it as above);
- the HTTP status of a download that answered with one (a 403 or 404 "did not
  serve it"; a 429 or 5xx "could not be asked");
- the transport failure of one that got no answer;
- `malformed_response` for a body that is not a PDF, served with a success
  status: it does not begin with `%PDF`, whatever its Content-Type says (a
  login page, a bot wall's challenge, #480). Python's check was "a PDF
  Content-Type *or* `%PDF`" until #478 and now matches the apps.

**Every platform tries every PDF Unpaywall names; then, only if no copy was
served and kept, OpenAlex's** (#480, stage B; `unpaywall_pdf_urls` in
`unpaywall_landing_page.json`, and `openalex_locations.json`). The apps try
them in Unpaywall's order; Python by its own priority. **The first copy served
ends the walk.** Saved, it is read. Not saved, its link is kept (apps) with a
caching note, and nothing further is asked. **When none is obtained, every
source tried is told** (see "Tried sources (#480)"). One difference is
deliberate: in Swift, a copy downloaded and cached that yields no text while
an abstract is held does not end the walk or the OpenAlex ask, since a
textless copy is no full text obtained; Python stops at any PDF it downloads
(extraction comes later). A copy was obtained all the same, so the
open-access question is settled: as for a copy not cached, no shortfall is
told beside the abstract, whatever was refused before or after it. A copy
refused for its size (Python alone has a limit) was not kept and settles
nothing, so OpenAlex is still asked after it.

Once every copy was refused, the chain goes on as though none had been named:
Python tries its remaining sources, and Swift falls back past them (no link
fallback is kept for them). Android's service returns the steps in chain order
(`FullTextResult.OpenAccessPdfs`), and `recordingFullTextFetch` walks them,
asking OpenAlex through its `askOpenAlex` hook only once no Unpaywall copy was
served. It resolves to the PDF obtained or linked (`OpenAccessPdf`), or to the
DOI link carrying every shortfall met. **Most of these
failures are bot walls, not missing copies** (#480; measured in
`doc/developer/unpaywall_pdf_survey/`). Our clients obtained 28% of 400 Unpaywall
PDFs; 81% of the rest were walls, 12% addresses that serve no PDF. A failure
whose answer was a challenge page, or a 403/503 from Cloudflare itself, was a wall
89% of the time. Whether such a failure gets its own kind, or a link to open in
the browser, is the maintainer's decision, not yet made.

**Our own stops are not the copy's answer**, and none of them is "no copy":

- A cancel records nothing: the caller walked away from the question.
- Python refuses a PDF larger than `MAX_PDF_SIZE`. The copy exists and went
  unread, so it is recorded as a lookup not made, `SourceLookupSkipped`
  (`OVER_SIZE_LIMIT`): "The open-access copy's PDF (larger than the download
  limit) could not be asked, …". Python's alone; the apps set no size limit.
- A PDF the source served that could not be cached (a write that failed, a
  rename that failed) is a fault of ours, and it settles the open-access
  question: the copy exists (#480, the maintainer's decision). It ends the
  walk and is told as a caching note, never as a shortfall (see "Tried sources
  (#480)"). The apps keep the PDF's link: Swift's `PDFTierOutcome.notCached`
  is held as the link fallback, and Android's `PdfDownload.NotSaved` is
  recorded as a link-only PDF ("A PDF of this article was found but could not
  be downloaded."), each with the note. Python has no link to offer, and
  recording nothing would let the discovery conclude the article has no full
  text, so it records a `NOT_SAVED` skip with the address; its error is the
  caching note alone.

**A partial download is never served as the PDF.** Python and Android write the
body to `<file>.part` and rename it into place only once it has arrived whole
(Android also checks `%PDF` first); a download that broke off leaves nothing a
later cache lookup could return as the whole article. BioMedLit holds the body
in memory and writes it atomically.

**The chain never ends on an absence while it is unsettled.** Every fallback
returned after the tier carries the shortfall: on Android always the DOI link;
in BioMedLit the abstract, a PDF link it could not download, the DOI link or
the PubMed record. Only when none of these can be built does BioMedLit throw
`openAccessNotEstablished`, never `noFullTextAvailable`, which the apps record
on the document for good (#475).

**No usable email is "not configured", not a 422.** Unpaywall refuses a blank
address, and Android's placeholder `bmlibrarian@example.com` (Python's
`FALLBACK_CONTACT_EMAIL`), with HTTP 422 for every article. Python
(`usable_unpaywall_email`) and Android (`UnpaywallContact.usableEmail`) do not
ask it then, and BioMedLit does not ask it with a blank address. Android asks
with the Unpaywall email, or failing that the NCBI email the settings screen
offers; iOS and macOS ask with the NCBI email, or an address of their own
Unpaywall accepts.

**Stored with the full text.** The apps keep it on the document beside the
other full-text fields (Swift `Document.fullTextOpenAccessShortfallJSON`,
Android `documents.full_text_open_access_shortfall_json`, Room 8). It is not a
`FullTextDegradation`: both can be true of one fetch, and on iOS/macOS the
banner says both.

```json
{"schema_version": 1, "source": "unpaywall_landing_page",
 "failure": {"kind": "http_status", "status_code": 408}}
```

`source` is one of the sources in the table above (`unpaywall`, `unpaywall_landing_page`,
`unpaywall_pdf`, `openalex`, `openalex_pdf`, `core` or `elsevier`); `failure`
is a search shortfall's failure object and reads back by its rules
(`search_failure_reporting.md`, "Persisted form"). An Unpaywall that was not
configured is stored as `{"schema_version": 1, "source": "unpaywall",
"skipped": "not_configured"}` in place of a failure, and a stored
`not_configured` skip reads as Unpaywall's whatever source it names. CORE's
refused key (#498) is stored as `{"schema_version": 1, "source": "core",
"skipped": "key_refused"}` (in schema 2, an entry `{"source": "core",
"skipped": "key_refused"}`), Elsevier's as the same with `"source":
"elsevier"`; a stored `key_refused` skip reads as Elsevier's when the source it
names is `elsevier`, and as CORE's otherwise (`core`, any other source, or
none), as before stage C2. Elsevier's off-network refusal is stored as
`{"schema_version": 1, "source": "elsevier", "skipped": "network_refused"}`
(in schema 2, an entry of that shape), and a stored `network_refused` skip
reads as Elsevier's whatever source it names. Any other skip reason reads by
its failure.

A single entry without an address is stored in this form (schema 1). Anything
else is `{"schema_version": 2, "entries": [{"source", "address"?, "failure" |
"skipped"}, …]}` (#480; rows under `persisted` in `open_access_statement.json`).
An entry that will not read becomes `{its source or unpaywall,
request_failed}`; a blank or non-string address is no address; a missing or
empty list, or any other schema, reads as `[{unpaywall, request_failed}]`.

The field is written only when a lookup
went unsettled, so **every stored value reads as some shortfall**: one that is
not a JSON object, or whose `schema_version` is neither 1 nor 2 (missing
included), reads as `{unpaywall, request_failed}`; an unknown source reads as
`unpaywall`.

**Written by every fetch, cleared by every fetch that settles it.** A result
carrying no shortfall clears the field, as does an upload, a cleared cache and
"no full text available". A result the chain could not settle at all
(`absenceNotEstablished` / `NotEstablished`) records nothing, as before. A
refetch whose stored PDF link is kept (`storedLinkKept`) writes nothing either.

**Where it is shown.** A note, never a warning: the link is complete in itself.

- **iOS/macOS:** a line of its own in `ParseWarningBanner`
  (`ParseWarningBannerContent`), beside whatever else the banner says, on every
  card and viewer that banners a document; a web link is not opened in the
  browser automatically while there is something to explain
  (`AppFullTextResult.hasNothingToExplain`). The iOS Full Text tab's link-only
  row opens Safari on a tap, so it shows the banner beneath the row (#472).
- **Android:** the full-text screen's web-link view, the fact-check document
  card and the report's document sheet (`OpenAccessShortfallNotice`).

**A link-only record is not an unfetched one** (#187 on iOS/macOS, #471 on
Android). A fetch date with nothing displayable behind it, and no recorded
absence, is link-only (`Document.isLinkOnly` / `DocumentEntity.isLinkOnly`).
Its card shows the link and why it is only one, never the "Get Full Text"
button of a record never fetched; a retry stays on offer. Nothing says full text
"is available" behind a link the chain did not read: a DOI resolves to the
publisher's landing page, which is often paywalled. Android names the three
kinds it can hold (`FullTextLinkKind`): the publisher's page ("This article's
full text was not retrieved; the publisher's page may offer it."), a PDF that
was found but could not be downloaded, and a PDF served but not saved ("A PDF
of this article was found and can be opened from its link.", #480), whose card
offers that PDF's address (`DocumentEntity.linkOnlyPdfUrl`) rather than the
publisher's page, as iOS/macOS keep the PDF's address as the record's link.

#### Tried sources (#480)

The maintainer's decisions of 2026-10-05. Pinned by
`fulltext_parity/open_access_statement.json`, read by all three platforms.

- **With a tried PDF, every source tried is listed:**
  `"Failed to obtain a PDF from the following tried sources: "`, then the
  entries joined by `"; "`, then `". "`, then the ending.
  - A PDF entry reads `{host}, named by {Unpaywall|OpenAlex} ({reason})`.
    The host is the address's host, lower-cased, else the address trimmed:
    Python's `urlsplit(address).hostname` (userinfo and port dropped; a space
    in the path does not hide it; a scheme-relative `//host/…` names its
    host; an authority with an unbalanced `[` or `]` has none, as `urlsplit`
    refuses it). The apps parse `scheme://authority` or `//authority` to the
    same result rather than use `URLComponents` or `java.net.URI` (rows under
    `hosts`).
  - A lookup entry reads `{name} ({reason})`, once per service, with the
    reason Python's `_unsettled` picks.
  - Entries come in chain order: other sources first, then `elsevier`,
    `unpaywall`, `unpaywall_landing_page`, `unpaywall_pdf`, `openalex`,
    `openalex_pdf`, `core` (stable). Elsevier's API is asked before any
    Unpaywall lookup, so its entry comes first (#480, stage C2). Entries that
    read the same (two PDFs on one host refused alike) are told once, the
    first after sorting.
  - An address is tried once, under the source that tried it first: one that
    both Unpaywall and OpenAlex name is listed once. This holds for an address
    refused before any request (not an absolute http(s) URL) too: Python's
    `known_urls`, Swift's `triedPDFs` and Android's `OpenAccessStep.addresses`
    all count it as tried.
  - The ending is "A freely available copy may exist. Whether this document
    is open access was not established." if any entry could not be asked,
    else "Whether this document is open access was not established." The
    configuration nudge follows.
  - Python's discovery, once nothing was obtained, gives this statement
    alone as its error, not after "Failed to download PDF from any available
    source.", which would say "Failed" twice. Without a tried PDF it keeps
    that claim and qualifies it.
- **Without a tried PDF, today's grouped sentence is kept**
  (`unestablished_access_clause`; one lookup reads exactly as before).
- **A PDF served but not saved is a caching note, never a shortfall:**
  "A PDF of this article was found at {host} but could not be saved on this
  device, so {only its link is kept | it could not be read}. Check the free
  storage space and try again."
  - Python records it as a `NOT_SAVED` skip, which keeps the discovery from
    concluding there is no full text. The discovery's message is the note
    alone: a served copy settles the open-access question, so "not
    established" beside it would contradict it. Other unsettled lookups stay
    in the record for the absence logic. Python always says "it could not be
    read".
  - Python's sentences built from a record (`unestablished_access_clause`,
    `paywall_message`, `no_pdf_sources_message`, `refused_access_sentence`)
    ignore its `NOT_SAVED` skips when they speak of access and append the
    note. So does the transparency analyser: its caveat
    (`_full_text_unassessed_caveat`, through `unsettled_lookups_clause`) and
    its refusal sentence (`refused_access_sentence`, which reads "A source
    refused access to this document." when only the note is left) never say
    a served copy "could not be asked".
  - The apps say "only its link is kept" when the link is what the reader is
    given: Swift when the stored link is the PDF's; Android when the record is
    link-only (`DocumentEntity.isLinkOnly`), whose card and sheet then offer
    the PDF's address (`linkOnlyPdfUrl`) and say `PDF_NOT_SAVED`'s words, never
    "could not be downloaded". Otherwise, an abstract returned instead, "it
    could not be read".
  - The rule is stated for open-access copies; other PDFs differ by
    platform. Python records a `NOT_SAVED` skip for a PDF from any source (a
    PMC render, a publisher's or DOI-resolved copy under the PDF download)
    and ends the walk there. Swift keeps a Europe PMC render's address as
    the note, but the render neither ends the walk nor settles the
    open-access question: Unpaywall is still asked. Android's chain returns
    the render before Unpaywall, so its note ends the fetch.
  - The apps store it as `Document.fullTextPDFNotSavedFrom` and
    `documents.full_text_pdf_not_saved_from` (Room 9). It is written and
    cleared by every fetch, as the shortfall is, and shown beside it
    (iOS/macOS: its own line in `ParseWarningBanner`; Android: the full-text
    screen, the fact-check card and the report's document sheet).

### PDF Downloading and Caching

```pseudocode
async function download_and_cache_pdf(
    url: string,
    article_id: string
) -> string:  # Returns local file path
    # `article_id` is the tagged ladder value from "Cache Keys", which cannot
    # be constructed for an article carrying no identifier at all. There is
    # therefore no shared entry to guard against here, and no refusal to make.
    #
    # Refusing an empty PMID was the earlier answer, and it was too blunt: it
    # threw away the article's *other* identifiers, so a Europe PMC record with
    # a PMC ID and no PMID got no PDF extraction at all, and the tier reported
    # a download failure indistinguishable from a dead link.
    filepath = cache_dir / cache_filename(article_id, url)

    # Check cache — validated, not a bare existence check. See
    # "Cache Read Validation" below for why and what it catches.
    cached = get_cached_pdf_path(article_id, url)
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
function get_cached_pdf_path(article_id: string, url: string) -> string | null:
    # Same guard, same reason: this must never read, quarantine, or serve the
    # entry that every identifier-less article shares.
    if article_id is empty:
        return null

    filepath = cache_dir / cache_filename(article_id, url)
    if not file_exists(filepath):
        return null

    head = read_bytes(filepath, count=4)
    if head == b"%PDF":
        return filepath

    # Quarantine, don't delete. Two facts justify it and no more: the entry
    # stops being served as this article's text, and its bytes stay available
    # to whoever investigates. Note a single-entry cache like this one has no
    # shadowing problem to solve — an atomic re-download simply overwrites the
    # entry. (bmlib's issue #71 argues something stronger, but that is a
    # property of its two-tier HTML-before-PDF lookup, not of this design.)
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

## OpenAlex's Locations (#480)

OpenAlex lists the places a work is hosted, some with a PDF URL Unpaywall
does not name (6 of 290 failed Unpaywall PDFs in the #480 spike; once every
Unpaywall location is tried, 1 of those 6 needed OpenAlex in the stage B
acceptance run). It is asked
once, by DOI, after every Unpaywall PDF failed and before the publisher and
DOI fallbacks (Python: before the first source that is not open access).
Pinned by `fulltext_parity/openalex_locations.json`.

```pseudocode
GET https://api.openalex.org/works/doi:{escape(doi)}?select=locations[&mailto={escape(contact)}]
# escape: RFC 3986 unreserved bare, UTF-8 bytes otherwise (Python's quote(s, safe="")),
# so a DOI is one path segment; no mailto without a usable contact email

200 → SERVED(pdf_urls(work))   # every locations[].pdf_url, non-blank string, trimmed,
                               # kept once, in order, whatever is_oa; a non-object
                               # location skipped; locations missing/null → none
                               # unreadable body, a non-object work, or locations not
                               # a list → UNREACHABLE(malformed_response)
404 → ABSENT                   # OpenAlex knows no such work (an HTML body)
any other status (after 429/5xx retries), transport failure → UNREACHABLE(failure)
```

`UNREACHABLE(http_status)` keeps #435's verb (`RequestFailure.is_answer`):
a 429 or a 5xx reads "CORE (…) could not be asked", any other status
(400, 403, 404, 410) "CORE (…) did not serve it". Either way it is an
unsettled lookup, never an absence: a search's 404 says nothing about the
article.

It is asked only when no Unpaywall copy was served and kept (in Swift, a
textless copy does not count; a copy refused for its size never does): it
could not raise the odds otherwise (the maintainer's decision, 2026-10-05).
It is never asked without a DOI, and a DOI that cleans to nothing (`doi:`, a
bare resolver URL, blanks) is none (Python cleans it once on entry; Swift
trims it first; Android treats a blank DOI as none). Candidates already in
Unpaywall's list are dropped (Python drops every address already found,
its PMC renders and publisher guesses too). Each is tried as an Unpaywall PDF
is: `%PDF`, `.part`, and refused, never offered as a link, under **OpenAlex's
copy** (`openalex_pdf`), with its address. An unreachable OpenAlex is recorded
under **OpenAlex** (`openalex`). An absence or a work naming no new PDF adds
nothing. Requests to `api.openalex.org` are paced at 10 per second
(`polite_request_pacing.md`).

The contact email is the one each platform already sends CrossRef for the
transparency analysis (Python: the PubMed email; iOS/macOS: the NCBI email,
or the app's own address `user@medicalfactchecker.app` when none is set;
Android: the NCBI email). Python and Android send no address when only their
placeholder is configured (`FALLBACK_CONTACT_EMAIL`,
`UnpaywallContact.usableEmail`). OpenAlex is a new recipient of the user's
address: before #480 no platform contacted OpenAlex (the transparency
analysers name its base URL but never call it). The maintainer chose
`mailto` = each platform's existing contact email in the first draft of
stage B.

- **Python** asks in `PDFDiscoverer` (`_discover_openalex`), lazily: at once
  when no other source was found, otherwise when the next source to try is not
  an open-access copy. Its publisher guesses (PLOS, Frontiers, PeerJ: typed
  `DOI_DIRECT` but marked open access) come before it; the apps have no such
  guesses.
- **Swift** asks in `FullTextService` after the Unpaywall tier, unless a copy
  was served and not cached (`openAccessNotSavedFrom`); a textless copy
  cached does not stop it (above).
- **Android** asks in `FullTextService.fetchFullText` when Unpaywall named no
  candidate it can request, and otherwise in recording, through its
  `askOpenAlex` hook, once every Unpaywall candidate failed.

## CORE's Extracted Text (#480, stage C)

CORE aggregates open-access repositories and serves the text it extracted
from their copies. Its v3 search is asked by DOI with **the user's own key**,
last in the chain: only when nothing earlier obtained the article's text (no
JATS body, no PDF downloaded, or one that yields no text, such as a scan; no
copy served but not saved), at most once per fetch, and never without a DOI. Service name **"CORE"**, source `core`
(desktop `core_text`), shown as **"CORE (extracted text)"**. Pinned by
`fulltext_parity/core_fulltext.json`.

```pseudocode
GET https://api.core.ac.uk/v3/search/works/?q={escape('doi:"' + lucene(trim(doi)) + '"')}&limit=3
    Authorization: Bearer {key}        # the key travels here and nowhere else
# lucene: \ → \\, then " → \"; escape: as OpenAlex's. The slash after works is
# required: without it CORE answers an HTML meta-refresh page.

no key            → no request, nothing recorded, nothing told (a debug log line,
                    on every platform)
this key refused (below) → KEY_REFUSED, no request
paused (below)    → UNREACHABLE(http_status 429), no request
200               → the first result that is an object, whose string doi
                    normalises to this DOI's, and whose string fullText,
                    trimmed, holds ≥ 5,000 code points: SERVED(that text);
                    none → ABSENT; an answer that is not UTF-8 JSON, is not
                    an object, whose results are not a list, or that holds
                    a string anywhere with an unpaired surrogate escape
                    (Apple's parser refuses the whole answer for one, so
                    every platform does) → UNREACHABLE(malformed_response)
401               → KEY_REFUSED, and this key is refused for the rest of the
                    process (shared by every client; held as sha256(trim(key)),
                    never the key); another key is asked as usual
any other status (after 429/5xx retries), transport failure → UNREACHABLE(failure)
```

`UNREACHABLE(http_status)` keeps #435's verb (`RequestFailure.is_answer`):
a 429 or a 5xx reads "CORE (…) could not be asked", any other status
(400, 403, 404, 410) "CORE (…) did not serve it". Either way it is an
unsettled lookup, never an absence: a search's 404 says nothing about the
article.

`normalise(doi)` trims, lower-cases, removes one leading `https://doi.org/`,
`http://doi.org/`, `https://dx.doi.org/`, `http://dx.doi.org/` or `doi:`, and
trims again. **The DOI check is what keeps another article's text out**: the
request is a search, and its results are not guaranteed to be this article.

- **Served** text is the article's full text, content kind `extracted`. It
  settles the open-access question, as a copy obtained does: no shortfall is
  stored with it, and it wins over a held abstract. It has no sections, so
  statement checks read "not assessed" (#428's "no marker, no charge"), as
  for a PDF's text: a funding or conflict-of-interest statement the text holds
  can still be found, but one it lacks is "not assessed" rather than counted
  against the study.
- **Unreachable** is an unsettled lookup under **CORE** (`core`), told in the
  open-access sentence ("CORE (HTTP 503 Service Unavailable) could not be
  asked, …") and last in "Tried sources" order. It blocks a settled absence
  (the maintainer's decision of 2026-10-06), as any unanswered source does.
- **A refused key (#498).** Only HTTP 401 means CORE refused the key; a 403
  stays an ordinary unreachable answer for that article (Cloudflare can answer
  403 to a valid key). The first 401 marks **that key** refused for the rest of
  the process, on the same session object as the 429 pause (Python
  `CoreThrottle`, Swift `CoreThrottle`, Android `CoreService`); every later
  fetch with that key makes no request. The refusal is scoped to the key
  (`core_fulltext.json`'s `key_refusal_scope`): the session object holds the
  SHA-256 digest (hex) of the trimmed key, never the key itself, and a fetch is
  refused without a request only when the current key's digest is the refused
  one. A key corrected in the settings is asked again; a 401 for it refuses that
  key instead. That 401, and every later fetch with the key, is `KEY_REFUSED`: recorded as a
  **skip** of CORE with reason `key_refused`, worded "the key in the settings
  was refused" (`core_fulltext.json`'s `key_refused_reason`), so the reader
  reads "CORE (the key in the settings was refused) could not be asked, so a
  freely available copy may exist. Whether this document is open access was
  not established." and, in "Tried sources", "CORE (the key in the settings
  was refused)". It blocks a settled absence, as any source not asked does,
  and adds no configuration nudge. A 401 ending resets the 429 count, as any
  other ending does; once a key is refused, that is what a fetch with it is
  told, paused or not.
- **A missing key is silent** (spec decision 4). It is not recorded as a
  `NOT_CONFIGURED` skip, which on the desktop would block every settled
  absence and add a configuration nudge to every sentence; the settings
  screens say what a key adds instead.
- **Two consecutive fetches ending in HTTP 429 pause CORE for the rest of the
  process.** CORE's personal key buys a daily token budget, not a rate, and
  the #480 spike saw 429s at 25 requests a minute. A paused fetch makes no
  request and is told as a 429. Any other ending resets the count.
- **Paced at 0.4 requests per second** (`polite_request_pacing.md`).
- **Where:** Python asks at each exit of `PDFDiscoverer.discover_and_download`
  that obtained no PDF, through a hook `FulltextDiscoverer` passes in, which
  reads the cached CORE text (`*.core.txt`) before asking. The cache file is
  stamped `core-text v2` and records the normalised DOI the text was served
  for; it is served again only for that DOI and only while it holds the
  5,000 code points, so the cache keeps CORE's rules. It is never returned
  by `find_existing_fulltext`, and a cache file that cannot be read is
  recorded as an unread cached full text (#354), so a CORE that then answers
  "none" settles nothing. Swift asks in `FullTextService` after OpenAlex,
  unless a copy was served and not cached.
  Both Python and Swift also ask CORE after a copy that yields no text (a
  scan), whether or not an abstract is held, as a textless copy is no full
  text obtained: served text wins, and otherwise the scan is returned with
  CORE's failure or refused key recorded beside it. Swift's textless Europe
  PMC render still ends the walk there, before Unpaywall and OpenAlex, where
  Python goes on to them (#505). Android stores PDFs without extracting text,
  so it does not.
  Android asks in `fetchFullText` when no open-access candidate exists, and
  otherwise in recording, through its `askCore` hook, once every candidate
  failed. Android shows the text as plain text, never through its
  JavaScript-enabled WebView. Android's Europe PMC render tier returns before
  Unpaywall (#493), so when Europe PMC lists a render Android asks neither
  Unpaywall, OpenAlex nor CORE.

## Elsevier's Article API (#480, stage C2)

Elsevier's Article Retrieval API serves an Elsevier article's PDF to a
requestor entitled to it. It is asked by DOI with **the user's own key** and,
when one is set, an **institutional token**: only for a DOI Elsevier
registered (`10.1016/`), at most once per fetch, after Europe PMC's PDF render
and before any Unpaywall lookup, and only when nothing earlier obtained the
article (no JATS body, no PDF). Service name **"Elsevier's API"**, source
`elsevier` (desktop `PDFSourceType.ELSEVIER_API`, `elsevier_api`; the full
text it yields is `FulltextSourceType.DOWNLOADED_PDF`, as any downloaded
PDF's), shown as **"Elsevier's API (PDF)"**. Pinned by
`fulltext_parity/elsevier_article.json`.

```pseudocode
eligible(doi) = normalise(doi).startswith("10.1016/")   # CORE's normalise, reused

GET https://api.elsevier.com/content/article/doi/{escape_path(bare(doi))}
    X-ELS-APIKey: {key}          # the key travels here and nowhere else
    X-ELS-Insttoken: {token}     # only when the token is not blank; never without a key
    Accept: application/pdf
    # Python also sends User-Agent: EUROPEPMC_USER_AGENT
# bare: trimmed, one resolver or doi: prefix removed as normalise matches it
# (in any case), trimmed again; the DOI's own case is kept. escape_path: ALPHA,
# DIGIT, - . _ ~ and / bare, every other UTF-8 byte as %XX in upper-case hex
# (Python's quote(s, safe="/")); a ; is encoded, as a servlet would read it as
# a path parameter. Never the apiKey or insttoken query parameter. Redirects
# are not followed. The base's trailing slashes are dropped.

no key, or a DOI not eligible → no request, nothing recorded, nothing told
                                (a debug log line, on every platform)
this key refused (below)      → KEY_REFUSED, no request
these credentials refused from this network (below)
                              → NETWORK_REFUSED, no request
paused (below)                → UNREACHABLE(http_status 429), no request
# (these three make no request, and neither count toward the pause nor reset it)
200 with an X-ELS-Status whose value, trimmed, starts WARNING (in any case)
                              → ABSENT: the first page only. Read before the
                                body; logged at INFO
200 whose body starts %PDF    → SERVED(the PDF), under the platform's PDF rules
                                (desktop: the size limit; the .part file; the
                                not-saved path)
200 otherwise                 → UNREACHABLE(malformed_response)
404                           → ABSENT
401                           → KEY_REFUSED, and this key is refused for the rest
                                of the process (held as sha256(trim(key)), never
                                the key), whatever the token
403 whose body, read to 64 KiB, holds the ASCII bytes AUTHENTICATION_ERROR
                              → NETWORK_REFUSED, and these credentials are refused
                                for the rest of the process (held as
                                sha256(trim(key) + "\n" + trim(token or "")))
any other status (any other 403, a 3xx; after 429/5xx retries), transport failure
                              → UNREACHABLE(failure)
```

The statuses 429, 500, 502, 503 and 504 are retried, four attempts in all, each
paced, as CORE's. `UNREACHABLE(http_status)` keeps #435's verb
(`RequestFailure.is_answer`): a 429 or a 5xx reads "Elsevier's API (…) could
not be asked", any other status (400, 403, 410, a 3xx) "Elsevier's API (…)
did not serve it". Either way it is an unsettled lookup, never an absence.

**The error answers are Elsevier's documented shapes, not observed ones.** The
#480 spike recorded only that Elsevier refused every request from outside the
institution with `AUTHENTICATION_ERROR`, not the status or the body. The
off-network refusal's status (403) and its body's format (XML for
`Accept: application/pdf`; a JSON row is pinned too) are taken from Elsevier's
documentation, and the fixture's rows will be corrected once the maintainer has
run `scripts/elsevier_probe.py` off the institution's network and on it. The
test (the token anywhere in the first 64 KiB of the body) is chosen to hold
for either format.

### What the reader is told

- **Served:** the article's PDF, shown as "Elsevier's API (PDF)"; its text is
  extracted as any downloaded PDF's. It settles the open-access question, as a
  copy obtained does: no shortfall is stored with it. A PDF that yields no text
  (a scan) follows the existing textless-PDF rules (Python, #499: CORE is
  asked after it).
- **Absent** (a 404, or the first page only): nothing is added and nothing is
  told; the chain goes on.
- **Unreachable:** an unsettled lookup under `elsevier` (Python
  `SERVICE_ELSEVIER`), with a lookup entry "Elsevier's API ({reason})":
  "Elsevier's API (HTTP 503 Service Unavailable) could not be asked, so a
  freely available copy may exist. Whether this document is open access was
  not established." or "Elsevier's API (HTTP 403 Forbidden) did not serve it,
  so whether this document is open access was not established." In "Tried
  sources" it comes first of the chain's entries, before Unpaywall's. It
  blocks a settled absence.
- **Key refused:** a skip of `elsevier` with reason `key_refused`: "Elsevier's
  API (the key in the settings was refused) could not be asked, so a freely
  available copy may exist. Whether this document is open access was not
  established." It blocks a settled absence and adds no configuration nudge.
- **Network refused:** a skip of `elsevier` with reason `network_refused`
  (Python `LookupSkipReason.NETWORK_REFUSED`): "Elsevier's API (not available
  from this network) could not be asked, so a freely available copy may exist.
  Whether this document is open access was not established." It blocks a
  settled absence and adds no configuration nudge.
- **Served but not saved** (desktop): the existing `NOT_SAVED` caching note,
  its address the article URL, which carries no key: "A PDF of this article
  was found at api.elsevier.com but could not be saved on this device, so it
  could not be read. Check the free storage space and try again." Nothing else
  is asked. The apps differ (below).
- **Larger than the download limit** (desktop only; the apps set none): an
  `OVER_SIZE_LIMIT` skip of `elsevier`, its address the article URL: "Failed to
  obtain a PDF from the following tried sources: api.elsevier.com, named by
  Elsevier's API (larger than the download limit). A freely available copy
  may exist. Whether this document is open access was not established." The
  chain goes on.

The notices and their stored forms are rows in
`open_access_unsettled_notice.json`.

### Decisions

The maintainer's decisions of 2026-10-08 override the spec's decision 3 (open
access only), which is dropped.

1. **A first-page PDF is never served.** A requestor who is not entitled gets
   200, the PDF's first page only, and `X-ELS-Status: WARNING - Response
   limited to first page because requestor not entitled to resource`. That is
   Elsevier's answer that this requestor gets no full text, so it is an
   **absence** for this source, told nothing, and the chain goes on to
   Unpaywall, which may hold an open copy. One page of an article is never
   used as its text (golden rule 13). The header is read before the body,
   since the first page is a valid PDF.
2. **Whatever the requestor is entitled to is served:** open-access articles
   anywhere, and subscribed ones from the institution's network or with an
   institutional token. Elsevier decides the entitlement and says so in its
   answer, so one request per article suffices; no metadata check is made
   first, which would double the requests against a weekly quota.
3. **The off-network refusal is unsettled**, as CORE's refused key is. The key
   is valid; the article may still be open access, or served on another
   network or with a token. The refusal says nothing about the article, so it
   cannot settle an absence. The channel is configured, so no nudge.
4. **Redirects are not followed.** The key travels in `X-ELS-APIKey`, a custom
   header that no client strips on a redirect (`requests` and OkHttp drop only
   `Authorization`, and only off-host; `URLSession` drops only
   `Authorization`), so a followed redirect would hand the key to wherever it
   points. A 3xx is therefore unreachable `http_status`, never followed.
5. **Refusals are scoped to the credentials refused.** A 401 refuses that key,
   whatever the token. A 403 `AUTHENTICATION_ERROR` refuses that key and token
   together, so a token added in the settings, or another key, is asked again.
   A 403 without the token (`AUTHORIZATION_ERROR`, an empty body, a CDN's)
   refuses nothing: it is an ordinary unreachable answer for that article. The
   session object holds digests (SHA-256, hex), never a key or a token.
6. **The session state is process-wide**, shared by every client, and shares
   nothing with CORE's: a CORE 429 never pauses Elsevier. Two consecutive
   fetches that end in 429 (after retries) pause Elsevier for the rest of the
   process; any other ending resets the count. Elsevier's weekly quota answers
   429 `QUOTA_EXCEEDED` once spent. A paused fetch makes no request and is told
   as a 429. **A fetch that makes no request** (key refused, network refused,
   paused) **neither counts toward the pause nor resets it**, as CORE's client
   returns before it records an ending (stage C2's ruling, 2026-10-08;
   `elsevier_article.json`'s `session` rows). The checks before a request come
   in the order of the outcome table: this key refused, these credentials
   refused from this network, then paused, so a refused key is told as
   refused even while Elsevier is paused.
7. **No key, or another publisher's DOI, is silent** (the spec's decision 4,
   as CORE's): no request, nothing recorded, no sentence, the absence settled
   as before. Elsevier publishes some imprints under other DOI prefixes; they
   are out of scope (the spec's rule).
8. **The key and the token never leave their headers.** They are the settings
   trimmed, and neither ever appears in a URL, a log line, an exception
   message or a `repr`, a stored record or an exported config. A blank key
   means Elsevier is not configured; the token is never sent without a key.
9. **An error body is read to 64 KiB** (`error_body_max_bytes`) to look for
   `AUTHENTICATION_ERROR`: a bounded read of a provider's error, not research
   content, so golden rule 13 does not apply.
10. **Paced at 2 requests per second** (`polite_request_pacing.md`): Elsevier
    allows 10 per second and a weekly quota.

### Rules for the apps

iOS/macOS and Android follow the outcome table above, with these rules, which
follow from their maps:

- **Elsevier's article URL is never a reader link**, since it needs the key. It
  is never stored as the document's PDF URL or link, offered as "Open in
  Browser", fetched again without its headers (Swift's `PDFContentLoader`,
  Android's `pdfOrLink`), or set as the not-saved address
  (`fullTextPdfNotSavedFrom` / `pdfNotSavedFrom`). A served Elsevier PDF is
  held only as a local file.
- **A failure or a refusal never falls back to a link.** It is recorded as the
  outcome table says, and the walk goes on to Unpaywall.
- **Served but not saved differs from the desktop** (a deviation, deliberate).
  The walk goes on to Unpaywall, and Elsevier records nothing then; a copy
  Unpaywall serves settles the question. When nothing later serves a copy, the
  apps' not-saved note is **not** used, as it carries a link. The result keeps
  `OpenAccessShortfall(source: elsevier, failure: request_failed)` instead,
  logged at ERROR with its cause, and the reader is told "Elsevier's API (the
  request failed) could not be asked, …". It keeps the absence unsettled,
  which is the property that matters.
- **No size limit**, as for every PDF in the apps.
- **Redirects are refused:** Swift with `RedirectRefusingTaskDelegate`
  (`Services/EutilsRequest.swift`) per task, as `PubMedService` uses it;
  Kotlin with a client derived with `followRedirects(false)` and
  `followSslRedirects(false)`.
- **Android reaches Elsevier only when Europe PMC offered no render URL**
  (#493). Android's render tier returns `EuropePmcPdf(url)` without
  downloading it, so a render that would fail never reaches the tiers after
  it. This is #493's limit, not fixed in stage C2; Elsevier is reached after
  a render once #493 is fixed.

### Where, and the settings

- **Python** asks in `PDFDiscoverer.discover_and_download`, after the DOI is
  cleaned and before the sources it discovers (its PMC renders, Unpaywall,
  OpenAlex, the publisher guesses); `FulltextDiscoverer`'s Europe PMC render
  (its step 2b) comes before it. The key and token are
  `LiteConfig.discovery.elsevier_api_key` and `elsevier_insttoken`
  (environment `ELSEVIER_API_KEY` / `ELSEVIER_INSTTOKEN`), saved owner-only
  and redacted on export as `core_api_key` is; two fields in the settings
  dialog's "Full Text" tab.
- **Swift** asks in `FullTextService.fetchFullText`, after Europe PMC's render
  tier and before the Unpaywall tier. Keychain keys `elsevier_api_key` and
  `elsevier_insttoken` (`AppSettings`); fields beside CORE's in
  `SettingsView` and `MacSettingsView`.
- **Android** asks in `FullTextService.fetchFullText`, before Unpaywall (and
  see #493 above). `EncryptedSharedPreferences` keys `elsevier_api_key` and
  `elsevier_insttoken` (`SettingsRepository`); masked fields beside CORE's.
- Saving a key reports failure, as CORE's does. The explanations, verbatim on
  every platform:
  - Key: "Optional. A free Elsevier API key (dev.elsevier.com) lets the app download the PDFs of Elsevier articles you are entitled to: open-access articles anywhere, subscribed ones from your institution's network."
  - Token: "Optional. An institutional token from Elsevier lets the key use your institution's subscriptions away from its network."

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
        extracted_text: string | null, local_pdf_path: string | null,
        # How much of the PDF the text came from. Travels with the text, and
        # is persisted with it — see "Extraction Coverage".
        extraction_coverage: (converted_pages, page_count) | null)
    DOI(web_url: string)
    Cached(file_path: string)
    # Callers record this on the document for good.
    Unavailable
    # (apps) Nothing was found, but Europe PMC did not settle it: never recorded.
    NotEstablished(failure: RequestFailure)

async function fetch_fulltext(
    pmc_id: string | null,
    doi: string | null,
    pmid: string | null,
    email: string,
    # What the record said its identifier was, carried from the search that
    # found it and persisted with the document. null means nothing was stated —
    # including every document stored before this field existed — and the shape
    # rule stands in. See "Identifier Kind" below.
    stated_kind: IdentifierKind | null
) -> FullTextResult:

    # The article half of the key. A ladder, tagged with the identifier's
    # kind — not the rung it arrived on; see "Cache Keys". null only when the
    # article carries none of the three, which is also the only case that
    # reaches no PDF tier at all.
    #
    # Built here, once, from the identifiers the *document* carries — never
    # from a PMC ID a lookup below resolves. A key that depended on whether a
    # search succeeded would file one article under two names across runs.
    #
    # There is no cache check at this point. The other half of the key is the
    # source URL, which is not known until a tier has one, so each PDF tier
    # consults the cache itself with `check_cache(cache_key, url)`.
    cache_key = article_cache_key(pmid, pmc_id, doi, stated_kind)

    # A body-less Europe PMC rendering, held here until every later tier has
    # had its turn. null when none was seen. See "Abstract Holdback" below.
    held_abstract: FullTextResult | null = null

    # Declared with europe_pmc_shortfall (the apps' not-established record).
    europe_pmc_shortfall = null
    pmc_open_data_shortfall = null

    # 2. Try Europe PMC XML (best quality). A preprint is fetched by its
    # Europe PMC record ID, having no PMC ID; with neither, the lookup is
    # recorded as skipped (no identifier), not as Europe PMC failing.
    accession = pmc_id or preprint_record_id
    if accession:
        fetch = await fetch_fulltext_xml(accession)
        # UNREACHABLE and ABSENT are both recorded against Europe PMC (see
        # Retrieval above), and the chain continues.
        if fetch is SERVED:
            # Pass the accession as known_pmc_id only when it is a PMC ID: a
            # preprint's figures are not filed under its PPR ID.
            content = parse_fulltext(fetch.xml, accession)
            result = FullTextResult.EuropePMC(
                html=content.html,
                markdown=content.markdown,
                content_kind=content.content_kind
            )
            if content.content_kind == ABSTRACT:
                held_abstract = result
            else:
                return result   # FULLTEXT — nothing beats it

    # 2a. PMC's open-data bucket (#480), reached only when step 2 returned no
    #     FULLTEXT result. Its abstract-only deposit is held back as Europe PMC's is.
    #     Not asked while Swift holds a body-less Europe PMC deposit: Python and
    #     Kotlin have no content kind and treat that deposit as served, so Swift
    #     matches them.
    if pmc_id and held_abstract == null:
        bucket = await fetch_pmc_open_data(pmc_id)
        if bucket is SERVED: (same parse and holdback as step 2, source pmc_open_data;
                              a parse failure sets failure = malformed_response)
        if bucket failed (UNREACHABLE, or its XML did not parse)
                and europe_pmc_shortfall == null:
            # The apps keep one not-established sentence, so Europe PMC's shortfall
            # takes precedence; Python records both in its lookup record.
            # Read only at 6b: the PDF and link exits below do not carry it
            # yet in the apps (#488); Python carries it on every result.
            pmc_open_data_shortfall = bucket.failure   # blocks "no full text"

    # 3. Try a free PDF tier (Europe PMC's own render, then Unpaywall).
    #
    #    Europe PMC's render URL arrives with identifier resolution, which a
    #    caller that already holds a PMC ID never triggers. Resolve it here if
    #    it is still missing, or this tier is silently skipped for exactly the
    #    open-access articles that have one.
    if europe_pmc_pdf_url == null:
        europe_pmc_pdf_url = await resolve_pdf_render_url(pmid, pmc_id, doi)

    #    A tier's outcome has four states, not two. "We chose not to download"
    #    and "we downloaded and it failed" used to be indistinguishable, so a
    #    render URL that 404s ended the chain and an open-access copy of the
    #    same paper was never requested.
    #
    #    After the render, every PDF Unpaywall names, then, only if no copy was
    #    served, OpenAlex's, asked once with every address already tried
    #    (#480, stage B). An open-access copy refused is recorded with its
    #    address and is never the link (#478); a copy served but not cached
    #    ends the walk with a caching note. "Tried sources (#480)" has the
    #    rules, and each platform's differences.
    #
    #    Between the render and the first Unpaywall lookup, Elsevier's API is
    #    asked once (#480, stage C2: with a key, for a 10.1016/ DOI, when nothing
    #    earlier obtained the article; "Elsevier's Article API"). A PDF it
    #    serves is returned as an open-access copy's is, held as a local file
    #    only; a first page only or a 404 adds nothing; unreachable or refused
    #    is recorded, and the walk goes on to Unpaywall. Its URL is never a
    #    link: it needs the key.
    for pdf_url in [europe_pmc_pdf_url, *await fetch_unpaywall_pdf_urls(doi, email),
                    *openalex_pdf_urls_once_none_served(doi, tried)]:
        if pdf_url == null:
            continue
        outcome = await download_and_extract(pdf_url, cache_key)

        switch outcome:
            case NOT_ATTEMPTED:          # extraction switched off
                if held_abstract != null:
                    continue
                return FullTextResult.PDF(pdf_url, NONE, null, null, null)

            case DOWNLOAD_FAILED:        # 404, server error, not a PDF
                # Europe PMC's render: keep the URL in reserve and try the
                # next tier (an open-access copy refused is recorded instead,
                # #478, and is never kept as the link). A link we
                # could not fetch still names the article, so it beats a
                # publisher landing page — and loses to any copy a later tier
                # actually retrieves. First writer wins: earlier tiers are
                # better sources.
                if link_fallback == null:
                    link_fallback = FullTextResult.PDF(pdf_url, NONE, null, null, null)
                continue

            case NO_TEXT(local_path):    # a scan, or a file the reader declined
                if held_abstract != null:
                    continue
                # A scan is no full text obtained: CORE is asked first (once,
                # with a key and a DOI; "CORE's Extracted Text").
                core = await ask_core_once(doi)
                if core.served:
                    return FullTextResult.CORE(core.text)
                # The file is real even though its prose is not; CORE's
                # failure or refused key goes with it.
                return FullTextResult.PDF(pdf_url, NONE, null, local_path, null,
                                          shortfall=core.unsettled)

            case EXTRACTED(local_path, text, coverage):
                return FullTextResult.PDF(pdf_url, EXTRACTED, text, local_path, coverage)

    # 3b. CORE's extracted text (with a key and a DOI, unless a copy was
    #     served and not cached): asked once; served text beats the held
    #     abstract. Unreachable or a refused key is recorded and keeps the
    #     absence open.
    core = await ask_core_once(doi)
    if core.served:
        return FullTextResult.CORE(core.text)

    # 4. The held abstract, if nothing better arrived.
    if held_abstract != null:
        return held_abstract

    # 5. Then a PDF whose bytes we could not fetch. Below the abstract, which
    #    is text in hand; above the publisher page, which only guesses at
    #    where the article might be.
    if link_fallback != null:
        return link_fallback

    # 6. Fall back to DOI resolver
    if doi:
        web_url = get_doi_url(doi)
        if web_url:
            return FullTextResult.DOI(web_url)

    # 6b. (apps) Europe PMC or the bucket recorded a lost search, a failed fetch
    #     or a 404, and no later fetch was served: the absence is not established,
    #     and callers persist Unavailable (#434). Europe PMC's JATS parse
    #     failure does not yet count here (#436); the bucket's does. Europe PMC's
    #     shortfall takes precedence in the sentence shown.
    if europe_pmc_shortfall != null:
        return FullTextResult.NotEstablished(europe_pmc_shortfall)
    if pmc_open_data_shortfall != null:
        return FullTextResult.NotEstablished(pmc_open_data_shortfall)

    # 7. No full text available
    return FullTextResult.Unavailable
```

### Extraction Coverage

A PDF extraction routinely recovers *some* of a document. The page counts it
produces must reach the caller and be persisted with the text, not merely
logged — this is the same defect as an unreported truncated parse, on a
different channel, and it is the more dangerous one: the document renders
complete on screen, so nothing about it looks wrong.

Carry `(converted_pages, page_count)` as one value, never as two independent
fields. Written separately they can be left describing different
extractions, and a coverage figure that disagrees with the text beside it
states a precise, wrong thing.

Text without coverage is the silence this exists to end. The converse is
allowed and is the point: a scan reports `0` of however many pages *with no
text at all*, because "we read a document and got nothing out of it" is the
fact the reader most needs, and pairing the two strictly would make it the
one fact the type could not state. A password-protected file reports the
same way — PDF libraries count its pages even when they hand back no text.
Only a file that could not be opened at all reports no coverage: there is
nothing to count, and inventing `0 of 0` would dress a failed read as a
measured one.

Surface it wherever a truncated parse is surfaced. The reason is specific:
the pages that fail to extract are disproportionately the *last* ones, which
is where funding, competing-interest and data-availability statements live.
A transparency analyser fed a partial extraction records their **absence**,
and the reader is told as a fact about the paper something that is only a
fact about our extraction.

Report completeness as "every page yielded text", and treat a zero-page
document as *not* complete — `converted_pages == page_count` is vacuously
true for it, and answering "complete" would report the emptiest possible
result as the most successful kind.

A page that yielded nothing is **not** a converted page. bmlib's
`PyMuPDFConverter` counts it as one, which makes a two-page article whose
second page is a scan report `2/2` and tell the reader nothing; the rule
here is the other one, and it is what makes a partial extraction visible at
all. (Neither rule catches a page bearing only a watermark or a download
stamp — closing that needs a minimum-prose floor, tracked separately.)

### Cache Keys

A cache entry is keyed on the article **and the source URL**, not on the
article alone:

```pseudocode
# The article half: the first identifier the document actually has, tagged
# with which kind it is. null when it has none of the three, which is the one
# case with no stable name to file bytes under.
function article_cache_key(pmid, pmc_id, doi, stated_kind) -> string | null:
    if not blank(pmid):
        return tagged(kind_tag(resolve_kind(stated_kind, trim(pmid))), trim(pmid))
    if not blank(pmc_id): return tagged("pmc", trim(pmc_id))
    if not blank(doi):    return "doi_" + hex(sha256(trim(doi)))[:32]
    return null

function kind_tag(kind) -> string:
    if kind == PUBMED:   return "pmid"
    if kind == PREPRINT: return "ppr"
    if kind == PMC:      return "pmc"
    if kind is a source token: return "src"   # stated, but not modelled here
    return "id"                               # nobody named it at all

    # "src" and "id" are separate buckets because the two describe different
    # situations, and since the shape rule stopped naming PubMed IDs one of
    # them is a bare decimal. A stated ETH accession and an unclassified
    # identifier with the same digits would otherwise share a filename and be
    # served each other's bytes. Neither tag carries the source token itself:
    # the token is network-supplied and this position needs a fixed
    # vocabulary, so two identifiers within one bucket that are byte-identical
    # still collide.

function tagged(tag, identifier) -> string:
    # Sanitising is lossy — every unsafe character becomes `_` — so an
    # identifier it alters needs a digest to stay distinct from every other
    # identifier that sanitises the same way. One it leaves untouched, which
    # is every well-formed PMID and PMC accession, keeps its readable name.
    #
    # `sanitise` replaces every character outside [A-Za-z0-9_] with `_`. The
    # identifier arrives from search results, and a value holding `/` or `..`
    # would place the written file outside the cache directory. `-` is
    # deliberately absent from that set, which is what leaves it free to
    # separate the article component from the source-URL fingerprint in
    # `cache_filename` below.
    #
    # The tag is not sanitised. Every tag comes from the fixed vocabulary in
    # `kind_tag`, and `stated_kind` refuses a source token outside [a-z0-9],
    # so no caller-supplied string reaches this position.
    safe = sanitise(identifier)
    if safe == identifier: return f"{tag}_{safe}"
    return f"{tag}_{safe}_{hex(sha256(identifier))[:32]}"

function cache_filename(article_id: string, url: string) -> string:
    # A stable digest — SHA-256 or equivalent. Not a language's built-in
    # hash: those are commonly seeded per process, so the filename would
    # change on every launch and every entry would miss forever.
    fingerprint = hex(sha256(url))[:16]

    return f"{article_id}-{fingerprint}.pdf"
```

Three things about that ladder are load-bearing.

**The primary slot comes first, not the PMC ID.** It is the rung most
consistently populated: Europe PMC returns a record `id` for effectively every
result, and results are commonly built as `pmid or id or ""` — so the slot is
empty only where neither was present — and PubMed supplies a PMID for every
result, whereas a PMC ID exists only for articles deposited in PMC. Putting the
always-present rung first means the fewest articles fall through to a weaker
one, and an article found through both providers lands on the same rung either
way — for a MEDLINE article both supply the same PMID. The lower rungs carry
the cases where the slot really is empty, which in practice means documents
persisted by older builds.

**The kind is part of the name, including for the primary slot.** That slot
does not hold one kind of thing: a PubMed ID for a MEDLINE record, a `PPR…`
accession for a preprint, a PMC ID for a PMC-only record. Untagged, an article
whose primary slot happens to hold `PMC7654321` names the same entry as a
different article reached by a *PubMed ID* of `PMC7654321`, and one is served
the other's bytes. Tagging invalidates entries written by earlier builds. They
are re-downloaded once, and then *orphaned* rather than replaced: the new
filename differs, and the per-article delete matches on the tagged prefix, so
only a full cache clear reclaims them. Still the cheap direction to be wrong in
— a stale entry costs one download and some disk, a wrong entry costs the
reader a wrong answer.

**The tag names the identifier's kind, not the rung it arrived on.** A PMC-only
record carries its accession in the primary slot *and* in `pmc_id`, so tagging
the rung filed one article under two names and downloaded its PDF twice — for
exactly the record class the ladder was added to serve. Both rungs tag `pmc`,
so both name one entry. This is also why the tag for a PubMed ID is `pmid` and
not `id`: `id` is now the bucket for an identifier whose kind nothing settles,
and two such identifiers that are byte-identical still share a name. That is
the one collision the scheme keeps, and it is the collision every primary-slot
value had before the kinds were separated.

**No two identifiers share a name**, which is stronger than keeping the kinds
apart and is the property the cache actually needs. Sanitising is not
injective, so any rung it alters carries a digest as well. Relying on real
identifiers being alphanumeric would make this a property of the data rather
than of the key, and the primary slot takes whatever the caller passes.

**The DOI is digested, not sanitised.** It carries `/` and `.`, neither of
which survives sanitising, so `10.1/abc` and `10.1_abc` both become `10_1_abc`
and share one entry. Every other rung is sanitised rather than trusted:
identifiers arrive from search results, and a value holding `/` or `..` would
place the written file outside the cache directory.

One article can be offered more than one PDF — Europe PMC's render URL and
Unpaywall's open-access copy are different files of the same paper. Keyed on
the identifier alone, the first tier to download wins the entry and every
later tier is served *its* bytes: the chain then returns a Europe PMC
download as the Unpaywall result, records the wrong provenance, and never
fetches the copy that might have extracted cleanly.

Deleting an article's cache must remove every entry it holds, and clearing
the cache must remove quarantined (`.corrupt`) entries too — otherwise bytes
set aside for inspection accumulate in a directory the user asked to empty.

### Identifier Resolution Queries

Resolving a PMC ID and a free PDF render URL means asking Europe PMC for the
article by identifier, and **Europe PMC answers only when the identifier is
asked for in its own terms**. A query that names the wrong source matches
nothing, which is indistinguishable from the article not existing.

```pseudocode
# Most specific first, in the same order the cache key ladder climbs.
function identifier_queries(pmid, pmc_id, doi, stated_kind) -> [Query]:
    queries = []

    if not blank(pmid):
        id = trim(pmid)
        kind = resolve_kind(stated_kind, id)
        if kind == PREPRINT:     queries.append(f'ext_id:{id} src:ppr')
        elif kind == PMC:        queries.append(f'PMCID:{id}')
        elif kind is a source token t: queries.append(f'ext_id:{id} src:{t}')
        else:                    queries.append(f'ext_id:{id} src:med')

    if not blank(pmc_id):
        queries.append(f'PMCID:{trim(pmc_id)}')

    if not blank(doi):
        queries.append(f'DOI:"{trim(doi)}"')

    # Drop repeats, keeping the first of each query string. A PMC-only record
    # carries its accession in the primary slot *and* in pmc_id, so both rungs
    # build the identical `PMCID:` query — for exactly the record class this
    # ladder was added to serve. Without this the same request goes out twice,
    # and on a transient failure the retry backoff is paid twice for one answer.
    # Keeping the *first* leaves the more specific rung's description to name
    # the article in the log.
    return dedupe_preserving_order(queries, by: query_string)
```

The kind comes from the record, not from the string. Europe PMC states it on
every result in the `source` field (`MED`, `PPR`, `PMC`, and a dozen more), and
the shape rule below is only a stand-in for records that stated none — every
document persisted before the field existed, and any identifier reaching the
chain from elsewhere:

```pseudocode
# What a provider said the identifier is. null when it said nothing.
#
# A token outside [a-z0-9] is refused, not carried. It reaches a query as
# `src:{token}` and a cache filename as a tag, and both need a closed set: a
# token holding a space or a colon makes the query parse as something else and
# match nothing, which this ladder reads as "no such article". Every token
# Europe PMC publishes is a short alphanumeric word, so this refuses nothing
# the provider actually sends.
function stated_kind(record) -> Kind | null:
    token = lowercase(trim(record.source))
    if blank(token): return null
    if not token.matches(/^[a-z0-9]+$/): return null
    if token == "med": return PUBMED
    if token == "ppr": return PREPRINT
    if token == "pmc": return PMC
    return SourceToken(token)     # NBK, PAT, AGR, ETH, …

# The stand-in, for identifiers nobody classified. Deliberately not total, and
# **it may not name a PubMed ID**. A bare decimal is the shape of a PubMed ID
# and equally the shape of a Europe PMC thesis (ETH), case report (CBA) or HIR
# accession, none of which carry a PubMed ID at all — 322,044 such records with
# abstracts, measured against the live Europe PMC API on 2026-09-11 with
# SRC:ETH OR SRC:CBA OR SRC:HIR, resultType=core. The count drifts daily; the
# argument needs only that it is not zero. Guessing wrong there does not produce a dead
# link: Europe PMC thesis 889149 and PubMed article 889149 both exist, and the
# second is a 1977 paper on mouse courtship, which is what the reader was
# handed as this article's source.
function infer_kind(id) -> Kind:
    u = uppercase(trim(id))
    if blank(u):             return UNKNOWN
    if u.starts_with("PPR"): return PREPRINT
    if u.starts_with("PMC"): return PMC
    return UNKNOWN

# Three sources of knowledge, strongest first: what the record said, what the
# identifier's shape settles, and finally who returned the record.
#
# A provider is consulted last, and only PubMed vouches. PubMed returns MEDLINE
# records and nothing else, so the search itself states what a document stored
# before the kind field existed never recorded — without which every such
# document loses its PubMed link. A *merged* search vouches for nothing: the
# mode is recorded on every document it produces, including the ones only
# Europe PMC returned.
#
# `all_digits` means ASCII `0`-`9`, and a blank id is never PUBMED. Both are
# load-bearing and both differ by language: Kotlin's `"".all { it.isDigit() }`
# is true and Python's `"".isdigit()` is false, so a port that omits the blank
# guard sends `pubmed.ncbi.nlm.nih.gov//` for an empty slot on one platform and
# not the other. A non-ASCII digit test is worse: it calls `١٢٣` a PubMed ID.
function resolve_kind(stated, id, provider = null) -> Kind:
    if stated is not null and stated != UNKNOWN: return stated
    shaped = infer_kind(id)
    if shaped != UNKNOWN: return shaped
    if provider == PUBMED and all_digits(trim(id)): return PUBMED  # ASCII 0-9
    return UNKNOWN

# The one predicate that authorises a PubMed URL or a `PMID:` citation line.
# Every surface asks this — the last-resort fallback and every link, share
# sheet and citation in the apps. Answered per surface, it is answered
# differently per surface: nine app surfaces had none of this rule at all.
function pubmed_id(id, kind) -> string | null:
    v = trim(id)
    if blank(v):                          return null
    if resolve_kind(kind, v) != PUBMED:   return null
    if not all_digits(v):                 return null   # ASCII 0-9
    return v
```

**Store the kind with the document, as the source token itself.** The record is
gone by the time any of this runs: the query, the cache filename and the
preprint indicator all happen days later, from persisted fields. A kind that is
not stored is a kind that must be guessed, and a guess can only recognise the
shapes it was taught — every other Europe PMC source is then asked for under
`src:med`, where it matches nothing. Storing the provider's own token means
nothing has to be invented to write it down, and an absent value keeps its own
meaning: "written before this field existed", which falls back to the shape
rule rather than claiming a kind.

**A shape-inferred `UNKNOWN` still queries `src:med`.** That is where such a
value has always gone. It matches nothing unless the identifier really is a
PubMed ID, so log the empty result — otherwise an identifier asked for under a
source that cannot answer is indistinguishable from an article Europe PMC has
never held.

**Only a PubMed ID may be pasted after the PubMed base URL, and a number's
shape never says it is one.** Every surface that builds such a URL, or prints a
`PMID:` line in a citation, goes through `pubmed_id` above — the retrieval
chain's last resort and every link, share sheet and reference list in the apps.

Two things this closes. A stated preprint whose accession happens to be numeric
is not handed to the reader as a PubMed link that names no article. And a bare
decimal that nothing vouched for is not handed to them as a PubMed link that
names *the wrong* article, which is the more serious of the two: a dead link
tells the reader something is wrong, and a live link to a real, unrelated paper
does not.

**Name a citation's identifier by the namespace that resolves it.** `PMID:` for
a PubMed ID, `PMCID:` for a PMC accession, `Europe PMC:` for a preprint
accession or any Europe PMC-sourced record, and nothing at all where neither
the record nor the provider names a namespace — a bare number under any label
invites the reader to read it as a PubMed ID. A citation outlives the session,
in an exported report someone else reads.

Measured against the live Europe PMC API on 2026-09-10:

| Query | Hits |
|---|---|
| `ext_id:12662058 src:med` | 1 |
| `ext_id:PPR1287966 src:ppr` | 1 |
| `ext_id:PPR1287966 src:med` | 0 |
| `PMCID:PMC1082889` | 1 |
| `ext_id:PMC1082889 src:pmc` | 0 |
| `ext_id:PMC1082889 src:med` | 0 |

Two failures follow from getting this wrong, and both are silent.

**A preprint is reachable only by accident.** Preprints carry no PMID and no
PMC ID, so the accession is the only identifier they have besides a DOI. Asked
for as `ext_id:<accession> src:med` it matches nothing, and the article reaches
its full text only through the DOI rung below — never by its own accession, and
not at all if the record carries no DOI. Europe PMC does hold open-access PDFs
for preprints: a `SRC:PPR` record answers `pmid: null, pmcid: null`, and an
open-access one carries a `pdf` entry with `availabilityCode: OA`.

**An article with a PMC ID and nothing else resolves no render URL.** Without
the PMC rung, such an article reaches no PDF tier however the cache is keyed —
which is why fixing the cache key alone does not fix it.

### Abstract Holdback

An abstract-only JATS rendering (`content_kind == ABSTRACT`), Europe PMC's or
PMC's open-data bucket's, must not be returned as soon as it is found. Returning it immediately makes it beat
every remaining tier, so an open-access PDF of the same paper becomes
unreachable and the abstract is cached and analysed as though it were the
article. Instead, hold it in a local and let the PDF tiers run; only return
it at the end, if nothing better arrived.

The holdback alone is not enough, and a port that stops there still has the
defect. When no PDF tier answers, the abstract is returned and cached like any
other result, so the *consumer* must check the kind as well: anything that
treats stored full text as the article's body — transparency analysis above
all — must be given nothing at all for a record whose kind is `ABSTRACT`. Make
that one accessor the whole app reads, not a check repeated at each call site.

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
async function download_and_extract(url: string, cache_key: string) -> Outcome:
    if extraction_disabled:
        return NOT_ATTEMPTED

    try:
        path = await download_and_cache_pdf(url, cache_key)
    except Cancelled:
        raise Cancelled   # propagate — never report this as an outcome
    except Error:
        return DOWNLOAD_FAILED   # the source is dead; try the next tier

    extraction = extract_text(path)

    # Before reading anything off `extraction`. The extractor stops early when
    # cancelled, so the partial value it returns is indistinguishable from a
    # genuinely short document unless cancellation is asked about first — and
    # it would otherwise be cached and shown as the article's text, with a
    # coverage figure describing how far the reader got before walking away.
    throw_if_cancelled()

    if not extraction.success or extraction.char_count == 0:
        return NO_TEXT(path)   # file is cached; nothing usable was recovered

    return EXTRACTED(path, extraction.text, extraction.coverage)
```

The text extractor itself should stop early when its task is cancelled, so a
long document does not hold the retrieval service after the reader has moved
on. It must not report that as a *failure* — a cancelled read is not an
unreadable file — which is why the caller discards the partial value by
checking cancellation rather than the extractor inventing an error state.

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
            # The already-cached path, or nothing. The display layer must not
            # download: the retrieval tier has already written these bytes to
            # disk and handed back their path, and fetching them again over the
            # network is a second download of a file the app already has.
            path = local_pdf_path
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

    # Elsevier's API (#480, stage C2), with a key and a 10.1016/ DOI: a PDF
    # it serves ends the fetch; anything else is recorded and the fetch goes on
    if doi:
        elsevier = await ask_elsevier(doi)
        if elsevier.served:
            return (FullTextResult.PDF(local_pdf_path=elsevier.path, ...), errors)

    # Try Unpaywall: every PDF it names (then OpenAlex's, #480)
    if doi:
        try:
            for pdf_url in await fetch_unpaywall_pdf_urls(doi, email):
                return (FullTextResult.PDF(pdf_url, ...), errors)
        except Error as e:
            errors.append(("Unpaywall", e))

    # Then CORE's extracted text (#480, stage C), with a key: here when no
    # candidate was named, otherwise in recording once every one failed
    if doi:
        core = await ask_core(doi)
        if core.served:
            return (FullTextResult.CoreText(core.text), errors)

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
│   └── 1234567-a1b2c3d4e5f60718.pdf   # Downloaded PDF, keyed on id + URL
└── metadata/
    └── cache_index.json     # Cache metadata
```

PDF filenames carry a digest of the source URL — see "Cache Keys" — so one
article can hold an entry per source without them overwriting each other.

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

## Conformance status

This file is a contract, not a report of what is built. Where an
implementation has not caught up, say so here rather than letting the
pseudocode imply otherwise — a contract describing a ladder no caller climbs
is what produced #202 in the first place.

As of 2026-09-11:

| Section | Swift (BioMedLit) | Python (desktop) | Kotlin (Android) |
|---|---|---|---|
| Tagged cache-key ladder | yes | no (#207) | no (#205) |
| Identifier resolution queries | yes | partial | no (#205) |
| Kind stated by the record, not inferred | yes | no (#207) | no (#205) |
| Kind persisted with the document | yes (iOS/macOS) | no (#207) | no (#205) |
| A PubMed URL requires a vouched PubMed ID | yes | n/a | n/a |

**The last row is Swift-only by construction, not by neglect.** Swift's
`SearchArticle` has one primary identifier slot, filled as
`pmid ?? id ?? ""`, so a thesis accession lands where a PubMed ID is expected
and every consumer must then ask what it is holding. Neither other platform has
a collapsed slot, but for two different reasons, and the difference matters to
anyone porting:

- **Python is safe by package boundary, not by nullability.** Its only PubMed
  URL builder is `PubMedArticle.__post_init__` in `pubmed/data_types.py`, whose
  `pmid: str` is *not* optional. What keeps it honest is that `PubMedArticle` is
  constructed from exactly one site, inside the PubMed-only package, so its slot
  holds a PubMed ID by construction. The Europe PMC-facing types — `ArticleInfo`
  and `LiteDocument` — do have a nullable `pmid`, filled from the record's own
  `pmid` field with no `id` fallback, and they feed no URL builder at all.
  Constructing a `PubMedArticle` from a Europe PMC record would import this
  whole section.
- **Kotlin is safe by nullability.** `DocumentEntity.pmid` is `String?`, filled
  from the record's `pmid` field alone in `EuropePMCService.kt`, and
  `Document.kt`'s `pubmedUrl` is gated as `pmid?.let { … }`, so a record without
  a PubMed ID carries `null` and gets no link.

Any port that gives either platform a single collapsed slot inherits the whole
of this section along with it.

**Python** branches `PMCID:` against `ext_id:… src:med` in
`europepmc.py`, so it reaches a PMC ID, but it tries the PMC rung *first*,
runs a single query rather than every rung, and has no preprint (`src:ppr`)
routing. A preprint therefore resolves only through its DOI, and not at all
without one.

Python *does* keep a persistent PDF cache — `pdf_utils.py` files bytes under
`{year}/{doi with / replaced by _}.pdf`, falling back to `doc_{id}.pdf`. It is
not "no cache" but an untagged one, and it commits both defects this section
names: the replacement is lossy with no digest, so two DOIs differing only
where the slashes fall share one entry, and nothing in the name records the
source URL, so a second URL for one article overwrites the first. Both tracked
in #207.

**Android** builds `ext_id:$pmid src:med` unconditionally in
`FullTextService.kt` and keys its cache on one untagged string. Tracked in
#205.

**Both ports also need the kind carried and stored**, not only the ladder.
Europe PMC's `source` field is decoded on every platform and *read* on every
platform — but on both ports it is read only far enough to set a boolean
preprint flag (`europepmc.py`, `EuropePMCService.kt`), and neither routes a
query or a cache key on it. A boolean cannot express `NBK`, `PAT` or `ETH`, and
cannot distinguish "stated nothing" from "stated something we do not model", so
a port that adds the ladder while still inferring the kind from an accession
prefix reproduces the narrower half of the same defect (#209).

## Platform-Specific Notes

### Python (Desktop)

- Use `requests` for HTTP
- Use `pathlib` for file paths
- Store cache in `~/.bmlibrarian_lite/cache/`
- `EuropePMCClient.fetch_fulltext_xml` is `fetch_fulltext_xml` above:
  `FullTextXmlFetch.served` / `.absent` / `.unreachable(RequestFailure)`
  (#429). `ArticleInfo.fulltext_accession` picks the PMC ID or, for a
  preprint, its `PPR` record ID. The sentence the reader sees at the end of
  the chain names every lookup that went unasked, Europe PMC's included:
  `PDFDiscoverer.discover_and_download(earlier_lookups=...)`.

### Swift (iOS/macOS)

- Use `URLSession` for HTTP
- Use `FileManager` for file operations
- Store cache in app's Caches directory
- See `Packages/BioMedLit/Sources/BioMedLit/Services/FullTextService.swift`

### Kotlin (Android)

- Use OkHttp/Retrofit for HTTP
- Store cache in app's cache directory
- Consider using Room for cache metadata
