# Full Text Through Machine Channels — Stage C2 (Elsevier) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** For an article whose DOI starts `10.1016/`, every platform asks Elsevier's Article Retrieval API for its PDF, with the user's own key (and institutional token, when set), after Europe PMC's PDF render and before Unpaywall. A full PDF Elsevier serves is the article's PDF. A first-page-only answer is never used.

**Architecture:**
- **One pure core, pinned by a shared fixture** (`fulltext_parity/elsevier_article.json`):
  - which DOIs are Elsevier's (`eligible`);
  - the article URL (`article_url`);
  - how an answer is classified (`answers`: status, `X-ELS-Status` header, body).
- **A typed fetch** per platform, with these outcomes:
  - served PDF bytes / file;
  - absent;
  - unreachable;
  - key refused;
  - network refused.
- **A process-wide session object** per platform holds:
  - the 429 pause;
  - the refused key's digest;
  - the network-refused credentials' digest.

  It is CORE's `CoreThrottle` generalised, not copied (Task 2).
- **One place in each chain:** before Unpaywall.
  - Python: the first step of `PDFDiscoverer.discover_and_download`.
  - Swift: `FullTextService.fetchFullText`.
  - Kotlin: `FullTextService.fetchFullText`.
- **Elsevier failures are unsettled lookups** under the new source `elsevier` ("Elsevier's API"), placed before `unpaywall` in chain order. A missing key, or a DOI that is not Elsevier's, makes no request and records nothing.

**Tech Stack:** as stage C1: Python 3.12 + `requests` + PySide6; Swift 5.9 + BioMedLit + SwiftUI + Keychain; Kotlin + OkHttp + kotlinx.serialization + Room + Compose + EncryptedSharedPreferences; pytest, XCTest, JUnit4 + MockWebServer + MockK.

**Spec:** `docs/superpowers/specs/2026-10-04-fulltext-machine-channels-design.md`, "Decisions" 3–6, "Stage C" (Elsevier half), "How outcomes reach the reader", "Pacing", "Keys and settings". Stage C1's plan, `docs/superpowers/plans/2026-10-06-fulltext-machine-channels-stage-c1.md`, set the patterns this plan copies: settings plumbing, `key_refused`, the session object, the shortfall codecs. Read C1's contract section "CORE's Extracted Text" in `doc/cross_platform/fulltext_retrieval.md` before starting any task.

## Maintainer decisions (2026-10-08)

1. **A first-page PDF is not served.** When the requestor is not entitled, Elsevier answers 200 with only the PDF's first page and the header `X-ELS-Status: WARNING - Response limited to first page because requestor not entitled to resource`. This is Elsevier's answer that this requestor gets no full text:
   - an **absence** for this source;
   - nothing told to the reader;
   - the chain goes on.

   Its page is never used as the article's text (golden rule 13).
2. **Whatever the requestor is entitled to is served.** Spec decision 3's open-access-only rule is dropped:
   - open-access articles anywhere;
   - subscribed articles from the institution's network or with an institutional token.

   One request per article; no metadata check first.
3. **The off-network refusal is unsettled**, as CORE's refused key is. It is told as "Elsevier's API (not available from this network)" and blocks a settled absence.
4. **The fixtures follow Elsevier's documented shapes** until the maintainer runs `scripts/elsevier_probe.py`, off the institution's network now and on it later. The shapes are corrected from those rows in a later commit. Two shapes are not yet observed: the off-network refusal's status (spec: 403 with `AUTHENTICATION_ERROR`) and the error body's format (XML for `Accept: application/pdf`, per the probes without a key).

## Global Constraints

