# Polite request pacing

Every outbound request to a third-party service goes through one host-keyed,
thread-safe limiter that paces it to a published-or-measured rate and backs off
when the service says it is struggling.

## Why

Europe PMC's nginx front end serves `503 Service Temporarily Unavailable` after
about **two rapid requests**, with no `Retry-After` header, and stays throttled
for up to ~70 seconds after a burst. Measured 2026-09-21 against
`https://www.ebi.ac.uk/europepmc/webservices/rest/<pmcid>/fullTextXML`:

```
1: HTTP 200 len=150085 17.5s
2: HTTP 200 len=150085 18.1s
3: HTTP 503 len=190    0.3s
4..8: HTTP 503
```

The light `search` endpoint is no better: the second back-to-back request read-
timed out at 30s.

`doc/developer/europepmc_and_pubmed.md` says "Recommended: 10 requests/second
maximum" for Europe PMC. That number is false, and is plausibly why no pacing
was ever added to `EuropePMCClient`. Correcting it is part of this work.

This is not only rudeness. A throttled article is currently reported to the
reader as having **no full text**, which is indistinguishable from "not open
access" — the same silent-degradation shape as #261/#304. The remedy for that
reporting gap is issue #341; this spec is the pacing half.

## What is impolite today

Audited 2026-09-21 across `src/`.

**No pacing at all:**

| Client | Services |
|---|---|
| `europepmc.py` (3 call sites), and `fulltext_discovery.py:376`, which borrows its session | Europe PMC / EBI |
| `pdf_discovery.py` (4 call sites) | Unpaywall, doi.org, publisher sites, PMC downloads |

**Pacing that exists but does not hold:**

| Client | Pacing | Defect |
|---|---|---|
| `pubmed/search_client.py` | `time.sleep(self.request_delay)`, 0.34s / 0.1s with key | per-instance, unlocked |
| `study_transparency_analyzer.py` (two classes) | `_rate_limit()`, 0.34 / 0.1 | per-instance, **unlocked** |
| `transparency/transparency_manager.py` | `_min_request_interval` | sound — lock-protected |
| `study_transparency_analyzer/batch_analyzer.py` | sequential path only | `analyze_batch_parallel` **bypasses it** |

Three structural flaws cut across these:

1. **Per-instance budgets under thread pools.** `agents/scoring_agent.py`,
   `agents/citation_agent.py`, `gui/systematic_review_tab.py` and
   `batch_analyzer.py` all use `ThreadPoolExecutor`. A budget keyed to `self`
   gives every worker a full budget: eight workers become 24 req/s at NCBI.
2. **Nothing is keyed to the host.** `search_client.py` and
   `study_transparency_analyzer.py` both call NCBI and each keeps its own
   budget, so together they exceed 3/s even single-threaded.
3. **The heaviest user has no pacing at all** — Europe PMC full text.

## Architecture

### `rate_limit.py` — the limiter

A new module holding one process-wide registry keyed by **host**, because the
host is what does the throttling. Two clients hitting NCBI share one budget;
one client hitting two hosts holds two.

- `acquire(host)` blocks until the caller may proceed, then records the
  departure time.
- Guarded by a `threading.Lock`, held across the wait, because every consumer
  runs under a thread pool. Serialising on the interval *is* the behaviour
  wanted: it is what makes N workers share one budget.
- The clock is injected. Tests advance it by hand and never sleep, so the suite
  stays fast and deterministic.

### Adaptive backoff

A fixed rate cannot be tuned for a service that publishes no limit. On a 429 or
503 the limiter is told:

- honour `Retry-After` when the response carries one, waiting at least that
  long before the next request to that host;
- otherwise halve the host's current rate, to a floor of **one request every
  30 seconds** — slow enough to stop hammering, never zero, so a service that
  recovers is noticed;
- after **ten consecutive successes** to that host, raise the rate by one step
  (double it), capped at the configured ceiling. Ten is arbitrary but stated:
  it is long enough that a single lucky request does not undo a penalty, and
  short enough that a transient blip costs seconds, not minutes.

