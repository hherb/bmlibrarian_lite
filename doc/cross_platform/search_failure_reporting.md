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

- it timed out, could not connect, or answered with an HTTP error status;
- it answered with a redirect (refused, never followed; see
  `doc/developer/europepmc_and_pubmed.md`);
- its answer reports an error instead of a result:
  - **esearch**: an `esearchresult` object holding an `ERROR` field. Checked
    live on 2026-09-14: `term=((` answers HTTP 200 with
    `{"esearchresult":{"ERROR":"Search Backend failed: …"}}`, and an expired
    `WebEnv` answers HTTP 200 with `{"esearchresult":{"ERROR":"Unable to obtain query #1"}}`;
  - **efetch**: an `<eFetchResult>` root holding `<ERROR>`;
- its answer cannot be read:
  - esearch: not JSON; no `esearchresult` object; `count` missing or not a
    decimal string; `idlist` missing or not a list of strings where PMIDs are
    being listed (a `rettype=count` answer legitimately has no `idlist`);
  - efetch: not well-formed XML, or a root other than `PubmedArticleSet`;
  - Europe PMC search: not a JSON object; `hitCount` missing or not a
    non-negative integer; `resultList.result` missing or not a list. Checked
    live on 2026-09-14: an unknown `cursorMark` answers HTTP 200 with
    `{"version":"6.9"}` and nothing else.
- its answer holds less than it says (`incomplete_response`):
  - esearch lists fewer PMIDs than `min(retmax, count − retstart, 10000 − retstart)`.
    A page that lists **none** of an expected non-zero number is a failed
    request; a page that lists some records the rest as missing;
  - a history-server page lists fewer PMIDs than its page size (recorded, and
    the next page is still asked for);
  - a Europe PMC page has no results before `min(max_results, hitCount)` were
    received: a failed request on the first page, recorded on a later one.

These are **not** failures, and must keep reading as empty:

- esearch `count` `"0"` with an empty `idlist`;
- efetch `<PubmedArticleSet></PubmedArticleSet>` (NCBI's answer for PMIDs it
  does not hold);
- Europe PMC `hitCount` 0 with an empty `resultList.result`.

**Never log, persist or show the text of a failed answer.** NCBI's 400 for a
bad key repeats the key, and the esearch backend's `ERROR` text includes a
request path; an XML root's namespace URI is text too. A failure travels as
its kind and HTTP status only. **Nor may the error keep what it replaced**: in
Python, `raise … from None` inside an `except` block still keeps the original
exception as `__context__`, and `requests`' `JSONDecodeError` holds the whole
body as `doc`. Classify inside the handler, raise after it.

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
    status_code: Int?                  # HTTP_STATUS and REDIRECT_REFUSED only

struct RetrievalShortfall:
    provider: "pubmed" | "europepmc"   # a source, never "both"
    failure: RequestFailure
    records_missing: Int?              # null: the source could not be searched
```

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
the empty source does not speak for the one that was never asked.

### Partial retrieval

| Stage | On failure | `records_missing` |
|-------|-----------|-------------------|
| PubMed history-server page (esearch `WebEnv`) | record it, **continue** with the next page | the failed pages' sizes |
| PubMed efetch batch | record it, **continue** with the next batch | PMIDs in the failed batches |
| Europe PMC later cursor page | record it, **stop** (a cursor cannot skip a page) | `min(max_results, hitCount) − results received` (readable or not) |
| A later page of the search for more documents (Research Questions) | record it, **stop** with the documents found | that page's size; an error if nothing new was found |
| Europe PMC first page | raise: the source could not be searched | null |
| A record the parser cannot read (PubMed article, Europe PMC result) | record it, keep the rest | the unreadable records, kind `malformed_response` |

The failure recorded for several failed batches is the first one. A shortfall
with nothing missing is not recorded.

## Telling the user

The clauses, shared verbatim so the platforms read alike:

| Case | Clause |
|------|--------|
| Source not searched | `"{Provider} could not be searched ({reason})"` |
| Records missing | `"{n} {Provider} record(s) could not be retrieved ({reason})"`, `n` with thousands separators, `record` when `n == 1` |

| Kind | `{reason}` |
|------|-----------|
| `http_status` | `"HTTP 429 Too Many Requests"` (status and its standard reason phrase; `"HTTP 599"` without one; `"an HTTP error"` without a status) |
| `redirect_refused` | `"a redirect (HTTP 307) was refused"` |
| `timeout` | `"the request timed out"` |
| `connection` | `"the connection failed"` |
| `service_error` | `"the service reported an error"` |
| `malformed_response` | `"the response could not be read"` |
| `incomplete_response` | `"the response was incomplete"` |
| `request_failed` | `"the request failed"` |

Several shortfalls join with `"; "`. Where they reach the reader:

- **Report.** The report opens with
  `> **Incomplete search:** {clauses}. Everything below rests only on the records that were retrieved.`
  and its Methodology gains `- **Search Completeness:** Incomplete: {clauses}`.
  A complete search adds neither. The notice is added by code, never left to
  the LLM.
- **Messages standing in for a report** ("No documents scored 3 or higher",
  "No documents passed quality filter") open with the same notice.
- **A search that raised** is an error in the search step, with the message
  `The search could not be completed: {clauses}.` followed by advice (below),
  shown in a dialog. No search session is saved.
- **GUI.** The review shows a persistent warning while it proceeds. The search
  for more documents (Research Questions) keeps what it found and **hands its
  shortfalls on with the documents**, so the review built from them reports
  the incomplete search too: a warning dialog alone left the report claiming a
  complete one.
- **MCP.** `fact_check_claim` and `search_literature` always return
  `retrieval_shortfalls` (empty when complete), each entry the persisted fields
  plus `description` (the clause). A failed call is an MCP **error result**
  (`isError`), its text a JSON object with `error`, `error_type` and, for a
  failed search, `retrieval_shortfalls` and `advice`.

What to do next, in order, each at most once:

| Condition | Advice |
|-----------|--------|
| any HTTP 429 | `"The service is limiting how often it can be searched: wait a minute and try again."` |
| a PubMed HTTP 429 | `"An NCBI API key, set in Settings, raises PubMed's limit."` |
| any `timeout` or `connection` | `"Check the internet connection and try again."` |
| none of the above | `"Try again later."` |

## Persisted form

A search session's metadata holds the shortfalls under `retrieval_shortfalls`,
absent when the search was complete:

```json
{"retrieval_shortfalls": [
  {"provider": "pubmed", "failure": {"kind": "http_status", "status_code": 429}, "records_missing": null}
]}
```

Report metadata holds the same list under `search_shortfalls`. Reading back
degrades, never drops: an unknown `kind` reads as `request_failed`, an
unreadable `status_code` as null, an unreadable or negative `records_missing`
as null (claiming more is missing, never less). An entry naming no source, or
a value that is not a list, is refused as a defect: skipping it would let a
report claim a complete search.
