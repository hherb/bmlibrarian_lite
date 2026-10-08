# Full Text Through Machine Channels — Stage C1 (CORE) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When nothing earlier in the chain obtained the article, every platform asks CORE, with the user's own key, for the text CORE extracted from a repository copy. A hit for this DOI of at least 5,000 characters becomes the article's full text, labelled "CORE (extracted text)". The key is set in each platform's settings.

**Architecture:**
- **One pure core, pinned by a shared fixture** (`fulltext_parity/core_fulltext.json`):
  - the search URL;
  - choosing the text from a search answer, accepting only a result whose own DOI is this article's;
  - the status table.
- **A typed fetch** per platform (served text / absent / unreachable), like stage A's bucket. A **process-wide throttle** pauses CORE for the session after two consecutive 429s.
- **One place in each chain:**
  - Python: `PDFDiscoverer` asks CORE through a hook at each exit that obtained no PDF and served no copy. The hook is passed in by `FulltextDiscoverer` and reads the CORE cache first. So CORE's failure is in the record before the reader's sentence is built.
  - Swift: `FullTextService.fetchFullText`, after OpenAlex.
  - Kotlin: the service when no open-access candidate exists, otherwise `recordingFullTextFetch` through an `askCore` hook after the walk.
- **A CORE failure is an unsettled lookup** under the new source `core` ("CORE"), last in chain order. A missing key makes no request and records nothing.

**Tech Stack:** Python 3.12 + `requests` + PySide6; Swift 5.9 + BioMedLit (`URLSession`) + SwiftUI + Keychain; Kotlin + OkHttp + kotlinx.serialization + Room + Compose + EncryptedSharedPreferences; pytest, XCTest, JUnit4 + MockWebServer + MockK.

**Spec:** `docs/superpowers/specs/2026-10-04-fulltext-machine-channels-design.md`, sections "Decisions", "Stage C" (CORE half), "How outcomes reach the reader", "Pacing", "Keys and settings". Stage B's plan, `docs/superpowers/plans/2026-10-05-fulltext-machine-channels-stage-b.md`, set the patterns this plan copies. Background: `doc/developer/unpaywall_pdf_survey/spikes/README.md` §1.

## Maintainer decisions (2026-10-06)

1. **Stage C is two PRs:** C1, this plan (CORE plus the key settings), then C2 (Elsevier, reusing the settings plumbing). C1 lands without any Elsevier field.
2. **A configured CORE that could not be asked is an unsettled lookup.** It is told to the reader in the open-access sentence, and "no full text" is not settled while it stands. This is the repo's "unreachable is not absent" rule. Only a missing key is silent and blocks nothing (spec decision 4).
3. **Live CORE and Elsevier keys exist for acceptance.** The maintainer exports them when Task 10 asks; they are not in the environment or `config.json` today.

**Deviation from the spec, recorded here and in the contract:** the spec's decision 4 says a missing key is "recorded in the audit as a lookup not made (`NOT_CONFIGURED`)". It is **not recorded at all** in C1:
- Python's `LookupRecord.anything_unsettled` counts every skip, so a `NOT_CONFIGURED` CORE skip would block every settled absence for users without a key.
- `configuration_nudge` would add "Configuring CORE would add…" to every sentence.
- The apps' `OpenAccessShortfall.Entry` admits a skip only for Unpaywall.

The settings screens say what a key adds instead. A debug log line records the skip.

## Global Constraints

- Python is the reference; Swift and Kotlin mirror it. A behaviour change touches `core_fulltext.json` and all three platforms.
- **Names, verbatim:**
  - Source raw value `core` (apps' `FullTextSource`, `OpenAccessSource`, Android's `FULLTEXT_SOURCE_CORE`).
  - Service name `"CORE"`: Python `SERVICE_CORE`, Swift `BioMedLitConstants.coreServiceName`, Kotlin `Constants.CORE_SERVICE_NAME`.
  - Display label `"CORE (extracted text)"`.
  - Desktop source type `core_text` (`FulltextSourceType.CORE_TEXT`), labelled `"Full Text (CORE, extracted text)"` in the interrogation tab.
- **Request:** `GET {base}/v3/search/works/?q={escape('doi:"' + lucene(doi) + '"')}&limit=3`.
  - `base` is `https://api.core.ac.uk`, its trailing slashes dropped.
  - The trailing slash after `works` is required: without it CORE answers an HTML meta-refresh page.
  - `doi` is trimmed. `lucene(doi)` replaces `\` with `\\` and then `"` with `\"`.
  - `escape` is RFC 3986's unreserved set bare and UTF-8 bytes otherwise (Python's `quote(s, safe="")`, as OpenAlex).
  - Headers: `Authorization: Bearer {key}` and `Accept: application/json`; Python also sends `User-Agent: EUROPEPMC_USER_AGENT`.