This is the part that makes us a good netizen rather than merely a compliant
one: it yields when a service is shedding load, which is exactly what Europe
PMC's nginx is signalling.

### `PoliteAdapter(HTTPAdapter)` — the integration point

Rather than editing the twelve call sites the audit found, an `HTTPAdapter`
subclass overrides `send()`: acquire before the request, report a 429/503 after
it. It is mounted on each session, so pacing cannot be forgotten at a call site
added later — the failure mode that produced this spec.

`pubmed/search_client.py` calls bare `requests.post`, so it moves onto a
session with the adapter mounted. That also gains it connection pooling.

### Per-host policy

Ceilings live in `constants.py`. Adaptive backoff applies beneath all of them.

| Host | Ceiling | Basis |
|---|---|---|
| `eutils.ncbi.nlm.nih.gov` | 3/s; 10/s with an API key | NCBI published |
| `www.ebi.ac.uk` (Europe PMC) | 1/s | measured; the documented 10/s is false |
| `api.openalex.org` | 10/s | published |
| `api.unpaywall.org` | 5/s | polite-pool convention |
| `api.crossref.org` | 5/s | polite pool, with `mailto` |
| `clinicaltrials.gov` | 5/s | matches Swift's existing `clinicalTrialsRateLimit` |
| `doi.org`, publisher hosts | 1/s | ordinary web servers, not APIs |
| anything else | 1/s | safe default |

### What this removes

The three ad-hoc per-instance limiters and the `analyze_batch_parallel` bypass
are subsumed by the shared limiter and deleted, so there is one place where
pacing is decided.

## Out of scope

- **LLM providers.** Anthropic and Ollama are the user's own endpoints, paid or
  local, not shared public infrastructure. `quality/study_classifier.py`'s
  `QUALITY_API_DELAY_SECONDS` stays as it is.
- **No off-switch.** A user-facing "disable politeness" toggle is the wrong
  affordance and is not built.
- **The reporting half of #341** — telling the reader "rate limited" rather
  than "no full text" — is a separate change against the `FULLTEXT_*`
  constants.

## Error handling

Pacing never invents a failure. `acquire` only ever delays; it does not raise
and does not cancel. A request that still fails after pacing fails exactly as
it does today, through the existing `Retry`/`retry_with_backoff` paths, so no
caller's error handling changes.

Long waits must remain observable: any wait **over one second** is logged at
debug with the host and the delay, and each penalty is logged at info with the
host and the new rate, so a slow review can be explained rather than guessed
at. The provider's own response text is not logged at info — it stays where
the existing error paths put it (#330).

## Testing

Unit tests for the limiter, with an injected clock and no real sleeping:

- a second request to one host waits the interval; a request to a different
  host does not;
- N threads against one host are serialised to the interval — the flaw that
  per-instance limiters had;
- a 503 halves the rate; `Retry-After` is honoured when present;
- the rate recovers toward the ceiling on sustained success, and never exceeds
  it;
- an unknown host gets the safe default.

Adapter tests against a stub transport assert that a sequence of requests is
spaced, and that a 429/503 response penalises the right host.

No new live-network tests. The existing integration suite stays behind
`-m integration`.

## Cross-platform

`doc/cross_platform/polite_request_pacing.md` becomes the canonical contract,
Python being the reference platform as with the other contracts in that
directory. The false 10/s in `doc/developer/europepmc_and_pubmed.md` is
corrected in the same change.

The ports are then lodged as issues rather than built here:

- Swift: `EuropePMCService`, `FullTextService` and `EutilsRequest` have no
  pacing; `ClinicalTrialsService` and `CrossRefService` have `enforceRateLimit`
  but per-service rather than per-host.
- Android: only `PubMedService.kt` paces; `EuropePMCApi`, `UnpaywallApi` and
  `FullTextService` have none.
