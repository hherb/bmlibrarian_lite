# Full text through machine channels

Add four sources that publishers and repositories offer to programs, so more
articles reach their full text without anyone in front of a browser: PMC's
open-data bucket, every open-access location Unpaywall and OpenAlex know of,
CORE's extracted text, and Elsevier's article API. All three platforms; Python
first as the reference.

This is the first of three sub-projects that came out of #480. The other two
are the embedded browser with its review queue, and the `challenged` failure
kind that travels with it. Both are out of scope here.

## Why

`doc/developer/unpaywall_pdf_survey/` measured 400 PDFs Unpaywall names. Our
clients obtain 28%. Of the failures, 81% are bot walls, 12% serve no PDF, and
4% are our own client. The spikes in its `spikes/` asked what recovers them.
On the 149 failures that matter (articles Europe PMC's record says are not
open access, so the Unpaywall PDF is their copy), unattended channels
recovered **47**:

| Channel | Recovered | Notes |
|---|---|---|
| PMC's open-data bucket | 28 | author-manuscript text; JATS XML is there too |
| CORE's extracted text | 14 | under-measured: CORE answered 429 to most searches |
| other Unpaywall locations | 9 | the desktop already tries them; the apps do not |
| OpenAlex locations | 4 | |
| Elsevier's API | not measured | refused off the institution's network |

These channels need no browser and no person, so they come before the embedded
browser, which recovers most of the rest.

## Scope and stages

Three stages, each its own PR. Each lands in Python first, with the shared
contract in `doc/cross_platform/fulltext_retrieval.md` and parity fixtures,
then the Swift (BioMedLit) and Kotlin ports.

| Stage | Adds | Keys |
|---|---|---|
| **A** | PMC's open-data bucket as a JATS source (its PDF only when it holds no XML) | none |
| **B** | Every Unpaywall location in the apps; then OpenAlex's locations | none |
| **C** | CORE's extracted text; Elsevier's API for open-access PDFs; settings for both keys | the user's own |

## Decisions

1. **The bucket's XML before its PDF.** Structured JATS feeds the transparency
   analyser's end-matter rules (`END_MATTER_MARKER`) and the reader's view; a
   PDF earns only "Limited certainty…".