- **The key** is the setting trimmed. **Blank means no key:** no request, nothing recorded, no sentence, a DEBUG log line. It travels only in the `Authorization` header. It never appears in a URL, a log line, an exception message, a stored record or an exported config.
- **When CORE is asked:** at most once per article fetch, with a non-blank DOI (after each platform's existing DOI cleaning) and a key. Only when the chain obtained nothing earlier: no JATS body, no PDF downloaded, no copy served but not saved.
  - Python: at each exit of `PDFDiscoverer.discover_and_download` that obtained no PDF and served no copy. These are the no-sources exit, the non-open-access paywall exit, the open-access paywall exit and the final failure. Never after a downloaded PDF (`_pdf_unreadable` included), never after `not_saved`, never under `skip_pdf`, never after a cancel.
  - Swift: after the OpenAlex block, inside the DOI block, when `openAccessNotSavedFrom == nil`.
  - Kotlin: in `fetchFullText` when neither Unpaywall nor OpenAlex named a candidate. Otherwise in `obtainingOpenAccessPdf` through `askCore`, once every candidate (OpenAlex's included) failed, never after a copy served.
- **CORE outcomes** (`status` table):
  - 200 with an answer we can read: **served** or **absent** by the selection rule below.
  - 200 whose body is not UTF-8, not JSON, not an object, or whose `results` is not a list (missing included): **unreachable** `malformed_response`. The HTML redirect page is one of these.
  - Any other status, after retries: **unreachable** `http_status`. A 404 included: a search endpoint's 404 says nothing about the article; an empty result list does.
  - A transport failure: **unreachable**, its kind.
  - 429/500/502/503/504 are retried, 4 attempts in all, each paced.
- **Selection rule** (`full_text` table). Walk `results` in order and serve the first result that:
  - is an object;
  - has a string `doi` whose normalised form equals the requested DOI's;
  - has a string `fullText` that, trimmed, is at least `min_chars` **Unicode code points** long.

  The served text is that trimmed `fullText`. No such result is **absent**.
  - `normalise(doi)`: trim, lower-case, then remove one leading prefix among `https://doi.org/`, `http://doi.org/`, `https://dx.doi.org/`, `http://dx.doi.org/` and `doi:`, then trim again.
  - **Code points, not graphemes or UTF-16 units:**
    - Python: `len(s)`.
    - Swift: `s.unicodeScalars.count`.
    - Kotlin: `s.codePointCount(0, s.length)`.
  - Trimming:
    - Python: `str.strip()`.
    - Swift: `trimmingCharacters(in: .whitespacesAndNewlines)`.
    - Kotlin: `trim()`.

  The fixture uses only ASCII spaces and newlines around text.
- **`CORE_MIN_FULLTEXT_CHARS = 5000`** (Python `CORE_MIN_FULLTEXT_CHARS`, Swift `BioMedLitConstants.coreMinFullTextCharacters`, Kotlin `Constants.CORE_MIN_FULLTEXT_CHARS`).
- **The session throttle:**
  - Two consecutive fetches that **end** in HTTP 429 (after retries) pause CORE for the rest of the process.
  - A paused fetch makes no request and returns **unreachable** `http_status` 429, told as "could not be asked".
  - Any fetch that ends otherwise resets the count; a pause is never lifted.
  - It is shared by every client in the process:
    - Python: module-level, `reset_core_throttle()` for tests.
    - Swift: `CoreThrottle.shared`, injectable.
    - Kotlin: state of the `@Singleton` `CoreService`.
  - The fixture pins `pause_after_consecutive_429: 2`.
- **Pacing:** `api.core.ac.uk` at **0.4 requests per second**.
  - Python: `POLITE_RATE_CEILINGS`.
  - Swift: `coreMinimumInterval = 2.5` s per service instance (as #489 for the others).
  - Kotlin: `RequestPacer(2500)` in the singleton.
- **What a fetch does to the reader:**
  - **Served:** the article's full text.
    - Content kind `extracted`. Python's markdown slot carries the plain text.
    - The open-access question is settled. Swift and Kotlin store no shortfall with it, and Python's success drops the unobtained copies as a downloaded PDF does.
    - It wins over a held abstract.
  - **Absent:** nothing is added.
  - **Unreachable:** a lookup failure under source `core` / `SERVICE_CORE`, and a lookup entry `"CORE ({reason})"`. Chain order puts it last, after `openalex_pdf`. It blocks a settled absence (Python: `anything_unsettled`; the apps always end on a DOI link, since CORE needs a DOI).
- **Desktop cache.** CORE text is cached beside the JATS cache:
  - Path: `generate_core_text_path`, the markdown path with `.md` replaced by `.core.txt`.
  - First line: the stamp `<!-- bmlibrarian-lite core-text v1 -->`.
  - Written atomically through `.partial` + `os.replace`.
  - Read **only at CORE's place in the chain**, by the hook, before asking CORE. `find_existing_fulltext` never returns it, so it can never shadow a JATS text.
- **Apps' storage:**
  - Swift: `fullTextContent` = text, `fullTextContentKindRaw` = `extracted`, `fullTextSource` = `core`, no PDF path. The `.markdown` display path shows it natively, with no WebView.
  - Kotlin: `fullTextMarkdown` = text, `fullTextSource` = `core`. It is **shown as plain text in a Compose `Text`, never through `markdownToBasicHtml`**, which does not escape HTML and feeds a WebView with JavaScript on.
  - No schema change on either app.
- **Keys:**
  - Desktop: `LiteConfig.discovery.core_api_key: Optional[str]`, environment fallback `CORE_API_KEY`. Written by `write_owner_only_file`, redacted as `pubmed.api_key` is, and a "Full Text" tab in the settings dialog.
  - iOS/macOS: Keychain key `core_api_key` via `AppSettings.coreAPIKey`; a field in `SettingsView` (Full Text section) and in `MacSettingsView`'s `PubMedSettingsTab`, the tab that already holds the NCBI key.
  - Android: `EncryptedSharedPreferences` key `core_api_key` via `SettingsRepository.getCoreApiKey()` / `saveCoreApiKey()`; a masked field in `AdvancedSection`.
  - The one-line explanation, verbatim, on every platform: `"Optional. A free CORE API key (core.ac.uk/services/api) lets the app read the text CORE extracted from repository copies when no other source has the article."`
- Docstrings: Google style (Python), `///` (Swift), KDoc (Kotlin). No magic numbers: constants go in `constants.py`, `BioMedLitConstants`, `Constants.kt`. No new dependency. No inline stylesheet in new Qt code; `scaled()` for pixels.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. **No GitHub closing keyword** before #480 or any number that stays open: write "Refs #480".

## Review Focus

1. **A CORE result for a different article is never served.** `q=doi:"…"` is a search, and the spike recorded no DOI check. Covered by fixture `full_text` rows "another article's text" and "the second result is this article's" (Task 1), and a chain test per platform: Python Task 4, Swift Task 6, Kotlin Task 9.
2. **The key never leaks.** It must stay out of the URL, logs, exception text, `to_redacted_dict()`, the CLI's config view and stored shortfalls. Tests: Python Tasks 2–3, Swift Task 6, Kotlin Task 8.
3. **Without a key nothing changes.** No request is made, no lookup recorded, no sentence added, and absence is still established. Existing suites run without a key; explicit controls in Tasks 4, 6, 8 and 9.
4. **CORE's text is untrusted markup.** On Android it never reaches the JavaScript-enabled WebView (Task 9). Swift renders natively; the desktop hands it to its markdown viewer, which runs no script.
5. **The 429 pause is session-wide**, across service instances: Swift builds six, and Python builds a `PDFDiscoverer` per document. A success resets the count. Tests: Python Task 2, Swift Tasks 5–6, Kotlin Task 8.

---

## File Structure

| File | Responsibility |
|---|---|
| `doc/cross_platform/fulltext_parity/core_fulltext.json` (new) | Names, `search_url`, `full_text`, `status`, the throttle and minimum constants |
| `doc/cross_platform/fulltext_parity/open_access_unsettled_notice.json` | Source `core` and its notice and persisted rows |
| `doc/cross_platform/fulltext_retrieval.md` | New section "CORE's Extracted Text (#480, stage C)"; chain list, tables, "Tried sources" order |
| `doc/cross_platform/polite_request_pacing.md` | Row `api.core.ac.uk` 0.4 |
| `src/bmlibrarian_lite/constants.py` | CORE block, `POLITE_RATE_CEILINGS`, `FULLTEXT_SOURCE_PRIORITY`, `ENV_CORE_API_KEY` |
| `src/bmlibrarian_lite/core_api.py` (new) | `core_search_url`, `normalise_doi`, `core_full_text`, `CoreFetch`, `CoreThrottle`, `CoreTextClient`, `default_core_client`, `reset_core_throttle` |
| `src/bmlibrarian_lite/analysis_failures.py` | `SERVICE_CORE` in `_OPEN_ACCESS_CHAIN` |
| `src/bmlibrarian_lite/pdf_discovery.py` | `DiscoveryResult.text`; `core_text` hook in `discover_and_download` |
| `src/bmlibrarian_lite/pdf_utils.py` | `generate_core_text_path`, `save_core_text`, `read_cached_core_text` |
| `src/bmlibrarian_lite/fulltext_discovery.py` | `FulltextSourceType.CORE_TEXT`; `core_api_key`; the hook |
| `src/bmlibrarian_lite/config.py`, `cli.py` | `DiscoveryConfig.core_api_key`, secret handling |
| `src/bmlibrarian_lite/gui/settings_dialog.py` | "Full Text" tab |
| `src/bmlibrarian_lite/gui/workers.py`, `gui/document_interrogation_tab.py`, `mcp_server.py`, `study_transparency_analyzer/study_transparency_analyzer.py`, `transparency/assessment.py` | Thread `core_api_key` |
| `tests/conftest.py` | Autouse `_no_live_core` guard and throttle reset |
| `tests/test_core_api.py`, `tests/test_core_discovery.py`, `tests/test_core_config.py` (new) | Python tests |
| `Packages/BioMedLit/Sources/BioMedLit/Services/CORE.swift` (new) | `CORE` namespace, `COREFetch`, `CoreThrottle` |
| `Packages/BioMedLit/Sources/BioMedLit/Services/FullTextService.swift` | `coreAPIKey`, `PacedHost.core`, header-capable `pacedAttempt`, `fetchCoreText`, chain step |
| `Packages/BioMedLit/Sources/BioMedLit/Models/FullTextModels.swift` | `FullTextSource.core`, `FullTextContent.core(text:)`, assert |
| `Packages/BioMedLit/Sources/BioMedLit/Models/OpenAccessShortfall.swift` | `OpenAccessSource.core` |
| `Packages/BioMedLit/Sources/BioMedLit/Utilities/Constants.swift`, `Utilities/RetryHelper.swift` | CORE constants, `RetryConfiguration.core` |
| `Packages/BioMedLit/Tests/BioMedLitTests/COREContractTests.swift`, `FullTextServiceCORETests.swift` (new) | Swift package tests |
| `ios/MedicalFactChecker/Sources/Models/FullTextSource.swift`, `Utilities/BioMedLitAdapters.swift`, `Views/Components/FullTextSourceBadge.swift`, `macOS/MacConstants.swift` | `AppFullTextSource.core` |
| `ios/MedicalFactChecker/Sources/Models/AppSettings.swift`, `Views/Settings/SettingsView.swift`, `macOS/Views/Settings/MacSettingsView.swift` | Key storage and fields |
| `ios/MedicalFactChecker/Tests/CoreTextDocumentTests.swift` (new) | App tests |
| `android/.../util/Constants.kt` | CORE block, `FULLTEXT_SOURCE_CORE*` |
| `android/.../data/remote/fulltext/Core.kt` (new) | `object Core`, `CoreFetch`, `CoreService` |
| `android/.../domain/model/OpenAccessShortfall.kt` | `OpenAccessSource.CORE` |
| `android/.../data/remote/fulltext/FullTextService.kt`, `FullTextRecording.kt` | `FullTextResult.CoreText`, chain step, `askCore`, recording |
| `android/.../data/local/entity/DocumentEntity.kt`, `ui/fulltext/*`, `ui/factcheck/FactCheckViewModel.kt`, `ui/report/ReportViewModel.kt` | Source label, plain-text display, hook wiring |
| `android/.../data/repository/SettingsRepository.kt`, `ui/settings/SettingsViewModel.kt`, `ui/settings/SettingsScreen.kt` | Key storage and field |
| `android/.../test/.../fulltext/CoreServiceTest.kt`, `CoreContractTest.kt`, `CoreTestDoubles.kt`, `FullTextServiceCoreTest.kt` (new) | Kotlin tests |

Android paths: `android/MedicalFactChecker/app/src/main/java/com/bmlibrarian/factchecker/…` (`main/`) and `…/app/src/test/java/com/bmlibrarian/factchecker/…` (`test/`).

---
## Task 1: The shared contract

**Files:**
- Create: `doc/cross_platform/fulltext_parity/core_fulltext.json`
- Modify: `doc/cross_platform/fulltext_parity/open_access_unsettled_notice.json`, `doc/cross_platform/fulltext_parity/open_access_statement.json`
- Modify: `doc/cross_platform/fulltext_retrieval.md`, `doc/cross_platform/polite_request_pacing.md`

**Interfaces:**
- Produces: the fixture every later task's contract test reads. Top-level keys, exactly: `schema_version, description, service_name, source, source_label, desktop_source_type, base_url, min_fulltext_chars, pause_after_consecutive_429, search_url, full_text, status, bodies`.
- Produces: source `core` → `"CORE"` in `open_access_unsettled_notice.json` `sources`.

- [ ] **Step 1: Write `core_fulltext.json`**

```json
{
  "schema_version": 1,
  "description": "CORE's extracted text, asked by DOI with the user's own key (#480, stage C). Read by tests/test_core_api.py, Packages/BioMedLit COREContractTests and Android CoreContractTest. The rules are in doc/cross_platform/fulltext_retrieval.md, under \"CORE's Extracted Text\". search_url: the request for a DOI (trimmed; backslash and double quote escaped for CORE's phrase query; the q value percent-encoded as Python's quote(s, safe='')). full_text: the text a parsed search answer serves for a DOI, given min_chars: the first result that is an object, whose string doi normalises to the requested DOI's (trim, lower-case, one resolver or doi: prefix removed, trim) and whose string fullText, trimmed, holds at least min_chars Unicode code points; outcome served (with that trimmed text), absent, or malformed (the answer is not an object, or its results are not a list). status: the outcome of each HTTP status (200 is read by full_text). bodies: 200 answers that cannot be read. Add a row here, not a test on one platform.",
  "service_name": "CORE",
  "source": "core",
  "source_label": "CORE (extracted text)",
  "desktop_source_type": "core_text",
  "base_url": "https://api.core.ac.uk",
  "min_fulltext_chars": 5000,
  "pause_after_consecutive_429": 2,
  "search_url": [
    {"name": "a DOI is one phrase, its slash escaped", "doi": "10.1016/j.cis.2021.102529", "base_url": null,
     "url": "https://api.core.ac.uk/v3/search/works/?q=doi%3A%2210.1016%2Fj.cis.2021.102529%22&limit=3"},
    {"name": "a padded DOI is asked trimmed", "doi": "  10.1159/000513404\n", "base_url": null,
     "url": "https://api.core.ac.uk/v3/search/works/?q=doi%3A%2210.1159%2F000513404%22&limit=3"},
    {"name": "a SICI DOI keeps every character, escaped", "doi": "10.1002/(SICI)1097-4636(199706)35:4<513::AID-JBM12>3.0.CO;2-G", "base_url": null,
     "url": "https://api.core.ac.uk/v3/search/works/?q=doi%3A%2210.1002%2F%28SICI%291097-4636%28199706%2935%3A4%3C513%3A%3AAID-JBM12%3E3.0.CO%3B2-G%22&limit=3"},
    {"name": "a double quote cannot end the phrase", "doi": "10.1000/a\"b", "base_url": null,
     "url": "https://api.core.ac.uk/v3/search/works/?q=doi%3A%2210.1000%2Fa%5C%22b%22&limit=3"},
    {"name": "a backslash is escaped before the quote", "doi": "10.1000/a\\b", "base_url": null,
     "url": "https://api.core.ac.uk/v3/search/works/?q=doi%3A%2210.1000%2Fa%5C%5Cb%22&limit=3"},
    {"name": "a non-ASCII DOI is sent as UTF-8 bytes", "doi": "10.1000/é", "base_url": null,
     "url": "https://api.core.ac.uk/v3/search/works/?q=doi%3A%2210.1000%2F%C3%A9%22&limit=3"},
    {"name": "a base URL's trailing slash is dropped", "doi": "10.1159/000513404", "base_url": "https://api.core.ac.uk/",
     "url": "https://api.core.ac.uk/v3/search/works/?q=doi%3A%2210.1159%2F000513404%22&limit=3"}
  ],
  "full_text": [
    {"name": "a hit for this DOI serves its text", "doi": "10.1159/000513404", "min_chars": 10,
     "answer": {"totalHits": 1, "results": [{"doi": "10.1159/000513404", "fullText": "Introduction. Methods."}]},
     "outcome": "served", "text": "Introduction. Methods."},
    {"name": "another article's text is never served", "doi": "10.1159/000513404", "min_chars": 10,
     "answer": {"totalHits": 1, "results": [{"doi": "10.1159/999999", "fullText": "Someone else's article, long enough."}]},
     "outcome": "absent", "text": null},
    {"name": "the second result is this article's", "doi": "10.1159/000513404", "min_chars": 10,
     "answer": {"results": [{"doi": "10.1/other", "fullText": "Not this one at all."}, {"doi": "10.1159/000513404", "fullText": "This article's text."}]},
     "outcome": "served", "text": "This article's text."},
    {"name": "a DOI matches without case or resolver prefix", "doi": "10.1016/J.CIS.2021.102529", "min_chars": 10,
     "answer": {"results": [{"doi": "https://doi.org/10.1016/j.cis.2021.102529", "fullText": "Matched text here."}]},
     "outcome": "served", "text": "Matched text here."},
    {"name": "a doi: prefix on the result matches", "doi": "10.1016/j.cis.2021.102529", "min_chars": 10,
     "answer": {"results": [{"doi": "doi:10.1016/j.cis.2021.102529", "fullText": "Matched text here."}]},
     "outcome": "served", "text": "Matched text here."},
    {"name": "a requested DOI given as a resolver URL matches", "doi": "https://dx.doi.org/10.1159/000513404", "min_chars": 10,
     "answer": {"results": [{"doi": "10.1159/000513404", "fullText": "Matched text here."}]},
     "outcome": "served", "text": "Matched text here."},
    {"name": "only one prefix is removed", "doi": "10.1159/000513404", "min_chars": 10,
     "answer": {"results": [{"doi": "doi:doi:10.1159/000513404", "fullText": "Matched text here."}]},
     "outcome": "absent", "text": null},
    {"name": "a hit without text adds nothing", "doi": "10.1159/000513404", "min_chars": 10,
     "answer": {"results": [{"doi": "10.1159/000513404", "fullText": null}]},
     "outcome": "absent", "text": null},
    {"name": "a text that is not a string adds nothing", "doi": "10.1159/000513404", "min_chars": 1,
     "answer": {"results": [{"doi": "10.1159/000513404", "fullText": 42}]},
     "outcome": "absent", "text": null},
    {"name": "a text below the minimum is no full text", "doi": "10.1159/000513404", "min_chars": 30,
     "answer": {"results": [{"doi": "10.1159/000513404", "fullText": "An abstract, no more."}]},
     "outcome": "absent", "text": null},
    {"name": "a text exactly at the minimum is served", "doi": "10.1159/000513404", "min_chars": 10,
     "answer": {"results": [{"doi": "10.1159/000513404", "fullText": "abcdefghij"}]},
     "outcome": "served", "text": "abcdefghij"},
    {"name": "a text is measured and served trimmed", "doi": "10.1159/000513404", "min_chars": 10,
     "answer": {"results": [{"doi": "10.1159/000513404", "fullText": "  abcdefghij\n"}]},
     "outcome": "served", "text": "abcdefghij"},
    {"name": "padding does not count towards the minimum", "doi": "10.1159/000513404", "min_chars": 11,
     "answer": {"results": [{"doi": "10.1159/000513404", "fullText": "  abcdefghij\n"}]},
     "outcome": "absent", "text": null},
    {"name": "code points are counted, not the characters a reader sees", "doi": "10.1159/000513404", "min_chars": 10,
     "answer": {"results": [{"doi": "10.1159/000513404", "fullText": "ééééé"}]},
     "outcome": "served", "text": "ééééé"},
    {"name": "code points are counted, not UTF-16 units", "doi": "10.1159/000513404", "min_chars": 11,
     "answer": {"results": [{"doi": "10.1159/000513404", "fullText": "😀😀😀😀😀😀😀😀😀😀"}]},
     "outcome": "absent", "text": null},
    {"name": "ten astral code points meet a minimum of ten", "doi": "10.1159/000513404", "min_chars": 10,
     "answer": {"results": [{"doi": "10.1159/000513404", "fullText": "😀😀😀😀😀😀😀😀😀😀"}]},
     "outcome": "served", "text": "😀😀😀😀😀😀😀😀😀😀"},
    {"name": "an empty result list is an absence", "doi": "10.1159/000513404", "min_chars": 10,
     "answer": {"totalHits": 0, "results": []},
     "outcome": "absent", "text": null},
    {"name": "a result that is not an object is skipped", "doi": "10.1159/000513404", "min_chars": 10,
     "answer": {"results": ["x", null, 3, {"doi": "10.1159/000513404", "fullText": "This article's text."}]},
     "outcome": "served", "text": "This article's text."},
    {"name": "a result without a DOI is never served", "doi": "10.1159/000513404", "min_chars": 10,
     "answer": {"results": [{"doi": null, "fullText": "Whose text is this?"}]},
     "outcome": "absent", "text": null},
    {"name": "a DOI that is not a string is never matched", "doi": "10.1159/000513404", "min_chars": 10,
     "answer": {"results": [{"doi": 10.1159, "fullText": "Whose text is this?"}]},
     "outcome": "absent", "text": null},
    {"name": "an answer without results cannot be read", "doi": "10.1159/000513404", "min_chars": 10,
     "answer": {"totalHits": 0},
     "outcome": "malformed", "text": null},
    {"name": "results that are null cannot be read", "doi": "10.1159/000513404", "min_chars": 10,
     "answer": {"results": null},
     "outcome": "malformed", "text": null},
    {"name": "results that are not a list cannot be read", "doi": "10.1159/000513404", "min_chars": 10,
     "answer": {"results": {}},
     "outcome": "malformed", "text": null},
    {"name": "an answer that is not an object cannot be read", "doi": "10.1159/000513404", "min_chars": 10,
     "answer": [],
     "outcome": "malformed", "text": null}
  ],
  "status": [
    {"status": 200, "outcome": "served"},
    {"status": 400, "outcome": "unreachable"},
    {"status": 401, "outcome": "unreachable"},
    {"status": 403, "outcome": "unreachable"},
    {"status": 404, "outcome": "unreachable"},
    {"status": 410, "outcome": "unreachable"},
    {"status": 429, "outcome": "unreachable"},
    {"status": 500, "outcome": "unreachable"},
    {"status": 503, "outcome": "unreachable"}
  ],
  "bodies": [
    {"name": "the HTML page CORE sends without the trailing slash",
     "body": "<html><head><meta http-equiv=\"refresh\" content=\"0;url=https://api.core.ac.uk/v3/search/works/\"></head><body></body></html>",
     "failure": "malformed_response"},
    {"name": "an empty body", "body": "", "failure": "malformed_response"},
    {"name": "a JSON array", "body": "[]", "failure": "malformed_response"},
    {"name": "an object without results", "body": "{\"totalHits\": 0}", "failure": "malformed_response"}
  ]
}
```

The status table's 200 row means "read by `full_text`". The client tests serve a hit answer for it.

- [ ] **Step 2: Add CORE to the notice contract**

In `open_access_unsettled_notice.json`:
- `sources`: add `"core": "CORE"`.
- `description`: change "…OpenAlex, or the PDF OpenAlex named (#480 stage B)" to "…OpenAlex, the PDF OpenAlex named (#480 stage B), or CORE (#480 stage C)".
- `notices`: append these three rows:

```json
{"source": "core", "kind": "timeout", "status_code": null,
 "notice": "CORE (the request timed out) could not be asked, so a freely available copy may exist. Whether this document is open access was not established."},
{"source": "core", "kind": "http_status", "status_code": 429,
 "notice": "CORE (HTTP 429 Too Many Requests) could not be asked, so a freely available copy may exist. Whether this document is open access was not established."},
{"source": "core", "kind": "http_status", "status_code": 401,
 "notice": "CORE (HTTP 401 Unauthorized) did not serve it, so whether this document is open access was not established."}
```

- `persisted.written`: append `{"source": "core", "kind": "http_status", "status_code": 503, "stored": {"schema_version": 1, "source": "core", "failure": {"kind": "http_status", "status_code": 503}}}`.
- `persisted.read`: append `{"name": "CORE's lookup", "stored": "{\"schema_version\":1,\"source\":\"core\",\"failure\":{\"kind\":\"timeout\",\"status_code\":null}}", "source": "core", "kind": "timeout", "status_code": null}`.

In `open_access_statement.json`, append to `statements`. Its order pins CORE last in chain order:

```json
{
  "name": "CORE is told after every PDF",
  "entries": [
    {"source": "core", "kind": "http_status", "status_code": 503},
    {"source": "unpaywall_pdf", "kind": "http_status", "status_code": 403, "address": "https://www.sciencedirect.com/x.pdf"}
  ],
  "statement": "Failed to obtain a PDF from the following tried sources: www.sciencedirect.com, named by Unpaywall (HTTP 403 Forbidden); CORE (HTTP 503 Service Unavailable). A freely available copy may exist. Whether this document is open access was not established."
}
```

- [ ] **Step 3: Validate the JSON**

Run: `python -c "import json,sys; [json.load(open(f'doc/cross_platform/fulltext_parity/{n}.json')) for n in ('core_fulltext','open_access_unsettled_notice','open_access_statement')]; print('ok')"`
Expected: `ok`

- [ ] **Step 4: Write the contract section**

In `doc/cross_platform/fulltext_retrieval.md`, add after "## OpenAlex's Locations (#480)" and before "## DOI Resolution":

````markdown
## CORE's Extracted Text (#480, stage C)

CORE aggregates open-access repositories and serves the text it extracted
from their copies. Its v3 search is asked by DOI with **the user's own key**,
last in the chain: only when nothing earlier obtained the article (no JATS
body, no PDF downloaded, no copy served but not saved), at most once per
fetch, and never without a DOI. Service name **"CORE"**, source `core`
(desktop `core_text`), shown as **"CORE (extracted text)"**. Pinned by
`fulltext_parity/core_fulltext.json`.

```pseudocode
GET https://api.core.ac.uk/v3/search/works/?q={escape('doi:"' + lucene(trim(doi)) + '"')}&limit=3
    Authorization: Bearer {key}        # the key travels here and nowhere else
# lucene: \ → \\, then " → \"; escape: as OpenAlex's. The slash after works is
# required: without it CORE answers an HTML meta-refresh page.

no key            → no request, nothing recorded, nothing told (a debug log line)
paused (below)    → UNREACHABLE(http_status 429), no request
200               → the first result that is an object, whose string doi
                    normalises to this DOI's, and whose string fullText,
                    trimmed, holds ≥ 5,000 code points: SERVED(that text);
                    none → ABSENT; an answer that is not an object, or whose
                    results are not a list → UNREACHABLE(malformed_response)
any other status (after 429/5xx retries), transport failure → UNREACHABLE(failure)
```

`normalise(doi)` trims, lower-cases, removes one leading `https://doi.org/`,
`http://doi.org/`, `https://dx.doi.org/`, `http://dx.doi.org/` or `doi:`, and
trims again. **The DOI check is what keeps another article's text out**: the
request is a search, and its results are not guaranteed to be this article.

- **Served** text is the article's full text, content kind `extracted`. It
  settles the open-access question, as a copy obtained does: no shortfall is
  stored with it, and it wins over a held abstract. It has no sections, so
  statement checks read "not assessed" (#428's "no marker, no charge"), as
  for a PDF's text.
- **Unreachable** is an unsettled lookup under **CORE** (`core`), told in the
  open-access sentence ("CORE (HTTP 503 Service Unavailable) could not be
  asked, …") and last in "Tried sources" order. It blocks a settled absence
  (the maintainer's decision of 2026-10-06), as any unanswered source does.
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
  reads the cached CORE text (`*.core.txt`, stamp `core-text v1`, never
  returned by `find_existing_fulltext`) before asking. Swift asks in
  `FullTextService` after OpenAlex, unless a copy was served and not cached.
  Android asks in `fetchFullText` when no open-access candidate exists, and
  otherwise in recording, through its `askCore` hook, once every candidate
  failed. Android shows the text as plain text, never through its
  JavaScript-enabled WebView.
````

Also in the same file:
- Add row `| CORE | Plain text | Fair (no structure) | text CORE extracted from repository copies, by DOI, with a key |` to the "Retrieval Priority" table, before "DOI Resolution".
- Change the Overview list item 3 to: `3. **Europe PMC's PDF render, then every Unpaywall PDF, then OpenAlex's, then CORE's extracted text** - Open access copies`.
- In "Tried sources (#480)", change the order line to read: "`unpaywall`, `unpaywall_landing_page`, `unpaywall_pdf`, `openalex`, `openalex_pdf`, `core` (stable)".

In `polite_request_pacing.md`, add the table row after the bucket's:

```markdown
| `api.core.ac.uk` | 0.4 (CORE's personal key allows 25 a minute, and a search can cost more than one token; #480) |
```

- [ ] **Step 5: Commit**

```bash
git add doc/cross_platform/fulltext_parity doc/cross_platform/fulltext_retrieval.md doc/cross_platform/polite_request_pacing.md
git commit -m "docs(fulltext): CORE's extracted text contract and fixtures (#480)

Refs #480.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Task 2: Python CORE client

**Files:**
- Create: `src/bmlibrarian_lite/core_api.py`
- Modify: `src/bmlibrarian_lite/constants.py`
- Modify: `src/bmlibrarian_lite/openalex.py`, `src/bmlibrarian_lite/pmc_open_data.py` (their `_HTTP_OK = 200` becomes `HTTP_OK`, a #492 item)
- Test: `tests/test_core_api.py`

**Interfaces:**
- Consumes: `core_fulltext.json` (Task 1).
- Produces:
  - `core_search_url(doi: str, base_url: str = CORE_API_BASE_URL) -> str`
  - `normalise_doi(doi: str) -> str`
  - `core_full_text(answer: object, doi: str, min_chars: int = CORE_MIN_FULLTEXT_CHARS) -> str | None`, which raises `ValueError` for an unreadable answer.
  - `CoreFetch`: frozen dataclass with `text: str | None`, `failure: RequestFailure | None`, classmethods `served(text)`, `absent()`, `unreachable(failure)`, property `is_unreachable`.
  - `CoreThrottle`: `paused` property and `record(status: int | None)`.
  - `session_core_throttle() -> CoreThrottle` and `reset_core_throttle() -> None`.
  - `CoreTextClient(api_key: str, base_url=CORE_API_BASE_URL, max_retries=CORE_MAX_RETRIES, throttle: CoreThrottle | None = None)`, whose `.fetch_full_text(doi: str) -> CoreFetch`.
  - `default_core_client(api_key: str | None) -> CoreTextClient | None`, which falls back to the `CORE_API_KEY` environment variable and returns `None` without a key.

- [ ] **Step 1: Add the constants**

In `constants.py`:
- Add `HTTP_OK = 200` beside `HTTP_NOT_FOUND`.
- Add to `POLITE_RATE_CEILINGS`, after the bucket's entry:

```python
    # CORE (#480, stage C): a personal key allows 25 requests a minute, and
    # the spike met 429s at that rate, so a search evidently costs more than
    # one token. Paced well under it.
    "api.core.ac.uk": 0.4,
```

Add after the OpenAlex block (after `OPENALEX_ENCODING`):

```python
# CORE's search of the text it extracted from repository copies, asked by
# DOI with the user's own key, last in the chain (#480, stage C). Named as
# the reader knows it.
SERVICE_CORE = "CORE"
CORE_HOST = "api.core.ac.uk"
CORE_API_BASE_URL = f"https://{CORE_HOST}"
# The slash after "works" matters: without it CORE answers an HTML page.
CORE_SEARCH_PATH = "/v3/search/works/"
# Results asked for: the DOI query can match more than one record.
CORE_SEARCH_LIMIT = 3
# Below this, a "full text" is an abstract or a cover page (the #480 spike's
# threshold), counted in Unicode code points.
CORE_MIN_FULLTEXT_CHARS = 5000
# Consecutive fetches ending in HTTP 429 after which CORE is not asked again
# this session: its key buys a daily budget, which no pacing can express.
CORE_PAUSE_AFTER_CONSECUTIVE_429 = 2
CORE_REQUEST_TIMEOUT_SECONDS = 30
CORE_MAX_RETRIES = 3
CORE_BACKOFF_FACTOR = 1
# CORE serves JSON, which is UTF-8 (RFC 8259).
CORE_ENCODING = "utf-8"
# The environment variable a CORE key may be given in, as NCBI_API_KEY is.
ENV_CORE_API_KEY = "CORE_API_KEY"
# How the desktop labels CORE's text, and the line opening its cache file.
CORE_SOURCE_LABEL = "CORE (extracted text)"
CORE_TEXT_CACHE_STAMP = "<!-- bmlibrarian-lite core-text v1 -->"
CORE_TEXT_CACHE_SUFFIX = ".core.txt"
```

Add `"core_text": 60,` to `FULLTEXT_SOURCE_PRIORITY`, after `"downloaded_pdf": 70,` (comment `# CORE's extracted text (no structure)`).

In `openalex.py` and `pmc_open_data.py`, delete `_HTTP_OK = 200`, import `HTTP_OK` from `.constants`, and replace each `_HTTP_OK` with `HTTP_OK`. Also replace `backoff_factor=1` there with `backoff_factor=CORE_BACKOFF_FACTOR`? **No:** leave their backoff literal. It is OpenAlex's own, and #492 tracks it.

- [ ] **Step 2: Write the failing tests**

Create `tests/test_core_api.py`:

```python
"""CORE's extracted text: the shared contract and the client (#480, stage C)."""

from __future__ import annotations

import json
import logging
from pathlib import Path
from typing import Any

import pytest

from bmlibrarian_lite.constants import (
    CORE_API_BASE_URL,
    CORE_HOST,
    CORE_MIN_FULLTEXT_CHARS,
    CORE_PAUSE_AFTER_CONSECUTIVE_429,
    CORE_SOURCE_LABEL,
    POLITE_RATE_CEILINGS,
    SERVICE_CORE,
)
from bmlibrarian_lite.core_api import (
    CoreFetch,
    CoreTextClient,
    CoreThrottle,
    core_full_text,
    core_search_url,
    default_core_client,
)
from bmlibrarian_lite.data_models import RequestFailure, RequestFailureKind

from .scripted_http_server import json_answer, running, status_answer

CONTRACT: dict[str, Any] = json.loads(
    (
        Path(__file__).resolve().parents[1]
        / "doc" / "cross_platform" / "fulltext_parity" / "core_fulltext.json"
    ).read_text(encoding="utf-8")
)

#: A key no test ever sends anywhere real.
KEY = "test-core-key-0123456789"

#: A hit long enough to be served, for the article the tests ask about.
DOI = "10.1159/000513404"
HIT = {"results": [{"doi": DOI, "fullText": "x" * CORE_MIN_FULLTEXT_CHARS}]}


def test_every_contract_table_is_read_here() -> None:
    """A table added to the contract must be read by a test here."""
    assert set(CONTRACT) == {
        "schema_version", "description", "service_name", "source",
        "source_label", "desktop_source_type", "base_url",
        "min_fulltext_chars", "pause_after_consecutive_429", "search_url",
        "full_text", "status", "bodies",
    }


def test_the_names_are_the_contracts() -> None:
    """Names and numbers are the contract's, not this platform's own."""
    assert CONTRACT["service_name"] == SERVICE_CORE
    assert CONTRACT["source_label"] == CORE_SOURCE_LABEL
    assert CONTRACT["base_url"] == CORE_API_BASE_URL
    assert CONTRACT["min_fulltext_chars"] == CORE_MIN_FULLTEXT_CHARS
    assert CONTRACT["pause_after_consecutive_429"] == CORE_PAUSE_AFTER_CONSECUTIVE_429


def test_the_contract_has_rows() -> None:
    """An emptied table would pass every parametrised test below."""
    assert len(CONTRACT["search_url"]) >= 7
    assert len(CONTRACT["full_text"]) >= 24
    assert len(CONTRACT["status"]) >= 9
    assert len(CONTRACT["bodies"]) >= 4


def test_core_is_paced_under_its_key_limit() -> None:
    """0.4 requests a second: under the personal key's 25 a minute."""
    assert POLITE_RATE_CEILINGS[CORE_HOST] == 0.4


@pytest.mark.parametrize("row", CONTRACT["search_url"], ids=lambda row: row["name"])
def test_each_search_url(row: dict[str, Any]) -> None:
    """The request for a DOI is the contract's, byte for byte."""
    base = row["base_url"] or CORE_API_BASE_URL
    assert core_search_url(row["doi"], base) == row["url"]


@pytest.mark.parametrize("row", CONTRACT["full_text"], ids=lambda row: row["name"])
def test_each_full_text_row(row: dict[str, Any]) -> None:
    """The text an answer serves for a DOI is the contract's."""
    if row["outcome"] == "malformed":
        with pytest.raises(ValueError):
            core_full_text(row["answer"], row["doi"], row["min_chars"])
        return
    assert core_full_text(row["answer"], row["doi"], row["min_chars"]) == row["text"]


def test_a_fetch_is_served_or_unreachable_never_both() -> None:
    """The typed fetch refuses an impossible pair, and a blank text."""
    with pytest.raises(ValueError):
        CoreFetch(text="t", failure=RequestFailure(RequestFailureKind.TIMEOUT))
    with pytest.raises(ValueError):
        CoreFetch.served("   ")


def _client(base_url: str, throttle: CoreThrottle | None = None) -> CoreTextClient:
    return CoreTextClient(
        KEY, base_url=base_url, max_retries=0, throttle=throttle or CoreThrottle()
    )


@pytest.mark.parametrize("row", CONTRACT["status"], ids=lambda row: str(row["status"]))
def test_the_contracts_statuses(row: dict[str, Any]) -> None:
    """Every status gets the contract's outcome; 404 is no absence here."""
    answer = json_answer(HIT) if row["status"] == 200 else status_answer(row["status"])
    with running([answer]) as server:
        fetch = _client(server.base_url).fetch_full_text(DOI)
    if row["outcome"] == "served":
        assert fetch.text == "x" * CORE_MIN_FULLTEXT_CHARS
    else:
        assert fetch.failure == RequestFailure(RequestFailureKind.HTTP_STATUS, row["status"])


@pytest.mark.parametrize("row", CONTRACT["bodies"], ids=lambda row: row["name"])
def test_an_answer_we_cannot_read_is_malformed(row: dict[str, Any]) -> None:
    """The HTML redirect page and its kin are unreadable, never an absence."""
    with running([status_answer(200, body=row["body"].encode("utf-8"))]) as server:
        fetch = _client(server.base_url).fetch_full_text(DOI)
    assert fetch.failure == RequestFailure(RequestFailureKind.MALFORMED_RESPONSE)


def test_a_body_that_is_not_utf8_is_malformed() -> None:
    """Strict UTF-8, as every JSON source."""
    with running([status_answer(200, body=b'{"results": ["\xff"]}')]) as server:
        fetch = _client(server.base_url).fetch_full_text(DOI)
    assert fetch.failure == RequestFailure(RequestFailureKind.MALFORMED_RESPONSE)


def test_the_key_travels_in_the_header_alone(caplog: pytest.LogCaptureFixture) -> None:
    """Bearer header, never the URL or a log line."""
    caplog.set_level(logging.DEBUG)
    with running([json_answer(HIT)]) as server:
        _client(server.base_url).fetch_full_text(DOI)
        request = server.requests[0]
    assert request.headers["Authorization"] == f"Bearer {KEY}"
    assert request.headers["Accept"] == "application/json"
    assert KEY not in request.path
    assert KEY not in caplog.text
    assert KEY not in repr(_client(server.base_url))


def test_a_blank_doi_is_never_asked() -> None:
    """No DOI, no search: an absence for this source, nothing sent."""
    with running([]) as server:
        assert _client(server.base_url).fetch_full_text("  ") == CoreFetch.absent()
        assert server.requests == []


def test_no_server_is_unreachable() -> None:
    """A refused connection is a lookup that failed, by its kind."""
    fetch = _client("http://127.0.0.1:9").fetch_full_text(DOI)
    assert fetch.is_unreachable
    assert fetch.failure is not None
    assert fetch.failure.kind is RequestFailureKind.CONNECTION


def test_two_429s_in_a_row_pause_core_for_the_session() -> None:
    """The third fetch sends nothing and is told as a 429."""
    throttle = CoreThrottle()
    with running([status_answer(429), status_answer(429)]) as server:
        client = _client(server.base_url, throttle)
        client.fetch_full_text(DOI)
        client.fetch_full_text(DOI)
        third = client.fetch_full_text(DOI)
        assert len(server.requests) == 2
    assert third.failure == RequestFailure(RequestFailureKind.HTTP_STATUS, 429)
    assert throttle.paused


def test_another_answer_between_429s_resets_the_count() -> None:
    """Control: 429, 200, 429 does not pause."""
    throttle = CoreThrottle()
    with running([status_answer(429), json_answer(HIT), status_answer(429)]) as server:
        client = _client(server.base_url, throttle)
        for _ in range(3):
            client.fetch_full_text(DOI)
    assert not throttle.paused


def test_the_pause_is_shared_by_every_client() -> None:
    """A second client built later sees the session's pause."""
    throttle = CoreThrottle()
    with running([status_answer(429), status_answer(429)]) as server:
        _client(server.base_url, throttle).fetch_full_text(DOI)
        _client(server.base_url, throttle).fetch_full_text(DOI)
        assert _client(server.base_url, throttle).fetch_full_text(DOI).failure == (
            RequestFailure(RequestFailureKind.HTTP_STATUS, 429)
        )
        assert len(server.requests) == 2


def test_no_key_means_no_client(monkeypatch: pytest.MonkeyPatch) -> None:
    """Blank and missing keys build nothing; the environment is a fallback."""
    monkeypatch.delenv("CORE_API_KEY", raising=False)
    assert default_core_client(None) is None
    assert default_core_client("   ") is None
    monkeypatch.setenv("CORE_API_KEY", KEY)
    assert isinstance(default_core_client(None), CoreTextClient)


def test_a_client_refuses_a_blank_key() -> None:
    """A client exists only to send a key."""
    with pytest.raises(ValueError):
        CoreTextClient("  ")
```

Before running, check `tests/scripted_http_server.py` for `status_answer`'s exact keyword (`body=`) and whether `server.requests` items expose `headers` and `path`. If they do not, extend the helper minimally: record `self.path` and `dict(self.headers)` per request in the handler. Do not change its existing users.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `pytest tests/test_core_api.py -q`
Expected: FAIL with `ModuleNotFoundError: No module named 'bmlibrarian_lite.core_api'`.

- [ ] **Step 4: Write `core_api.py`**

```python
"""CORE's extracted text, asked by DOI with the user's own key (#480, stage C).

CORE aggregates open-access repositories and serves the text it extracted
from their copies. It is the poorest full-text form the chain reads, so it
is asked last, only when nothing earlier obtained the article. The rules are
in doc/cross_platform/fulltext_retrieval.md, "CORE's Extracted Text", pinned
by doc/cross_platform/fulltext_parity/core_fulltext.json.

The key travels in the ``Authorization`` header and nowhere else: never in a
URL, a log line or a ``repr``.
"""

from __future__ import annotations

import json
import logging
import os
import threading
from collections.abc import Mapping
from dataclasses import dataclass
from urllib.parse import quote

import requests
from urllib3.util.retry import Retry

from .constants import (
    CORE_API_BASE_URL,
    CORE_BACKOFF_FACTOR,
    CORE_ENCODING,
    CORE_MAX_RETRIES,
    CORE_MIN_FULLTEXT_CHARS,
    CORE_PAUSE_AFTER_CONSECUTIVE_429,
    CORE_REQUEST_TIMEOUT_SECONDS,
    CORE_SEARCH_LIMIT,
    CORE_SEARCH_PATH,
    ENV_CORE_API_KEY,
    EUROPEPMC_USER_AGENT,
    HTTP_OK,
    HTTP_TOO_MANY_REQUESTS,
    RETRYABLE_HTTP_STATUSES,
)
from .data_models import RequestFailure, RequestFailureKind
from .polite_session import mount_politely
from .search_failures import request_failure_from_exception

logger = logging.getLogger(__name__)

#: Ways a DOI is written that name the same DOI; one is removed.
_DOI_PREFIXES = (
    "https://doi.org/",
    "http://doi.org/",
    "https://dx.doi.org/",
    "http://dx.doi.org/",
    "doi:",
)


def core_search_url(doi: str, base_url: str = CORE_API_BASE_URL) -> str:
    """CORE's search for one DOI, as a phrase query.

    Args:
        doi: The DOI; trimmed here.
        base_url: CORE's API root; trailing slashes are dropped.

    Returns:
        The request URL, pinned by the contract's ``search_url`` rows.
    """
    phrase = doi.strip().replace("\\", "\\\\").replace('"', '\\"')
    query = quote(f'doi:"{phrase}"', safe="")
    return (
        f"{base_url.rstrip('/')}{CORE_SEARCH_PATH}"
        f"?q={query}&limit={CORE_SEARCH_LIMIT}"
    )


def normalise_doi(doi: str) -> str:
    """A DOI as compared: trimmed, lower-cased, one resolver prefix removed.

    Args:
        doi: A DOI as a source wrote it.

    Returns:
        The comparable form; empty for a DOI that cleans to nothing.
    """
    text = doi.strip().lower()
    for prefix in _DOI_PREFIXES:
        if text.startswith(prefix):
            text = text[len(prefix):]
            break
    return text.strip()


def core_full_text(
    answer: object, doi: str, min_chars: int = CORE_MIN_FULLTEXT_CHARS
) -> str | None:
    """The full text a CORE search answer serves for this DOI.

    Only a result whose own DOI is this article's counts: the request is a
    search, and serving another article's text as this one's would be worse
    than serving none.

    Args:
        answer: The parsed JSON answer.
        doi: The DOI asked about.
        min_chars: The fewest code points a full text holds, trimmed.

    Returns:
        The first matching result's ``fullText``, trimmed; ``None`` when no
        result is this article's full text.

    Raises:
        ValueError: If the answer is not an object, or its ``results`` is
            not a list: an answer we cannot read is not an absence.
    """
    if not isinstance(answer, Mapping):
        raise ValueError("CORE's answer is not an object")
    results = answer.get("results")
    if not isinstance(results, list):
        raise ValueError("CORE's answer holds no list of results")
    wanted = normalise_doi(doi)
    if not wanted:
        return None
    for result in results:
        if not isinstance(result, Mapping):
            continue
        result_doi = result.get("doi")
        if not isinstance(result_doi, str) or normalise_doi(result_doi) != wanted:
            continue
        text = result.get("fullText")
        if not isinstance(text, str):
            continue
        text = text.strip()
        if len(text) >= min_chars:
            return text
    return None


@dataclass(frozen=True)
class CoreFetch:
    """What asking CORE for one DOI learned: served, absent or unreachable.

    Attributes:
        text: The article's text, when served.
        failure: Why CORE could not be asked, when unreachable.
    """

    text: str | None
    failure: RequestFailure | None

    def __post_init__(self) -> None:
        """Refuse a fetch both served and unreachable, or a blank text."""
        if self.text is not None and self.failure is not None:
            raise ValueError("A CORE fetch is served or unreachable, never both")
        if self.text is not None and not self.text.strip():
            raise ValueError("A blank text is not CORE's full text")

    @classmethod
    def served(cls, text: str) -> CoreFetch:
        """CORE holds this article's text."""
        return cls(text=text, failure=None)

    @classmethod
    def absent(cls) -> CoreFetch:
        """CORE answered, and holds no full text of this article."""
        return cls(text=None, failure=None)

    @classmethod
    def unreachable(cls, failure: RequestFailure) -> CoreFetch:
        """CORE could not be asked, or its answer could not be read."""
        return cls(text=None, failure=failure)

    @property
    def is_unreachable(self) -> bool:
        """Whether the lookup failed."""
        return self.failure is not None


class CoreThrottle:
    """CORE's session pause after consecutive 429s.

    CORE's key buys a daily token budget, which no per-second pacing can
    express. Once two fetches in a row end in 429, asking again only spends
    the reader's time, so CORE is not asked again until the process ends.
    """

    def __init__(self, pause_after: int = CORE_PAUSE_AFTER_CONSECUTIVE_429) -> None:
        """Start unpaused.

        Args:
            pause_after: Consecutive 429 endings that pause CORE.
        """
        self._pause_after = pause_after
        self._consecutive = 0
        self._paused = False
        self._lock = threading.Lock()

    @property
    def paused(self) -> bool:
        """Whether CORE is paused for the rest of the session."""
        with self._lock:
            return self._paused

    def record(self, status: int | None) -> None:
        """Note how one fetch ended.

        Args:
            status: The HTTP status it ended on, or ``None`` when it got none.
        """
        with self._lock:
            if status != HTTP_TOO_MANY_REQUESTS:
                self._consecutive = 0
                return
            self._consecutive += 1
            if self._consecutive >= self._pause_after and not self._paused:
                self._paused = True
                logger.warning(
                    "CORE answered HTTP 429 %d times in a row; it is not asked "
                    "again this session.",
                    self._consecutive,
                )


_session_throttle = CoreThrottle()


def session_core_throttle() -> CoreThrottle:
    """The pause every CORE client in this process shares."""
    return _session_throttle


def reset_core_throttle() -> None:
    """Forget the session's pause. For tests, as ``reset_limiters`` is."""
    global _session_throttle
    _session_throttle = CoreThrottle()


class CoreTextClient:
    """Asks CORE's search for one DOI's extracted text."""

    def __init__(
        self,
        api_key: str,
        base_url: str = CORE_API_BASE_URL,
        max_retries: int = CORE_MAX_RETRIES,
        throttle: CoreThrottle | None = None,
    ) -> None:
        """Build a client that sends this key.

        Args:
            api_key: The user's CORE key.
            base_url: CORE's API root.
            max_retries: Retries for a 429, a 5xx or a transport failure.
            throttle: The session pause; the process-wide one by default.

        Raises:
            ValueError: If the key is blank: without one nothing is asked.
        """
        key = api_key.strip()
        if not key:
            raise ValueError("CORE is asked only with a key")
        self._base_url = base_url
        self._throttle = throttle if throttle is not None else session_core_throttle()
        session = requests.Session()
        session.headers.update({
            "User-Agent": EUROPEPMC_USER_AGENT,
            "Accept": "application/json",
            "Authorization": f"Bearer {key}",
        })
        retry = Retry(
            total=max_retries,
            backoff_factor=CORE_BACKOFF_FACTOR,
            status_forcelist=list(RETRYABLE_HTTP_STATUSES),
            allowed_methods=["GET"],
            raise_on_status=False,
        )
        self._session = mount_politely(session, retry=retry)

    def __repr__(self) -> str:
        """Name the client without its key."""
        return f"CoreTextClient(base_url={self._base_url!r})"

    def fetch_full_text(self, doi: str) -> CoreFetch:
        """Ask CORE for this DOI's extracted text.

        Args:
            doi: The article's DOI.

        Returns:
            Served text, an absence (CORE answered and holds none of this
            article, or there is no DOI), or the failure.
        """
        if not doi.strip():
            return CoreFetch.absent()
        if self._throttle.paused:
            return CoreFetch.unreachable(
                RequestFailure(RequestFailureKind.HTTP_STATUS, HTTP_TOO_MANY_REQUESTS)
            )
        try:
            response = self._session.get(
                core_search_url(doi, self._base_url),
                timeout=CORE_REQUEST_TIMEOUT_SECONDS,
            )
        except requests.exceptions.RequestException as error:
            self._throttle.record(None)
            return CoreFetch.unreachable(request_failure_from_exception(error))
        except ValueError:
            # A redirect that will not parse, as OpenAlex's.
            self._throttle.record(None)
            return CoreFetch.unreachable(RequestFailure(RequestFailureKind.REQUEST_FAILED))
        self._throttle.record(response.status_code)
        if response.status_code != HTTP_OK:
            return CoreFetch.unreachable(
                RequestFailure(RequestFailureKind.HTTP_STATUS, response.status_code)
            )
        try:
            text = core_full_text(json.loads(response.content.decode(CORE_ENCODING)), doi)
        except ValueError:
            logger.warning("CORE's answer could not be read.")
            return CoreFetch.unreachable(RequestFailure(RequestFailureKind.MALFORMED_RESPONSE))
        return CoreFetch.served(text) if text is not None else CoreFetch.absent()


def default_core_client(api_key: str | None) -> CoreTextClient | None:
    """The client discovery uses: ``None`` without a key.

    A module-level seam, as ``default_openalex_client`` is, so the test
    suite keeps every discovery off the real CORE (tests/conftest.py).

    Args:
        api_key: The configured key; the ``CORE_API_KEY`` environment
            variable is used when this is empty.

    Returns:
        A client, or ``None`` when no key is set: CORE is then not asked,
        and nothing is recorded (spec decision 4).
    """
    key = (api_key or os.environ.get(ENV_CORE_API_KEY, "")).strip()
    if not key:
        logger.debug("CORE is not asked: no CORE API key is configured.")
        return None
    return CoreTextClient(key)
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `pytest tests/test_core_api.py tests/test_openalex.py tests/test_pmc_open_data.py -q`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/bmlibrarian_lite/core_api.py src/bmlibrarian_lite/constants.py src/bmlibrarian_lite/openalex.py src/bmlibrarian_lite/pmc_open_data.py tests/test_core_api.py tests/scripted_http_server.py
git commit -m "feat(python): CORE's extracted text client, paced and paused per session (#480)

Refs #480.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Task 3: Python key setting

**Files:**
- Modify: `src/bmlibrarian_lite/config.py`, `src/bmlibrarian_lite/cli.py`, `src/bmlibrarian_lite/gui/settings_dialog.py`
- Modify: `doc/user/guide.md` (the spec's "Docs": how to get a free CORE key)
- Test: `tests/test_core_config.py`

**Interfaces:**
- Produces: `DiscoveryConfig.core_api_key: Optional[str] = None`, saved by `to_dict()`, redacted by `to_redacted_dict()`, and rejected as the redaction placeholder on load. Also the dialog widget `self.core_api_key_input: QLineEdit`.

- [ ] **Step 1: Write the failing tests**

Create `tests/test_core_config.py`:

```python
"""The CORE key in the desktop's settings (#480, stage C)."""

from __future__ import annotations

import json
import stat
from pathlib import Path

from bmlibrarian_lite.config import LiteConfig
from bmlibrarian_lite.constants import REDACTED_SECRET_PLACEHOLDER

KEY = "test-core-key-0123456789"


def test_the_key_defaults_to_none() -> None:
    """No key until the user sets one."""
    assert LiteConfig().discovery.core_api_key is None


def test_the_key_round_trips_through_the_owner_only_file(tmp_path: Path) -> None:
    """Saved with the other secrets, readable by the owner alone."""
    config = LiteConfig()
    config.discovery.core_api_key = KEY
    path = tmp_path / "config.json"
    config.save(path)
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    assert LiteConfig.load(path).discovery.core_api_key == KEY


def test_an_export_never_carries_the_key() -> None:
    """The redacted form names that a key is set, not the key."""
    config = LiteConfig()
    config.discovery.core_api_key = KEY
    redacted = config.to_redacted_dict()
    assert redacted["discovery"]["core_api_key"] == REDACTED_SECRET_PLACEHOLDER
    assert KEY not in json.dumps(redacted)


def test_a_redacted_export_loaded_back_is_no_key(tmp_path: Path) -> None:
    """The placeholder is never sent to CORE as a key."""
    path = tmp_path / "config.json"
    path.write_text(json.dumps({"discovery": {"core_api_key": REDACTED_SECRET_PLACEHOLDER}}))
    assert LiteConfig.load(path).discovery.core_api_key is None


def test_the_unpaywall_email_survives_beside_the_key(tmp_path: Path) -> None:
    """Control: the discovery section's other field is still read."""
    path = tmp_path / "config.json"
    path.write_text(json.dumps({"discovery": {"unpaywall_email": "a@b.org"}}))
    loaded = LiteConfig.load(path)
    assert loaded.discovery.unpaywall_email == "a@b.org"
    assert loaded.discovery.core_api_key is None
```

Check the real signatures of `LiteConfig.save` and `LiteConfig.load` (`config.py:938` and the classmethod near `_from_dict`) and adapt the path arguments if they differ. Keep the assertions.

Add a GUI test at the end of the file, guarded as the repo's GUI tests are (`pytest.importorskip("PySide6")` plus the `qapp` fixture used by `tests/test_settings_dialog*.py`; copy that file's setup):

```python
def test_the_dialog_saves_and_clears_the_key(qapp, tmp_path: Path, monkeypatch) -> None:
    """The Full Text tab's field writes the key; an empty field clears it."""
    from bmlibrarian_lite.gui.settings_dialog import SettingsDialog

    config = LiteConfig()
    monkeypatch.setattr(LiteConfig, "save", lambda self, *a, **k: None)
    dialog = SettingsDialog(config)
    dialog.core_api_key_input.setText(f"  {KEY}  ")
    dialog._save_settings()
    assert config.discovery.core_api_key == KEY
    dialog.core_api_key_input.setText("")
    dialog._save_settings()
    assert config.discovery.core_api_key is None
```

Use the dialog's actual constructor and save-method names (save is at `settings_dialog.py:1128-1186`). If an existing dialog test constructs it differently, follow that test.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pytest tests/test_core_config.py -q`
Expected: FAIL with `AttributeError: 'DiscoveryConfig' object has no attribute 'core_api_key'`.

- [ ] **Step 3: Implement**

`config.py`:
- `DiscoveryConfig` gains `core_api_key: Optional[str] = None  # CORE's API key (#480): CORE's extracted text when no other source has the article`.
- `_from_dict`: `config.discovery = DiscoveryConfig(unpaywall_email=discovery_data.get("unpaywall_email", ""), core_api_key=_reject_redaction_placeholder(discovery_data.get("core_api_key"), "discovery.core_api_key", ENV_CORE_API_KEY))`.
- `_reject_redaction_placeholder(value, field="pubmed.api_key", env_var="NCBI_API_KEY")` generalises its warning: replace the hard-coded `pubmed.api_key` and `NCBI_API_KEY` in its message with `field` and `env_var`. The existing call keeps its meaning through the defaults.
- `_to_dict_without_secrets` keeps `discovery` to `{"unpaywall_email": …}`. Its docstring already says a secret is filled in by both writers.
- `to_dict()` adds `data["discovery"]["core_api_key"] = self.discovery.core_api_key`.
- `to_redacted_dict()` adds `data["discovery"]["core_api_key"] = REDACTED_SECRET_PLACEHOLDER if self.discovery.core_api_key else None`.

`cli.py`: in the non-JSON config view, after the NCBI `API key:` line, add `print(f"  CORE API key: {REDACTED_SECRET_PLACEHOLDER if config.discovery.core_api_key else '(not set)'}")`, matching that block's indentation and wording style.

`settings_dialog.py`: add `_setup_fulltext_tab`, registered in `_setup_ui` after the PubMed tab:

```python
    def _setup_fulltext_tab(self) -> None:
        """Set up the Full Text tab: keys for optional full-text sources (#480)."""
        tab = QWidget()
        layout = QFormLayout(tab)
        layout.setContentsMargins(scaled(12), scaled(12), scaled(12), scaled(12))
        layout.setFieldGrowthPolicy(QFormLayout.ExpandingFieldsGrow)

        self.core_api_key_input = QLineEdit()
        self.core_api_key_input.setPlaceholderText("Optional")
        self.core_api_key_input.setEchoMode(QLineEdit.Password)
        self.core_api_key_input.setToolTip(CORE_API_KEY_EXPLANATION)
        layout.addRow("CORE API Key:", self.core_api_key_input)
        layout.addRow(QLabel(f"<small>{CORE_API_KEY_EXPLANATION}</small>"))

        self.tab_widget.addTab(tab, "Full Text")
```

Add `CORE_API_KEY_EXPLANATION` to `constants.py` (CORE block) with the verbatim sentence from Global Constraints. Load it in the dialog's load method beside the PubMed key: `if self.config.discovery.core_api_key: self.core_api_key_input.setText(self.config.discovery.core_api_key)`. Save it beside the PubMed key: `core_key = self.core_api_key_input.text().strip(); self.config.discovery.core_api_key = core_key or None`. No stylesheet.

**User guide.** In `doc/user/guide.md`:
- After "#### PubMed Email (Recommended)", add:

````markdown
#### CORE API Key (Optional)

CORE (core.ac.uk) holds the text it extracted from open-access repository
copies. With a free key, BMLibrarian Lite reads that text when no other
source has the article. Register at https://core.ac.uk/services/api, then
enter the key under Settings → Full Text, or set it in the environment:
```bash
export CORE_API_KEY="your-key"
```
The key is stored only in your configuration file (readable by you alone)
and sent only to CORE. Without one, CORE is simply not asked.
````

- Replace the "Full-Text Discovery" list with the chain as it now stands:
  1. Europe PMC XML;
  2. PMC's open-access collection (the same JATS, by PMC ID, including author manuscripts);
  3. Europe PMC PDF;
  4. every Unpaywall PDF, then OpenAlex's;
  5. CORE's extracted text (with a key; plain text, so statement checks are "not assessed");
  6. DOI resolution;
  7. manual upload.

  Keep the paragraph after it.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pytest tests/test_core_config.py tests/ -q -k "config or settings"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/bmlibrarian_lite/config.py src/bmlibrarian_lite/cli.py src/bmlibrarian_lite/gui/settings_dialog.py src/bmlibrarian_lite/constants.py tests/test_core_config.py doc/user/guide.md
git commit -m "feat(python): a CORE API key in the settings, saved and redacted as a secret (#480)

Refs #480.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Task 4: Python chain

**Files:**
- Modify: `src/bmlibrarian_lite/analysis_failures.py` (`_OPEN_ACCESS_CHAIN`)
- Modify: `src/bmlibrarian_lite/pdf_utils.py`, `src/bmlibrarian_lite/pdf_discovery.py`, `src/bmlibrarian_lite/fulltext_discovery.py`
- Modify (threading `core_api_key`): `src/bmlibrarian_lite/gui/workers.py`, `src/bmlibrarian_lite/gui/document_interrogation_tab.py`, `src/bmlibrarian_lite/mcp_server.py`, `src/bmlibrarian_lite/study_transparency_analyzer/study_transparency_analyzer.py`, `src/bmlibrarian_lite/transparency/assessment.py`, `src/bmlibrarian_lite/transparency/transparency_manager.py`, `src/bmlibrarian_lite/gui/systematic_review_tab.py`
- Modify: `tests/conftest.py`, `pyproject.toml` (marker), `tests/test_open_access_unsettled_notice.py` and `tests/test_open_access_statement.py` (`SERVICES` gains `"core": SERVICE_CORE`)
- Test: `tests/test_core_discovery.py`

**Interfaces:**
- Consumes: `CoreFetch`, `default_core_client`, `CoreTextClient` (Task 2); `DiscoveryConfig.core_api_key` (Task 3).
- Produces:
  - `DiscoveryResult.text: str | None = None`.
  - `PDFDiscoverer.discover_and_download(..., core_text: Callable[[str], CoreFetch] | None = None)`.
  - `FulltextDiscoverer(..., core_api_key: str | None = None, core: CoreTextClient | None = None)`.
  - `FulltextSourceType.CORE_TEXT = "core_text"`.
  - In `pdf_utils`: `generate_core_text_path(doc_dict, base_dir=None) -> Path`, `save_core_text(doc_dict, text, base_dir=None) -> Path` and `read_cached_core_text(path: Path) -> str | None`.
  - `StudyTransparencyAnalyzer(..., core_api_key: str | None = None)`.
  - `create_background_analyzer(..., core_api_key: str | None = None)`.

- [ ] **Step 1: Write the failing tests**

Create `tests/test_core_discovery.py`:

```python
"""CORE's place in the desktop's chain (#480, stage C)."""

from __future__ import annotations

from pathlib import Path
from typing import Any
from unittest.mock import patch

import pytest

from bmlibrarian_lite.analysis_failures import unestablished_access_clause
from bmlibrarian_lite.constants import (
    CORE_TEXT_CACHE_STAMP,
    SERVICE_CORE,
    SERVICE_OPENALEX,
)
from bmlibrarian_lite.core_api import CoreFetch
from bmlibrarian_lite.data_models import (
    LookupRecord,
    RequestFailure,
    RequestFailureKind,
    SourceLookupFailure,
)
from bmlibrarian_lite.fulltext_discovery import FulltextDiscoverer, FulltextSourceType
from bmlibrarian_lite.pdf_discovery import DiscoveryResult, PDFDiscoverer
from bmlibrarian_lite.pdf_utils import (
    find_existing_fulltext,
    generate_core_text_path,
    read_cached_core_text,
    save_core_text,
)

DOI = "10.1159/000513404"
TEXT = "The article's extracted text."


class _Core:
    """CORE answering one scripted fetch, and counting what it is asked."""

    def __init__(self, fetch: CoreFetch) -> None:
        self.fetch = fetch
        self.asked: list[str] = []

    def fetch_full_text(self, doi: str) -> CoreFetch:
        self.asked.append(doi)
        return self.fetch


def _no_pdf_sources(self: PDFDiscoverer, doi: Any, pmid: Any, pmcid: Any):
    return [], LookupRecord()


def _discover(core: _Core, tmp_path: Path, **kwargs: Any):
    """A discovery in which Europe PMC, the bucket and every PDF source find nothing."""
    discoverer = FulltextDiscoverer(use_browser_fallback=False, core=core)
    doc = {"doi": DOI, "id": "d1"}
    with patch.object(PDFDiscoverer, "_discover_sources", _no_pdf_sources), \
         patch("bmlibrarian_lite.fulltext_discovery.get_fulltext_base_dir", return_value=tmp_path), \
         patch("bmlibrarian_lite.pdf_utils.get_fulltext_base_dir", return_value=tmp_path):
        return discoverer.discover_fulltext(doc_dict=doc, doi=DOI, **kwargs)
```

**Before writing the tests below,** read `tests/test_openalex_discovery.py:82-140` and `tests/test_pmc_open_data_discovery.py:41-90`. They show how those suites stop Europe PMC's XML, the bucket and the cache from answering, which helpers they patch and how. Replace `_discover`'s patches with exactly that setup, adding the `_no_pdf_sources` patch. The tests below need only its contract: a discovery where nothing before CORE finds the article.

```python
def test_cores_text_is_the_full_text_when_nothing_else_has_it(tmp_path: Path) -> None:
    """Served: the article's text, labelled CORE's, asked by the DOI."""
    core = _Core(CoreFetch.served(TEXT))
    result = _discover(core, tmp_path)
    assert result.success
    assert result.source_type is FulltextSourceType.CORE_TEXT
    assert result.markdown_content == TEXT
    assert core.asked == [DOI]


def test_core_knowing_nothing_adds_nothing(tmp_path: Path) -> None:
    """Absent: the result is what it was without CORE, and absence holds."""
    result = _discover(_Core(CoreFetch.absent()), tmp_path)
    assert not result.success
    assert SERVICE_CORE not in {f.service for f in result.lookups.failures}


def test_an_unreachable_core_is_told_and_blocks_absence(tmp_path: Path) -> None:
    """The maintainer's decision: a configured CORE that could not be asked is unsettled."""
    failure = RequestFailure(RequestFailureKind.HTTP_STATUS, 503)
    result = _discover(_Core(CoreFetch.unreachable(failure)), tmp_path)
    assert SourceLookupFailure(SERVICE_CORE, failure) in result.lookups.failures
    assert not result.absence_established
    assert "CORE (HTTP 503 Service Unavailable) could not be asked" in (result.error or "")


def test_without_a_key_core_is_not_asked_and_nothing_is_recorded(tmp_path: Path) -> None:
    """Spec decision 4: silent, and blocks nothing."""
    discoverer = FulltextDiscoverer(use_browser_fallback=False)  # conftest: no client
    assert discoverer._core is None
    result = _discover_with(discoverer, tmp_path)
    assert SERVICE_CORE not in {f.service for f in result.lookups.failures}
    assert all(s.service != SERVICE_CORE for s in result.lookups.skipped)
```

Write `_discover_with(discoverer, tmp_path)` as `_discover`'s body taking a built discoverer, and have `_discover` call it.

```python
def test_a_downloaded_pdf_means_core_is_never_asked(tmp_path: Path) -> None:
    """The first copy obtained ends the walk."""
    core = _Core(CoreFetch.served(TEXT))
    downloaded = DiscoveryResult(success=True, file_path=tmp_path / "a.pdf")
    with patch.object(PDFDiscoverer, "discover_and_download", return_value=downloaded), \
         patch("bmlibrarian_lite.fulltext_discovery.extract_pdf_text", return_value="PDF text"):
        result = FulltextDiscoverer(use_browser_fallback=False, core=core)._try_pdf_download(
            {"doi": DOI}, None, None, DOI, None
        )
    assert result.source_type is FulltextSourceType.DOWNLOADED_PDF
    assert core.asked == []


def test_a_copy_served_but_not_saved_means_core_is_never_asked() -> None:
    """A served copy settles the question; CORE could add nothing."""
    core = _Core(CoreFetch.served(TEXT))
    discoverer = PDFDiscoverer(use_browser_fallback=False)
    not_saved = DiscoveryResult(success=False, not_saved=True)
    source = _open_access_source("https://repo.example.org/a.pdf")
    with patch.object(PDFDiscoverer, "_discover_sources", lambda *a: ([source], LookupRecord())), \
         patch.object(PDFDiscoverer, "_try_download", return_value=not_saved):
        result = discoverer.discover_and_download(Path("/tmp/x.pdf"), doi=DOI, core_text=core.fetch_full_text)
    assert core.asked == []
    assert not result.success


def test_core_is_asked_after_every_refused_copy_and_openalex(tmp_path: Path) -> None:
    """Last before the link: Unpaywall's refused PDF and OpenAlex come first."""
    order: list[str] = []
    refused = DiscoveryResult(success=False, failure=RequestFailure(RequestFailureKind.HTTP_STATUS, 403))
    source = _open_access_source("https://walled.example.org/a.pdf")

    def try_download(self, src, output_path, title):
        order.append("pdf")
        return refused

    def openalex(self, doi, known):
        order.append("openalex")
        return [], LookupRecord(failures=(SourceLookupFailure(SERVICE_OPENALEX, RequestFailure(RequestFailureKind.TIMEOUT)),))

    def core(doi: str) -> CoreFetch:
        order.append("core")
        return CoreFetch.unreachable(RequestFailure(RequestFailureKind.TIMEOUT))

    with patch.object(PDFDiscoverer, "_discover_sources", lambda *a: ([source], LookupRecord())), \
         patch.object(PDFDiscoverer, "_try_download", try_download), \
         patch.object(PDFDiscoverer, "_discover_openalex", openalex):
        result = PDFDiscoverer(use_browser_fallback=False).discover_and_download(
            tmp_path / "x.pdf", doi=DOI, core_text=core
        )
    assert order == ["pdf", "openalex", "core"]
    services = [f.service for f in result.lookups.failures]
    assert services.index(SERVICE_OPENALEX) < services.index(SERVICE_CORE)
    assert result.error is not None and result.error.endswith(
        "Whether this document is open access was not established."
    )
    assert "; CORE (the request timed out)" in result.error


def test_core_serving_drops_the_refused_copies(tmp_path: Path) -> None:
    """A text obtained settles the question, as a downloaded PDF does."""
    refused = DiscoveryResult(success=False, failure=RequestFailure(RequestFailureKind.HTTP_STATUS, 403))
    source = _open_access_source("https://walled.example.org/a.pdf")
    with patch.object(PDFDiscoverer, "_discover_sources", lambda *a: ([source], LookupRecord())), \
         patch.object(PDFDiscoverer, "_try_download", return_value=refused):
        result = PDFDiscoverer(use_browser_fallback=False).discover_and_download(
            tmp_path / "x.pdf", doi=DOI, core_text=lambda doi: CoreFetch.served(TEXT)
        )
    assert result.success and result.text == TEXT and result.file_path is None
    assert result.lookups == LookupRecord()


def test_core_is_asked_once_whatever_the_exit(tmp_path: Path) -> None:
    """A non-open-access paywall after a CORE miss does not ask again."""
    asked: list[str] = []
    paywalled = DiscoveryResult(success=False, is_paywall=True, error="Paywalled",
                                failure=RequestFailure(RequestFailureKind.HTTP_STATUS, 401))
    source = _publisher_source("https://publisher.example.org/a.pdf")
    with patch.object(PDFDiscoverer, "_discover_sources", lambda *a: ([source], LookupRecord())), \
         patch.object(PDFDiscoverer, "_try_download", return_value=paywalled):
        PDFDiscoverer(use_browser_fallback=False).discover_and_download(
            tmp_path / "x.pdf", doi=DOI,
            core_text=lambda doi: asked.append(doi) or CoreFetch.absent(),
        )
    assert asked == [DOI]


def test_no_doi_no_core(tmp_path: Path) -> None:
    """CORE is searched by DOI alone."""
    asked: list[str] = []
    with patch.object(PDFDiscoverer, "_discover_sources", lambda *a: ([], LookupRecord())):
        PDFDiscoverer(use_browser_fallback=False).discover_and_download(
            tmp_path / "x.pdf", pmid="123",
            core_text=lambda doi: asked.append(doi) or CoreFetch.absent(),
        )
    assert asked == []


def test_another_articles_text_is_not_served_through_the_chain(tmp_path: Path) -> None:
    """Review focus 1, end to end: a search hit for another DOI is an absence."""
    from bmlibrarian_lite.core_api import core_full_text
    answer = {"results": [{"doi": "10.1159/999999", "fullText": "x" * 6000}]}
    fetch = CoreFetch.served(t) if (t := core_full_text(answer, DOI)) else CoreFetch.absent()
    result = _discover(_Core(fetch), tmp_path)
    assert not result.success


def test_the_core_cache_is_read_at_cores_place_and_never_shadows_jats(tmp_path: Path) -> None:
    """Cached CORE text is served without asking; find_existing_fulltext never returns it."""
    doc = {"doi": DOI, "id": "d1"}
    path = save_core_text(doc, TEXT, base_dir=tmp_path)
    assert path == generate_core_text_path(doc, base_dir=tmp_path)
    assert path.read_text(encoding="utf-8").startswith(CORE_TEXT_CACHE_STAMP + "\n")
    assert read_cached_core_text(path) == TEXT
    assert find_existing_fulltext(doc, base_dir=tmp_path) is None
    core = _Core(CoreFetch.served("live text"))
    result = _discover(core, tmp_path)
    assert result.markdown_content == TEXT
    assert core.asked == []


def test_a_damaged_core_cache_is_asked_again(tmp_path: Path) -> None:
    """No stamp, another stamp or an empty body is no cached text."""
    doc = {"doi": DOI, "id": "d1"}
    path = generate_core_text_path(doc, base_dir=tmp_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    for content in ("plain text", "<!-- other v1 -->\ntext", f"{CORE_TEXT_CACHE_STAMP}\n  \n"):
        path.write_text(content, encoding="utf-8")
        assert read_cached_core_text(path) is None


def test_core_is_told_last_in_chain_order() -> None:
    """CORE after every open-access source, whatever order it was recorded in."""
    record = LookupRecord(failures=(
        SourceLookupFailure(SERVICE_CORE, RequestFailure(RequestFailureKind.HTTP_STATUS, 503)),
        SourceLookupFailure(SERVICE_OPENALEX, RequestFailure(RequestFailureKind.TIMEOUT)),
    ))
    clause = unestablished_access_clause(record)
    assert clause.index("OpenAlex") < clause.index("CORE")


def test_the_key_reaches_the_discoverer_from_each_caller(monkeypatch: pytest.MonkeyPatch) -> None:
    """Workers, MCP and the transparency analyser pass the configured key."""
    seen: list[str | None] = []
    monkeypatch.setattr(
        "bmlibrarian_lite.fulltext_discovery.default_core_client",
        lambda key: seen.append(key) or None,
    )
    FulltextDiscoverer(core_api_key="k1")
    from bmlibrarian_lite.gui.workers import FulltextDiscoveryWorker
    FulltextDiscoveryWorker({"doi": DOI}, core_api_key="k2")._build_discoverer()
    assert seen == ["k1", "k2"]
```

`FulltextDiscoveryWorker` builds its discoverer inline (`workers.py:442-447`). Extract that into a method `_build_discoverer(self) -> FulltextDiscoverer` so this test can reach it, and call it from `run`. Do the same for `StudyTransparencyAnalyzer._discover_fulltext` (`:2983-2988`): extract `_fulltext_discoverer()` and add the assertion `StudyTransparencyAnalyzer("a@b.org", core_api_key="k3")._fulltext_discoverer()` → `seen` gains `"k3"`. The MCP server builds its discoverer at `mcp_server.py:819-823`: pass `core_api_key=config.discovery.core_api_key` there, and assert it by the same monkeypatch where that module has a test (`tests/test_mcp_server*.py`). If it has none, assert it by reading the call in a small test that calls the enclosing function with a stub config.

The helpers `_open_access_source(url)` and `_publisher_source(url)` build `PDFSource(url=url, source_type=PDFSourceType.UNPAYWALL_OA, is_open_access=True)` and `PDFSource(url=url, source_type=PDFSourceType.DOI_DIRECT, is_open_access=False)`. Check `PDFSource`'s required fields at `pdf_discovery.py:448` and fill the rest as `tests/test_openalex_discovery.py` does.

In `tests/test_open_access_unsettled_notice.py` and `tests/test_open_access_statement.py`, add `"core": SERVICE_CORE` to `SERVICES` and import `SERVICE_CORE`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pytest tests/test_core_discovery.py tests/test_open_access_unsettled_notice.py tests/test_open_access_statement.py -q`
Expected: FAIL. The new module raises `ImportError: cannot import name 'generate_core_text_path'`. The statement row "CORE is told after every PDF" fails on order, since CORE ranks first until the chain names it.

- [ ] **Step 3: Implement the guard**

In `tests/conftest.py`, after `_no_live_openalex`:

```python
@pytest.fixture(autouse=True)
def _no_live_core(
    request: pytest.FixtureRequest, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Keep every discovery off the real CORE (#480, stage C).

    No key means no client, which is what a user without one has; a test
    that wants CORE passes its own client. A CORE_API_KEY in the developer's
    environment must not reach the network from the suite.
    """
    from bmlibrarian_lite.core_api import reset_core_throttle

    reset_core_throttle()
    monkeypatch.delenv("CORE_API_KEY", raising=False)
    if request.node.get_closest_marker("real_core_client"):
        return
    monkeypatch.setattr(
        "bmlibrarian_lite.fulltext_discovery.default_core_client",
        lambda api_key: None,
    )
```

Register the marker in `pyproject.toml` beside `real_openalex_client`: `"real_core_client: the full-text discoverer builds its real CORE client (tests/conftest.py otherwise builds none)"`. Mark `test_the_key_reaches_the_discoverer_from_each_caller` with it: it patches the seam itself.

- [ ] **Step 4: Implement the chain**

`analysis_failures.py`: import `SERVICE_CORE`; `_OPEN_ACCESS_CHAIN` gains `SERVICE_CORE` last. Leave `_NAMED_BY` alone: CORE names no PDF.

`pdf_utils.py`, after `read_cached_fulltext`:

```python
def generate_core_text_path(
    doc_dict: Dict[str, Any], base_dir: Optional[Path] = None
) -> Path:
    """Where CORE's text for this document is cached (#480, stage C).

    Beside the JATS markdown, under another suffix, so
    :func:`find_existing_fulltext` -- read before Europe PMC is asked --
    never returns it: CORE's text is the poorest form and must not shadow
    a JATS text a later fetch could get.

    Args:
        doc_dict: Document dictionary with pmcid, pmid, doi, year, etc.
        base_dir: Base directory for full-text storage.

    Returns:
        The markdown path with ``.md`` replaced by ``.core.txt``.
    """
    return generate_fulltext_path(doc_dict, base_dir).with_suffix(CORE_TEXT_CACHE_SUFFIX)


def save_core_text(
    doc_dict: Dict[str, Any], text: str, base_dir: Optional[Path] = None
) -> Path:
    """Cache CORE's text, stamped and written whole or not at all.

    Args:
        doc_dict: Document dictionary with pmcid, pmid, doi, year, etc.
        text: CORE's text for the article.
        base_dir: Base directory for full-text storage.

    Returns:
        Where it was saved.

    Raises:
        OSError: If it cannot be written; nothing partial is left.
    """
    path = generate_core_text_path(doc_dict, base_dir)
    path.parent.mkdir(parents=True, exist_ok=True)
    partial = path.with_name(f"{path.name}.partial")
    try:
        partial.write_text(f"{CORE_TEXT_CACHE_STAMP}\n{text}", encoding="utf-8")
        os.replace(partial, path)
    except OSError:
        partial.unlink(missing_ok=True)
        raise
    return path


def read_cached_core_text(path: Path) -> str | None:
    """CORE's cached text, or ``None`` when there is none to trust.

    Args:
        path: :func:`generate_core_text_path`'s path.

    Returns:
        The text without its stamp; ``None`` when the file is missing,
        unreadable, unstamped, stamped otherwise or empty.
    """
    try:
        content = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return None
    except (OSError, UnicodeDecodeError) as error:
        logger.warning("Cached CORE text could not be read (%s).", type(error).__name__)
        return None
    stamp, _, text = content.partition("\n")
    if stamp != CORE_TEXT_CACHE_STAMP or not text.strip():
        return None
    return text
```

Import `CORE_TEXT_CACHE_STAMP` and `CORE_TEXT_CACHE_SUFFIX` from `.constants`.

`pdf_discovery.py`:
- Import `Callable`, `SERVICE_CORE` and `CoreFetch` (from `.core_api`).
- `DiscoveryResult` gains `text: Optional[str] = None`. Document it in the docstring: "CORE's extracted text, when no PDF was obtained and CORE served the article (#480, stage C); only with ``success`` and no ``file_path``". In `__post_init__`, add:

```python
        if self.text is not None and (not self.success or self.file_path is not None):
            raise ValueError("CORE's text is a success without a file")
```

- Add, above `PDFDiscoverer`:

```python
class _CoreFallback:
    """CORE's text, asked at most once, at the first exit that obtained no PDF.

    Asked inside the discovery rather than after it, so a failure is in the
    record before the reader's sentence is built from it (#480, stage C).
    """

    def __init__(self, fetch: Callable[[str], CoreFetch] | None, doi: str | None) -> None:
        self._fetch = fetch if doi else None
        self._doi = doi or ""

    def ask(self) -> tuple[str | None, LookupRecord]:
        """Ask CORE, once.

        Returns:
            The text when CORE served it, and what to record otherwise.
        """
        if self._fetch is None:
            return None, LookupRecord()
        fetch, self._fetch = self._fetch, None
        outcome = fetch(self._doi)
        if outcome.text is not None:
            return outcome.text, LookupRecord()
        if outcome.failure is not None:
            return None, LookupRecord(
                failures=(SourceLookupFailure(SERVICE_CORE, outcome.failure),)
            )
        return None, LookupRecord()
```

- `discover_and_download` gains the keyword `core_text: Callable[[str], CoreFetch] | None = None`. Document it: "Asks CORE for its extracted text, by the cleaned DOI, at the first exit that obtained no PDF and served no copy". After the DOI is cleaned (line ~846), add `core = _CoreFallback(core_text, doi)`. Then at each exit that obtained no PDF and served no copy, **before** its message is built, insert this block. The exits are the `if not sources:` return, the non-open-access paywall `else:` return inside the loop, and the shared tail after the browser fallback, before `if last_paywall_result:`.

```python
            core_text_found, core_lookups = core.ask()
            if core_text_found is not None:
                return DiscoveryResult(success=True, text=core_text_found, lookups=lookups)
            lookups = lookups.merged(core_lookups)
            told = told.merged(core_lookups)
```

  In the shared tail, insert it right after `not_obtained = self._ranked(unobtained)`. Do not insert it on the `not_saved`, cancel or success returns.

`fulltext_discovery.py`:
- `FulltextSourceType` gains `CORE_TEXT = "core_text"  # CORE's extracted text (#480, stage C)`.
- `FulltextDiscoverer.__init__` gains `core_api_key: str | None = None` and `core: CoreTextClient | None = None` (documented), and sets `self._core = core if core is not None else default_core_client(core_api_key)`. Import `default_core_client`, `CoreFetch` and `CoreTextClient` from `.core_api` by name, so conftest's patch of `bmlibrarian_lite.fulltext_discovery.default_core_client` takes effect.
- Add:

```python
    def _core_text(self, doc_dict: Dict[str, Any], doi: str) -> CoreFetch:
        """CORE's text for this article: the cached copy, else CORE asked.

        Read here, at CORE's place in the chain, so a cached CORE text never
        shadows the sources asked before it.

        Args:
            doc_dict: Document dictionary, for the cache path.
            doi: The cleaned DOI.

        Returns:
            What CORE holds for the article.
        """
        assert self._core is not None
        cached = read_cached_core_text(generate_core_text_path(doc_dict))
        if cached is not None:
            return CoreFetch.served(cached)
        fetch = self._core.fetch_full_text(doi)
        if fetch.text is not None:
            try:
                save_core_text(doc_dict, fetch.text)
            except OSError as error:
                logger.warning("CORE's text could not be cached (%s).", type(error).__name__)
        return fetch
```

- In `_try_pdf_download`, pass `core_text=(lambda clean_doi: self._core_text(doc_dict, clean_doi)) if self._core is not None else None` to `discover_and_download`. Before the existing `if pdf_result.success and pdf_result.file_path:`, add:

```python
            if pdf_result.success and pdf_result.text is not None:
                return FulltextResult(
                    success=True,
                    source_type=FulltextSourceType.CORE_TEXT,
                    markdown_content=pdf_result.text,
                    lookups=pdf_result.lookups,
                )
```

- `discover_fulltext` (module-level, `:961`) gains `core_api_key: str | None = None`, passed through.

**Threading.** Each caller passes the configured key:
- `gui/workers.py`: `PDFDiscoveryWorker` is unchanged (it calls `PDFDiscoverer` directly; CORE is a text source). `FulltextDiscoveryWorker.__init__` gains `core_api_key: str | None = None`, used by the extracted `_build_discoverer`.
- `gui/document_interrogation_tab.py:911-917`: passes `core_api_key=self.config.discovery.core_api_key`. Its `source_labels` map (`:942-948`) gains `"core_text": "Full Text (CORE, extracted text)"`.
- `mcp_server.py:819-823`: `core_api_key=config.discovery.core_api_key`.
- `StudyTransparencyAnalyzer.__init__` gains `core_api_key: str | None = None`, stored and passed in the extracted `_fulltext_discoverer()`. `transparency/assessment.py` `create_background_analyzer(email, pubmed_api_key=None, unpaywall_email=None, core_api_key=None)` passes it. Each construction site that has a config passes `config.discovery.core_api_key`: `transparency/transparency_manager.py:95-99`, `gui/systematic_review_tab.py:846-851` and `gui/workers.py:1465-1469`.
  - Follow how each already receives `unpaywall_email`. Where a site has no config (`batch_analyzer.py`, `examples.py`, the analyser's CLI), leave it: the environment fallback serves it.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `pytest tests/test_core_discovery.py tests/test_open_access_unsettled_notice.py tests/test_open_access_statement.py tests/test_openalex_discovery.py tests/test_pmc_open_data_discovery.py tests/test_absence_needs_a_lookup.py -q`
Expected: PASS.

- [ ] **Step 6: Run the whole Python suite**

Run: `pytest tests/ -q`
Expected: no failures. A test that asserts a worker's or analyser's exact constructor keywords may need the new `core_api_key` added. Change only that keyword list.

- [ ] **Step 7: Commit**

```bash
git add -A src/bmlibrarian_lite tests pyproject.toml
git commit -m "feat(python): CORE's extracted text, last before the link, cached apart (#480)

Asked inside PDF discovery at each exit that obtained no PDF, so its failure
is in the record the reader's sentence is built from. A missing key asks and
records nothing.

Refs #480.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---
## Task 5: Swift — CORE's pure rules and the session throttle (BioMedLit)

**Files:**
- Create: `Packages/BioMedLit/Sources/BioMedLit/Services/CORE.swift`
- Modify: `Packages/BioMedLit/Sources/BioMedLit/Services/OpenAlex.swift` (make `escaped(_:)` internal and reuse it)
- Modify: `Packages/BioMedLit/Sources/BioMedLit/Utilities/Constants.swift`, `Utilities/RetryHelper.swift`
- Modify: `Packages/BioMedLit/Sources/BioMedLit/Models/OpenAccessShortfall.swift`
- Test: `Packages/BioMedLit/Tests/BioMedLitTests/COREContractTests.swift`

**Interfaces:**
- Produces:
  - `public enum CORE`, with:
    - `static func searchURL(doi: String, baseURL: String = BioMedLitConstants.coreBaseURL) -> URL?`
    - `static func normalisedDOI(_ doi: String) -> String`
    - `static func fullText(fromAnswer data: Data, doi: String, minCharacters: Int = BioMedLitConstants.coreMinFullTextCharacters) throws -> String?`
    - `static func fullText(fromAnswerObject object: Any, doi: String, minCharacters: Int) throws -> String?`
  - `enum COREFetch: Equatable { case served(String); case absent; case unreachable(RequestFailure) }`
  - `public final class CoreThrottle: @unchecked Sendable` with `static let shared`, `init(pauseAfter:)`, `var isPaused: Bool` and `func record(endedOn status: Int?)`.
  - `OpenAccessSource.core` (raw `"core"`, `serviceName` `"CORE"`), last in `chainOrder`.
  - `RetryConfiguration.core`.

- [ ] **Step 1: Add the constants**

In `Constants.swift`, after the OpenAlex block:

```swift
    // MARK: - CORE (#480, stage C)

    /// CORE's API root; pinned by fulltext_parity/core_fulltext.json.
    public static let coreBaseURL = "https://api.core.ac.uk"
    /// The search path. Its trailing slash matters: without it CORE answers an HTML page.
    public static let coreSearchPath = "/v3/search/works/"
    /// Results asked for: a DOI query can match more than one record.
    public static let coreSearchLimit = 3
    /// CORE as the reader's sentences name it, verbatim on every platform.
    public static let coreServiceName = "CORE"
    /// The fewest Unicode code points CORE's text holds to count as a full text.
    public static let coreMinFullTextCharacters = 5000
    /// Consecutive fetches ending in 429 after which CORE is not asked again this session.
    public static let corePauseAfterConsecutive429 = 2
    /// 0.4 requests a second, Python's POLITE_RATE_CEILINGS entry, per service instance (#489).
    public static let coreMinimumInterval: TimeInterval = 2.5
```

In `RetryHelper.swift`, beside `.openAlex`:

```swift
    /// Configuration for CORE (#480, stage C): four attempts, as Python's.
    public static let core = RetryConfiguration(
        maxAttempts: 4, initialDelay: 1.0, maxDelay: 30.0, backoffMultiplier: 2.0, jitterFactor: 0.2
    )
```

- [ ] **Step 2: Write the failing contract tests**

Create `COREContractTests.swift`. Copy `OpenAlexContractTests.swift`'s `enum OpenAlexContract` loader: it walks up from `#filePath` and stops at `.git`. Name the copy `enum COREContract`, pointing at `doc/cross_platform/fulltext_parity/core_fulltext.json`. Then:

```swift
import XCTest
@testable import BioMedLit

final class COREContractTests: XCTestCase {
    private var contract: [String: Any] = [:]

    override func setUpWithError() throws {
        contract = try COREContract.load()
    }

    private func table(_ name: String, minimum: Int) throws -> [[String: Any]] {
        let rows = try XCTUnwrap(contract[name] as? [[String: Any]], name)
        XCTAssertGreaterThanOrEqual(rows.count, minimum, "\(name) lost rows")
        return rows
    }

    func testEveryContractTableIsReadHere() {
        XCTAssertEqual(Set(contract.keys), [
            "schema_version", "description", "service_name", "source", "source_label",
            "desktop_source_type", "base_url", "min_fulltext_chars",
            "pause_after_consecutive_429", "search_url", "full_text", "status", "bodies",
        ])
    }

    func testTheNamesAreTheContracts() {
        XCTAssertEqual(contract["service_name"] as? String, BioMedLitConstants.coreServiceName)
        XCTAssertEqual(contract["source"] as? String, OpenAccessSource.core.rawValue)
        XCTAssertEqual(contract["base_url"] as? String, BioMedLitConstants.coreBaseURL)
        XCTAssertEqual(contract["min_fulltext_chars"] as? Int, BioMedLitConstants.coreMinFullTextCharacters)
        XCTAssertEqual(contract["pause_after_consecutive_429"] as? Int, BioMedLitConstants.corePauseAfterConsecutive429)
        XCTAssertEqual(OpenAccessSource.core.serviceName, "CORE")
    }

    func testEachSearchURL() throws {
        for row in try table("search_url", minimum: 7) {
            let name = row["name"] as? String ?? "?"
            let doi = try XCTUnwrap(row["doi"] as? String, name)
            let base = row["base_url"] as? String ?? BioMedLitConstants.coreBaseURL
            XCTAssertEqual(CORE.searchURL(doi: doi, baseURL: base)?.absoluteString, row["url"] as? String, name)
        }
    }

    func testEachFullTextRow() throws {
        for row in try table("full_text", minimum: 24) {
            let name = row["name"] as? String ?? "?"
            let doi = try XCTUnwrap(row["doi"] as? String, name)
            let minimum = try XCTUnwrap(row["min_chars"] as? Int, name)
            let answer = try XCTUnwrap(row["answer"], name)
            if row["outcome"] as? String == "malformed" {
                XCTAssertThrowsError(try CORE.fullText(fromAnswerObject: answer, doi: doi, minCharacters: minimum), name)
            } else {
                XCTAssertEqual(
                    try CORE.fullText(fromAnswerObject: answer, doi: doi, minCharacters: minimum),
                    row["text"] as? String, name
                )
            }
        }
    }

    func testEachUnreadableBodyThrows() throws {
        for row in try table("bodies", minimum: 4) {
            let body = Data(try XCTUnwrap(row["body"] as? String).utf8)
            XCTAssertThrowsError(try CORE.fullText(fromAnswer: body, doi: "10.1/x"), row["name"] as? String ?? "?")
        }
    }

    func testABodyThatIsNotUTF8Throws() {
        XCTAssertThrowsError(try CORE.fullText(fromAnswer: Data([0x7B, 0xFF, 0x7D]), doi: "10.1/x"))
    }

    func testCOREIsLastInChainOrder() {
        XCTAssertEqual(OpenAccessShortfall.chainOrder.last, .core)
    }

    func testTwo429sInARowPause() {
        let throttle = CoreThrottle(pauseAfter: 2)
        throttle.record(endedOn: 429)
        XCTAssertFalse(throttle.isPaused)
        throttle.record(endedOn: 429)
        XCTAssertTrue(throttle.isPaused)
    }

    func testAnotherEndingResetsTheCount() {
        let throttle = CoreThrottle(pauseAfter: 2)
        throttle.record(endedOn: 429)
        throttle.record(endedOn: 200)
        throttle.record(endedOn: 429)
        XCTAssertFalse(throttle.isPaused)
        throttle.record(endedOn: nil)
        throttle.record(endedOn: 429)
        XCTAssertFalse(throttle.isPaused)
    }
}
```

`JSONSerialization` decodes `"😀"` escapes into the real astral scalar, so the code-point rows test what they say. If `chainOrder` is private, make it `static let chainOrder` internal; the tests are `@testable`.

Also extend `OpenAccessShortfallContractTests`: its `sources` map comparison must include `core`. The `notices`, `persisted` and `statements` rows added in Task 1 are read by the existing loops once `OpenAccessSource(rawValue: "core")` exists. Run it to confirm.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `cd Packages/BioMedLit && swift test --filter 'COREContractTests|OpenAccessShortfallContractTests'`
Expected: compile failure, `cannot find 'CORE' in scope`. Per the swift-build-hang memory: type-check first with `swiftc -typecheck` if a build stalls; never run two SwiftPM builds at once.

- [ ] **Step 4: Implement `CORE.swift`**

```swift
import Foundation

/// CORE's extracted text, asked by DOI with the user's own key (#480, stage C).
///
/// The pure rules, pinned by `doc/cross_platform/fulltext_parity/core_fulltext.json`;
/// the request is `FullTextService.fetchCoreText(doi:apiKey:)`. Only a result whose
/// own DOI is this article's counts: the request is a search, and another article's
/// text served as this one's would be worse than none.
public enum CORE {
    /// Ways a DOI is written that name the same DOI; one is removed.
    private static let doiPrefixes = [
        "https://doi.org/", "http://doi.org/", "https://dx.doi.org/", "http://dx.doi.org/", "doi:",
    ]

    enum ParseError: Error {
        case notUTF8
        case notAnObject
        case resultsNotAList
    }

    /// CORE's search for one DOI, as a phrase query: trimmed, `\` and `"` escaped,
    /// percent-encoded as Python's `quote(s, safe="")`.
    public static func searchURL(doi: String, baseURL: String = BioMedLitConstants.coreBaseURL) -> URL? {
        let phrase = doi.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        var base = Substring(baseURL)
        while base.hasSuffix("/") { base = base.dropLast() }
        let query = OpenAlex.escaped("doi:\"\(phrase)\"")
        return URL(string: "\(base)\(BioMedLitConstants.coreSearchPath)?q=\(query)&limit=\(BioMedLitConstants.coreSearchLimit)")
    }

    /// A DOI as compared: trimmed, lower-cased, one resolver or `doi:` prefix removed.
    public static func normalisedDOI(_ doi: String) -> String {
        var text = doi.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let prefix = doiPrefixes.first(where: { text.hasPrefix($0) }) {
            text = String(text.dropFirst(prefix.count))
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The full text CORE's answer serves for this DOI, or nil; throws for an answer we cannot read.
    static func fullText(
        fromAnswer data: Data, doi: String,
        minCharacters: Int = BioMedLitConstants.coreMinFullTextCharacters
    ) throws -> String? {
        guard let body = String(data: data, encoding: .utf8) else { throw ParseError.notUTF8 }
        let object = try JSONSerialization.jsonObject(with: Data(body.utf8), options: [.fragmentsAllowed])
        return try fullText(fromAnswerObject: object, doi: doi, minCharacters: minCharacters)
    }

    /// The selection rule on a parsed answer: the first result that is an object, whose
    /// string `doi` normalises to this DOI's and whose string `fullText`, trimmed, holds at
    /// least `minCharacters` Unicode code points (not graphemes).
    static func fullText(fromAnswerObject object: Any, doi: String, minCharacters: Int) throws -> String? {
        guard let answer = object as? [String: Any] else { throw ParseError.notAnObject }
        guard let results = answer["results"] as? [Any] else { throw ParseError.resultsNotAList }
        let wanted = normalisedDOI(doi)
        guard !wanted.isEmpty else { return nil }
        for case let result as [String: Any] in results {
            guard let resultDOI = result["doi"] as? String, normalisedDOI(resultDOI) == wanted,
                  let text = result["fullText"] as? String else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.unicodeScalars.count >= minCharacters { return trimmed }
        }
        return nil
    }
}

/// What asking CORE for one DOI learned.
enum COREFetch: Equatable {
    case served(String)
    case absent
    case unreachable(RequestFailure)
}

/// CORE's session pause: two consecutive fetches ending in 429 stop CORE being asked
/// again until the process ends. Shared by every `FullTextService`, since the app builds
/// one per screen; CORE's key buys a daily budget no pacing can express.
public final class CoreThrottle: @unchecked Sendable {
    /// The pause every service in this process shares.
    public static let shared = CoreThrottle()

    private let lock = NSLock()
    private let pauseAfter: Int
    private var consecutive = 0
    private var paused = false

    public init(pauseAfter: Int = BioMedLitConstants.corePauseAfterConsecutive429) {
        self.pauseAfter = pauseAfter
    }

    /// Whether CORE is paused for the rest of the session.
    public var isPaused: Bool {
        lock.lock(); defer { lock.unlock() }
        return paused
    }

    /// Note how one fetch ended: its HTTP status, or nil when it got none.
    func record(endedOn status: Int?) {
        lock.lock(); defer { lock.unlock() }
        guard status == BioMedLitConstants.httpStatusRateLimited else {
            consecutive = 0
            return
        }
        consecutive += 1
        if consecutive >= pauseAfter { paused = true }
    }
}
```

In `OpenAlex.swift`, change `private static func escaped` to `static func escaped` and add a doc line: "Also CORE's (#480, stage C)."

In `OpenAccessShortfall.swift`:
- Add `case core = "core"` to `OpenAccessSource`, with `serviceName` `BioMedLitConstants.coreServiceName`.
- Append `.core` to `chainOrder`.
- In `namedBy`, return nil for `.core`: it names no PDF.
- Let every other exhaustive switch over `OpenAccessSource` treat `.core` as a lookup source, like `.openAlex`. The compiler lists them.

Leave `restoredEntry`'s rule alone (any stored skip is Unpaywall's): CORE is never skipped.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd Packages/BioMedLit && swift test --filter 'COREContractTests|OpenAccessShortfallContractTests|OpenAlexContractTests'`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Packages/BioMedLit
git commit -m "feat(swift): CORE's selection rule, URL and session throttle in BioMedLit (#480)

Refs #480.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Task 6: Swift — CORE in `FullTextService`

**Files:**
- Modify: `Packages/BioMedLit/Sources/BioMedLit/Services/FullTextService.swift`
- Modify: `Packages/BioMedLit/Sources/BioMedLit/Models/FullTextModels.swift`
- Modify: `Packages/BioMedLit/Tests/BioMedLitTests/FullTextServiceParseWarningsTests.swift` (`StubURLProtocol` records request headers)
- Test: `Packages/BioMedLit/Tests/BioMedLitTests/FullTextServiceCORETests.swift`

**Interfaces:**
- Consumes: Task 5's `CORE`, `COREFetch`, `CoreThrottle`, `RetryConfiguration.core` and `OpenAccessSource.core`.
- Produces:
  - `FullTextService.init(..., coreAPIKey: String? = nil, coreRetry: RetryConfiguration = .core, coreThrottle: CoreThrottle = .shared, ...)`. The new parameters go after `openAlexRetry` and before `writeCachedPDF`.
  - `public var asksCore: Bool`.
  - `FullTextSource.core` (raw `"core"`, `displayName` `"CORE (extracted text)"`).
  - `FullTextContent.core(text: String)`.

- [ ] **Step 1: Record headers in the stub**

In `StubURLProtocol`, add `static var requestedHeaders: [[String: String]] = []`, cleared in `reset()`. In `startLoading`, append `request.allHTTPHeaderFields ?? [:]` wherever `requestedURLs` is appended. Add the default fallback route `"api.core.ac.uk": (200, Data(#"{"results": []}"#.utf8))` beside OpenAlex's.

- [ ] **Step 2: Write the failing tests**

Create `FullTextServiceCORETests.swift`. Copy `FullTextServiceOpenAlexTests`' `setUp`/`tearDown`, its `ExtractingStub` use and its `makeService`. That setup makes Europe PMC, the bucket, Unpaywall and OpenAlex find nothing, and the `routes["search"]` entry is kept. Extend `makeService` with `coreAPIKey: String? = "test-core-key"` and `coreThrottle: CoreThrottle = CoreThrottle()`, passing `coreRetry: .noRetry` (the fileprivate extension there; copy it). Then:

```swift
    private let doi = "10.1159/000513404"
    private func hit(_ text: String, doi: String? = nil) -> Data {
        let object: [String: Any] = ["results": [["doi": doi ?? self.doi, "fullText": text]]]
        return try! JSONSerialization.data(withJSONObject: object)
    }
    private var longText: String { String(repeating: "x", count: BioMedLitConstants.coreMinFullTextCharacters) }

    func testCOREsTextIsTheFullTextWhenNothingElseHasIt() async throws {
        StubURLProtocol.routes["api.core.ac.uk"] = (200, hit(longText))
        let result = try await makeService().fetchFullText(pmcId: nil, doi: doi, pmid: "1")
        XCTAssertEqual(result.content, .core(text: longText))
        XCTAssertEqual(result.contentKind, .extracted)
        XCTAssertEqual(result.extractedText, longText)
        XCTAssertNil(result.openAccessShortfall)
        XCTAssertNil(result.localPDFPath)
    }

    func testTheKeyTravelsInTheHeaderAlone() async throws {
        StubURLProtocol.routes["api.core.ac.uk"] = (200, hit(longText))
        _ = try await makeService().fetchFullText(pmcId: nil, doi: doi, pmid: "1")
        let index = try XCTUnwrap(StubURLProtocol.requestedURLs.firstIndex { $0.host == "api.core.ac.uk" })
        XCTAssertEqual(StubURLProtocol.requestedHeaders[index]["Authorization"], "Bearer test-core-key")
        XCTAssertFalse(StubURLProtocol.requestedURLs[index].absoluteString.contains("test-core-key"))
    }

    func testAnotherArticlesTextIsNeverServed() async throws {
        StubURLProtocol.routes["api.core.ac.uk"] = (200, hit(longText, doi: "10.1159/999999"))
        let result = try await makeService().fetchFullText(pmcId: nil, doi: doi, pmid: "1")
        XCTAssertNotEqual(result.content.source, .core)
    }

    func testAnUnreachableCOREIsAnUnsettledLookup() async throws {
        StubURLProtocol.routes["api.core.ac.uk"] = (503, Data())
        let result = try await makeService().fetchFullText(pmcId: nil, doi: doi, pmid: "1")
        XCTAssertEqual(result.openAccessShortfall?.entries.last?.source, .core)
        XCTAssertEqual(result.openAccessShortfall?.entries.last?.reason, .failed(.httpStatus(503)))
    }

    func testTheSourceIsTheContracts() throws {
        let contract = try COREContract.load()
        XCTAssertEqual(contract["source"] as? String, FullTextSource.core.rawValue)
        XCTAssertEqual(contract["source_label"] as? String, FullTextSource.core.displayName)
    }

    func testWithoutAKeyCOREIsNeverAsked() async throws {
        _ = try await makeService(coreAPIKey: nil).fetchFullText(pmcId: nil, doi: doi, pmid: "1")
        XCTAssertFalse(StubURLProtocol.requestedURLs.contains { $0.host == "api.core.ac.uk" })
        XCTAssertFalse(makeService(coreAPIKey: "   ").asksCore)
    }

    func testCOREKnowingNothingAddsNothing() async throws {
        let result = try await makeService().fetchFullText(pmcId: nil, doi: doi, pmid: "1")
        XCTAssertFalse(result.openAccessShortfall?.entries.contains { $0.source == .core } ?? false)
    }

    func testTwo429sPauseCOREAcrossServices() async throws {
        let throttle = CoreThrottle()
        StubURLProtocol.routes["api.core.ac.uk"] = (429, Data())
        _ = try await makeService(coreThrottle: throttle).fetchFullText(pmcId: nil, doi: doi, pmid: "1")
        _ = try await makeService(coreThrottle: throttle).fetchFullText(pmcId: nil, doi: doi, pmid: "2")
        let before = StubURLProtocol.requestedURLs.filter { $0.host == "api.core.ac.uk" }.count
        let third = try await makeService(coreThrottle: throttle).fetchFullText(pmcId: nil, doi: doi, pmid: "3")
        XCTAssertEqual(StubURLProtocol.requestedURLs.filter { $0.host == "api.core.ac.uk" }.count, before)
        XCTAssertEqual(third.openAccessShortfall?.entries.last?.reason, .failed(.httpStatus(429)))
    }

    func testACopyServedButNotCachedMeansCOREIsNotAsked() async throws {
        // Copy FullTextServiceOpenAlexTests' "served but not cached" setup: an Unpaywall
        // PDF route answering %PDF and a `writeCachedPDF` that throws.
        StubURLProtocol.routes["api.core.ac.uk"] = (200, hit(longText))
        // ... that setup, then:
        // XCTAssertFalse(StubURLProtocol.requestedURLs.contains { $0.host == "api.core.ac.uk" })
    }

    func testCOREsTextWinsOverAHeldAbstract() async throws {
        // Copy FullTextServicePMCOpenDataTests' body-less Europe PMC deposit route
        // (the abstract-only XML), then:
        StubURLProtocol.routes["api.core.ac.uk"] = (200, hit(longText))
        // let result = try await makeService().fetchFullText(pmcId: "PMC1", doi: doi, pmid: "1")
        // XCTAssertEqual(result.content, .core(text: longText))
    }

    func testRequestsArePaced() async throws {
        // Copy FullTextServiceOpenAlexTests.testRequestsArePaced, with routes on
        // api.core.ac.uk answering 503 then 200 under `coreRetry: .oneRetry`, and assert
        // the two CORE requests are at least BioMedLitConstants.coreMinimumInterval apart.
    }
```

The last three tests depend on setups that exist verbatim in the named sibling files. **Complete them by copying those setups**: each comment names the file and test whose arrange step to copy. The assertions are given. Keep the test names.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `cd Packages/BioMedLit && swift test --filter FullTextServiceCORETests`
Expected: compile failure, `extra argument 'coreAPIKey' in call`.

- [ ] **Step 4: Implement**

`FullTextModels.swift`:
- `FullTextSource` gains `case core = "core"`; `displayName` `"CORE (extracted text)"`.
- `FullTextContent` gains `case core(text: String)`. Its accessors:
  - `source` → `.core`;
  - `html`, `markdown`, `pdfURL` and `webURL` → nil.
- In `FullTextResult.init`'s asserts (`:301-395`):
  - change `extractedText == nil || extractionCoverage != nil` to `extractedText == nil || extractionCoverage != nil || content.source == .core`;
  - add `content.source != .core || (contentKind == .extracted && extractedText != nil && localPDFPath == nil && openAccessShortfall == nil)`, with the message "CORE's text is extracted text, with no PDF and no shortfall".

`FullTextService.swift`:
- Stored properties: `private let coreAPIKey: String?` (the init argument trimmed, nil when empty), `private let coreRetry: RetryConfiguration` and `private let coreThrottle: CoreThrottle`. Add `public var asksCore: Bool { coreAPIKey != nil }`.
- `PacedHost` gains `case core`, whose `minimumInterval` is `BioMedLitConstants.coreMinimumInterval`.
- `pacedAttempt(_ url: URL, host: PacedHost, headers: [String: String] = [:])`: after building the `URLRequest`, `for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }`. Existing callers are unchanged.
- Add, beside `fetchOpenAlexPDFURLs`:

```swift
    /// CORE's extracted text for a DOI (#480, stage C). The key travels in the
    /// `Authorization` header alone. A fetch ending in 429 counts towards the session
    /// pause; any other ending resets it.
    func fetchCoreText(doi: String, apiKey: String) async throws -> COREFetch {
        guard !doi.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .absent }
        if coreThrottle.isPaused { return .unreachable(.httpStatus(BioMedLitConstants.httpStatusRateLimited)) }
        guard let url = CORE.searchURL(doi: doi) else { return .unreachable(.requestFailed) }
        let headers = ["Authorization": "Bearer \(apiKey)", "Accept": "application/json"]
        do {
            let (status, body) = try await RetryHelper.retry(
                config: coreRetry, shouldRetry: RetryHelper.retryOnlyTransient
            ) { try await self.pacedAttempt(url, host: .core, headers: headers) }
            coreThrottle.record(endedOn: status)
            guard status == BioMedLitConstants.httpStatusOK else { return .unreachable(.httpStatus(status)) }
            do {
                if let text = try CORE.fullText(fromAnswer: body, doi: doi) { return .served(text) }
                return .absent
            } catch {
                return .unreachable(.malformedResponse)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch FullTextError.serverError(let statusCode) {
            coreThrottle.record(endedOn: statusCode)
            return .unreachable(.httpStatus(statusCode))
        } catch {
            coreThrottle.record(endedOn: nil)
            return .unreachable(SearchTransport.failure(for: error))
        }
    }
```

  Copy any further `catch` clause `fetchOpenAlexPDFURLs` has (`:1210-1249`, e.g. `FullTextError.invalidResponse` → `.malformedResponse`) before the final `catch`, with `coreThrottle.record(endedOn: nil)` added to each.
- In `fetchFullText`, after the OpenAlex block (`:633-666`) and before `settledOpenAccessShortfall` (`:668`), inside the same DOI block, using the same DOI variable the OpenAlex call uses:

```swift
            // CORE's extracted text (#480, stage C): the poorest form, so last, only with
            // the user's key and only when no copy was served. A failure is an unsettled
            // lookup, as OpenAlex's is (the maintainer's decision, 2026-10-06).
            if openAccessNotSavedFrom == nil, let coreAPIKey {
                switch try await fetchCoreText(doi: doi, apiKey: coreAPIKey) {
                case .served(let text):
                    return FullTextResult(
                        content: .core(text: text), warnings: [], degradation: degradation,
                        contentKind: .extracted, extractedText: text, localPDFPath: nil,
                        extractionCoverage: nil, openAccessShortfall: nil, pdfNotSavedFrom: nil
                    )
                case .absent:
                    break
                case .unreachable(let failure):
                    openAccessShortfall = .adding(
                        OpenAccessShortfall(source: .core, failure: failure), to: openAccessShortfall
                    )
                }
            }
```

  Match `FullTextResult.init`'s real parameter list (`FullTextModels.swift:301`) and the `warnings` the other returns in this function pass, e.g. the bucket's.
- `exhaustedChainError` needs no change: a CORE shortfall rides in `openAccessShortfall`. Since CORE needs a DOI, the DOI link fallback always exists after it.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd Packages/BioMedLit && swift test`
Expected: 0 failures (the whole package: exhaustive switches over `FullTextSource`/`FullTextContent` must compile).

- [ ] **Step 6: Commit**

```bash
git add Packages/BioMedLit
git commit -m "feat(swift): CORE's extracted text after OpenAlex, with the user's key (#480)

Refs #480.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Task 7: Swift app — CORE's source, storage and the key setting

**Files:**
- Modify: `ios/MedicalFactChecker/Sources/Models/FullTextSource.swift`, `Sources/Utilities/BioMedLitAdapters.swift`, `Sources/Views/Components/FullTextSourceBadge.swift`, `Sources/macOS/MacConstants.swift`
- Modify: `ios/MedicalFactChecker/Sources/Models/AppSettings.swift`, `Sources/Views/Settings/SettingsView.swift`, `Sources/macOS/Views/Settings/MacSettingsView.swift`
- Test: `ios/MedicalFactChecker/Tests/CoreTextDocumentTests.swift`

**Interfaces:**
- Consumes: Task 6's `FullTextSource.core`, `FullTextContent.core(text:)` and `asksCore`.
- Produces:
  - `AppFullTextSource.core` (raw `"core"`).
  - `AppSettings.coreAPIKey: String` (Keychain `core_api_key`).
  - `BMLFullTextService.create(ncbiEmail: String, coreAPIKey: String) -> BMLFullTextService`. `create(from:)` calls it.

- [ ] **Step 1: Write the failing tests**

Create `CoreTextDocumentTests.swift`, following an existing test in `ios/MedicalFactChecker/Tests/` that builds a `Document` in an in-memory `ModelContainer` (e.g. `FullTextSourceDisplayTests.swift`):

```swift
import XCTest
@testable import MedicalFactChecker
import BioMedLit

final class CoreTextDocumentTests: XCTestCase {
    private let text = String(repeating: "x", count: 5000)

    private var coreResult: BioMedLit.FullTextResult {
        BioMedLit.FullTextResult(
            content: .core(text: text), warnings: [], degradation: nil,
            contentKind: .extracted, extractedText: text, localPDFPath: nil,
            extractionCoverage: nil, openAccessShortfall: nil, pdfNotSavedFrom: nil
        )
    }

    func testTheSourceIsTheContracts() {
        XCTAssertEqual(AppFullTextSource.core.rawValue, "core")
        XCTAssertEqual(AppFullTextSource.core.displayName, "CORE (extracted text)")
        XCTAssertTrue(AppFullTextSource.core.canDisplayInApp)
        XCTAssertEqual(AppFullTextSource(rawValue: "core"), .core)
    }

    func testCOREsTextReachesTheAppAsPlainContent() {
        let app = coreResult.toAppFullTextResult()
        XCTAssertEqual(app.source, .core)
        XCTAssertEqual(app.content, .markdown(text))
        XCTAssertEqual(app.contentKind, .extracted)
    }

    func testAStoredCORETextIsShownAndAnalysed() throws {
        let document = makeDocument()
        document.applyFullTextResult(coreResult.toAppFullTextResult())
        XCTAssertEqual(document.fullTextContent, text)
        XCTAssertEqual(document.fullTextSource, "core")
        XCTAssertNil(document.fullTextPDFPath)
        XCTAssertNil(document.fullTextOpenAccessShortfallJSON)
        XCTAssertEqual(document.displayedFullText, .markdown(text))
        XCTAssertEqual(document.analyzableFullText, text)
    }

    func testTheKeyReachesTheService() {
        XCTAssertTrue(BMLFullTextService.create(ncbiEmail: "", coreAPIKey: "k").asksCore)
        XCTAssertFalse(BMLFullTextService.create(ncbiEmail: "", coreAPIKey: "  ").asksCore)
    }
}
```

Use the real names in the app: the adapter method (`BioMedLitAdapters.swift:440`), `applyFullTextResult` (`Document.swift:961`) and `displayedFullText`'s case names (`Document.swift:1111`). Write `makeDocument()` as that sibling test does. If a name differs, keep the assertion and change the call.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd ios/MedicalFactChecker && swift test --filter CoreTextDocumentTests`
Expected: compile failure, `type 'AppFullTextSource' has no member 'core'`.

- [ ] **Step 3: Implement**

`FullTextSource.swift`, `AppFullTextSource`:
- `case core = "core"`, with doc comment "CORE's extracted text (#480, stage C)."
- `displayName` → `"CORE (extracted text)"`.
- `iconName` → `"text.alignleft"`.
- `canDisplayInApp` → true (add to the first list).
- Update the doc comment on `canDisplayInApp`.

`BioMedLitAdapters.swift`:
- `content(of:localPDFPath:)`: `case .core(let text): return .markdown(text)`.
- `appSource(of:)`: `.core → .core`.
- Replace `create(from:)` with:

```swift
    static func create(from settings: AppSettings) -> BMLFullTextService {
        create(ncbiEmail: settings.ncbiEmail, coreAPIKey: settings.coreAPIKey)
    }

    /// The service for these settings: the NCBI email (or the app's own address) and,
    /// when one is set, the user's CORE key (#480, stage C).
    static func create(ncbiEmail: String, coreAPIKey: String) -> BMLFullTextService {
        let email = ncbiEmail.isEmpty ? "user@medicalfactchecker.app" : ncbiEmail
        let key = coreAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return BMLFullTextService(email: email, coreAPIKey: key.isEmpty ? nil : key)
    }
```

`FullTextSourceBadge.swift`: `case .core: return .teal`, and add `.core` to the preview. `MacConstants.swift`: `case .core: return unpaywallTint`.

`AppSettings.swift`: copy the `ncbiAPIKey` pattern (`:115-133`) as `coreAPIKey`, with `_coreAPIKeyCache` and `Keys.coreAPIKey = "core_api_key"`. `resetToDefaults()` sets `coreAPIKey = ""`.

`SettingsView.swift` (iOS), in the Full Text section (`:370-377`), after the auto-fetch toggle:

```swift
                SecureField("CORE API Key (optional)", text: $coreAPIKey)
                    .textContentType(.password)
                Button("Save CORE API Key") {
                    settings.coreAPIKey = coreAPIKey
                    showingSaveConfirmation = true
                }
                .disabled(coreAPIKey == settings.coreAPIKey)
```

Also in `SettingsView.swift`:
- Put the explanation sentence (Global Constraints, verbatim) in that section's footer, appended to any existing footer text.
- Add `@State private var coreAPIKey = ""`, loaded in `loadCurrentValues()`.
- The disabled test allows saving an empty field, which clears the key.

`MacSettingsView.swift`, `PubMedSettingsTab`: add `Section("CORE API Key (Optional)")`, mirroring its NCBI section:
- a `SecureField("CORE API Key", text: $coreAPIKey)`;
- a Save button (`settings.coreAPIKey = coreAPIKey`) and a "Get API Key" button opening `https://core.ac.uk/services/api`;
- the explanation as a `Text(...).font(.caption).foregroundStyle(.secondary)`.

Load it in its `.onAppear`.

- [ ] **Step 4: Run the tests and both builds**

Run, chained in one background job (per the swift-build-hang memory):

```bash
cd ios/MedicalFactChecker && swift test && \
xcodebuild -scheme MedicalFactChecker -destination 'platform=macOS' build -quiet && \
xcodebuild -scheme MedicalFactChecker -destination 'platform=iOS Simulator,name=iPhone 16' build -quiet
```

Expected: 0 test failures; both builds succeed. `SettingsView` is iOS-only code that `swift test` does not compile, so the simulator build is the only gate on it. If `iPhone 16` is not installed, pick one from `xcrun simctl list devices available`.

- [ ] **Step 5: Commit**

```bash
git add ios/MedicalFactChecker
git commit -m "feat(apple): CORE's text shown and analysed; a CORE key in the settings (#480)

Refs #480.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Task 8: Kotlin — CORE's pure rules and the service

**Files:**
- Create: `main/data/remote/fulltext/Core.kt`
- Modify: `main/util/Constants.kt`, `main/domain/model/OpenAccessShortfall.kt`, `main/data/repository/SettingsRepository.kt` (`getCoreApiKey`/`saveCoreApiKey`)
- Test: `test/data/remote/fulltext/CoreContractTest.kt`, `CoreServiceTest.kt`, `CoreTestDoubles.kt`

**Interfaces:**
- Produces:
  - `object Core`, with:
    - `fun searchUrl(doi: String, baseUrl: String = Constants.CORE_BASE_URL): String`
    - `fun normalisedDoi(doi: String): String`
    - `fun fullText(json: String, doi: String, minChars: Int = Constants.CORE_MIN_FULLTEXT_CHARS): String?`
    - `fun fullText(answer: JsonElement, doi: String, minChars: Int): String?`

    Both `fullText` functions throw `IllegalArgumentException` for an unreadable answer.
  - `sealed interface CoreFetch { data class Served(val text: String); data object Absent; data class Unreachable(val failure: RequestFailure) }`
  - `@Singleton class CoreService`, with:
    - `suspend fun fetchText(doi: String): CoreFetch?`, which returns null when no key is set;
    - `val isPaused: Boolean`.
  - `OpenAccessSource.CORE("core", Constants.CORE_SERVICE_NAME)`, last in `CHAIN_ORDER`.
  - `SettingsRepository.getCoreApiKey(): String` and `saveCoreApiKey(apiKey: String)`.
  - Test double `absentCore(): CoreService`.

- [ ] **Step 1: Add the constants**

In `Constants.kt`, after the OpenAlex block:

```kotlin
    /** CORE's API root (#480, stage C); pinned by fulltext_parity/core_fulltext.json. */
    const val CORE_BASE_URL = "https://api.core.ac.uk"
    /** The search path; its trailing slash matters (without it CORE answers an HTML page). */
    const val CORE_SEARCH_PATH = "/v3/search/works/"
    /** Results asked for: a DOI query can match more than one record. */
    const val CORE_SEARCH_LIMIT = 3
    /** CORE as the reader's sentences name it, verbatim on every platform. */
    const val CORE_SERVICE_NAME = "CORE"
    /** The fewest Unicode code points CORE's text holds to count as a full text. */
    const val CORE_MIN_FULLTEXT_CHARS = 5000
    /** Consecutive fetches ending in 429 after which CORE is not asked again this session. */
    const val CORE_PAUSE_AFTER_CONSECUTIVE_429 = 2
    /** 0.4 requests a second, Python's POLITE_RATE_CEILINGS entry. */
    const val CORE_MIN_INTERVAL_MS = 2500L
    /** Further attempts after the first, for a transport failure or a retryable status. */
    const val CORE_MAX_RETRIES = 3
    /** CORE's wait before its first retry, doubling after; the bucket's value. */
    const val CORE_INITIAL_BACKOFF_MS = PMC_OPEN_DATA_INITIAL_BACKOFF_MS
    /** Connect and read timeout for one CORE request, in seconds. */
    const val CORE_REQUEST_TIMEOUT_SECONDS = 30L
    /** Statuses retried for CORE: Python's RETRYABLE_HTTP_STATUSES. */
    val CORE_RETRYABLE_STATUSES = setOf(429, 500, 502, 503, 504)
    /** The settings screen's one line on what a CORE key adds. */
    const val CORE_API_KEY_EXPLANATION =
        "Optional. A free CORE API key (core.ac.uk/services/api) lets the app read the text CORE extracted from repository copies when no other source has the article."
```

In the Full-Text Source block, add `const val FULLTEXT_SOURCE_CORE = "core"` and `const val FULLTEXT_SOURCE_CORE_LABEL = "CORE (extracted text)"`.

- [ ] **Step 2: Write the failing tests**

`CoreTestDoubles.kt`:

```kotlin
package com.bmlibrarian.factchecker.data.remote.fulltext

import io.mockk.coEvery
import io.mockk.every
import io.mockk.mockk

/** CORE with no key: never asked, as for a user without one. A relaxed mock returns null too, but say it. */
internal fun absentCore(): CoreService = mockk {
    coEvery { fetchText(any()) } returns null
    every { isPaused } returns false
}
```

`CoreContractTest.kt`: copy `OpenAlexContractTest`'s `contractFile()` walk and `table(name, minimum)` helper, pointing at `core_fulltext.json`. Then:

```kotlin
    @Test fun `every contract table is read here`() {
        assertEquals(
            setOf("schema_version", "description", "service_name", "source", "source_label",
                "desktop_source_type", "base_url", "min_fulltext_chars",
                "pause_after_consecutive_429", "search_url", "full_text", "status", "bodies"),
            contract.keys
        )
    }

    @Test fun `the names are the contract's`() {
        assertEquals(Constants.CORE_SERVICE_NAME, contract.string("service_name"))
        assertEquals(Constants.FULLTEXT_SOURCE_CORE, contract.string("source"))
        assertEquals(OpenAccessSource.CORE.persistedValue, contract.string("source"))
        assertEquals(Constants.FULLTEXT_SOURCE_CORE_LABEL, contract.string("source_label"))
        assertEquals(Constants.CORE_BASE_URL, contract.string("base_url"))
        assertEquals(Constants.CORE_MIN_FULLTEXT_CHARS, contract["min_fulltext_chars"]!!.jsonPrimitive.int)
        assertEquals(Constants.CORE_PAUSE_AFTER_CONSECUTIVE_429, contract["pause_after_consecutive_429"]!!.jsonPrimitive.int)
    }

    @Test fun `each search_url row`() {
        for (row in table("search_url", 7)) {
            val base = row["base_url"]?.jsonPrimitive?.contentOrNull ?: Constants.CORE_BASE_URL
            assertEquals(row.string("name"), row.string("url"), Core.searchUrl(row.string("doi"), base))
        }
    }

    @Test fun `each full_text row`() {
        for (row in table("full_text", 24)) {
            val name = row.string("name")
            val min = row["min_chars"]!!.jsonPrimitive.int
            val answer = row["answer"]!!
            if (row.string("outcome") == "malformed") {
                assertThrows(name, IllegalArgumentException::class.java) {
                    Core.fullText(answer, row.string("doi"), min)
                }
            } else {
                assertEquals(name, row["text"]?.jsonPrimitive?.contentOrNull, Core.fullText(answer, row.string("doi"), min))
            }
        }
    }

    @Test fun `each unreadable body throws`() {
        for (row in table("bodies", 4)) {
            assertThrows(row.string("name"), IllegalArgumentException::class.java) {
                Core.fullText(row.string("body"), "10.1/x")
            }
        }
    }

    @Test fun `CORE is last in chain order`() {
        assertEquals(OpenAccessSource.CORE, OpenAccessShortfall.CHAIN_ORDER.last())
    }
```

Here `row.string(key)` is `this[key]!!.jsonPrimitive.content`, written as a private extension in the file. If `CHAIN_ORDER` is private, make it `internal`.

`CoreServiceTest.kt`: copy `OpenAlexServiceTest`'s MockWebServer setup (`:51-80`). Its `service(...)` builds the internal constructor: `CoreService(PmcOpenDataService.bucketClient(OkHttpClient(), 5L), server.url("").toString().trimEnd('/'), { key }, RequestPacer(0L), maxRetries = 0, initialBackoffMs = 0L)` with `var key: String? = "test-core-key"`. Route on `encodedPath` `/v3/search/works/`. Tests:

```kotlin
    @Test fun `every status row of the fixture gets its outcome`()      // 200 → Served(hit), else Unreachable(forHttpStatus(code)); 404 included
    @Test fun `an answer we cannot read is malformed`()                  // each `bodies` row → Unreachable(MALFORMED_RESPONSE)
    @Test fun `a body that is not UTF-8 is malformed`()                  // bytes 7B FF 7D
    @Test fun `the key travels in the header alone`()                   // takeRequest().getHeader("Authorization") == "Bearer test-core-key"; requestUrl has no key; Log.lines has no key
    @Test fun `without a key nothing is asked`()                        // key = null and key = "  " → fetchText returns null; server.requestCount == 0
    @Test fun `a blank DOI is never asked`()                            // Absent, requestCount 0
    @Test fun `two 429s in a row pause CORE for the session`()          // 429, 429, then third returns Unreachable(429) with requestCount still 2; isPaused true
    @Test fun `another answer between 429s resets the count`()          // 429, 200 hit, 429 → not paused
    @Test fun `no server is unreachable`()                              // server.shutdown() first → Unreachable(CONNECTION)
    @Test fun `cancellation still propagates`()                         // copy OpenAlex's interceptor test
    @Test fun `every attempt takes a pacer slot`()                      // copy OpenAlex's pacer test
```

Write each body as its `OpenAlexServiceTest` counterpart, with the assertion named in the comment. The hit body is `{"results":[{"doi":"10.1159/000513404","fullText":"<5000 x>"}]}`, built with `"x".repeat(Constants.CORE_MIN_FULLTEXT_CHARS)`.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `cd android/MedicalFactChecker && ./gradlew testDebugUnitTest --tests '*Core*'`
Expected: compile failure, `Unresolved reference: Core`.

- [ ] **Step 4: Implement `Core.kt`**

```kotlin
package com.bmlibrarian.factchecker.data.remote.fulltext

import android.util.Log
import com.bmlibrarian.factchecker.data.remote.transparency.RequestPacer
import com.bmlibrarian.factchecker.data.repository.SettingsRepository
import com.bmlibrarian.factchecker.domain.model.RequestFailure
import com.bmlibrarian.factchecker.domain.model.RequestFailureKind
import com.bmlibrarian.factchecker.util.Constants
import com.bmlibrarian.factchecker.util.NetworkRetry
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.IOException
import javax.inject.Inject
import javax.inject.Singleton

/**
 * CORE's extracted text, asked by DOI with the user's own key (#480, stage C).
 *
 * The pure rules, pinned by doc/cross_platform/fulltext_parity/core_fulltext.json. Only a
 * result whose own DOI is this article's counts: the request is a search, and another
 * article's text served as this one's would be worse than none.
 */
object Core {
    private val doiPrefixes = listOf(
        "https://doi.org/", "http://doi.org/", "https://dx.doi.org/", "http://dx.doi.org/", "doi:"
    )

    /** CORE's search for one DOI, as a phrase query; escaped as OpenAlex's. */
    fun searchUrl(doi: String, baseUrl: String = Constants.CORE_BASE_URL): String {
        val phrase = doi.trim().replace("\\", "\\\\").replace("\"", "\\\"")
        val query = OpenAlex.escaped("doi:\"$phrase\"")
        return "${baseUrl.trimEnd('/')}${Constants.CORE_SEARCH_PATH}?q=$query&limit=${Constants.CORE_SEARCH_LIMIT}"
    }

    /** A DOI as compared: trimmed, lower-cased, one resolver or `doi:` prefix removed. */
    fun normalisedDoi(doi: String): String {
        var text = doi.trim().lowercase()
        doiPrefixes.firstOrNull { text.startsWith(it) }?.let { text = text.removePrefix(it) }
        return text.trim()
    }

    /** The full text CORE's answer serves for this DOI, or null. @throws IllegalArgumentException for an unreadable answer. */
    fun fullText(json: String, doi: String, minChars: Int = Constants.CORE_MIN_FULLTEXT_CHARS): String? {
        val answer = try {
            Json.parseToJsonElement(json)
        } catch (e: kotlinx.serialization.SerializationException) {
            throw IllegalArgumentException("CORE's answer is not JSON", e)
        }
        return fullText(answer, doi, minChars)
    }

    /**
     * The first result that is an object, whose string `doi` normalises to this DOI's and whose
     * string `fullText`, trimmed, holds at least [minChars] Unicode code points.
     */
    fun fullText(answer: JsonElement, doi: String, minChars: Int): String? {
        val results = (answer as? JsonObject ?: throw IllegalArgumentException("CORE's answer is not an object"))["results"]
            as? JsonArray ?: throw IllegalArgumentException("CORE's answer holds no list of results")
        val wanted = normalisedDoi(doi)
        if (wanted.isEmpty()) return null
        for (result in results) {
            val record = result as? JsonObject ?: continue
            val resultDoi = (record["doi"] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: continue
            if (normalisedDoi(resultDoi) != wanted) continue
            val text = (record["fullText"] as? JsonPrimitive)?.takeIf { it.isString }?.content?.trim() ?: continue
            if (text.codePointCount(0, text.length) >= minChars) return text
        }
        return null
    }
}

/** What asking CORE for one DOI learned. */
sealed interface CoreFetch {
    data class Served(val text: String) : CoreFetch
    data object Absent : CoreFetch
    data class Unreachable(val failure: RequestFailure) : CoreFetch
}

/**
 * Asks CORE's search for a DOI's extracted text, with the user's key in the
 * `Authorization` header alone. A singleton, so its session pause is the process's:
 * two consecutive fetches ending in 429 stop CORE being asked until the app restarts.
 */
@Singleton
class CoreService internal constructor(
    private val httpClient: OkHttpClient,
    private val baseUrl: String,
    private val apiKey: () -> String?,
    private val pacer: RequestPacer,
    private val maxRetries: Int,
    private val initialBackoffMs: Long,
    private val pauseAfter: Int = Constants.CORE_PAUSE_AFTER_CONSECUTIVE_429
) {
    @Inject
    constructor(httpClient: OkHttpClient, settingsRepository: SettingsRepository) : this(
        PmcOpenDataService.bucketClient(httpClient, Constants.CORE_REQUEST_TIMEOUT_SECONDS),
        Constants.CORE_BASE_URL,
        { settingsRepository.getCoreApiKey().trim().takeIf { it.isNotEmpty() } },
        RequestPacer(Constants.CORE_MIN_INTERVAL_MS),
        Constants.CORE_MAX_RETRIES,
        Constants.CORE_INITIAL_BACKOFF_MS
    )

    private val throttleLock = Any()
    private var consecutive429 = 0
    @Volatile private var paused = false

    /** Whether CORE is paused for the rest of the session. */
    val isPaused: Boolean get() = paused

    /** CORE's text for [doi]; null when no key is set, in which case nothing is asked or recorded. */
    suspend fun fetchText(doi: String): CoreFetch? {
        val key = apiKey() ?: return null
        if (doi.isBlank()) return CoreFetch.Absent
        if (paused) return CoreFetch.Unreachable(RequestFailure.forHttpStatus(Constants.HTTP_TOO_MANY_REQUESTS))
        val url = Core.searchUrl(doi, baseUrl).toHttpUrlOrNull()
            ?: return CoreFetch.Unreachable(RequestFailure(RequestFailureKind.REQUEST_FAILED))
        return try {
            val (code, bytes) = get(Request.Builder().url(url)
                .header("Accept", "application/json")
                .header("Authorization", "Bearer $key")
                .build())
            record(code)
            if (code != Constants.HTTP_OK) return CoreFetch.Unreachable(RequestFailure.forHttpStatus(code))
            val body = bytes.strictUtf8() ?: return malformed(null)
            try {
                Core.fullText(body, doi)?.let { CoreFetch.Served(it) } ?: CoreFetch.Absent
            } catch (e: IllegalArgumentException) {
                malformed(e)
            }
        } catch (e: RetryableStatusException) {
            record(e.statusCode)
            CoreFetch.Unreachable(RequestFailure.forHttpStatus(e.statusCode))
        } catch (e: CancellationException) {
            throw e
        } catch (e: IOException) {
            record(null)
            CoreFetch.Unreachable(RequestFailure.fromException(e))
        } catch (e: Exception) {
            record(null)
            Log.e(TAG, "CORE could not be asked: ${e.javaClass.simpleName}")
            CoreFetch.Unreachable(RequestFailure(RequestFailureKind.REQUEST_FAILED))
        }
    }

    private fun record(status: Int?) {
        synchronized(throttleLock) {
            if (status != Constants.HTTP_TOO_MANY_REQUESTS) {
                consecutive429 = 0
                return
            }
            consecutive429 += 1
            if (consecutive429 >= pauseAfter && !paused) {
                paused = true
                Log.w(TAG, "CORE answered HTTP 429 $consecutive429 times in a row; not asked again this session")
            }
        }
    }

    private fun malformed(cause: Throwable?): CoreFetch {
        Log.w(TAG, "CORE's answer could not be read: ${cause?.javaClass?.simpleName ?: "not UTF-8"}")
        return CoreFetch.Unreachable(RequestFailure(RequestFailureKind.MALFORMED_RESPONSE))
    }

    private suspend fun get(request: Request): Pair<Int, ByteArray> = NetworkRetry.withExponentialBackoff(
        maxRetries = maxRetries,
        initialDelayMs = initialBackoffMs,
        shouldRetry = { NetworkRetry.isRetryableException(it) }
    ) {
        pacer.awaitTurn() // every attempt takes its own slot
        withContext(Dispatchers.IO) {
            httpClient.newCall(request).execute().use { response ->
                if (response.code in Constants.CORE_RETRYABLE_STATUSES) {
                    throw RetryableStatusException(response.code)
                }
                response.code to (response.body?.bytes() ?: ByteArray(0))
            }
        }
    }

    private companion object {
        const val TAG = "CoreService"
    }
}
```

Constants and functions to check:
- `Constants.HTTP_OK` and `Constants.HTTP_TOO_MANY_REQUESTS`: if either is missing, add it beside `HTTP_NOT_FOUND` (`= 200`, `= 429`).
- `OpenAlex.escaped`: make `OpenAlex.kt`'s private `escaped` `internal`.
- `strictUtf8` is `internal` in `PmcOpenData.kt:40`; it is reachable from the same package.

`OpenAccessShortfall.kt`:
- `OpenAccessSource` gains `CORE("core", Constants.CORE_SERVICE_NAME)`.
- `CHAIN_ORDER` gains `OpenAccessSource.CORE` last.
- Any exhaustive `when` over `OpenAccessSource` treats `CORE` as a lookup source (the compiler lists them).

`SettingsRepository.kt`:
- Add `KEY_CORE_API_KEY = "core_api_key"`.
- `fun getCoreApiKey(): String` and `fun saveCoreApiKey(apiKey: String)`, mirroring `getNcbiApiKey`/`saveNcbiApiKey` (`:269-285`, encrypted prefs plus the cache).
- `resetToDefaults()` already clears both stores and the cache.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd android/MedicalFactChecker && ./gradlew testDebugUnitTest --tests '*Core*' --tests '*OpenAccessShortfall*' --tests '*OpenAlex*'`
Expected: PASS. `OpenAccessShortfallContractTest` now reads the `core` notice and persisted rows (Task 1).

- [ ] **Step 6: Commit**

```bash
git add android/MedicalFactChecker
git commit -m "feat(android): CORE's selection rule and service, paused per session (#480)

Refs #480.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Task 9: Kotlin — CORE in the chain, its display and the key setting

**Files:**
- Modify: `main/data/remote/fulltext/FullTextService.kt` (constructor, `FullTextResult.CoreText`, chain step, `askCore`, `getSourceConstant`)
- Modify: `main/data/remote/fulltext/FullTextRecording.kt` (`askCore` hook, `recording` branch)
- Modify: `main/di/NetworkModule.kt` (`provideFullTextService` gains `coreService: CoreService`)
- Modify: `main/data/local/entity/DocumentEntity.kt` (`fullTextSourceDisplay`), `main/ui/fulltext/components/FullTextSourceBadge.kt`
- Modify: `main/ui/fulltext/FullTextViewModel.kt`, `main/ui/fulltext/FullTextScreen.kt` (plain-text state)
- Modify: `main/ui/factcheck/FactCheckViewModel.kt`, `main/ui/report/ReportViewModel.kt`, `main/ui/fulltext/FullTextViewModel.kt` (pass `askCore`)
- Modify: `main/ui/settings/SettingsViewModel.kt`, `main/ui/settings/SettingsScreen.kt`
- Modify tests that construct `FullTextService` (five files, each gains `core = absentCore()`) or call `recordingFullTextFetch` (each gains `askCore = { null }`)
- Test: `test/data/remote/fulltext/FullTextServiceCoreTest.kt`; additions to `OpenAccessStepsRecordingTest.kt`, `FullTextViewModel*Test.kt`, `SettingsViewModel*Test.kt`

**Interfaces:**
- Consumes: Task 8's `CoreService`, `CoreFetch`, `OpenAccessSource.CORE` and the settings repository methods.
- Produces:
  - `FullTextResult.CoreText(val text: String) : FullTextResult(hasContent = true)`.
  - `FullTextService.askCore(doi: String): CoreFetch?`.
  - `recordingFullTextFetch(result, downloadPdf, askOpenAlex, askCore: suspend (doi: String) -> CoreFetch?)`.
  - `FullTextState.PlainTextContent(val text: String, val title: String, val source: String)`.
  - The settings VM's `coreApiKeyInput`, `updateCoreApiKeyInput` and `saveCoreApiKey()`.

- [ ] **Step 1: Write the failing tests**

`FullTextServiceCoreTest.kt`: copy `FullTextServiceOpenAlexTest`'s setup (`:66`), whose service is built with `openAlex = absentOpenAlex()`, now plus `core = core`, where `var core: CoreService = absentCore()`. Use its Unpaywall mock answering "no location" so no candidate exists.

```kotlin
    private val doi = "10.1159/000513404"
    private val text = "x".repeat(Constants.CORE_MIN_FULLTEXT_CHARS)

    private fun coreAnswering(fetch: CoreFetch?): CoreService = mockk {
        coEvery { fetchText(any()) } returns fetch
    }

    @Test fun `with no open-access candidate, CORE's text is the result`() = runTest {
        core = coreAnswering(CoreFetch.Served(text))
        val result = service().fetchFullText(null, doi, "1").getOrThrow()
        assertEquals(FullTextResult.CoreText(text), result)
    }

    @Test fun `an unreachable CORE is told on the DOI link, last`() = runTest {
        core = coreAnswering(CoreFetch.Unreachable(RequestFailure.forHttpStatus(503)))
        val result = service().fetchFullText(null, doi, "1").getOrThrow() as FullTextResult.DoiUrl
        assertEquals(OpenAccessSource.CORE, result.openAccessShortfall!!.entries.last().source)
    }

    @Test fun `CORE knowing nothing adds nothing`() = runTest {
        core = coreAnswering(CoreFetch.Absent)
        val result = service().fetchFullText(null, doi, "1").getOrThrow() as FullTextResult.DoiUrl
        assertTrue(result.openAccessShortfall?.entries.orEmpty().none { it.source == OpenAccessSource.CORE })
    }

    @Test fun `without a key nothing is recorded`() = runTest {
        core = coreAnswering(null)
        val result = service().fetchFullText(null, doi, "1").getOrThrow() as FullTextResult.DoiUrl
        assertTrue(result.openAccessShortfall?.entries.orEmpty().none { it.source == OpenAccessSource.CORE })
    }

    @Test fun `with candidates in hand, CORE is not asked by the service`() = runTest {
        // Copy FullTextServiceOpenAlexTest's "with Unpaywall's candidates in hand" arrange step.
        core = coreAnswering(CoreFetch.Served(text))
        // val result = service().fetchFullText(null, doi, "1").getOrThrow()
        // assertTrue(result is FullTextResult.OpenAccessPdfs)
        // coVerify(exactly = 0) { core.fetchText(any()) }
    }

    @Test fun `no DOI, no CORE`() = runTest {
        core = coreAnswering(CoreFetch.Served(text))
        service().fetchFullText(null, null, "1")
        coVerify(exactly = 0) { core.fetchText(any()) }
    }

    @Test fun `a CORE text is recorded as CORE's, plain, with no shortfall`() = runTest {
        // Copy FullTextRecordingTest's entity fixture; then:
        // val recorded = entity.recordingFullTextFetch(FullTextResult.CoreText(text), { error("no PDF") }, { _, _ -> emptyList() }, { null })
        // assertEquals(text, recorded.document.fullTextMarkdown)
        // assertNull(recorded.document.fullTextHTML)
        // assertEquals(Constants.FULLTEXT_SOURCE_CORE, recorded.document.fullTextSource)
        // assertNull(recorded.document.fullTextOpenAccessShortfallJson)
        // assertEquals(Constants.FULLTEXT_SOURCE_CORE_LABEL, recorded.document.fullTextSourceDisplay)
    }
```

Complete the two commented tests by copying the named arrange steps; the assertions are given.

In `OpenAccessStepsRecordingTest.kt`, add:

```kotlin
    @Test fun `CORE is asked once every candidate failed, OpenAlex's included`()   // walk fails, askOpenAlex returns [], askCore served → result is CoreText, recorded markdown == text; askCore called once with the DOI, after askOpenAlex
    @Test fun `CORE is not asked when a copy was served, saved or not`()           // downloadPdf returns Saved / NotSaved → askCore never called
    @Test fun `an unreachable CORE is told after every refusal`()                  // walk fails (403), askCore Unreachable(503) → DoiUrl's shortfall entries end with CORE
```

Write each in the shape of that file's OpenAlex tests (`:207-302`), with a recording list for call order.

In the full-text VM test (`FullTextViewModelOpenAccessShortfallTest.kt` or the VM test that drives `loadDocument`), add:

```kotlin
    @Test fun `a stored CORE text is shown as plain text, never as HTML`() // entity with fullTextSource "core", fullTextMarkdown "<script>alert(1)</script>" → state is PlainTextContent with that exact text
```

In the settings VM test (create `SettingsViewModelCoreKeyTest.kt` if none fits, mocking `SettingsRepository` as the existing settings tests do):

```kotlin
    @Test fun `saving the CORE key trims it, and an empty field clears it`() // updateCoreApiKeyInput("  k  "); saveCoreApiKey() → verify { repo.saveCoreApiKey("k") }; then "" → verify { repo.saveCoreApiKey("") }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd android/MedicalFactChecker && ./gradlew testDebugUnitTest --tests '*Core*' --tests '*OpenAccessStepsRecording*'`
Expected: compile failure, `Unresolved reference: CoreText`.

- [ ] **Step 3: Implement**

`FullTextService.kt`:
- The constructor gains `private val core: CoreService` after `openAlex`. `NetworkModule.provideFullTextService` gains the parameter and passes it.
- `FullTextResult` gains:

```kotlin
    /** CORE's extracted text (#480, stage C): plain text, shown as such, never as HTML. */
    data class CoreText(val text: String) : FullTextResult(hasContent = true)
```

- Add `suspend fun askCore(doi: String): CoreFetch? = core.fetchText(doi)`.
- In `fetchFullText`, after the OpenAlex steps produced no candidate and their shortfalls were folded (`:456-461`), and before the DOI link (`:466`):

```kotlin
            // CORE's extracted text (#480, stage C): last, only with a key, and only
            // because no open-access candidate exists. A failure is an unsettled lookup.
            when (val fetched = core.fetchText(usableDoi)) {
                is CoreFetch.Served -> return Result.success(FullTextResult.CoreText(fetched.text))
                is CoreFetch.Unreachable -> openAccessShortfall = OpenAccessShortfall.adding(
                    OpenAccessShortfall(OpenAccessSource.CORE, OpenAccessUnsettledReason.Failed(fetched.failure)),
                    openAccessShortfall
                )
                CoreFetch.Absent, null -> Unit
            }
```

  Use the local variable names and the `adding` argument order that the OpenAlex folding there uses.
- `getSourceConstant`: `is FullTextResult.CoreText -> Constants.FULLTEXT_SOURCE_CORE`.

`FullTextRecording.kt`:
- `recordingFullTextFetch` gains the parameter `askCore: suspend (doi: String) -> CoreFetch?`, with no default, so no caller can forget it. It is passed to `obtainingOpenAccessPdf`. In that function, where both walks have failed and the DOI link is built, first:

```kotlin
    when (val fetched = askCore(result.doi)) {
        is CoreFetch.Served -> {
            val text = FullTextResult.CoreText(fetched.text)
            return RecordedFetch(recording(text, pdfPath = null), text)
        }
        is CoreFetch.Unreachable -> shortfall = OpenAccessShortfall.adding(
            OpenAccessShortfall(OpenAccessSource.CORE, OpenAccessUnsettledReason.Failed(fetched.failure)),
            shortfall
        )
        CoreFetch.Absent, null -> Unit
    }
```

  Use that function's own name for its folded shortfall. Never reach this after a copy was served: the existing returns for `Saved`/`NotSaved` already leave first.
- `recording()` gains:

```kotlin
        is FullTextResult.CoreText -> copy(
            fullTextMarkdown = result.text,
            fullTextHTML = null,
            fullTextSource = Constants.FULLTEXT_SOURCE_CORE,
            fullTextFetchedAt = Date(),
            fullTextOpenAccessShortfallJson = null,
            fullTextPdfNotSavedFrom = null
        )
```

  If the `PmcOpenDataXml` branch sets more fields (e.g. `fullTextUnavailable = false`), set them the same way.

Callers pass `askCore = { doi -> fullTextService.askCore(doi) }` at every site that passes `askOpenAlex`:
- `FactCheckViewModel.kt:585-600`
- `ReportViewModel.kt:433-448`
- `FullTextViewModel.kt:252-257` and `298-302`

`DocumentEntity.fullTextSourceDisplay` and the domain `Document`'s mirror, if it maps sources: `Constants.FULLTEXT_SOURCE_CORE -> Constants.FULLTEXT_SOURCE_CORE_LABEL`. `FullTextSourceBadge.kt`: give `"core (extracted text)"` the OpenAlex colour.

`FullTextViewModel.kt`:
- `FullTextState` gains `data class PlainTextContent(val text: String, val title: String, val source: String) : FullTextState`.
- In `loadDocument`, before the markdown branch (`:198`): `if (doc.fullTextSource == Constants.FULLTEXT_SOURCE_CORE && !doc.fullTextMarkdown.isNullOrEmpty()) → PlainTextContent(doc.fullTextMarkdown, title, Constants.FULLTEXT_SOURCE_CORE_LABEL)`.
- `handleFullTextResult`: `is FullTextResult.CoreText -> PlainTextContent(result.text, title, Constants.FULLTEXT_SOURCE_CORE_LABEL)`.

`FullTextScreen.kt`: render `PlainTextContent` as `FullTextSourceBadge(source)` plus `SelectionContainer { Text(text, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp)) }`. Use the screen's existing padding constant if `MarkdownContent` uses one. **Never** pass it to `markdownToBasicHtml` or `HtmlViewer`.

Settings:
- `SettingsViewModel`: mirror the NCBI key's input state (`:79-81`, `:191`, `:438-449`, `:594`) as `coreApiKeyInput`, `updateCoreApiKeyInput(value)` and `saveCoreApiKey()`. Save trims the input and calls `settingsRepository.saveCoreApiKey(trimmed)`, then `showStatus(if (trimmed.isEmpty()) "CORE API key cleared" else "CORE API key saved")`.
- `SettingsScreen.AdvancedSection` gains `coreApiKey: String`, `onCoreApiKeyChange: (String) -> Unit` and `onSaveCoreApiKey: () -> Unit`, wired from `SettingsScreen` (`:190-197`). After the NCBI email field, add:

```kotlin
            var showCoreKey by remember { mutableStateOf(false) }
            OutlinedTextField(
                value = coreApiKey,
                onValueChange = onCoreApiKeyChange,
                label = { Text("CORE API Key (optional)") },
                supportingText = { Text(Constants.CORE_API_KEY_EXPLANATION) },
                visualTransformation = if (showCoreKey) VisualTransformation.None else PasswordVisualTransformation(),
                trailingIcon = {
                    IconButton(onClick = { showCoreKey = !showCoreKey }) {
                        Icon(
                            if (showCoreKey) Icons.Default.VisibilityOff else Icons.Default.Visibility,
                            contentDescription = if (showCoreKey) "Hide CORE API key" else "Show CORE API key"
                        )
                    }
                },
                singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )
            Button(onClick = onSaveCoreApiKey) { Text("Save CORE API Key") }
```

Update every test that builds `FullTextService` (`core = absentCore()`) or calls `recordingFullTextFetch` (`askCore = { null }`). The compiler lists them.

- [ ] **Step 4: Run the whole Android suite**

Run: `cd android/MedicalFactChecker && ./gradlew test`
Expected: BUILD SUCCESSFUL, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add android/MedicalFactChecker
git commit -m "feat(android): CORE's text last in the chain, shown as plain text; a CORE key in the settings (#480)

Refs #480.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Task 10: Verification, acceptance and hand-over

**Files:**
- Modify: `doc/developer/unpaywall_pdf_survey/spikes/README.md` (an acceptance paragraph), `doc/cross_platform/fulltext_retrieval.md` (its acceptance sentence), `HANDOVER.md`
- Create (scratchpad only, not committed): the acceptance script and the mutation harness

- [ ] **Step 1: Every suite and gate**

Run each; every one must pass before going on:

```bash
pytest tests/ -q
python .github/scripts/lint_delta.py --base-ref origin/master
cd Packages/BioMedLit && swift test
cd ios/MedicalFactChecker && swift test && xcodebuild -scheme MedicalFactChecker -destination 'platform=macOS' build -quiet
cd android/MedicalFactChecker && ./gradlew test
```

The iOS simulator build ran in Task 7. Re-run it if any Swift app file changed since.

- [ ] **Step 2: No test reaches the network**

Run, per the dead-proxy memory:

```bash
HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 NO_PROXY=127.0.0.1,localhost pytest tests/ -q
```

Expected: the same results as Step 1. A test that fails only here reaches a live API; fix it with a stub.

- [ ] **Step 3: Mutation check of the new branches (Python)**

Write a harness in the scratchpad that, for each mutation below:
1. backs up `src/bmlibrarian_lite/core_api.py` or `pdf_discovery.py` with `shutil.copy`;
2. applies one textual mutation, asserting it matched exactly once;
3. runs `pytest tests/test_core_api.py tests/test_core_discovery.py -q -x` with `PYTHONDONTWRITEBYTECODE=1`, `PYTHONPATH=src` and `__pycache__` cleared;
4. restores from the backup and asserts the file's bytes equal the backup.

Before the first mutation, assert the unmutated run passes. **No git command anywhere in the restore** (memories: restore wipes uncommitted work; sweep needs two guards; restore must be verified).

| Mutation | Must be caught by |
|---|---|
| `normalise_doi(result_doi) != wanted` → `False` | "another article's text is never served" |
| `len(text) >= min_chars` → `len(text) > min_chars` | "a text exactly at the minimum is served" |
| `text = text.strip()` (in `core_full_text`) deleted | "padding does not count towards the minimum" |
| `status != HTTP_TOO_MANY_REQUESTS` → `status == HTTP_TOO_MANY_REQUESTS` | the throttle tests |
| `self._consecutive = 0` deleted | "another answer between 429s resets the count" |
| `if response.status_code != HTTP_OK:` → `if response.status_code >= 500:` | the status table's 404 row |
| `fetch, self._fetch = self._fetch, None` → `fetch = self._fetch` | "core is asked once whatever the exit" |
| `lookups = lookups.merged(core_lookups)` (first occurrence) deleted | "an unreachable core is told and blocks absence" |

Any survivor means a missing test: add it, then re-run the sweep. Report the table with outcomes in the PR.

- [ ] **Step 4: Live acceptance**

Ask the maintainer to export `CORE_API_KEY` in this shell. Then, in the scratchpad, write a script that reads `doc/developer/unpaywall_pdf_survey/spikes/2026-10-04-channels.jsonl`, keeps the 149 rows whose `stratum` is `epmc-not-oa`, and for each calls `default_core_client(None).fetch_full_text(row["doi"])`. Paced by the client, this takes about 7 minutes. It records `served` (with the text length), `absent` or the failure.

Run it with `python -I`, and print:
- the counts of served, absent and unreachable (by status);
- for the spike's 14 recoveries (rows where `core.full_text_chars >= 5000`), which were served.

Re-analyse, never re-fetch: save the rows to the scratchpad and work from that file.

The criterion is at least 14 of the 149, or every one of the spike's 14 that CORE did not answer 429 to. Then:
- If a spike recovery is now `absent`, check by hand whether CORE's result DOI differs (a legitimate refusal by the DOI rule) or the rule is too strict. Report each case.
- If a probe reveals that the percent-encoded `q` is not understood (every row absent), stop and report: the URL form is a contract change.
- Write one paragraph with the counts under a new heading "Stage C1 acceptance (2026-10-xx)" in `spikes/README.md`, and one sentence in the CORE section of `fulltext_retrieval.md`.
- Unset the key afterwards.

- [ ] **Step 5: Lodge what this slice found but does not fix**

Open issues (title + body; "Refs #480"; no closing keyword anywhere):
- Android's `markdownToBasicHtml` does not escape HTML, and feeds a JavaScript-enabled WebView. JATS-derived markdown can carry decoded `<…>` text (`FullTextScreen.kt:706`).
- Android's settings screen never shows the NCBI API key that `SettingsViewModel` holds (`ncbiApiKeyInput`).
- The desktop settings dialog has no field for `discovery.unpaywall_email`.

Check `gh issue list --search` first, so none is lodged twice.

- [ ] **Step 6: Hand-over**

Update `HANDOVER.md`:
- Replace the C1 "In flight" entry with "C2: Elsevier (next)", noting that the settings plumbing exists to copy.
- Add a compressed "Recently landed" bullet for C1 with the rules that bind: DOI match; code points; silent without a key; an unreachable CORE blocks absence; last in chain order; session pause; the `.core.txt` cache; Android plain text.
- List the new issues under "Potential follow-ups".
- Keep it under 500 lines.

Then commit, push and open the PR:

```bash
git add HANDOVER.md doc
git commit -m "docs: stage C1 acceptance and hand-over (#480)

Refs #480.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push -u origin feat/machine-channels-stage-c1-core-480
gh pr create --base master --title "Machine channels, stage C1: CORE's extracted text and its key (#480)" --body-file <scratchpad>/pr_body.md
```

The PR body:
- says "Refs #480" (no closing keyword; #480 stays open for C2);
- lists the maintainer decisions;
- states the spec deviation (no `NOT_CONFIGURED` record);
- includes the mutation table and the acceptance counts;
- ends with `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.

After it is open, confirm #480 is still open.
