# Polite Request Pacing

A budget of one request per instant is not a budget when every instance,
every worker thread and every service class keeps one of its own. This
document is the cross-platform contract for pacing outbound requests to
free, unauthenticated (or lightly authenticated) third-party services —
PubMed E-utilities, Europe PMC, CrossRef, ClinicalTrials.gov, OpenAlex,
Unpaywall, DOI resolution — so this application asks each of them no faster
than it says it will tolerate, on one shared budget, regardless of how many
clients or threads are asking.

Python (`rate_limit.py`, `polite_session.py`, the `POLITE_*` block in
`constants.py`) is the reference.

| Platform | Status |
|----------|--------|
| Python | Conforms |
| Swift (BioMedLit) | **Unchecked.** `EuropePMCService`, `FullTextService` and `EutilsRequest` (`Packages/BioMedLit/Sources/BioMedLit/Services/`) make outbound requests with no pacing at all. `ClinicalTrialsService` and `CrossRefService` have `enforceRateLimit()`, but it is per service instance rather than per host: two services calling the same host each keep a full budget, and concurrent analysis multiplies it again |
| Android | **Unchecked.** Only `PubMedService.kt` paces (`delay(delayMs)`, ~line 478). `EuropePMCApi`, `UnpaywallApi` and `FullTextService` (`app/src/main/java/com/bmlibrarian/factchecker/data/remote/`) have none |

## Why

Six ad-hoc limiters shipped before this contract, each wrong the same way:
paced per instance, not per host, so nothing stopped two clients calling the
same host from each keeping a full budget, and a `ThreadPoolExecutor`
multiplied the budget again by its worker count. They were:

- `PubMedSearchClient.request_delay` (`pubmed/search_client.py`);
- five `_rate_limit()` methods in
  `study_transparency_analyzer/study_transparency_analyzer.py`, one each on
  `PubMedClient`, `CrossRefClient`, `ClinicalTrialsClient`,
  `EuropePMCClient` and `OpenAlexClient`.

