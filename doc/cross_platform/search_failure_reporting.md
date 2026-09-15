# Search Failure Reporting

A literature source that failed is not a source with no evidence. This document
is the cross-platform contract for telling the two apart, from the HTTP answer
to the words the reader sees. Python (`search_failures.py`, `search_service.py`)
is the reference; the ports mirror it.

| Platform | Status |
|----------|--------|
| Python | Conforms (#247, #248, Python half of #255) |
| Swift (BioMedLit + app) | Not yet: #256 (both-provider search drops a failure with a `print`), #255 (esearch/efetch `ERROR` in HTTP 200), #253 (paging past PubMed's cap in a both-provider search) |
| Android | Not yet: #252 (every failed search is dropped silently), #255, #123 (efetch parse errors swallowed) |

## Why

Before #247, Python's PubMed client answered a spent retry with `None`, and
every caller turned that into an empty result. A rate-limited user read "No
documents found for this query."; an agent calling MCP `fact_check_claim` read
"No documents found matching the query." and concluded the literature was
silent on the claim. A failed efetch batch or history page shortened the result
set without a word (#248), and E-utilities reports some failures inside an HTTP
200, which read as a search that matched nothing (#255).

## What is a failed request

A request fails when, after its retries:

- it timed out, could not connect, or answered with an HTTP error status. A
  timeout that used up its retries is a timeout, however the HTTP library
  wraps it: Python's `requests` re-raises urllib3's spent read-timeout retry
  as a plain `ConnectionError`;
- (E-utilities only) it answered with a redirect: refused, never followed,
  because the request body holds the NCBI API key (see
  `doc/developer/europepmc_and_pubmed.md`). Europe PMC requests carry no
  credential, and its redirects are followed;
- its answer reports an error instead of a result:
  - **esearch**: an `esearchresult` object holding an `ERROR` field. Checked
    live on 2026-09-14: `term=((` answers HTTP 200 with
    `{"esearchresult":{"ERROR":"Search Backend failed: …"}}`, and an expired
    `WebEnv` answers HTTP 200 with `{"esearchresult":{"ERROR":"Unable to obtain query #1"}}`.
    Decode it leniently: past the 9,999-record cap the `ERROR` text holds a
    raw newline (checked live 2026-09-15), which strict JSON refuses, and
    that answer is still a service error;
  - **efetch**: an `<eFetchResult>` root, NCBI's error document;
- its answer cannot be read:
  - esearch: not JSON; no `esearchresult` object; `count` missing or not a
    decimal string where a total is read (history-server pages are read for
    their PMIDs only); `idlist` missing or not a list of strings on every
    esearch except a `rettype=count` answer, which legitimately has none; a
    history-server search (`usehistory=y`) whose `count` exceeds its listing
    but that names no `webenv` and `querykey` string;
  - efetch: not well-formed XML, or a root other than `PubmedArticleSet` and
    `eFetchResult`;
  - Europe PMC search: not a JSON object; `hitCount` missing or not a
    non-negative integer; `resultList.result` missing or not a list. Checked
    live on 2026-09-14: an unknown `cursorMark` answers HTTP 200 with only a
    `version` field (`{"version":"6.9"}`).
- its answer holds less than it says (`incomplete_response`):
  - esearch lists fewer PMIDs than `min(retmax, count − retstart, 9999 − retstart)`.
    PubMed lists only the first 9,999 records of a search, and `retstart`
    can be at most 9998 (both checked live 2026-09-15). A page that lists
    **none** of an expected non-zero number is a failed request; a page that
    lists some records the rest as missing;
  - a history-server page lists fewer PMIDs than its page size (recorded, and
    the next page is still asked for);
  - a Europe PMC page has no results, or its cursor ends (no
    `nextCursorMark`, or the one just used), before `min(max_results, hitCount)`
    results were received, readable or not. An empty first page is a failed
    request; anything else is recorded. Checked live on 2026-09-15: the
    cursor ends only once every hit was sent.

These are **not** failures, and must keep reading as empty:

- esearch `count` `"0"` with an empty `idlist`;
- efetch `<PubmedArticleSet></PubmedArticleSet>` (NCBI's answer for PMIDs it
  does not hold);
- Europe PMC `hitCount` 0 with an empty `resultList.result`.

**Never log, persist or show the text of a failed answer.** NCBI's 400 for a
bad key repeats the key, and the esearch backend's `ERROR` text includes a
request path; an XML root's namespace URI is text too, and so is an XML parse
error's message (it can name an entity from the body: log its code and
position only). A failure travels as its kind and HTTP status only. **Nor may
the error keep what it replaced**: in Python, `raise … from None` inside an
`except` block still keeps the original exception as `__context__`, and a
`JSONDecodeError` holds the whole body as `doc`. Classify inside the handler,
raise after it.

## The failure record

```pseudocode
enum RequestFailureKind:          # raw values are persisted: never rename
    TIMEOUT            = "timeout"
    CONNECTION         = "connection"
    HTTP_STATUS        = "http_status"
    REDIRECT_REFUSED   = "redirect_refused"
    SERVICE_ERROR      = "service_error"       # an ERROR inside a 200 answer
    MALFORMED_RESPONSE = "malformed_response"
    INCOMPLETE_RESPONSE = "incomplete_response" # fewer records than it counted
    REQUEST_FAILED     = "request_failed"      # anything else

struct RequestFailure:
    kind: RequestFailureKind
    status_code: Int?                  # HTTP_STATUS and REDIRECT_REFUSED only; 100–999

struct RetrievalShortfall:
    provider: "pubmed" | "europepmc"   # a source, never "both"
    failure: RequestFailure
    records_missing: Int?              # at least 1; null: the source could not be searched
```

Construction refuses a record that breaks these rules: a status code on
another kind or outside 100–999, a shortfall naming `both`, or one missing
fewer than one record. The stored `provider` strings are exactly `"pubmed"`
and `"europepmc"`, whatever a platform's own provider enum stores (BioMedLit's
Swift `SearchProvider.europePMC` encodes as `"europePMC"`, Android's enum name
is `EUROPE_PMC`): a port maps explicitly. `{Provider}` in the clauses below is
`PubMed` or `Europe PMC`.

A client raises (throws, returns a failure `Result`) a source error carrying
`provider` and `RequestFailure` for a failed **search**. It never returns an
empty result for one.

## What a search does with a failure

The user's decisions (2026-09-14): **proceed on what was retrieved, and tell
the user**; a search that failures leave with nothing is an error.

```pseudocode
function search(query, provider):
    shortfalls = []
    articles = []
    for source in sources(provider):             # one, or PubMed then Europe PMC
        try:
            result = source.search(query)
        catch SourceError as e:
            shortfalls.append(Shortfall(e.provider, e.failure, records_missing=null))
            continue                              # the other source still runs
        articles += result.articles
        shortfalls += partial_shortfalls(result)  # see below
    merged = merge_and_filter(articles)
    if merged is empty and shortfalls is not empty:
        raise SearchFailed(shortfalls)            # never "No documents found"
    return Result(merged, shortfalls)
```

A single-provider search whose source fails therefore raises, and so does a
both-provider search where one source failed and the other matched nothing:
the empty source does not speak for the one that did not answer.

### Partial retrieval

| Stage | On failure | `records_missing` |
|-------|-----------|-------------------|
| PubMed history-server page (esearch `WebEnv`) | record it, **continue** with the next page | the failed pages' sizes, plus what short pages left out |
| PubMed efetch batch | record it, **continue** with the next batch | PMIDs in the failed batches |
| Europe PMC later cursor page, an empty page, or a cursor that ends early | record it, **stop** (a cursor cannot skip a page) | `min(max_results, hitCount) − results received` (readable or not) |
| A later page of the search for more documents (Research Questions) | record it, **stop** with the documents found | the PMIDs that page should have listed, `min(batch, count − offset, 9999 − offset)`. The search never asks for a page past that end, so this is never 0 |
| An efetch batch of the search for more documents | record it, **continue** | PMIDs in the failed batch |
| Europe PMC first page | raise: the source could not be searched | null |
| A record the parser cannot read (PubMed article, Europe PMC result) | record it, keep the rest | the unreadable records, kind `malformed_response` |

The failure recorded for several failed batches of one fetch is the first one.
A shortfall with nothing missing is not recorded. The search for more
documents, which pages through PubMed one batch at a time, reports the same
failure of the same source once, the counts added; and when failures leave it
with no new document, it is an error like any other search.

## Telling the user

The clauses, shared verbatim so the platforms read alike:

| Case | Clause |
|------|--------|
| Source not searched | `"{Provider} could not be searched ({reason})"` |
| Records missing | `"{n} {Provider} record(s) could not be retrieved ({reason})"`, `n` with thousands separators, `record` when `n == 1` |

| Kind | `{reason}` |
|------|-----------|
| `http_status` | `"HTTP 429 Too Many Requests"`: the status and its phrase from the table below; `"HTTP 599"` for a status the table lacks; `"an HTTP error"` without a status |
| `redirect_refused` | `"a redirect (HTTP 307) was refused"`; `"a redirect was refused"` without a status |
| `timeout` | `"the request timed out"` |
| `connection` | `"the connection failed"` |
| `service_error` | `"the service reported an error"` |
| `malformed_response` | `"the response could not be read"` |
| `incomplete_response` | `"the response was incomplete"` |
| `request_failed` | `"the request failed"` |

The phrases are fixed here (RFC 9110 wording), not taken from a platform
library, whose phrases differ (Python 3.13 renamed 413, 414 and 422; Swift's
are lowercase and localised):

| Status | Phrase |
|--------|--------|
| 400 | `Bad Request` |
| 401 | `Unauthorized` |
| 403 | `Forbidden` |
| 404 | `Not Found` |
| 408 | `Request Timeout` |
| 413 | `Content Too Large` |
| 414 | `URI Too Long` |
| 429 | `Too Many Requests` |
| 500 | `Internal Server Error` |
| 502 | `Bad Gateway` |
| 503 | `Service Unavailable` |
| 504 | `Gateway Timeout` |

Several shortfalls join with `"; "`. Where they reach the reader:

- **Report.** The report opens with
  `> **Incomplete search:** {clauses}. Everything below rests only on the records that were retrieved.`
  followed by a blank line and the report, and its Methodology gains
  `- **Search Completeness:** Incomplete: {clauses}`. A complete search adds
  neither. The notice is added by code, never left to the LLM.
- **Messages standing in for a report** ("No documents scored 3 or higher",
  "No documents passed quality filter") open with the same notice. A check of
  what such a text is (is it a report to save?) reads the text behind the
  notice.
- **A search that raised** is an error in the search step, with the message
  `The search could not be completed: {clauses}.` followed by a blank line and
  advice (below), shown in a dialog. No search session is saved.
- **GUI.** The review shows a persistent warning while it proceeds; documents
  handed to the review from a complete search clear an earlier warning. The
  search for more documents (Research Questions) keeps what it found and
  **hands its shortfalls on with the documents**, so the review built from
  them reports the incomplete search too: a warning dialog alone left the
  report claiming a complete one.
- **MCP.** `fact_check_claim` and `search_literature` always return
  `retrieval_shortfalls` (empty when complete), each entry the persisted fields
  plus `description` (the clause). A failed call is an MCP **error result**
  (`isError`), its text a JSON object with `error`, `error_type` and, for a
  failed search, `retrieval_shortfalls` and `advice`.

What to do next, in order, each at most once, joined with a single space:

| Condition | Advice |
|-----------|--------|
| any HTTP 429 | `"The service is limiting how often it can be searched: wait a minute and try again."` |
| a PubMed HTTP 429 | `"An NCBI API key, set in Settings, raises PubMed's limit."` |
| a PubMed HTTP 400, 401 or 403 | `"If an NCBI API key is set in Settings, check that it is correct: PubMed refuses a request whose key it does not accept."` |
| any `service_error` | `"If it happens again, rephrase the question: the service may be unable to process the query."` |
| any `timeout` or `connection` | `"Check the internet connection and try again."` |
| none of the above | `"Try again later."` |

## Persisted form

A search session's metadata holds the shortfalls under `retrieval_shortfalls`.
Write the key only when the search was incomplete; a complete search leaves it
out (in Kotlin, omit the field rather than writing `null`):

```json
{"retrieval_shortfalls": [
  {"provider": "pubmed", "failure": {"kind": "http_status", "status_code": 429}, "records_missing": null}
]}
```

Report metadata holds the same list under `search_shortfalls`, written as `[]`
for a complete search; metadata saved before #247 has no key, which reads as
`[]`.

Reading back degrades, never drops:

- an unknown `kind`, or a `failure` that is missing or not an object, reads
  as `request_failed` (with no status code);
- a `status_code` that is not an integer from 100 to 999 (`true` included),
  or that belongs to a kind that carries none, reads as null;
- a `records_missing` that is not an integer of at least 1 (`true` included)
  reads as null, which claims more is missing, never less.

Refused as a defect, because skipping it would let a report claim a complete
search:

- an entry that is not an object, or whose `provider` is not `"pubmed"` or
  `"europepmc"` (`"both"` included);
- a key that is present but does not hold a list, `null` included.