2. **CORE's plain text counts as full text**, labelled as extracted text. It
   has no sections, so statement checks read "not assessed" rather than
   charging a missing statement: the rule "no marker, no charge" (#428)
   already does this.
3. **Elsevier is PDF-only, open-access articles only**, at first. Its full-text
   XML is Elsevier's own schema and would need a new converter; retrieving a
   non-open-access PDF through the API is not permitted. Revisit only if PDFs
   prove too few.
4. **An optional channel without a key stays silent to the reader.** It is
   recorded in the audit as a lookup not made (`NOT_CONFIGURED`), blocks no
   settled absence, and adds no sentence; the settings screen says what a key
   adds. (Unpaywall keeps its existing "not configured" sentence: it is not
   optional.)
5. **Elsevier's off-network refusal is asked about once per session.** Its
   `AUTHENTICATION_ERROR` 403 means the key is valid but this network is not
   entitled. It becomes a skip reason, "not available from this network", and
   no further Elsevier request is made that session.
6. **No stealth or impersonation.** Every channel here is one the provider
   offers to programs, asked under our own identity
   (`polite_request_pacing.md`). The obscura spike measured, and rejected,
   the alternative.

## Where each source sits

Identical on all three platforms. Bold entries are new.

1. Europe PMC `fullTextXML` (unchanged).
2. **PMC's open-data bucket** (stage A): asked when a PMC ID is known and
   step 1 gave no usable body (404, 500, unreachable, body-less or
   unparsable). A preprint (`PPR`, no PMC ID) skips it.
3. Europe PMC `?pdf=render` (unchanged; answers 403 to every client, #453).
4. **Elsevier's API** (stage C): only for a DOI starting `10.1016/`, only with
   a key, and before any ScienceDirect download, which is walled.
5. Unpaywall: **every location** in the apps (stage B), in the desktop's order.
6. **OpenAlex's locations** not already tried (stage B).
7. **CORE's extracted text** (stage C): the poorest form, so last before the
   link.
8. The DOI link (unchanged).

Where each platform takes the new steps:

- **Python:** `FulltextDiscoverer.discover_fulltext` gains
  `_try_pmc_open_data` between `_try_europepmc_xml` and `_try_europepmc_pdf`.
  `PDFDiscoverer._discover_sources` gains Elsevier, OpenAlex and CORE.
- **Swift:** BioMedLit's `FullTextService` chain.
- **Kotlin:** `FullTextService.fetchFullText`.

## Stage A: PMC's open-data bucket

PMC publishes its open-access and author-manuscript collections in the public
S3 bucket `pmc-oa-opendata` (AWS Open Data). NCBI's old `oa.fcgi` service now
answers 404.

1. **Find the record.** Request
   `GET https://pmc-oa-opendata.s3.amazonaws.com/?list-type=2&prefix=metadata/{PMCID}.`
   and take the highest version among the listed `metadata/{PMCID}.{N}.json`
   keys. `KeyCount` 0 means the article is not in either collection: an
   **answer**, an absence for this source.
2. **Read it.** Fetch the metadata JSON, which carries `xml_url`, `pdf_url`,
   `text_url`, `is_pmc_openaccess`, `is_manuscript` and `license_code`. Its
   URLs are `s3://pmc-oa-opendata/{key}?md5=…`; map them to
   `https://pmc-oa-opendata.s3.amazonaws.com/{key}` and drop the query.
3. **Fetch the text.** Fetch `xml_url` and convert it with the existing JATS
   converter (Python `jats_markdown.py`; the apps' JATS parsers). A body-less
   deposit follows Europe PMC's rule: it is held back, and the chain goes on.
   Only when the record has no `xml_url` is `pdf_url` downloaded, under the
   `%PDF` and `.part` rules that already apply.
4. **Record what was learned.** A missing object answers `404 NoSuchKey`: an
   absence for this source. A 429, a 5xx or a transport failure is "could not
   be asked" (`RequestFailure`). If the bucket was the last route that could
   have served the text, the result is "not established", never "no full
   text", as an unreachable Europe PMC already is.

The cached text records its source (`pmc_open_data`), so the reader and the
audit say where it came from. The XML is not truncated (golden rule 13).

**As built (PR #487).** The binding rules are in
`doc/cross_platform/fulltext_retrieval.md` and
`fulltext_parity/pmc_open_data.json`; where this section differs, they win:

- No bucket PDF fallback: a record without `xml_url` is an absence for this
  source, and the chain goes on to the PDF tiers.
- The bucket is not asked after a body-less Europe PMC deposit, on any
  platform; only Swift holds back a body-less *bucket* deposit (Python and
  Kotlin have no content kind).
- An absence is a listing naming no version of the article, or a record with
  no `xml_url`. A listing 404 is S3's `NoSuchBucket`, and a 404 after the
  listing named the object is the bucket disagreeing with itself: both are
  unreachable. An answer we cannot read is `malformed_response`.
- The desktop's cache does not yet record its source (#485), so a cached text
  is labelled neutrally.

## Stage B: every location, and OpenAlex

- **Unpaywall, every location (apps).** Port the desktop's behaviour
  (`PDFDiscoverer._discover_unpaywall`). Try every location's `url_for_pdf`,
  deduplicated, in Unpaywall's order. Read a landing page (the first location
  without a PDF URL, as `choose_unpaywall_url` picks it) only when no location
  names a PDF. Record every PDF that could not be obtained, in Unpaywall's
  order, and only when no source served the PDF (superseding the first
  draft's "one failure, the earliest"; see the as-built note below). Before
  stage B the apps tried the best location alone.
  - **Not ported.** The desktop's derived PMC addresses (`ptpmcrender.fcgi`,
    `/pmc/articles/{id}/pdf/`), which are walled and which stage A supersedes.
    Its publisher-specific URL guesses, which are a desktop heuristic outside
    this contract.
- **OpenAlex.** Request `GET https://api.openalex.org/works/doi:{doi}` with
  `mailto` set to the contact email each platform already sends Crossref for
  the transparency analysis. (This draft also said OpenAlex already received
  it, so no new party would; that was wrong: no platform called OpenAlex
  before stage B, so OpenAlex is a new recipient. See the as-built note.)
  Without one, the request goes to the common pool rather than being
  skipped. Try each
  `locations[].pdf_url` not already tried, in OpenAlex's order, under the same
  download rules. A PDF OpenAlex named that could not be obtained is refused,
  not "no copy", under a new source, "OpenAlex's copy" (`openalex_pdf`). This
  mirrors `unpaywall_pdf` (#478).

**As built.** The binding rules are in `doc/cross_platform/fulltext_retrieval.md`
("OpenAlex's Locations", "Tried sources (#480)") and
`fulltext_parity/openalex_locations.json`; where this section differs, they win.
- Every `pdf_url` counts, whatever its `is_oa`.
- OpenAlex is asked only once no Unpaywall copy was served and kept (Android
  through a hook in its download step; in Swift a textless copy cached does
  not count).
- When no PDF is obtained, every source tried is told, each PDF by host and by
  who named it; not only the earliest failure, as the first draft said.
- OpenAlex newly receives the contact email (`mailto`); the contract states
  which address each platform sends.
- The first copy served ends the walk. One not saved is a caching note of its
  own, stored on the document in the apps, never a shortfall.
- `select=locations` is asked for.

## Stage C: CORE and Elsevier

**CORE.**
- **Request.** `GET https://api.core.ac.uk/v3/search/works/?q=doi:"{doi}"&limit=3`
  with `Authorization: Bearer {key}`. The trailing slash matters: without it
  CORE answers an HTML meta-refresh page, not JSON.
- **What counts.** A result's `fullText` at least `CORE_MIN_FULLTEXT_CHARS`
  long is the article's full text, source "CORE (extracted text)". The
  constant is new, 5,000 characters, the spike's threshold. It keeps out
  abstracts and cover pages.
- **Not used.** `downloadUrl` and the v3 download route, which sit behind
  Cloudflare even with a key.
- **Pacing.** 0.4 requests per second, the personal key's 25 a minute. The
  daily token budget cannot be expressed as a rate, so two consecutive 429s
  pause CORE for the rest of the session as "could not be asked".

**Elsevier.**
- **Request.** `GET https://api.elsevier.com/content/article/doi/{doi}` with
  `Accept: application/pdf`, `X-ELS-APIKey` and, when configured,
  `X-ELS-Insttoken`.
- **Answers.**
  - A 200 whose body starts `%PDF` is served.
  - A 404 is an absence.
  - A 403 with `AUTHENTICATION_ERROR` is the session-wide skip (decision 5).
  - Anything else is a `RequestFailure`.
- **Scope.** DOIs starting `10.1016/` only.

## How outcomes reach the reader

- **New source names** in the existing shortfall and lookup vocabulary:
  "PMC's open-access collection", "OpenAlex", "OpenAlex's copy", "CORE",
  "Elsevier's API". Each is added to the contract's source list and to the
  apps' `OpenAccessShortfall` codecs.
- **Answers add nothing.** "No entry", "no location" and "no result" are
  answers: no shortfall.
- **Failures follow `RequestFailure` and `is_answer`** as they stand (a 429 or
  5xx "could not be asked"; a 403 or 404 from a download "did not serve it").
- **A settled "no full text" still needs** every non-optional source answered.
  The optional channels (CORE, Elsevier) never block it (decision 4).
- **Keys never appear in reader-facing text.** `RequestFailure.describe()`
  carries no provider text, and no key ever appears in a URL, a log line or a
  stored record.

## Pacing

Add each new host to `POLITE_RATE_CEILINGS`, the apps' counterparts, and
the `polite_request_pacing.md` table:

| Host | Ceiling | Basis |
|---|---|---|
| `pmc-oa-opendata.s3.amazonaws.com` | 5/s | S3 publishes no limit; conservative |
| `api.openalex.org` | 10/s (exists) | OpenAlex's published limit |
| `api.core.ac.uk` | 0.4/s | personal key: 25 a minute |
| `api.elsevier.com` | 2/s | Elsevier allows 10/s and a weekly quota |

`Retry-After` is honoured, and capped, as everywhere else.

## Keys and settings

- **Desktop.** `LiteConfig.discovery` gains `core_api_key`,
  `elsevier_api_key` and `elsevier_insttoken`, saved through
  `write_owner_only_file` and redacted on export as `pubmed.api_key` is
  (`REDACTED_SECRET_PLACEHOLDER`, `_reject_redaction_placeholder`). The
  settings dialog gets three fields with a one-line explanation each.
- **iOS and macOS.** Keychain via `KeychainHelper`; fields in `SettingsView`
  and `MacSettingsView`.
- **Android.** `EncryptedSharedPreferences` in `SettingsRepository`; fields on
  the settings screen.

Each key travels only in its request header: `Authorization: Bearer`,
`X-ELS-APIKey`, `X-ELS-Insttoken`.

## Testing

- **Shared fixtures** in `doc/cross_platform/fulltext_parity/`:
  - an S3 listing with several versions, and one with `KeyCount` 0;
  - metadata JSON: open access with XML, manuscript with XML, PDF without XML;
  - S3's `NoSuchKey` body;
  - OpenAlex locations;
  - CORE: a hit with `fullText`, a hit without, an empty result, the HTML
    redirect page, and a 429;
  - Elsevier's `AUTHENTICATION_ERROR` body.

  Python's tests and the Swift and Kotlin parity tests read the same files.
- **A control beside every rule:**
  - a 404 or `KeyCount` 0 is an absence, and a 429 or 5xx is not;
  - a missing key makes no request;
  - an off-network Elsevier refusal stops further Elsevier requests;
  - a body-less bucket deposit is held back;
  - a key never appears in a URL, a log or a stored record.
- **The repo's usual gates:** a mutation check of the new branches, driven
  from Python with a verified restore, and the dead-proxy run proving no test
  touches the network.
- **Acceptance, per stage, manual.** Replay the survey's committed failures
  through the new chain and confirm it recovers at least what the spike did.
  Stage A must reach at least 28 of the 149. Stages B and C are compared with
  the spike's rows.

## Docs

- `doc/cross_platform/fulltext_retrieval.md`: the new sources, their order,
  and their outcomes.
- `polite_request_pacing.md`: the ceilings.
- The user guide: how to get free CORE and Elsevier keys, and that Elsevier's
  works only from the institution's network or with an institutional token.

## Out of scope

- **The embedded browser and its review queue,** and the `challenged` failure
  kind (sub-projects 2 and 3).
- **Fixing or removing the desktop's Playwright fallback** (#483), which the
  embedded browser replaces.
- **An Elsevier XML converter; CORE downloads; Wiley's and Springer's
  text-mining APIs.**
- **Europe PMC's render tier** (#453).