`EuropePMCClient` (`europepmc.py`, the main search path — not the
transparency analyzer's client of the same name above) and the PDF/full-text
discovery clients (`pdf_discovery.py`) had no pacing at all. Europe PMC in
particular serves 503 after about two rapid requests (see "Europe PMC
Limits" in `doc/developer/europepmc_and_pubmed.md`), so an unpaced client or
a per-instance one racing several workers throttled itself within seconds of
starting a review.

`transparency/transparency_manager.py` also holds a `Lock` and a
`_min_request_interval`, and **keeps it deliberately** — it is not a seventh
ad-hoc limiter to fold into this one. It throttles how often the background
executor *starts* a whole transparency analysis (itself several paced HTTP
calls to several hosts), not requests to one host; it is genuinely
lock-protected, unlike the per-instance limiters above, which raced each
other under concurrency. A port must not delete or merge it while doing this
work.

## The rules

A port conforms when it implements all of the following.

**1. The key is the host, and the budget is shared process-wide.** One
limiter per hostname (as the URL's authority gives it, not per service
instance, per client object or per thread), created on first use and reused
by every caller for the rest of the process. This is the point of the
contract: the limiters it replaces were per-instance, so a
`ThreadPoolExecutor` gave each worker a full budget of its own, and two
clients calling the same host — say, the transparency analyzer's
`PubMedClient` and the main search path's PubMed client — each thought they
had NCBI's whole allowance to themselves. Python: `rate_limit.limiter_for`,
backed by a process-wide registry under a lock (`rate_limit.reset_limiters`
exists only so tests do not share pacing state with each other).

The registry is keyed on the host **alone**, never on (host, credential):
two limiters for one host would hand it two budgets and defeat the rule. A
credential that raises what the service permits (rule 2's NCBI API key)
therefore *raises the shared limiter's ceiling* when it is higher than the
one in force, and is ignored when it is not. A ceiling is never lowered, so
neither caller order loses: an unkeyed caller arriving second cannot take
away the rate the key bought, and a keyed caller arriving second is not
stuck at the unkeyed rate. Python: `rate_limit.limiter_for`,
`RateLimiter.raise_ceiling_to`.

**2. Ceilings are per host, in requests per second**, from a published or
measured rate, falling back to a conservative default for a host with
neither. Python's table (`constants.POLITE_RATE_CEILINGS`, default
`constants.DEFAULT_POLITE_RATE_PER_SECOND`):

| Host | Requests/second |
|------|------------------|
| `eutils.ncbi.nlm.nih.gov` | 3 (10 with a registered NCBI API key) |
| `www.ebi.ac.uk` (Europe PMC) | 1 |
| `api.openalex.org` | 10 |
| `api.unpaywall.org` | 5 |
| `api.crossref.org` | 5 |
| `clinicaltrials.gov` | 5 |
| `doi.org`, `dx.doi.org` | 1 |
| any other host | 1 (the default) |

Europe PMC's ceiling is measured, not published: its own documentation once
claimed 10/s, which is plausibly why it shipped with no pacing at all
(`doc/developer/europepmc_and_pubmed.md`, "Europe PMC Limits").

**3. An explicit `Retry-After` is honoured in full, up to five minutes.**
When a throttled response names how long to wait, that is the new interval —
a service that asks for 60 seconds gets 60, because shortening what it asked
for is less polite than asking. **The 30-second floor applies only to the
halving path** (rule 4), when the service pushed back without saying for how
long; it never caps an explicit `Retry-After`.

The one bound on it is a separate, much higher ceiling of five minutes
(`constants.POLITE_MAX_PENALTY_SECONDS`). Pacing reaches arbitrary publisher
hosts, and a Cloudflare-fronted one answers `Retry-After: 3600` readily; an
uncapped honouring of that would pin the host for an hour and, because the
wait is taken on the calling thread, park a desktop application's worker for
the same hour. Five minutes is long enough to be a real yield to a
struggling service and short enough that the application stays answerable.
The two limits are not the same limit and both apply: 30 seconds bounds our
own halving, 300 seconds bounds what a stranger's header may impose.

Python: `polite_session.retry_after_seconds` reads only the numeric form of
the header (the HTTP-date form is valid but rare here, and a wrong parse
would be worse than falling back to halving); `RateLimiter.penalise` clamps
it to `POLITE_MAX_PENALTY_SECONDS`.

**4. Without an explicit wait, halve the rate, down to a floor of one
request per 30 seconds** (`constants.POLITE_PENALTY_FLOOR_SECONDS`). Ten
consecutive successful requests then double the rate back, capped at the
host's own ceiling — never faster than rule 2 allows, however long the host
has been quiet (`constants.POLITE_RECOVERY_SUCCESSES`; Python:
`RateLimiter.succeed`). A single success does not undo a penalty; a
penalised host earns its rate back one doubling at a time, resetting the
success count on the next penalty.

Only an answer that actually worked counts as a success: a status below 400
(`constants.HTTP_ERROR_STATUS_MIN`). A host streaming 500, 502 or 504 is
failing, not recovering, and crediting those would let a broken service be
asked faster and faster while it breaks. Those statuses are still returned
to the caller unchanged — only the recovery signal is withheld.

**5. Loopback is never paced.** `localhost`, `::1`, any `*.localhost`
hostname, and any literal address `ipaddress` calls loopback, are skipped
entirely: no acquire, no penalty, no registry entry. A loopback address is
this process's own machine, not somebody else's service — a local model
server (Ollama on `localhost:11434`) must not be throttled by a contract
written for the free public services it calls over the network. Detection
inspects only the literal host string; it performs no DNS resolution, so
checking it never adds a lookup to the request path. Python:
`polite_session.is_loopback_host`.

**6. Throttle retries happen through the pacing, not inside a transport's
own retry loop**, and the retry budget for them is inherited from the
client's own configured total rather than invented. A transport-level retry
(urllib3's `Retry` on `requests`, or the platform equivalent) re-sends
inside a single logical send, where a limiter sitting below it cannot pace
the resend. So throttle statuses (429, 503;
`constants.POLITE_THROTTLE_STATUSES`) are taken out of the transport's own
retry-on-status list and retried by the pacing layer instead, one
`acquire()` per attempt — capped at `constants.POLITE_MAX_THROTTLE_RETRIES`
by default, but a client that configures its own retry budget on the
mounted session has that budget honoured instead, so the two do not silently
disagree. A client whose own calling code already retries (PubMed's search
client), or which makes exactly one request per call and reports the result
itself (the five transparency clients), mounts with a retry total of zero,
so mounting pacing does not multiply that client's request count. Adding
pacing must never increase the traffic it exists to reduce: the default
budget would turn one physical request into four on a persistent 503, and
those extra requests are charged to a budget other call sites share. Python: `polite_session.mount_politely` strips the
throttle statuses from the passed-in `Retry` and passes its `total` through
to `PoliteAdapter` as `max_throttle_retries`; `PoliteAdapter.send` runs the
acquire/send/penalise loop.

**7. Pacing never invents a failure, and never re-classifies one.**
`acquire()` only delays; it never raises and never turns a request into an
error. Nor may handing a status back change what a caller makes of it: a
caller that only ever saw a transport-level exception for a persistent 5xx
now sees the response, and any status classification it does must check the
status before sniffing the body. A 503 is a broken server, never a paywall
(`pdf_discovery.py`). A throttle that outlives its
retries is handed back to the caller as the response it is (a 429 or 503),
so the caller's existing error handling — retries, error classification,
whatever it already does with a bad status — runs exactly as it would
without pacing in front of it. A port must not, for instance, raise once the
throttle retries are spent: that is a new failure mode this contract does
not add.

## Where it lives (Python)

- `rate_limit.py` — `HostPolicy` (a ceiling, refusing zero or negative),
  `RateLimiter` (thread-safe: a caller *claims* its departure time under the
  lock, advancing the limiter's clock before releasing it, and then waits for
  that time with the lock released — which is what makes concurrent workers
  share one budget rather than hold one each, without a long penalty on one
  host freezing every thread that wants it), `policy_for_host`,
  `limiter_for`, `reset_limiters`.
- `polite_session.py` — `PoliteAdapter` (a `requests.HTTPAdapter` subclass),
  `mount_politely` (mounts one `PoliteAdapter` on both the `http://` and
  `https://` prefixes of a session), `retry_after_seconds`,
  `is_loopback_host`.
- `constants.py` — the `POLITE_*` block: `POLITE_RATE_CEILINGS`,
  `DEFAULT_POLITE_RATE_PER_SECOND`, `NCBI_RATE_WITH_API_KEY_PER_SECOND`,
  `POLITE_PENALTY_FLOOR_SECONDS`, `POLITE_MAX_PENALTY_SECONDS`,
  `POLITE_RECOVERY_SUCCESSES`, `POLITE_SLOW_WAIT_LOG_SECONDS`,
  `POLITE_THROTTLE_STATUSES`, `POLITE_MAX_THROTTLE_RETRIES`, and
  `HTTP_ERROR_STATUS_MIN` (the recovery signal's threshold).

Every client that makes outbound requests to a third-party host mounts
pacing on its `requests.Session` through `mount_politely` at construction,
rather than pacing itself: `pubmed/search_client.py`, `europepmc.py`,
`pdf_discovery.py`, and the five clients in
`study_transparency_analyzer/study_transparency_analyzer.py`.

## Ports

Nothing here has been checked against Swift or Android beyond the specific
gaps named in the platform table above, which is data collected while
writing this contract, not a full audit. A port conforms when: one limiter
serves each host, shared across every service instance and thread rather
than held per instance; the ceilings match the table in rule 2 (or the
host's own published or measured limit, for a host not yet in it); an
explicit wait-time from the host is honoured in full and never shortened;
absent one, the rate halves toward a 30-second floor and recovers only after
ten consecutive successes, never past the host's own ceiling; a loopback
address is never paced; a throttle status is retried through the pacing
layer — never inside a transport's own retry-on-status loop — against a
budget the client configured itself; and pacing never turns a request into
a failure the caller did not already have to handle.