- Python is the reference; Swift and Kotlin mirror it. A behaviour change touches `elsevier_article.json` and all three platforms.
- **Names, verbatim:**
  - Source raw value `elsevier` (apps' `OpenAccessSource`, Android's `FULLTEXT_SOURCE_ELSEVIER`, Swift's `FullTextSource`).
  - Service name `"Elsevier's API"`: Python `SERVICE_ELSEVIER`, Swift `BioMedLitConstants.elsevierServiceName`, Kotlin `Constants.ELSEVIER_SERVICE_NAME`.
  - Display label of a PDF it served: `"Elsevier's API (PDF)"`.
  - Desktop `PDFSourceType.ELSEVIER_API = "elsevier_api"`. The full text it yields is `FulltextSourceType.DOWNLOADED_PDF`, as any downloaded PDF's.
  - New skip reason `network_refused`, worded `"not available from this network"`. Python adds `LookupSkipReason.NETWORK_REFUSED`; the apps add their counterparts.
- **Eligibility.** `elsevier_eligible(doi)` is true when `normalise(doi)` starts with `10.1016/`.
  - `normalise` is CORE's `normalise_doi`: trim, lower-case, remove one leading resolver prefix or `doi:`, trim again. Reuse it; do not copy it.
  - Every other DOI makes no request and records nothing. Elsevier publishes some imprints under other prefixes; they are out of scope (the spec's rule).
- **Request:** `GET {base}/content/article/doi/{escape_path(doi)}`.
  - `base` is `https://api.elsevier.com`, its trailing slashes dropped.
  - `doi` is the DOI trimmed, prefix removed as `normalise` does, **case kept**.
  - `escape_path` leaves ALPHA, DIGIT, `-`, `.`, `_`, `~` and `/` bare and percent-encodes every other UTF-8 byte in upper-case hex. That is Python's `quote(s, safe="/")`. A `;` must be encoded: a servlet would read it as a path parameter.
  - Headers:
    - `X-ELS-APIKey: {key}`;
    - `X-ELS-Insttoken: {token}`, only when the token is non-blank;
    - `Accept: application/pdf`;
    - Python also sends `User-Agent: EUROPEPMC_USER_AGENT`.
  - **Never** the `apiKey` or `insttoken` query parameters.
  - **Redirects are not followed.** A redirect would carry `X-ELS-APIKey`, a custom header no client strips across hosts. A 3xx is unreachable `http_status`.
- **The key and the token** are the settings trimmed. **A blank key means Elsevier is not configured:** no request, nothing recorded, no sentence, a DEBUG log line. The token is optional and never sent without a key.

  Each travels only in its header. Neither ever appears in:
  - a URL;
  - a log line;
  - an exception message or a `repr`;
  - a stored record;
  - an exported config.
- **When Elsevier is asked:**
  - at most once per article fetch;
  - with an eligible DOI (after each platform's existing DOI cleaning) and a key;
  - after Europe PMC's render tier and before any Unpaywall lookup;
  - only when nothing earlier obtained the article: no JATS body, no PDF.
- **Outcomes** (the fixture's `answers` table), checked in this order:
  1. This key refused this session → **key_refused**, no request.
  2. These credentials refused from this network this session → **network_refused**, no request.
  3. Paused → **unreachable** `http_status` 429, no request.
  4. Ask, then classify the answer:
     - **200** with an `X-ELS-Status` header whose value, trimmed, starts with `WARNING` (case-insensitive) → **absent** (`not_entitled`, logged at INFO). This is checked **before** the body.
     - **200** whose body starts `%PDF` → **served**, under the platform's existing PDF rules: the size limit (desktop only), the `.part` file, the not-saved path.
     - **200** otherwise → **unreachable** `malformed_response`.
     - **404** → **absent**.
     - **401** → **key_refused**; this key is refused for the rest of the process (SHA-256 of the trimmed key, as CORE).
     - **403** whose body contains the ASCII bytes `AUTHENTICATION_ERROR` → **network_refused**. These credentials are refused for the rest of the process: SHA-256 of `trim(key) + "\n" + trim(token or "")`. Corrected credentials, such as a token added in the settings, are asked again. At most `ELSEVIER_ERROR_BODY_MAX_BYTES` (64 KiB) of an error body is read for this test. It is a bounded read of a provider error, not research content.
     - **403** otherwise, and any other status (3xx included) after retries → **unreachable** `http_status`.
     - Transport failure → **unreachable**, its kind.
  - Retries: 429/500/502/503/504 are retried, 4 attempts in all, each paced, as CORE's.
  - The pause: two consecutive fetches that **end** in 429 (after retries) pause Elsevier for the rest of the process, as CORE's. Any other ending resets the count. Elsevier's weekly quota answers 429 `QUOTA_EXCEEDED` once spent.
- **What a fetch does to the reader:**
  - **Served:** the article's PDF.
    - Source "Elsevier's API (PDF)"; the PDF's text is extracted as any downloaded PDF's.
    - The open-access question is settled: no shortfall is stored with it.
    - A PDF that yields no text (a scan) follows the existing textless-PDF rules (Python #499: CORE is asked after it).
  - **Absent** (404, or the first-page warning): nothing is added, and the chain goes on.
  - **Unreachable:** a lookup failure under `elsevier` / `SERVICE_ELSEVIER`, and a lookup entry `"Elsevier's API ({reason})"`. It blocks a settled absence. Chain order puts it before `unpaywall`.
  - **Key refused:** a skip of `elsevier` with reason `key_refused` ("the key in the settings was refused"). It blocks absence and adds no configuration nudge.
  - **Network refused:** a skip of `elsevier` with reason `network_refused` ("not available from this network"). It blocks absence and adds no configuration nudge.
  - **Served but not saved:** on the desktop, the existing `NOT_SAVED` caching note, with the article URL as its address (the URL carries no key), and nothing else is asked. The apps differ: see "Rules for the apps".
  - **Larger than the download limit** (desktop only; the apps set none): an `OVER_SIZE_LIMIT` skip of `elsevier`, address the article URL. The chain goes on.
- **Pacing:** `api.elsevier.com` at **2 requests per second**.
  - Python: `POLITE_RATE_CEILINGS`.
  - Swift: `elsevierMinimumInterval = 0.5` s.
  - Kotlin: `RequestPacer(500)` in the singleton.
- **Keys:**
  - Desktop: `LiteConfig.discovery.elsevier_api_key` and `elsevier_insttoken: Optional[str]`, environment fallbacks `ELSEVIER_API_KEY` / `ELSEVIER_INSTTOKEN`. Written by `write_owner_only_file` and redacted as `core_api_key` is (both fields), with two fields in the settings dialog's "Full Text" tab.
  - iOS/macOS: Keychain keys `elsevier_api_key`, `elsevier_insttoken` via `AppSettings`; fields beside CORE's in `SettingsView` and `MacSettingsView`.
  - Android: `EncryptedSharedPreferences` keys `elsevier_api_key`, `elsevier_insttoken` via `SettingsRepository`; masked fields beside CORE's.
  - Key saves report failure, as C1's do.
  - The explanations, verbatim, on every platform:
    - Key: `"Optional. A free Elsevier API key (dev.elsevier.com) lets the app download the PDFs of Elsevier articles you are entitled to: open-access articles anywhere, subscribed ones from your institution's network."`
    - Token: `"Optional. An institutional token from Elsevier lets the key use your institution's subscriptions away from its network."`
- Docstrings: Google style (Python), `///` (Swift), KDoc (Kotlin). No magic numbers. No new dependency. No inline stylesheet in new Qt code; `scaled()` for pixels.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. **No GitHub closing keyword** before #480 or any number that stays open: write "Refs #480".

## Review Focus

1. **A first-page PDF is never served** on any platform. Fixture rows "first page only" and "a warning in any case"; a chain test per platform asserting that Unpaywall is asked next.
2. **The key and token never leak.** They must stay out of:
   - URLs;
   - logs;
   - exception text and `repr`;
   - `to_redacted_dict()` and the CLI's config view;
   - stored shortfalls;
   - **redirects**: one is never followed.
3. **Without a key, or for another publisher's DOI, nothing changes.** No request, no lookup, no sentence; absence still established. Explicit controls on every platform.
4. **Refusals are scoped.**
   - A 401 refuses that key only.
   - A 403 `AUTHENTICATION_ERROR` refuses those credentials only. A token added later is asked.
   - A 403 without the token is an ordinary unreachable answer.
5. **The session state is process-wide**, across service instances, and shared with nothing of CORE's: a CORE 429 never pauses Elsevier.

---

## File Structure

| File | Responsibility |
|---|---|
| `doc/cross_platform/fulltext_parity/elsevier_article.json` (new) | Names, `eligible`, `article_url`, `answers`, constants |
| `doc/cross_platform/fulltext_parity/open_access_unsettled_notice.json` | Source `elsevier`, its notices and persisted rows, `network_refused` |
| `doc/cross_platform/fulltext_retrieval.md` | New section "Elsevier's Article API (#480, stage C2)"; chain list, tables, "Tried sources" order |
| `doc/cross_platform/polite_request_pacing.md` | Row `api.elsevier.com` 2 |
| `docs/superpowers/specs/2026-10-04-fulltext-machine-channels-design.md` | As-built note under "Stage C" for decisions 1–3 |
| `src/bmlibrarian_lite/constants.py` | Elsevier block, `POLITE_RATE_CEILINGS`, env names, `SERVICE_ELSEVIER` |
| `src/bmlibrarian_lite/keyed_service_session.py` (new) | `KeyedServiceSession`, the generalised `CoreThrottle` |
| `src/bmlibrarian_lite/core_api.py` | `CoreThrottle` built on `KeyedServiceSession`, API unchanged |
| `src/bmlibrarian_lite/elsevier_api.py` (new) | `elsevier_eligible`, `elsevier_article_url`, `ElsevierCredentials`, `ElsevierFetch`, `ElsevierArticleClient`, `default_elsevier_client`, `reset_elsevier_session` |
| `src/bmlibrarian_lite/data_models.py` | `LookupSkipReason.NETWORK_REFUSED`; `KEY_REFUSED`/`NETWORK_REFUSED` admitted for Elsevier |
| `src/bmlibrarian_lite/analysis_failures.py` | `SERVICE_ELSEVIER` in `_OPEN_ACCESS_CHAIN` before Unpaywall |
| `src/bmlibrarian_lite/pdf_discovery.py` | `PDFSourceType.ELSEVIER_API`; the Elsevier step |
| `src/bmlibrarian_lite/fulltext_discovery.py`, `config.py`, `cli.py`, `gui/settings_dialog.py`, `gui/workers.py`, `gui/document_interrogation_tab.py`, `mcp_server.py`, `transparency/*`, `study_transparency_analyzer/study_transparency_analyzer.py` | Thread `ElsevierCredentials` wherever `core_api_key` travels |
| `scripts/elsevier_probe.py` | Ask through `elsevier_article_url`, so the probe checks the shipped URL |
| `tests/conftest.py` | Autouse `_no_live_elsevier` guard and session reset |
| `tests/test_elsevier_api.py`, `tests/test_elsevier_discovery.py`, `tests/test_elsevier_config.py`, `tests/test_keyed_service_session.py` (new) | Python tests |
| Swift / Kotlin | Tasks 5–8 |
| `doc/user/guide.md` (beside "CORE API Key (Optional)") | How to get an Elsevier key and token, and that it works from the institution's network or with a token |

---

## Task 1: The shared contract

**Files:** `doc/cross_platform/fulltext_parity/elsevier_article.json` (new), `open_access_unsettled_notice.json`, `fulltext_retrieval.md`, `polite_request_pacing.md`, the spec's as-built note.

- [ ] **Step 1: `elsevier_article.json`**, schema 1, shaped like `core_fulltext.json`:
  - `description`: what each table means and which tests read it (`tests/test_elsevier_api.py`, BioMedLit `ElsevierContractTests`, Android `ElsevierContractTest`).
  - Constants:
    - `service_name` "Elsevier's API";
    - `source` "elsevier";
    - `source_label` "Elsevier's API (PDF)";
    - `desktop_source_type` "elsevier_api";
    - `base_url` "https://api.elsevier.com";
    - `doi_prefix` "10.1016/";
    - `pause_after_consecutive_429` 2;
    - `key_refused_status` 401;
    - `key_refused_reason` "the key in the settings was refused";
    - `network_refused_status` 403;
    - `network_refused_token` "AUTHENTICATION_ERROR";
    - `network_refused_reason` "not available from this network";
    - `first_page_header` "X-ELS-Status";
    - `first_page_prefix` "WARNING";
    - `error_body_max_bytes` 65536;
    - `follows_redirects` false;
    - `requests_per_second` 2.
  - `eligible` rows: `{doi, eligible}`:
    - `10.1016/j.cell.2020.02.052` true;
    - upper-case `10.1016/S0140-6736(20)30183-5` true;
    - `https://doi.org/10.1016/j.x.1` true;
    - `doi:10.1016/j.x.1` true;
    - padded `"  10.1016/j.x.1\n"` true;
    - `10.10160/x` false (prefix, not registrant);
    - `10.1371/journal.pone.0000217` false;
    - `""` false;
    - `10.1016` (no slash) false.
  - `article_url` rows: `{name, doi, base_url, url}`:
    - plain;
    - case kept;
    - parentheses encoded (`%28`, `%29`);
    - SICI DOI (`10.1016/S0022-5193(05)80123-X` and one with `<`, `>`, `;`, `:`);
    - padded DOI trimmed;
    - resolver prefix removed;
    - a base URL with a trailing slash.
  - `answers` rows: `{name, status, headers, body_text | body_pdf, outcome, failure_kind}`. The outcome is one of `served`, `absent`, `unreachable`, `key_refused`, `network_refused`. `body_pdf: true` means the body is `%PDF-1.7\n…` (the tests build it). Rows:
    - 200 PDF, no header → served;
    - 200 PDF, `X-ELS-Status: WARNING - Response limited to first page because requestor not entitled to resource` → absent ("first page only");
    - 200 PDF, header `warning - …` lower-case → absent ("a warning in any case");
    - 200 PDF, header `OK` → served ("a status that is no warning");
    - 200 HTML body → unreachable `malformed_response`;
    - 200 empty body → unreachable `malformed_response`;
    - 404 → absent;
    - 401 → key_refused;
    - 403 XML body `<service-error><status><statusCode>AUTHENTICATION_ERROR</statusCode><statusText>Requestor configuration settings insufficient for access to this resource.</statusText></status></service-error>` → network_refused;
    - 403 JSON body `{"service-error":{"status":{"statusCode":"AUTHENTICATION_ERROR","statusText":"…"}}}` → network_refused;
    - 403 `AUTHORIZATION_ERROR` body → unreachable `http_status`;
    - 403 empty → unreachable `http_status`;
    - 302 → unreachable `http_status`;
    - 400, 410, 429, 500, 503 → unreachable `http_status`.
  - `session` rows: sequences of `{credentials, status}` and the outcome of the next fetch:
    - two 429s → paused;
    - 429, 404, 429 → not paused;
    - 401 for key A → key A refused, key B asked;
    - 403 `AUTHENTICATION_ERROR` for (A, no token) → (A, no token) refused, (A, token T) asked.

- [ ] **Step 2: `open_access_unsettled_notice.json`.**
  - Add the source `"elsevier": "Elsevier's API"`.
  - Add notice rows for Elsevier:
    - `http_status` 503 ("could not be asked");
    - `http_status` 403 ("did not serve it");
    - `timeout`;
    - skipped `key_refused`;
    - skipped `network_refused`: "Elsevier's API (not available from this network) could not be asked, so a freely available copy may exist. Whether this document is open access was not established." No nudge.
  - Add persisted rows written and read for `elsevier` failures and both skips, in the schema the apps store (v2 `entries`). A stored `key_refused` row naming `core` or no source still reads as CORE's. Keep the old rows byte-for-byte.
  - Update the `description` accordingly.

- [ ] **Step 3: `fulltext_retrieval.md`**: a section "Elsevier's Article API (#480, stage C2)" after "CORE's Extracted Text". It holds:
  - the pseudocode block (the Global Constraints' request and outcomes, in CORE's section's style);
  - the decisions, with their reasons;
  - the reader's sentences.

  Also:
  - insert Elsevier into the chain list and the "Tried sources" order (before Unpaywall);
  - add `elsevier` to the source-name table;
  - add `network_refused` to the skip-reason table;
  - extend the rule that a stored `key_refused` reads as CORE's.

- [ ] **Step 4:** add a `polite_request_pacing.md` row, `api.elsevier.com | 2/s | Elsevier allows 10/s and a weekly quota`.

- [ ] **Step 5:** in the spec, add an "As built (C2, maintainer 2026-10-08)" note under "Stage C" → "Elsevier". It records decisions 1–3, the no-redirect rule and the credential-scoped refusals, and says the contract wins.

- [ ] **Step 6:** commit `docs(elsevier): the stage C2 contract and fixture (#480)`.

## Task 2: Python session state, generalised

**Files:** `src/bmlibrarian_lite/keyed_service_session.py` (new), `core_api.py`, `tests/test_keyed_service_session.py` (new).

- [ ] **Step 1: failing tests** for `KeyedServiceSession(service, key_refused_status, pause_after)`:
  - `paused` after `pause_after` consecutive 429 endings, and never lifted;
  - another ending resets the count;
  - `refuses_key(digest)` after a `key_refused_status` ending, for that digest only;
  - `refuses_network(digest)` after `record_network_refused(digest)`, for that digest only;
  - thread safety: N threads recording 429 → paused exactly once (one warning logged);
  - `credentials_digest(key, token)` is SHA-256 hex of `trim(key) + "\n" + trim(token or "")` and differs with and without a token.
- [ ] **Step 2: implement.** Move `CoreThrottle`'s body into `KeyedServiceSession`, adding the network refusal. Keep `CoreThrottle` as a subclass with CORE's defaults, so every C1 test passes unchanged. Keep `core_key_digest` (move the hashing into the new module and re-export it). The log lines name `service`.
- [ ] **Step 3:** `pytest tests/test_keyed_service_session.py tests/test_core_api.py tests/test_core_discovery.py -q`, then commit `refactor(python): CORE's session state as a keyed-service session (#480)`.

## Task 3: Python Elsevier client and settings

**Files:** `constants.py`, `elsevier_api.py` (new), `data_models.py`, `config.py`, `cli.py`, `gui/settings_dialog.py`, `tests/test_elsevier_api.py`, `tests/test_elsevier_config.py`, `tests/conftest.py`.

- [ ] **Step 1: constants.**
  - `ELSEVIER_API_BASE_URL`, `ELSEVIER_HOST`, `ELSEVIER_ARTICLE_PATH = "/content/article/doi/"`, `ELSEVIER_DOI_PREFIX`.
  - `ELSEVIER_MAX_RETRIES = 3`, `ELSEVIER_BACKOFF_FACTOR`, `ELSEVIER_REQUEST_TIMEOUT_SECONDS`.
  - `ELSEVIER_KEY_REFUSED_STATUS = 401`, `ELSEVIER_NETWORK_REFUSED_STATUS = 403`, `ELSEVIER_NETWORK_REFUSED_TOKEN = b"AUTHENTICATION_ERROR"`.
  - `ELSEVIER_STATUS_HEADER = "X-ELS-Status"`, `ELSEVIER_WARNING_PREFIX = "warning"`.
  - `ELSEVIER_ERROR_BODY_MAX_BYTES = 65536`, `ELSEVIER_PAUSE_AFTER_CONSECUTIVE_429 = 2`.
  - `ENV_ELSEVIER_API_KEY`, `ENV_ELSEVIER_INSTTOKEN`.
  - `SERVICE_ELSEVIER = "Elsevier's API"`, `ELSEVIER_SOURCE_LABEL`.
  - `POLITE_RATE_CEILINGS["api.elsevier.com"] = 2.0`.
  - The two explanation strings.
- [ ] **Step 2: failing tests** (`tests/test_elsevier_api.py`). They read the fixture: every `eligible`, `article_url` and `answers` row, and the `session` rows through a real `ElsevierArticleClient` against a stubbed transport (the C1 tests show how; use `responses` or the adapter stub `test_core_api.py` uses). Plus:
  - the key and token appear in the request's headers and nowhere in its URL;
  - no token → no `X-ELS-Insttoken` header;
  - `repr(client)` and every log record (caplog at DEBUG) hold neither;
  - a 302 to another host is not followed (the stub would fail the test if asked);
  - the first-page answer writes nothing to `output_path` and leaves no `.part`;
  - a served PDF is written through `.part` and renamed, and over `MAX_PDF_SIZE` is refused for size;
  - a write that fails is `not_saved`;
  - a cancel mid-stream writes nothing;
  - a 401 → that key refused, another key asked; a 403 `AUTHENTICATION_ERROR` → those credentials refused, the same key with a token asked;
  - a CORE pause never pauses Elsevier.
- [ ] **Step 3: implement `elsevier_api.py`.**
  - `ElsevierCredentials(api_key, insttoken)`: frozen dataclass, `repr=False` fields; a constructor refusing a blank key; `digest` properties.
  - `elsevier_eligible`, `elsevier_article_url`: pure.
  - `ElsevierFetch`: `served(path)`, `absent()`, `unreachable(failure)`, `key_refused()`, `network_refused()`, `refused_for_size()`, `not_saved()`, and `lookups(url)` building the record per the Global Constraints. Validate impossible combinations as `CoreFetch` does.
  - `ElsevierArticleClient(credentials, base_url, max_retries, session_state)` with `fetch_pdf(doi, output_path, cancelled: Callable[[], bool]) -> ElsevierFetch`. It uses `mount_politely` with a `Retry` as CORE's and `allow_redirects=False`, and streams with `read_body_prefix` / `partial_download_path` / `discard_partial_download`. Import them from `pdf_discovery` lazily, or move them to a small `pdf_download.py` that both import: no import cycle.
  - `session_elsevier_state()`, `reset_elsevier_session()`, and `default_elsevier_client(api_key, insttoken)`, which returns `None` without a key and falls back to the environment.
  - `data_models`: `LookupSkipReason.NETWORK_REFUSED` with its wording. `KEY_REFUSED` is admitted for CORE or Elsevier; `NETWORK_REFUSED` only for Elsevier; neither with an address.
- [ ] **Step 4: settings.** `DiscoveryConfig.elsevier_api_key`, `elsevier_insttoken` (`repr=False`):
  - load, save, redacted dict, `_reject_redaction_placeholder`, CLI view (`tests/test_elsevier_config.py` mirrors `test_core_config.py`);
  - two fields in the "Full Text" tab under CORE's, password echo, tooltips the explanations, the environment placeholder when set there;
  - the dialog's save path reports failure as C1's does;
  - `doc/user/guide.md`: a section "Elsevier API Key and Institutional Token (Optional)" beside CORE's, saying where to get them (dev.elsevier.com), that a key alone was refused for every article from outside the institution's network in the #480 spike, open-access ones included, and that an institutional token is meant to lift that.
- [ ] **Step 5: `tests/conftest.py`.** Add an autouse guard that makes `default_elsevier_client` return `None` unless a test opts in, and resets the session, as `_no_live_core` does.
- [ ] **Step 6:** run `pytest tests/ -q` and `ruff check` on the new files, then commit `feat(python): Elsevier's article API client and its key settings (#480)`.

## Task 4: Python chain

**Files:** `pdf_discovery.py`, `fulltext_discovery.py`, `analysis_failures.py`, the threading sites (every place `core_api_key` travels: `gui/workers.py`, `gui/document_interrogation_tab.py`, `mcp_server.py`, `transparency/assessment.py`, `transparency/transparency_manager.py`, `study_transparency_analyzer.py`), `scripts/elsevier_probe.py`, `tests/test_elsevier_discovery.py`.

- [ ] **Step 1: failing chain tests** (stub clients, no network):
  - an Elsevier PDF served → success, source `ELSEVIER_API`, Unpaywall never asked, nothing unsettled;
  - first-page answer → Unpaywall asked next, and nothing about Elsevier in the record or sentence;
  - 404 → as first-page;
  - unreachable 503 → recorded under `SERVICE_ELSEVIER`, told in the sentence before Unpaywall's entries, and `FulltextResult` is `NOT_ASSESSED`, never `NOT_FOUND`, when nothing else serves;
  - key refused / network refused → the skip, told with its words, blocks absence, no nudge;
  - not saved → the caching note, nothing else asked;
  - over size → skip recorded, Unpaywall asked;
  - non-Elsevier DOI → client never called, absence settles as before;
  - no key → as non-Elsevier;
  - Elsevier asked once per discovery even when PMC sources exist;
  - the PDF yields no text → CORE is asked next (#499's path), and Elsevier's file stays cached;
  - cancelled before → Elsevier not asked;
  - `_OPEN_ACCESS_CHAIN` order: Elsevier's entry before Unpaywall's in "Tried sources".
- [ ] **Step 2: implement.**
  - `PDFDiscoverer(elsevier=…)` (default `None`). In `discover_and_download`, after the DOI is cleaned and before `_discover_sources`, ask Elsevier when `elsevier is not None and elsevier_eligible(doi)`:
    - served → `DiscoveryResult(success=True, file_path, source=PDFSource(url, ELSEVIER_API))`, with the title check as `_try_download` does;
    - not saved → the caching-note return;
    - otherwise merge its `lookups(url)` into `lookups` and `told`, and go on.
  - `FulltextDiscoverer(elsevier_credentials=…, elsevier=…)` passes the client down.
  - Thread `ElsevierCredentials.from_config(config.discovery)` (`None` without a key) through every site `core_api_key` reaches. `TransparencyManager` rebuilds its analyser when either Elsevier setting changes, as it does for CORE's key.
  - `scripts/elsevier_probe.py` asks through `elsevier_article_url`.
- [ ] **Step 3:** run `pytest tests/ -q` and `python .github/scripts/lint_delta.py --base-ref origin/master`, then commit `feat(python): Elsevier's API in the full-text chain, before Unpaywall (#480)`.

## Rules for the apps (both)

These follow from the Swift and Kotlin maps, and bind Tasks 5–8.

- **Elsevier's article URL is never a reader link.** It needs the key. It is never:
  - stored as the document's PDF URL or link;
  - offered as "Open in Browser";
  - re-fetched without headers (`PDFContentLoader`, Android's `pdfOrLink`);
  - set as `fullTextPdfNotSavedFrom` / `pdfNotSavedFrom`.

  A served Elsevier PDF is held only as a **local file**.
- **Download failures and refusals never fall back to a link.** They are recorded as the outcome table says, and the walk goes on to Unpaywall.
- **Not saved** (our write failed): the walk goes on to Unpaywall, and Elsevier records nothing. A copy Unpaywall serves settles the question. When nothing later serves a copy, the apps' existing not-saved note is **not** used (it carries a link). Instead the result keeps `OpenAccessShortfall(source: elsevier, failure: request_failed)`, logged at ERROR with the cause.
  - This is an apps-only deviation from the desktop's `NOT_SAVED` note, recorded in the contract.
  - It keeps absence unsettled, which is the property that matters.
- **No size limit** in the apps (none exists for any PDF there).
- **Redirects refused.**
  - Swift: `RedirectRefusingTaskDelegate` (`Services/EutilsRequest.swift`) per task, as `PubMedService` uses it.
  - Kotlin: a client derived with `followRedirects(false)` and `followSslRedirects(false)`.
- **Android #493.** Android's render tier returns `EuropePmcPdf(url)` without downloading it, so a failed render never reaches the tiers after it. Elsevier, after the render tier in the contract's order, is therefore asked on Android only when Europe PMC offered no render URL. This is #493's limit and is not fixed here. The contract and the hand-over say so, and Elsevier is reached once #493 is fixed.

## Task 5: Swift — Elsevier's pure rules and session state (BioMedLit)

**Files:**
- `Packages/BioMedLit/Sources/BioMedLit/Services/Elsevier.swift` (new);
- `Services/CORE.swift` (`CoreThrottle` generalised);
- `Utilities/Constants.swift`, `Utilities/RetryHelper.swift`;
- `Models/OpenAccessShortfall.swift`;
- `Tests/BioMedLitTests/ElsevierContractTests.swift` (new), `OpenAccessShortfallContractTests.swift`.

- [ ] **Step 1: failing tests**, reading `elsevier_article.json` with a walk-up loader like `COREContract`:
  - every `eligible` and `article_url` row;
  - `Elsevier.classify(status:headers:body:)` over every `answers` row;
  - every `session` row against a fresh `KeyedServiceSession`;
  - `testEveryContractTableIsReadHere`;
  - the names (`elsevierServiceName`, source `elsevier`, label);
  - `OpenAccessShortfall.chainOrder.first == .elsevier`.

  In `OpenAccessShortfallContractTests`, update for the new source and the `network_refused` rows. A `key_refused` row now reads as its named source when that is `elsevier`, otherwise as CORE's.
- [ ] **Step 2: implement.**
  - `public enum Elsevier`: `isEligible(doi:)` (uses `CORE.bareDOI` + lower-case prefix test), `articleURL(doi:baseURL:)`, `classify(...) -> ElsevierAnswer`, `credentialsDigest(key:token:)`.
  - Move the hashing into a shared `KeyDigest` helper. `CORE.keyDigest` stays as a forwarder.
  - `enum ElsevierFetch: Equatable`: `served(localPath: String)`, `absent`, `unreachable(RequestFailure)`, `keyRefused`, `networkRefused`, `notSaved`.
  - `KeyedServiceSession` (new, generalised from `CoreThrottle`, NSLock, `@unchecked Sendable`), with `refuses(keyDigest:)`, `refusesNetwork(credentialsDigest:)`, `record(endedOn:keyDigest:)`, `recordNetworkRefused(credentialsDigest:)` and `isPaused`.
    - `CoreThrottle` becomes a subclass or typealias keeping its API and `.shared`.
    - `ElsevierSession.shared` is a separate instance.
  - Constants:
    - `elsevierBaseURL`, `elsevierArticlePath`, `elsevierDOIPrefix`;
    - `elsevierServiceName`, `elsevierSourceLabel`;
    - `elsevierKeyRefusedStatus`, `elsevierNetworkRefusedStatus`, `elsevierNetworkRefusedToken`;
    - `elsevierStatusHeader`, `elsevierWarningPrefix`;
    - `elsevierErrorBodyMaxBytes`, `elsevierPauseAfterConsecutive429`;
    - `elsevierMinimumInterval = 0.5`, `elsevierNetworkRefusedReason`;
    - `RetryConfiguration.elsevier`.
  - `OpenAccessSource.elsevier` (raw `elsevier`), first in `chainOrder`.
  - `OpenAccessUnsettledReason.networkRefused`. `keyRefused.described` stays the shared wording. The `Entry` init admits `keyRefused` for `.core` or `.elsevier`, and `networkRefused` only for `.elsevier`, both without an address.
  - Statics `elsevierKeyRefused`, `elsevierNetworkRefused`.
  - The codec: skip string `network_refused`. `restoredEntry` reads `key_refused` as `.elsevier` when the stored source is `elsevier`, and as `.core` otherwise; `network_refused` reads as `.elsevier`.
- [ ] **Step 3:** run `swiftc -typecheck` first (memory: SwiftPM hang), then `cd Packages/BioMedLit && swift test`, then commit `feat(swift): Elsevier's pure rules and session state (#480)`.

## Task 6: Swift — Elsevier in `FullTextService`

**Files:** `Services/FullTextService.swift`, `Models/FullTextModels.swift`, `Tests/BioMedLitTests/FullTextServiceElsevierTests.swift` (new), and the `StubURLProtocol` default fallback routes.

- [ ] **Step 1: failing tests**, in the style of `FullTextServiceCORETests`:
  - served → `FullTextResult` with content `.elsevier(localPath)`, source `.elsevier`, the PDF's text extracted, Unpaywall never requested;
  - first-page → Unpaywall requested next, no entry;
  - 404 → as first-page;
  - 503 → `OpenAccessShortfall(.elsevier, 503)` first in the notice, and `exhaustedChainError` not "no full text";
  - 401 and 403 `AUTHENTICATION_ERROR` → the skips, shared across service instances (two services, one session), scoped to the credentials;
  - the key and token only in headers;
  - no token → no header;
  - a redirect is refused (`StubURLProtocol.redirects`);
  - non-Elsevier DOI and no key → no Elsevier request;
  - not saved → walk goes on, shortfall `request_failed` when nothing serves, and the result carries **no** `api.elsevier.com` URL anywhere (`pdfURL`, link, `pdfNotSavedFrom`);
  - textless Elsevier PDF → CORE asked (`textlessCopyOrCORE`);
  - the pacing slot.

  Add `api.elsevier.com` → 404 to `defaultFallbackRoutes`.
- [ ] **Step 2: implement.**
  - `FullTextService.init(… elsevierAPIKey:, elsevierInstToken:, elsevierSession: = .shared)`, trimmed with blank → nil; update the DocC init symbol.
  - `PacedHost.elsevier`.
  - A paced fetch that returns the `HTTPURLResponse` too. Either extend `pacedAttempt` to return headers or add a sibling. It must use the redirect-refusing delegate and the PDF download timeout. Error bodies are read up to `elsevierErrorBodyMaxBytes` for the token test only.
  - `fetchElsevierPDF(doi:cacheKey:) -> ElsevierFetch` writes through `cachePDF` / `writeCachedPDF` under the document's cache key.
  - In `fetchFullText`, between the render tier and Unpaywall: move `openAccessShortfall`'s declaration above it, then ask and map the outcomes.
    - Served → extract with the existing extractor and return, or `textlessCopyOrCORE` for a textless PDF.
  - `FullTextSource.elsevier` ("Elsevier's API (PDF)"), `FullTextContent.elsevier(localPath:)`. Its `pdfURL` is the **file** URL, so the `localPDFPath` assert holds.
  - Review the assert at `FullTextModels.swift` ~412–418: a shortfall on a textless Elsevier copy may carry only CORE's entries, as Unpaywall's does.
  - `asksElsevier` mirrors `asksCore`.
  - Update the chain-order doc comments.
- [ ] **Step 3:** run `swift test` in `Packages/BioMedLit`, then commit `feat(swift): Elsevier's API in the full-text chain, before Unpaywall (#480)`.

## Task 7: Swift app — source, storage and the key settings

**Files:**
- `ios/MedicalFactChecker/Sources/Models/FullTextSource.swift`, `Utilities/BioMedLitAdapters.swift`;
- `Views/Components/FullTextSourceBadge.swift`, `macOS/MacConstants.swift`;
- `Models/AppSettings.swift`, `Models/Document.swift` (check `applyFullTextResult` stores the local path);
- `Views/Settings/SettingsView.swift`, `macOS/Views/Settings/MacSettingsView.swift`;
- `Tests/ElsevierDocumentTests.swift` (new), `Tests/APIKeySaveTests.swift`.

- [ ] **Step 1: failing tests:**
  - `AppFullTextSource.elsevier` label, icon and `canDisplayInApp`;
  - the adapter maps `.elsevier(localPath)` to a local PDF;
  - a document applied from an Elsevier result stores the local path and no remote URL;
  - `create(from:)` passes both settings (`asksElsevier`);
  - saving each key reports failure through `StubSecretStore(failsSaves:)`;
  - `resetToDefaults` clears both.
- [ ] **Step 2: implement.**
  - `AppSettings.elsevierAPIKey` / `elsevierInstToken` (Keychain keys `elsevier_api_key`, `elsevier_insttoken`) with `saveElsevierAPIKey` / `saveElsevierInstToken` → `Bool`.
  - `BMLFullTextService.create(ncbiEmail:coreAPIKey:elsevierAPIKey:elsevierInstToken:)`, with defaults so existing calls compile.
  - Fields:
    - iOS: the "Full Text" section, below CORE.
    - macOS: `PubMedSettingsTab`, a section "Elsevier API Key (Optional)" with a "Get API Key" link to `https://dev.elsevier.com/`.
    - `SecureField`s, Save buttons through `reportKeySave`, the verbatim explanations as footers.
  - Badge colours: the same as Unpaywall's.
- [ ] **Step 3:** run `cd ios/MedicalFactChecker && swift test`, then `xcodebuild -scheme MedicalFactChecker -destination 'platform=macOS' build`. Run the iOS simulator build too, since `SettingsView` is iOS-guarded code. Then commit `feat(swift app): Elsevier's PDFs and the key settings (#480)`.

## Task 8: Kotlin — Elsevier's rules, service, chain, display and settings

**Files** (Android paths as C1's plan gives them):
- `util/Constants.kt`;
- `data/remote/fulltext/Elsevier.kt` (new: `object Elsevier`, `ElsevierFetch`, `@Singleton ElsevierService`);
- `data/remote/fulltext/KeyedServiceSession.kt` (new, generalised from `CoreService`'s state; `CoreService` uses it);
- `domain/model/OpenAccessShortfall.kt`;
- `data/remote/fulltext/FullTextService.kt`, `FullTextRecording.kt`;
- `di/NetworkModule.kt`;
- `data/local/entity/DocumentEntity.kt` (`fullTextSourceDisplay`);
- `domain/model/FullTextLinkKind.kt`, `ui/fulltext/components/FullTextSourceBadge.kt`, `ui/fulltext/FullTextViewModel.kt` (`handleFullTextResult`);
- `data/repository/SettingsRepository.kt`, `ui/settings/SettingsViewModel.kt`, `ui/settings/SettingsScreen.kt`;
- tests: `ElsevierContractTest.kt`, `ElsevierServiceTest.kt`, `ElsevierTestDoubles.kt` (`absentElsevier()`), `FullTextServiceElsevierTest.kt`, `SettingsViewModelElsevierKeyTest.kt`, plus the contract tests the shortfall change touches.

- [ ] **Step 1: failing tests:**
  - **Contract:** every table in `elsevier_article.json`, read via the walk-up loader (the gradle `inputs.dir` already covers the directory).
  - **Service** (MockWebServer, `RequestPacer(0)`, no retries):
    - every `answers` row;
    - key and token in headers only, never in a `Log` line (the `android.util.Log` shim);
    - a 302 to another host not followed (custom `Dns` as `CoreServiceTest`);
    - the 429 pause;
    - key and credentials scopes;
    - cancellation rethrown;
    - one pacer slot per attempt.
  - **Chain** (`FullTextServiceElsevierTest`):
    - served → `FullTextResult.ElsevierPdf(localPath)`, Unpaywall never called;
    - first-page / 404 → Unpaywall called;
    - 503 → `OpenAccessShortfall(ELSEVIER, …)` first in the notice;
    - the skips;
    - non-Elsevier DOI and no key → not called;
    - a render URL present → Elsevier not asked (#493's limit, pinned so fixing #493 updates it);
    - not saved → walk goes on, `request_failed` shortfall when nothing serves.
  - **Recording:** `ElsevierPdf` stores `pdf_path` and source `elsevier`, **never** an `api.elsevier.com` URL in any column (`fullTextPdfNotSavedFrom` included). `FullTextLinkKind.forStoredSource("elsevier")` is a downloaded PDF, not a publisher page.
  - **Settings:** save reports failure (`writeSecretKey`); reset clears both.
- [ ] **Step 2: implement.**
  - `ElsevierService(OkHttpClient, SettingsRepository)`, `@Inject`, `@Singleton`:
    - a derived client with timeouts, `retryOnConnectionFailure(false)` and redirects off;
    - `RequestPacer(Constants.ELSEVIER_MIN_INTERVAL_MS = 500)`;
    - `suspend fun fetchPdf(doi): ElsevierFetch?` (null = not asked).
  - Cache file: `cacheDir/fulltext_pdfs/elsevier-<sha256(normalised doi)>.pdf`, via `.part` and `copyToCache`, `%PDF` checked, a cached file reused.
  - `FullTextService` takes `ElsevierService`; update `NetworkModule` and the six test construction sites with `absentElsevier()`.
  - In `fetchFullText`, after the render tier and before Unpaywall, map outcomes as the Global Constraints say.
  - `FullTextResult.ElsevierPdf(pdfPath)`, added to every exhaustive `when` (`getSourceConstant`, `recording()`, `recordingFullTextFetch`, `handleFullTextResult`).
  - `OpenAccessSource.ELSEVIER("elsevier", ELSEVIER_SERVICE_NAME)`, first in `CHAIN_ORDER`.
  - `OpenAccessUnsettledReason.NetworkRefused`; `KeyRefused` admitted for CORE or ELSEVIER; codec as Swift's.
  - Constants `FULLTEXT_SOURCE_ELSEVIER = "elsevier"`, `FULLTEXT_SOURCE_ELSEVIER_LABEL`, and the explanations.
  - Two masked fields in `AdvancedSection` below CORE's, with save buttons and `keySaveStatus`.
  - Update the four ViewModel tests' relaxed mocks if a new `FullTextService` method is called.
- [ ] **Step 3:** run `cd android/MedicalFactChecker && ./gradlew test`, then commit `feat(android): Elsevier's API in the full-text chain, and its key settings (#480)`.

## Task 9: Verification, review and hand-over

- [ ] **Step 1: every suite and gate:**
  - `pytest tests/ -q`;
  - `python .github/scripts/lint_delta.py --base-ref origin/master`;
  - `swift test` in `Packages/BioMedLit` and in `ios/MedicalFactChecker`;
  - `xcodebuild … platform=macOS build`, and the iOS simulator build;
  - `./gradlew test`.
- [ ] **Step 2: dead-proxy run:** `HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 NO_PROXY=127.0.0.1,localhost pytest tests/ -q` gives the same results.
- [ ] **Step 3: Python mutation sweep** in the scratchpad, as C1's Task 10 Step 3: `shutil.copy` backup, a verified restore, no git, a passing baseline, `PYTHONPATH=src`, `PYTHONDONTWRITEBYTECODE=1`. Mutations:

  | Mutation | Must be caught by |
  |---|---|
  | `startswith(ELSEVIER_WARNING_PREFIX)` → `False` | "first page only" |
  | `.lower()` dropped from the warning test | "a warning in any case" |
  | the `AUTHENTICATION_ERROR` test → `True` | "403 AUTHORIZATION_ERROR is unreachable" |
  | `allow_redirects=False` → `True` | the redirect test |
  | the eligibility prefix test → `True` | "a non-Elsevier DOI is never asked" |
  | the credentials digest without the token | "a token added later is asked" |
  | `lookups = lookups.merged(elsevier_lookups)` deleted | "an unreachable Elsevier is told and blocks absence" |
  | `SERVICE_ELSEVIER` moved after `SERVICE_UNPAYWALL` in `_OPEN_ACCESS_CHAIN` | the chain-order test |

- [ ] **Step 4: review** with review agents (silent failures, tests, the key-leak focus). Give any mutation-testing reviewer its own worktree. Fix what they confirm.
- [ ] **Step 5: lodge** what this slice finds but does not fix (no closing keyword; "Refs #480").
- [ ] **Step 6: hand-over and PR.**
  - `HANDOVER.md`: C2 in flight → awaiting the maintainer's probe and on-network acceptance; the follow-ups.
  - Push, then `gh pr create --base master`. The body says "Refs #480", lists the decisions, the apps' not-saved deviation, #493's limit and the mutation table, and ends with the Claude Code line.
  - Afterwards, confirm #480 and #493 are still open.
