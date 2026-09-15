# Search Failure Reporting

A literature source that failed is not a source with no evidence. This document
is the cross-platform contract for telling the two apart, from the HTTP answer
to the words the reader sees. Python (`search_failures.py`, `search_service.py`)
is the reference; the ports mirror it.

| Platform | Status |
|----------|--------|
| Python | Conforms (#247, #248, Python half of #255) |
| Swift (BioMedLit + app) | Not yet: #256 (both-provider search drops a failure with a `print`), #255 (esearch/efetch `ERROR` in HTTP 200), #253 (paging past PubMed's cap in a both-provider search); also adopt [Alternative queries](#alternative-queries-smart-search) |
| Android | Conforms (#252, Android half of #255); how its paging maps onto the contract is under [Android](#android) |

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
with no new document, it is an error like any other search. Combining never
merges a source that could not be searched into a count, and reports it once
for each failure however often it failed.

## Telling the user

The clauses, shared verbatim so the platforms read alike:

| Case | Clause |
|------|--------|
| Source not searched | `"{Provider} could not be searched ({reason})"` |
| Records missing | `"{n} {Provider} record(s) could not be retrieved ({reason})"`, `n` with thousands separators, `record` when `n == 1` |
| An alternative query's source not searched | `"an alternative search of {Provider} could not be completed ({reason})"` |
| Records an alternative query lost | `"{n} {Provider} record(s) from an alternative search could not be retrieved ({reason})"`, `n` and `record` as for records missing |

The last two apply only to [alternative queries](#alternative-queries-smart-search).

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
  reads as null, which claims more is missing, never less;
- where a platform runs [alternative queries](#alternative-queries-smart-search),
  a `query` that is not `"alternative"` reads as the original query, for the
  same reason.

Refused as a defect, because skipping it would let a report claim a complete
search:

- an entry that is not an object, or whose `provider` is not `"pubmed"` or
  `"europepmc"` (`"both"` included);
- a key that is present but does not hold a list, `null` included.

## Alternative queries (smart search)

Android and Swift run *smart search*: when the claim's own query finds too
little, an LLM proposes alternative queries and each is searched. Python has no
such step. An alternative query's source that fails must not read as "PubMed
could not be searched" when the original query's PubMed results are in the
report (user's decision, 2026-09-15). So a shortfall also records which query
it belongs to:

```pseudocode
enum ShortfallQuery:          # persisted marker: never rename
    ORIGINAL                  # stores no marker
    ALTERNATIVE = "alternative"

struct RetrievalShortfall:    # the failure record above, plus
    query: ShortfallQuery     # ORIGINAL unless smart search ran the query
```

- It chooses the clause (the alternative-query rows under
  [Telling the user](#telling-the-user)). The advice does not depend on it.
- Combining adds counts only within the same query: an alternative search's
  loss is never merged into the original query's. An alternative query's
  source that could not be searched is reported once, however many queries
  failed the same way.
- Persisted as `"query": "alternative"` on the entry, written only for an
  alternative query. Reading back, a `query` that is not that string, or no
  `query`, reads as the original query, whose clause claims more is missing,
  never less. Python writes none and ignores the key.
- One alternative query failing does not end smart search: the next is still
  tried. When smart search runs on its own (too few relevant documents), what
  its queries lost is recorded like any shortfall. When the user asked for more
  evidence and failures left smart search with no new document, that is a
  failed search: nothing it lost is kept, the report stays as it was, the
  failure is shown, and smart search stays available to try again. Once a query
  has found a new document, what the queries lose is recorded before any later
  documents are saved.

Generating the queries is not a source's failure, so it records no shortfall
(user's decision, 2026-09-16):

- A request to the model that failed (a broken connection, a refused key)
  shows that alternative searches could not be run and to check the model and
  its key; smart search stays available, and the request costs nothing.
- An answer holding no usable query (text that is not a list of queries, or no
  content) is asked for again, up to `MAX_QUERY_RETRIES` (2) more times, each a
  paid call. When no answer is usable, smart search is marked as tried, so no
  later batch asks and pays again, and the user is told the model's answers
  held no usable query.

## Android

Android asks each provider for **one page per call** (the batch size, halved
between providers for a search of both), and the session keeps its paging
between the user's requests for more. The contract's stages map as follows:

| Stage | On failure | `records_missing` |
|-------|-----------|-------------------|
| A first page (the claim's search, or an alternative query) | the source could not be searched; its paging stays where it was, so it is not paged later | null |
| A later PubMed page (Fetch more, Get more evidence) | record it, and page on past it | `min(batch, count − offset, 9999 − offset)` |
| A later Europe PMC page | record it, and end the cursor | `max(1, min(batch, hitCount − records received so far))`; `max(1, min(batch, hitCount))` for a session saved before the count was kept |
| esearch lists none of the PMIDs it counts | a failed request, recorded by the first-page or later-page row | as that row |
| esearch lists fewer PMIDs than expected, some | record it; the next page starts after the unlisted PMIDs | the unlisted PMIDs |
| efetch of a page's PMIDs fails after its retries, answers `eFetchResult`, is no article set, or breaks off | record it; the page's whole articles are kept | the PMIDs without a readable article |
| A Europe PMC page that is empty although records remain | a failed request, recorded by the first-page or later-page row | as that row |
| A Europe PMC cursor that ends before every hit arrived | record it: nothing past an ended cursor can be asked for | `hitCount − records received`, this page's included, so what an earlier short page left out is counted too; nothing for a session saved before the count was kept |
| An unreadable record (no PMID or title, or a Europe PMC record that does not decode) | record it, keep the rest | the unreadable records |

**A page that failures leave with no new document changes nothing**: no
paging, no document and no shortfall is kept, so asking again asks for the same
page. A page that fails the same way every time therefore cannot be skipped;
the user can go on with the documents found. What a page lost is recorded
before its documents are saved, and both before its paging moves. A search
that fails while the session holds no document ends the session as failed: the
session is kept, but the history list shows only completed sessions. A request
for more that fails returns to the decision to fetch more (Fetch more) or keeps
the report as it was (Get more evidence), and shows the failure with its
advice. The session stores its
shortfalls in `sessions.retrieval_shortfalls_json` (Room v6), in the persisted
form above; `null` is a complete search. `sessions.epmc_results_received` counts
the Europe PMC records received; it is `null` for a session saved before v6,
whose cursor can outlive its last hit, and then a later page is expected to
hold nothing in particular. PubMed is never asked past offset 9998: a provider
with no next page is not asked for one. A damaged record of shortfalls is a
persistent warning, and the session refuses to go on rather than write a
report that could not say whether its search was complete: Get more evidence
keeps the report and says why, and every other step that would search or write
a report ends the session as failed, saying why, before it searches or spends
any budget.

Two failures are not a source's, so they are not shortfalls. Saved NCBI
credentials that cannot be read (a broken keystore) stop the search with what
to do in Settings: like a failed search, a first search ends as failed, Fetch
more returns to the decision, and Get more evidence keeps the report. Smart
search whose queries could not be generated follows
[Alternative queries](#alternative-queries-smart-search).

Android's report has no metadata and no Methodology section of its own. Code
adds the notice, and a `## Methodology` section holding only the Search
Completeness line before `## References` (user's decision, 2026-09-15); a
complete search's report is unchanged. The report screen, the PDF and the
shared text draw the notice **before the verdict**, since all three show the
verdict and summary ahead of the report's text, and the history list marks a
report whose search was incomplete.
