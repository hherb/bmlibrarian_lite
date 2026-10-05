# Full Text Through Machine Channels — Stage B Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The apps try every PDF Unpaywall names, as the desktop already does. All three platforms then try the PDFs OpenAlex names that Unpaywall did not. When none can be obtained, the reader is told every source tried and why each failed. A PDF served but not saved is told as a caching problem of its own.

**Architecture:**
- **Pure helpers, pinned by shared fixtures:**
  - `unpaywall_pdf_urls`: every location's `url_for_pdf`, best first.
  - `openalex_pdf_urls` and `untried_pdf_urls`: OpenAlex's `locations[].pdf_url` not already tried.
  - The **tried-sources statement**: the open-access shortfall becomes a list of entries, each tried PDF carrying its address.
- **The OpenAlex client** returns a typed fetch (served / absent / unreachable), like stage A's bucket.
- **The candidates are tried in chain order:**
  - Unpaywall's PDFs, then its landing page, which is read only when no location names a PDF.
  - Then OpenAlex's untried PDFs. **OpenAlex is asked only when no Unpaywall PDF was served.**
- **The first PDF served ends the walk.** If it was saved, the article is read. If it was not saved, its link is kept and the reader gets the caching note.

**Tech Stack:** Python 3.12 + `requests`; Swift 5.9 + BioMedLit (`URLSession`, `JSONSerialization`) + SwiftData; Kotlin + OkHttp + kotlinx.serialization + Room; pytest, XCTest, JUnit4 + MockWebServer + MockK.

**Spec:** `docs/superpowers/specs/2026-10-04-fulltext-machine-channels-design.md`, section "Stage B". Background: `doc/developer/unpaywall_pdf_survey/spikes/README.md`, rows `spikes/2026-10-04-channels.jsonl`. Stage A's plan, `docs/superpowers/plans/2026-10-04-fulltext-machine-channels-stage-a.md`, set the patterns this plan copies.

## Maintainer decisions (2026-10-05)

1. **No OpenAlex request that cannot raise the odds.** OpenAlex is asked only once no Unpaywall PDF was served. This holds on every platform, Android included: the download step (`recordingFullTextFetch`) asks it through a hook (Task 14).
2. **A composite failure statement.** When at least one PDF was tried and none obtained, the reader is told: "Failed to obtain a PDF from the following tried sources: …". It lists each tried PDF **by host and by who named it**, plus each lookup that went unsettled, in chain order. **A lookup-only shortfall keeps today's sentence**, which is Python's grouped clause (one entry is today's single sentence; Swift and Kotlin port the grouping for two or more).
3. **A copy served but not saved settles the open-access question.** Its link is kept and no shortfall is recorded. **The reader is told of the caching problem in a note of its own**, beside the link, not in the composite list. The note is stored on the document in both apps.
4. **One PR** for the whole stage.

Also taken, from the first draft:
- Every OpenAlex `pdf_url` counts, whatever its `is_oa`. The spike recovered `real.mtak.hu`'s copy, which OpenAlex marks closed.
- OpenAlex is asked with `select=locations`.
- `mailto` is each platform's existing contact email:
  - Python: the PubMed email.
  - Swift: the service's `email`.
  - Android: the NCBI email.
  - The placeholder is excluded. With none, the request goes without `mailto`.
- Android's `FullTextResult.UnpaywallPdf` is replaced by `OpenAccessPdfs` (what to try, from the service) and `OpenAccessPdf` (the one obtained or linked).

## Global Constraints

- Python is the reference; Swift and Kotlin mirror it. A behaviour change touches the shared fixture and all three platforms.
- **Unpaywall's candidates** are every location's `url_for_pdf`, trimmed and deduplicated (first occurrence kept), in Unpaywall's order: `best_oa_location`, then `oa_locations`. The landing page is read only when that list is empty. The apps try the candidates in that order; Python tries them by its own priority (#478).
- **OpenAlex request:** `GET https://api.openalex.org/works/doi:{DOI}?select=locations[&mailto={EMAIL}]`.
  - Both values are percent-encoded with RFC 3986's unreserved set left bare and UTF-8 bytes otherwise. This is Python's `quote(s, safe="")`.
  - `mailto` is left out without a usable contact.
- **OpenAlex's candidates** are every `locations[].pdf_url`, trimmed and deduplicated, in OpenAlex's order, minus any URL already in Unpaywall's candidate list. `landing_page_url` is never read.
- **OpenAlex outcomes:**
  - 200 with a JSON object whose `locations` is a list, missing or null: **served**.
  - 404: **absent**. OpenAlex sends an HTML body for an unknown DOI.
  - Any other status after retries: **unreachable** `http_status`.
  - An unreadable body, a non-object work, or `locations` not a list: **unreachable** `malformed_response`.
  - Transport failure: **unreachable**, its kind.
  - 429/500/502/503/504 are retried, 4 attempts, each one paced.
- **Pacing:** `api.openalex.org` gets **10/s**. Python already has it. Swift uses a 0.1 s minimum interval per service instance (#489). Android uses `RequestPacer(100)` in an app-wide `@Singleton`.
- **Names, verbatim:**
  - `"OpenAlex"` (raw `openalex`) and `"OpenAlex's copy"` (raw `openalex_pdf`).
  - The app source is raw `openalex`, label `"OpenAlex"`.
  - "named by Unpaywall" / "named by OpenAlex".
- **When OpenAlex is asked:** with a DOI, once. Only when no Unpaywall candidate was served (saved or not), after the landing page, and before the publisher and DOI fallbacks. Python asks it before the first source that is not open access.
- **The first candidate served ends the walk.**
  - Saved: the article is read.
  - Not saved: the link is kept (apps) or the copy is unread (Python), and the caching note is told. No further candidate and no OpenAlex request follows, because saving is our problem, not the source's.
- **The tried-sources statement** (fixture `open_access_statement.json`):
  - It is used when the shortfall holds a tried PDF, an entry with an address.
  - Its text: `"Failed to obtain a PDF from the following tried sources: "` + entries joined by `"; "` + `". "` + the ending.
  - **A PDF entry** reads `"{host}, named by {Unpaywall|OpenAlex} ({reason})"`. The host is the address's host, lower-cased; an address without one is named as given, trimmed.
  - **A lookup entry** reads `"{service name} ({reason})"`, once per service, with the reason chosen by Python's `_unsettled` rule.
  - **Order:** any source outside the open-access chain first, in the order given; then `unpaywall`, `unpaywall_landing_page`, `unpaywall_pdf` entries, `openalex`, `openalex_pdf` entries. The sort is stable.
  - **The ending** is `"A freely available copy may exist. Whether this document is open access was not established."` if any entry could not be asked. Otherwise it is `"Whether this document is open access was not established."`.
  - The configuration nudge follows, when Unpaywall was not configured.
- **Without a tried PDF, the statement is today's.** Python's `unestablished_access_clause`: `{Sentence-start(unasked joined)} could not be asked, and {answered joined} did not serve it, so {ending}` plus the nudge. `joined` is `A (x)`, `A (x) and B (y)`, or `A (x), B (y) and C (z)`.
- **The caching note:** `"A PDF of this article was found at {host} but could not be saved on this device, so {only its link is kept | it could not be read}. Check the free storage space and try again."`.
  - The apps use "only its link is kept" when the link is the result, and "it could not be read" when an abstract was returned instead.
  - Python always uses "it could not be read".
  - The note is never part of the shortfall.
- **The stored shortfall in the apps:**
  - A single entry without an address is written in today's v1 form, so its rows are unchanged.
  - Anything else is written as `{"schema_version": 2, "entries": [{"source", "address"?, "failure" | "skipped"}, …]}`.
  - **Reading:** v1 is one entry. In v2, an entry that is not an object, or whose failure will not read, reads as `{its source or unpaywall, request_failed}`. A blank or non-string address is no address. A missing or empty `entries`, or any other schema, reads as `[{unpaywall, request_failed}]`.
  - Every stored value reads as some shortfall.
- A PDF we could not obtain is refused under `unpaywall_pdf` or `openalex_pdf` by #478's rules:
  - `request_failed` for an address that is not an absolute http(s) URL with a host;
  - its status for an HTTP answer;
  - `malformed_response` for a body that does not start with `%PDF`;
  - its kind for a transport failure.
- No test reaches the real OpenAlex:
  - Python: an autouse conftest guard.
  - Swift: `StubURLProtocol.fallbackRoutes` answers OpenAlex 404.
  - Android: `absentOpenAlex()`.
- **SwiftData and Room:**
  - A new optional field is proven with an **earlier build's store** (`StoreMigrationTests`), as PR #473 did.
  - Room goes 8 → 9 through `AppDatabase.ALL_MIGRATIONS`, with a migration test.
- Docstrings: Google style (Python), `///` (Swift), KDoc (Kotlin). No magic numbers: constants go in `constants.py`, `BioMedLitConstants`, `Constants.kt`. No new dependency.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. **No GitHub closing keyword** before #480 or any number that stays open ("Refs #480").

## Review Focus

1. **A PDF named by Unpaywall and OpenAlex both is requested once.**
   - Fixture `pdf_urls` "tried" rows (Task 9).
   - A chain test per platform: Python Task 10, Swift Task 12, Kotlin Task 14.
2. **A copy served but not saved: no shortfall, a caching note, no crash, and no further request.**
   - Swift `FullTextResult.init` asserts that an open-access copy's link carries no shortfall.
   - Tested in Swift (Task 6), Kotlin (Task 7) and Python (Task 8).
3. **A stored shortfall from today's build (v1) reads as before; a v2 one round-trips.** A garbled v2 one still reads as some shortfall. Fixture `persisted` rows, read by Swift (Task 4) and Kotlin (Task 5).
4. **A DOI that needs escaping reaches OpenAlex as one path segment on every platform.** This covers a SICI DOI with `<>;:()` and a non-ASCII DOI. Fixture `work_url` rows (Task 9).
5. **Existing tests do not reach the network and do not change outcome.**
   - Python: the autouse guard (Task 10), then a dead-proxy run (Task 15).
   - Swift: the default OpenAlex 404 route (Task 12).
   - Kotlin: `absentOpenAlex()` (Task 14).
   - The apps' existing single-entry notice rows still pass after the list change (Tasks 4–5).

---

## File Structure

| File | Responsibility |
|---|---|
| `doc/cross_platform/fulltext_parity/unpaywall_landing_page.json` | New table `unpaywall_pdf_urls`; schema 3 |
| `doc/cross_platform/fulltext_parity/open_access_unsettled_notice.json` | Sources `openalex`, `openalex_pdf`; their rows |
| `doc/cross_platform/fulltext_parity/open_access_statement.json` (new) | Hosts, statements (composite and grouped), caching note, v2 persisted form |
| `doc/cross_platform/fulltext_parity/openalex_locations.json` (new) | Names, base URL, `work_url`, `pdf_urls`, `status` |
| `src/bmlibrarian_lite/data_models.py` | `address` on `SourceLookupFailure`/`SourceLookupSkipped`; `LookupSkipReason.NOT_SAVED` |
| `src/bmlibrarian_lite/analysis_failures.py` | `address_host`, `tried_sources_statement`, `not_saved_note`; the access sentences use them |
| `src/bmlibrarian_lite/oa_landing_page.py` | `unpaywall_pdf_urls` |
| `src/bmlibrarian_lite/openalex.py` (new) | Pure helpers, `OpenAlexWorkFetch`, `OpenAlexLocationsClient` |
| `src/bmlibrarian_lite/constants.py` | `SERVICE_OPENALEX*`, OpenAlex host/URL/timeout/retries |
| `src/bmlibrarian_lite/pdf_discovery.py` | Every unobtained copy recorded with its address; a copy not saved ends the walk; `OPENALEX_OA`; `_discover_openalex`; the splice |
| `src/bmlibrarian_lite/fulltext_discovery.py`, `gui/workers.py`, `gui/document_interrogation_tab.py`, `mcp_server.py`, `study_transparency_analyzer/study_transparency_analyzer.py` | `openalex_email` |
| `tests/conftest.py`, `pyproject.toml` | Autouse OpenAlex guard; marker |
| `tests/test_open_access_statement.py` (new), `tests/test_openalex.py` (new), `tests/test_openalex_discovery.py` (new), `tests/test_unobtained_unpaywall_pdf.py` | Python tests |
| `Packages/BioMedLit/Sources/BioMedLit/Models/OpenAccessShortfall.swift` | Entries, v2 codec, grouped and composite notice, caching note |
| `Packages/BioMedLit/Sources/BioMedLit/Services/UnpaywallLandingPage.swift`, `Services/OpenAlex.swift` (new), `Services/FullTextService.swift` | Candidates, OpenAlex, the walk |
| `Packages/BioMedLit/Sources/BioMedLit/Models/FullTextModels.swift` | `.openAlex` source and content; `pdfNotSavedFrom`; init assert |
| `Packages/BioMedLit/Sources/BioMedLit/Utilities/Constants.swift`, `Utilities/RetryHelper.swift` | OpenAlex constants and retry |
| `Packages/BioMedLit/Tests/BioMedLitTests/…` | `OpenAccessStatementContractTests`, `OpenAlexContractTests`, `FullTextServiceUnpaywallLocationsTests`, `FullTextServiceOpenAlexTests`, `StubURLProtocol` |
| `ios/MedicalFactChecker/Sources/Models/Document.swift`, `Views/Components/ParseWarningBanner.swift`, `Models/FullTextSource.swift`, `Utilities/BioMedLitAdapters.swift`, `Views/Components/FullTextSourceBadge.swift`, `macOS/MacConstants.swift` | Stored caching note, banner line, app source |
| `ios/MedicalFactChecker/Tests/StoreMigrationTests.swift`, `FullTextSourceDisplayTests.swift`, `OpenAccessShortfallNoticeTests.swift` | App tests |
| `MAIN/domain/model/OpenAccessShortfall.kt` | Entries, v2 codec, grouped and composite notice, caching note |
| `MAIN/data/remote/fulltext/UnpaywallLandingPage.kt`, `OpenAlex.kt` (new), `FullTextService.kt`, `FullTextRecording.kt` | Candidates, OpenAlex, steps, the walk |
| `MAIN/data/local/AppDatabase.kt`, `entity/DocumentEntity.kt`, `dao/DocumentDao.kt` | Room 9: `full_text_pdf_not_saved_from` |
| `MAIN/ui/fulltext/…`, `ui/factcheck/…`, `ui/report/…` | Caching note shown where `OpenAccessShortfallNotice` is; ViewModels pass the OpenAlex hook |
| `MAIN/domain/model/FullTextLinkKind.kt`, `di/NetworkModule.kt`, `util/Constants.kt` | Source, wiring |
| `TEST/…` | Contract, service, chain, recording and migration tests; `OpenAlexTestDoubles.kt` |
| `doc/cross_platform/fulltext_retrieval.md`, `doc/cross_platform/polite_request_pacing.md`, the spec | Contract text, pacing rows, "As built" |

Android paths abbreviate `android/MedicalFactChecker/app/src/main/java/com/bmlibrarian/factchecker/` as `MAIN/` and the matching test root as `TEST/`.

---

### Task 1: Every Unpaywall PDF: the contract and the pure helpers, all three platforms

**Files:**
- Modify: `doc/cross_platform/fulltext_parity/unpaywall_landing_page.json`
- Modify: `src/bmlibrarian_lite/oa_landing_page.py` (after `location_pdf_url`)
- Modify: `tests/test_oa_landing_page.py`
- Modify: `Packages/BioMedLit/Sources/BioMedLit/Services/UnpaywallLandingPage.swift` (beside `choose(from:)`, L97)
- Modify: `Packages/BioMedLit/Tests/BioMedLitTests/UnpaywallLandingPageContractTests.swift`
- Modify: `MAIN/data/remote/fulltext/UnpaywallLandingPage.kt` (beside `chooseUrl`, L194)
- Modify: `TEST/data/remote/fulltext/UnpaywallLandingPageContractTest.kt`

**Interfaces:**
- Produces:
  - Python `unpaywall_pdf_urls(response: Mapping[str, Any]) -> list[str]`
  - Swift `static func pdfURLs(from response: UnpaywallResponse) -> [String]` on `UnpaywallLandingPage`
  - Kotlin `fun pdfUrls(response: UnpaywallResponse): List<String>` on `object UnpaywallLandingPage`

- [ ] **Step 1: Add the table to the fixture**

In `unpaywall_landing_page.json`, set `"schema_version": 3`. In `description`, after "Which URL the Unpaywall tier tries," insert "every PDF URL it tries in turn (unpaywall_pdf_urls, #480 stage B),". Then add this table after `unpaywall_choice`. No row holds a non-object location, because Swift decodes the answer with `Codable` and fails on one.

```json
"unpaywall_pdf_urls": [
  {"name": "the best location repeated in oa_locations is tried once",
   "response": {"best_oa_location": {"url_for_pdf": "https://pub.example.org/a.pdf"},
                "oa_locations": [{"url_for_pdf": "https://pub.example.org/a.pdf"}, {"url_for_pdf": "https://repo.example.org/b.pdf"}]},
   "expected": ["https://pub.example.org/a.pdf", "https://repo.example.org/b.pdf"]},
  {"name": "Unpaywall's order, not the version's",
   "response": {"best_oa_location": {"url_for_pdf": "https://repo.example.org/accepted.pdf", "version": "acceptedVersion"},
                "oa_locations": [{"url_for_pdf": "https://pub.example.org/published.pdf", "version": "publishedVersion"}]},
   "expected": ["https://repo.example.org/accepted.pdf", "https://pub.example.org/published.pdf"]},
  {"name": "a location without a PDF URL is passed over",
   "response": {"best_oa_location": {"url": "https://repo.example.org/item/1", "url_for_landing_page": "https://repo.example.org/item/1"},
                "oa_locations": [{"url_for_pdf": "https://other.example.org/c.pdf"}]},
   "expected": ["https://other.example.org/c.pdf"]},
  {"name": "a blank url_for_pdf is no PDF, and a padded one is trimmed",
   "response": {"oa_locations": [{"url_for_pdf": "   "}, {"url_for_pdf": " https://repo.example.org/d.pdf "}]},
   "expected": ["https://repo.example.org/d.pdf"]},
  {"name": "a padded duplicate is the same PDF",
   "response": {"oa_locations": [{"url_for_pdf": " https://repo.example.org/e.pdf"}, {"url_for_pdf": "https://repo.example.org/e.pdf"}]},
   "expected": ["https://repo.example.org/e.pdf"]},
  {"name": "no location names a PDF",
   "response": {"best_oa_location": {"url_for_landing_page": "https://hdl.handle.net/2115/95934"}},
   "expected": []},
  {"name": "null locations",
   "response": {"best_oa_location": null, "oa_locations": null},
   "expected": []},
  {"name": "fields absent altogether",
   "response": {},
   "expected": []}
],
```

- [ ] **Step 2: Write the failing Python tests**

In `tests/test_oa_landing_page.py`, add `unpaywall_pdf_urls` to the import from `bmlibrarian_lite.oa_landing_page`. Add `"unpaywall_pdf_urls"` to the set in `test_every_contract_table_is_read_here`, and `assert len(CONTRACT["unpaywall_pdf_urls"]) >= 5` to `test_the_contract_has_rows`. Then add:

```python
@pytest.mark.parametrize(
    "row", CONTRACT["unpaywall_pdf_urls"], ids=lambda row: row["name"]
)
def test_unpaywall_pdf_urls_match_the_contract(row: dict[str, Any]) -> None:
    """Each row's answer names the PDFs the contract lists, in its order."""
    assert unpaywall_pdf_urls(row["response"]) == row["expected"]


@pytest.mark.parametrize(
    "row",
    [row for row in CONTRACT["unpaywall_pdf_urls"] if row["expected"]],
    ids=lambda row: row["name"],
)
def test_the_desktop_discovers_the_same_pdfs(row: dict[str, Any]) -> None:
    """Python's discovery names exactly these Unpaywall PDFs, in this order.

    The desktop then tries them by its own priority (#478), but the list is
    the one the apps try, so the two cannot disagree about which PDFs exist.
    """
    from bmlibrarian_lite.pdf_discovery import PDFDiscoverer, PDFSourceType

    class _Answer:
        status_code = 200

        @staticmethod
        def json() -> dict[str, Any]:
            return row["response"]

        @staticmethod
        def raise_for_status() -> None:
            return None

    class _Session:
        def get(self, url: str, **kwargs: Any) -> _Answer:
            return _Answer()

    discoverer = PDFDiscoverer(unpaywall_email="test@example.com", use_browser_fallback=False)
    discoverer._session = _Session()  # type: ignore[assignment]
    sources, failure = discoverer._discover_unpaywall("10.1/x")

    assert failure is None
    assert [
        s.url for s in sources if s.source_type is PDFSourceType.UNPAYWALL_OA
    ] == row["expected"]
```

The second test takes only rows that name a PDF. A row naming none sends `_discover_unpaywall` to the landing page, which this fake session cannot serve; that path is `test_unpaywall_landing_page_discovery.py`'s.

- [ ] **Step 3: Run them to see them fail**

Run: `pytest tests/test_oa_landing_page.py -q`
Expected: FAIL. `ImportError: cannot import name 'unpaywall_pdf_urls'`.

- [ ] **Step 4: Implement Python's helper**

In `src/bmlibrarian_lite/oa_landing_page.py`, after `location_pdf_url`:

```python
def unpaywall_pdf_urls(response: Mapping[str, Any]) -> list[str]:
    """Every PDF URL an Unpaywall answer names, best location first.

    The candidates every platform tries (#480, stage B): the desktop already
    tried every location, the apps only the best one's. A URL named by more
    than one location -- the best location is usually repeated in
    ``oa_locations`` -- is kept once, where it first appears.

    Args:
        response: Unpaywall's decoded JSON answer for one DOI.

    Returns:
        Each location's :func:`location_pdf_url`, in Unpaywall's order,
        without repeats; empty when no location names a PDF.
    """
    urls: list[str] = []
    for location in unpaywall_locations(response):
        url = location_pdf_url(location)
        if url and url not in urls:
            urls.append(url)
    return urls
```

- [ ] **Step 5: Run the Python tests**

Run: `pytest tests/test_oa_landing_page.py -q`
Expected: PASS.

- [ ] **Step 6: Swift: the failing contract test**

In `UnpaywallLandingPageContractTests.swift`, add `"unpaywall_pdf_urls"` to the set in `testEveryContractTableIsReadHere`, and add:

```swift
    func testEachUnpaywallPDFURLsRow() throws {
        let rows = try loadTable("unpaywall_pdf_urls")
        XCTAssertGreaterThanOrEqual(rows.count, 5, "an empty table would pass vacuously")
        for row in rows {
            let name = string(row, "name") ?? "?"
            let json = try JSONSerialization.data(withJSONObject: row["response"] ?? [:])
            let response = try JSONDecoder().decode(UnpaywallResponse.self, from: json)

            XCTAssertEqual(
                UnpaywallLandingPage.pdfURLs(from: response),
                row["expected"] as? [String],
                name
            )
        }
    }
```

Run: `cd Packages/BioMedLit && swift build --build-tests 2>&1 | tail -5`
Expected: FAIL. `type 'UnpaywallLandingPage' has no member 'pdfURLs'`.

- [ ] **Step 7: Swift: implement**

In `UnpaywallLandingPage.swift`, after `choose(from:)`:

```swift
    /// Every PDF URL an Unpaywall answer names, best location first (#480,
    /// stage B): each location's `url_for_pdf`, trimmed, kept once where it
    /// first appears. The chain tries them in this order; Python's
    /// `unpaywall_pdf_urls`, pinned by `unpaywall_landing_page.json`.
    ///
    /// - Parameter response: Unpaywall's answer for one DOI.
    /// - Returns: The PDF URLs, possibly none.
    static func pdfURLs(from response: UnpaywallResponse) -> [String] {
        let locations = [response.bestOaLocation].compactMap { $0 } + (response.oaLocations ?? [])
        var urls: [String] = []
        for location in locations {
            if let pdf = present(location.urlForPdf), !urls.contains(pdf) {
                urls.append(pdf)
            }
        }
        return urls
    }
```

Run: `cd Packages/BioMedLit && swift test --filter UnpaywallLandingPageContractTests`
Expected: PASS.

- [ ] **Step 8: Kotlin: the failing contract test**

In `UnpaywallLandingPageContractTest.kt`, add `"unpaywall_pdf_urls"` to the set in `every contract table is read here`, and add:

```kotlin
    @Test
    fun `each unpaywall_pdf_urls row`() {
        for (row in table("unpaywall_pdf_urls")) {
            assertEquals(
                "${row.string("name")}",
                row.getValue("expected").jsonArray.map { it.jsonPrimitive.content },
                UnpaywallLandingPage.pdfUrls(response(row.getValue("response").jsonObject))
            )
        }
    }
```

Run: `cd android/MedicalFactChecker && ./gradlew testDebugUnitTest --tests '*UnpaywallLandingPageContractTest*' -q`
Expected: FAIL (compile). `Unresolved reference: pdfUrls`.

- [ ] **Step 9: Kotlin: implement**

In `UnpaywallLandingPage.kt`, after `chooseUrl`:

```kotlin
    /**
     * Every PDF URL an Unpaywall answer names, best location first (#480,
     * stage B): each location's `url_for_pdf`, trimmed, kept once where it
     * first appears. The chain tries them in this order; Python's
     * `unpaywall_pdf_urls`, pinned by `unpaywall_landing_page.json`.
     *
     * @param response Unpaywall's answer for one DOI
     * @return The PDF URLs, possibly none
     */
    fun pdfUrls(response: UnpaywallResponse): List<String> =
        (listOfNotNull(response.best_oa_location) + response.oa_locations.orEmpty())
            .mapNotNull { present(it.url_for_pdf) }
            .distinct()
```

`distinct()` keeps first occurrences in order.

Run: `cd android/MedicalFactChecker && ./gradlew testDebugUnitTest --tests '*UnpaywallLandingPageContractTest*' -q`
Expected: PASS.

- [ ] **Step 10: Commit**

```bash
git add doc/cross_platform/fulltext_parity/unpaywall_landing_page.json src/bmlibrarian_lite/oa_landing_page.py tests/test_oa_landing_page.py Packages/BioMedLit/Sources/BioMedLit/Services/UnpaywallLandingPage.swift Packages/BioMedLit/Tests/BioMedLitTests/UnpaywallLandingPageContractTests.swift android/MedicalFactChecker/app/src/main/java/com/bmlibrarian/factchecker/data/remote/fulltext/UnpaywallLandingPage.kt android/MedicalFactChecker/app/src/test/java/com/bmlibrarian/factchecker/data/remote/fulltext/UnpaywallLandingPageContractTest.kt
git commit -m "feat(all): every PDF an Unpaywall answer names, pinned by the contract (#480)

Refs #480.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: The shortfall vocabulary: `openalex` and `openalex_pdf`, all three platforms

**Files:**
- Modify: `src/bmlibrarian_lite/constants.py` (after `SERVICE_UNPAYWALL_PDF`, ~L1082)
- Modify: `doc/cross_platform/fulltext_parity/open_access_unsettled_notice.json`
- Modify: `tests/test_open_access_unsettled_notice.py` (`SERVICES`, imports)
- Modify: `Packages/BioMedLit/Sources/BioMedLit/Models/OpenAccessShortfall.swift` (`OpenAccessSource`, L24)
- Modify: `MAIN/domain/model/OpenAccessShortfall.kt` (`OpenAccessSource`, L35)

**Interfaces:**
- Produces:
  - Python `SERVICE_OPENALEX = "OpenAlex"` and `SERVICE_OPENALEX_PDF = "OpenAlex's copy"`.
  - Swift `OpenAccessSource.openAlex` (`"openalex"`) and `.openAlexPDF` (`"openalex_pdf"`).
  - Kotlin `OpenAccessSource.OPENALEX` and `OPENALEX_PDF`.

This task is cross-platform on purpose. The fixture's `sources` table is asserted equal to each platform's source set, so adding it on one platform alone fails the other two.

- [ ] **Step 1: Add the fixture rows**

In `open_access_unsettled_notice.json`:
- `sources` gains `"openalex": "OpenAlex"` and `"openalex_pdf": "OpenAlex's copy"`.
- `description`: "Unpaywall, the landing page it named, or the PDF it named (#478)" becomes "Unpaywall, the landing page it named, the PDF it named (#478), OpenAlex, or the PDF OpenAlex named (#480 stage B)".
- `notices` gains these rows, one per line like the others:

```json
{"source": "openalex", "kind": "timeout", "status_code": null, "notice": "OpenAlex (the request timed out) could not be asked, so a freely available copy may exist. Whether this document is open access was not established."},
{"source": "openalex", "kind": "http_status", "status_code": 503, "notice": "OpenAlex (HTTP 503 Service Unavailable) could not be asked, so a freely available copy may exist. Whether this document is open access was not established."},
{"source": "openalex", "kind": "malformed_response", "status_code": null, "notice": "OpenAlex (the response could not be read) could not be asked, so a freely available copy may exist. Whether this document is open access was not established."},
{"source": "openalex_pdf", "kind": "http_status", "status_code": 403, "notice": "OpenAlex's copy (HTTP 403 Forbidden) did not serve it, so whether this document is open access was not established."},
{"source": "openalex_pdf", "kind": "malformed_response", "status_code": null, "notice": "OpenAlex's copy (the response could not be read) could not be asked, so a freely available copy may exist. Whether this document is open access was not established."},
{"source": "openalex_pdf", "kind": "request_failed", "status_code": null, "notice": "OpenAlex's copy (the request failed) could not be asked, so a freely available copy may exist. Whether this document is open access was not established."}
```

- `persisted.written` gains:

```json
{"source": "openalex", "kind": "http_status", "status_code": 429, "stored": {"schema_version": 1, "source": "openalex", "failure": {"kind": "http_status", "status_code": 429}}},
{"source": "openalex_pdf", "kind": "http_status", "status_code": 403, "stored": {"schema_version": 1, "source": "openalex_pdf", "failure": {"kind": "http_status", "status_code": 403}}}
```

- `persisted.read` gains:

```json
{"name": "OpenAlex's own lookup", "stored": "{\"schema_version\":1,\"source\":\"openalex\",\"failure\":{\"kind\":\"timeout\",\"status_code\":null}}", "source": "openalex", "kind": "timeout", "status_code": null},
{"name": "the PDF OpenAlex named", "stored": "{\"schema_version\":1,\"source\":\"openalex_pdf\",\"failure\":{\"kind\":\"malformed_response\",\"status_code\":null}}", "source": "openalex_pdf", "kind": "malformed_response", "status_code": null}
```

Each notice must equal what Python's `unestablished_access_clause` builds. Step 3 runs those rows; if one differs, the fixture text is wrong, not the code.

- [ ] **Step 2: Python: the failing test**

In `tests/test_open_access_unsettled_notice.py`, import `SERVICE_OPENALEX` and `SERVICE_OPENALEX_PDF` and extend the mapping:

```python
SERVICES = {
    "unpaywall": SERVICE_UNPAYWALL,
    "unpaywall_landing_page": SERVICE_UNPAYWALL_LANDING_PAGE,
    "unpaywall_pdf": SERVICE_UNPAYWALL_PDF,
    "openalex": SERVICE_OPENALEX,
    "openalex_pdf": SERVICE_OPENALEX_PDF,
}
```

Run: `pytest tests/test_open_access_unsettled_notice.py -q`
Expected: FAIL. `ImportError: cannot import name 'SERVICE_OPENALEX'`.

- [ ] **Step 3: Python: the constants**

In `constants.py`, after `SERVICE_UNPAYWALL_PDF`:

```python
# OpenAlex's record of a work, asked by DOI for the PDFs its locations name
# that Unpaywall did not (#480, stage B). Named as the reader knows it.
SERVICE_OPENALEX = "OpenAlex"
# A PDF OpenAlex named that we could not obtain. OpenAlex answered; the copy
# it pointed at went unassessed, so it is never "no copy" (#478's rule).
SERVICE_OPENALEX_PDF = "OpenAlex's copy"
```

Run: `pytest tests/test_open_access_unsettled_notice.py -q`
Expected: PASS. If a notice row fails, correct the row's text to the sentence Python built and re-run. Python is the reference.

- [ ] **Step 4: Swift: the source cases**

In `OpenAccessShortfall.swift`, add to `OpenAccessSource` after `case pdf = "unpaywall_pdf"`:

```swift
    /// OpenAlex's record of the work, asked for the PDFs Unpaywall did not
    /// name (#480, stage B).
    case openAlex = "openalex"
    /// A PDF OpenAlex named that could not be obtained: OpenAlex answered, the
    /// copy went unassessed (#478's rule).
    case openAlexPDF = "openalex_pdf"
```

and to `serviceName`:

```swift
        case .openAlex: return "OpenAlex"
        case .openAlexPDF: return "OpenAlex's copy"
```

Run: `cd Packages/BioMedLit && swift test --filter OpenAccessShortfallContractTests`
Expected: PASS. `testEachSourceIsNamedAsPythonNamesIt`, the notice rows and the round trip all read the new rows.

- [ ] **Step 5: Kotlin: the source entries**

In `OpenAccessShortfall.kt`, add after `PDF(...)`:

```kotlin
    /** OpenAlex's record of the work, asked for the PDFs Unpaywall did not name (#480, stage B). */
    OPENALEX("openalex", "OpenAlex"),

    /** A PDF OpenAlex named that could not be obtained: OpenAlex answered, the copy went unassessed. */
    OPENALEX_PDF("openalex_pdf", "OpenAlex's copy");
```

Mind the `;` that ends the entry list.

Run: `cd android/MedicalFactChecker && ./gradlew testDebugUnitTest --tests '*OpenAccessShortfall*' -q`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/bmlibrarian_lite/constants.py doc/cross_platform/fulltext_parity/open_access_unsettled_notice.json tests/test_open_access_unsettled_notice.py Packages/BioMedLit/Sources/BioMedLit/Models/OpenAccessShortfall.swift android/MedicalFactChecker/app/src/main/java/com/bmlibrarian/factchecker/domain/model/OpenAccessShortfall.kt
git commit -m "feat(all): name OpenAlex and its copy in the open-access shortfall (#480)

Refs #480.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: The tried-sources statement and the caching note: contract and Python

**Files:**
- Create: `doc/cross_platform/fulltext_parity/open_access_statement.json`
- Modify: `src/bmlibrarian_lite/data_models.py`:
  - `SourceLookupFailure` (L312), `SourceLookupSkipped` (L410): an `address`
  - `LookupSkipReason` (L356) and `_SKIP_REASONS`: `NOT_SAVED`
- Modify: `src/bmlibrarian_lite/analysis_failures.py`:
  - new `address_host`, `tried_sources_statement`, `not_saved_note`
  - `unestablished_access_clause` (L1007), `refused_access_sentence` (L1078), `paywall_message` (L1100), `no_pdf_sources_message` (L1124)
- Modify: `src/bmlibrarian_lite/constants.py` (`SERVICE_OPENALEX*` exist from Task 2)
- Create: `tests/test_open_access_statement.py`

**Interfaces:**
- Produces, in `data_models`:
  - `SourceLookupFailure(service, failure, address: str | None = None)`
  - `SourceLookupSkipped(service, reason, address: str | None = None)`
  - Both strip the address; a blank one is `None`.
  - `LookupSkipReason.NOT_SAVED = "not_saved"`, worded "served, but could not be saved on this device".
- Produces, in `analysis_failures`:
  - `address_host(address: str) -> str`
  - `tried_sources_statement(record: LookupRecord) -> str`, which is `""` when no PDF was tried
  - `not_saved_note(record: LookupRecord, link_kept: bool = False) -> str`, which is `""` without a `NOT_SAVED` skip
  - `TRIED_SOURCES_LEAD`
- Every existing sentence builder ignores `NOT_SAVED` skips for its access wording, and appends `not_saved_note` instead.

- [ ] **Step 1: The fixture**

Create `doc/cross_platform/fulltext_parity/open_access_statement.json` with exactly this content. It was generated from a prototype of the Python below, and its lookup-only rows equal what today's `unestablished_access_clause` builds:

```json
{
  "schema_version": 1,
  "description": "What the reader is told once open-access PDFs were tried and none obtained (#480 stage B, maintainer's decision 2026-10-05), the caching note for a PDF served but not saved (decision 3), and the apps' stored list (schema 2). Read by tests/test_open_access_statement.py (Python: hosts, statements, not_saved_note), Packages/BioMedLit OpenAccessStatementContractTests and Android OpenAccessStatementContractTest (every table). The rules are in doc/cross_platform/fulltext_retrieval.md, 'Tried sources (#480)'. An entry is a lookup (source, kind and status_code, or skipped) or a tried PDF (unpaywall_pdf or openalex_pdf with an address). statements: with a tried PDF, 'Failed to obtain a PDF from the following tried sources: ' and each entry, in chain order (unpaywall, unpaywall_landing_page, unpaywall_pdf, openalex, openalex_pdf; stable), a PDF as '{host}, named by {Unpaywall|OpenAlex} ({reason})', a lookup once per service as '{name} ({reason})' (Python's _unsettled picks the reason), then the ending ('A freely available copy may exist. ' only if an entry could not be asked) and the configuration nudge; without one, Python's grouped unestablished_access_clause. hosts: the address's host, lower-cased, else the address trimmed. persisted.written: a single entry without an address keeps schema 1 (open_access_unsettled_notice.json); anything else is schema 2. persisted.read: every stored value reads as some shortfall. Add a row here, not a test on one platform.",
  "lead": "Failed to obtain a PDF from the following tried sources: ",
  "hosts": [
    {
      "address": "https://Walled.Example.org/a.pdf",
      "host": "walled.example.org"
    },
    {
      "address": "http://real.mtak.hu/138217/1/article-p187.pdf",
      "host": "real.mtak.hu"
    },
    {
      "address": "ftp://repo.example.org/x.pdf",
      "host": "repo.example.org"
    },
    {
      "address": " /bitstream/a.pdf ",
      "host": "/bitstream/a.pdf"
    },
    {
      "address": "https://repo.example.org:8443/a.pdf",
      "host": "repo.example.org"
    },
    {
      "address": "not a url",
      "host": "not a url"
    }
  ],
  "statements": [
    {
      "name": "one PDF refused",
      "entries": [
        {
          "source": "unpaywall_pdf",
          "kind": "http_status",
          "status_code": 403,
          "address": "https://walled.example.org/a.pdf"
        }
      ],
      "statement": "Failed to obtain a PDF from the following tried sources: walled.example.org, named by Unpaywall (HTTP 403 Forbidden). Whether this document is open access was not established."
    },
    {
      "name": "two Unpaywall PDFs and an unreachable OpenAlex",
      "entries": [
        {
          "source": "unpaywall_pdf",
          "kind": "http_status",
          "status_code": 403,
          "address": "https://walled.example.org/a.pdf"
        },
        {
          "source": "unpaywall_pdf",
          "kind": "malformed_response",
          "status_code": null,
          "address": "https://repo.example.org/b.pdf"
        },
        {
          "source": "openalex",
          "kind": "timeout",
          "status_code": null
        }
      ],
      "statement": "Failed to obtain a PDF from the following tried sources: walled.example.org, named by Unpaywall (HTTP 403 Forbidden); repo.example.org, named by Unpaywall (the response could not be read); OpenAlex (the request timed out). A freely available copy may exist. Whether this document is open access was not established."
    },
    {
      "name": "chain order, whatever the order given",
      "entries": [
        {
          "source": "openalex_pdf",
          "kind": "http_status",
          "status_code": 404,
          "address": "https://oa.example.org/c.pdf"
        },
        {
          "source": "unpaywall_pdf",
          "kind": "http_status",
          "status_code": 403,
          "address": "https://walled.example.org/a.pdf"
        }
      ],
      "statement": "Failed to obtain a PDF from the following tried sources: walled.example.org, named by Unpaywall (HTTP 403 Forbidden); oa.example.org, named by OpenAlex (HTTP 404 Not Found). Whether this document is open access was not established."
    },
    {
      "name": "Unpaywall not configured, then OpenAlex's PDF refused",
      "entries": [
        {
          "source": "unpaywall",
          "skipped": "not_configured"
        },
        {
          "source": "openalex_pdf",
          "kind": "http_status",
          "status_code": 403,
          "address": "https://repo.example.org/b.pdf"
        }
      ],
      "statement": "Failed to obtain a PDF from the following tried sources: Unpaywall (not configured); repo.example.org, named by OpenAlex (HTTP 403 Forbidden). A freely available copy may exist. Whether this document is open access was not established. Configuring Unpaywall would add an open-access route this search did not have."
    },
    {
      "name": "an unread landing page, then OpenAlex's PDF not a PDF",
      "entries": [
        {
          "source": "unpaywall_landing_page",
          "kind": "http_status",
          "status_code": 502
        },
        {
          "source": "openalex_pdf",
          "kind": "malformed_response",
          "status_code": null,
          "address": "https://oa.example.org/c.pdf"
        }
      ],
      "statement": "Failed to obtain a PDF from the following tried sources: the open-access copy's landing page (HTTP 502 Bad Gateway); oa.example.org, named by OpenAlex (the response could not be read). A freely available copy may exist. Whether this document is open access was not established."
    },
    {
      "name": "an address with no host is named as given",
      "entries": [
        {
          "source": "unpaywall_pdf",
          "kind": "request_failed",
          "status_code": null,
          "address": " /bitstream/a.pdf "
        }
      ],
      "statement": "Failed to obtain a PDF from the following tried sources: /bitstream/a.pdf, named by Unpaywall (the request failed). A freely available copy may exist. Whether this document is open access was not established."
    },
    {
      "name": "a lookup named once, by the failure that left it open",
      "entries": [
        {
          "source": "openalex",
          "kind": "http_status",
          "status_code": 400
        },
        {
          "source": "openalex",
          "kind": "timeout",
          "status_code": null
        },
        {
          "source": "openalex_pdf",
          "kind": "http_status",
          "status_code": 403,
          "address": "https://oa.example.org/c.pdf"
        }
      ],
      "statement": "Failed to obtain a PDF from the following tried sources: OpenAlex (the request timed out); oa.example.org, named by OpenAlex (HTTP 403 Forbidden). A freely available copy may exist. Whether this document is open access was not established."
    },
    {
      "name": "lookups only: Python's grouped sentence",
      "entries": [
        {
          "source": "unpaywall",
          "kind": "timeout",
          "status_code": null
        },
        {
          "source": "openalex",
          "kind": "http_status",
          "status_code": 503
        }
      ],
      "statement": "Unpaywall (the request timed out) and OpenAlex (HTTP 503 Service Unavailable) could not be asked, so a freely available copy may exist. Whether this document is open access was not established."
    },
    {
      "name": "lookups only, one answered",
      "entries": [
        {
          "source": "unpaywall",
          "skipped": "not_configured"
        },
        {
          "source": "openalex",
          "kind": "http_status",
          "status_code": 400
        }
      ],
      "statement": "Unpaywall (not configured) could not be asked, and OpenAlex (HTTP 400 Bad Request) did not serve it, so a freely available copy may exist. Whether this document is open access was not established. Configuring Unpaywall would add an open-access route this search did not have."
    },
    {
      "name": "one lookup: today's sentence",
      "entries": [
        {
          "source": "openalex",
          "kind": "timeout",
          "status_code": null
        }
      ],
      "statement": "OpenAlex (the request timed out) could not be asked, so a freely available copy may exist. Whether this document is open access was not established."
    }
  ],
  "not_saved_note": [
    {
      "address": "https://repo.example.org/b.pdf",
      "link_kept": true,
      "note": "A PDF of this article was found at repo.example.org but could not be saved on this device, so only its link is kept. Check the free storage space and try again."
    },
    {
      "address": "https://repo.example.org/b.pdf",
      "link_kept": false,
      "note": "A PDF of this article was found at repo.example.org but could not be saved on this device, so it could not be read. Check the free storage space and try again."
    }
  ],
  "persisted": {
    "written": [
      {
        "name": "one lookup keeps schema 1",
        "entries": [
          {
            "source": "openalex",
            "kind": "timeout",
            "status_code": null
          }
        ],
        "stored": {
          "schema_version": 1,
          "source": "openalex",
          "failure": {
            "kind": "timeout",
            "status_code": null
          }
        }
      },
      {
        "name": "a tried PDF is schema 2",
        "entries": [
          {
            "source": "unpaywall_pdf",
            "kind": "http_status",
            "status_code": 403,
            "address": "https://walled.example.org/a.pdf"
          }
        ],
        "stored": {
          "schema_version": 2,
          "entries": [
            {
              "source": "unpaywall_pdf",
              "address": "https://walled.example.org/a.pdf",
              "failure": {
                "kind": "http_status",
                "status_code": 403
              }
            }
          ]
        }
      },
      {
        "name": "a skip and a tried PDF",
        "entries": [
          {
            "source": "unpaywall",
            "skipped": "not_configured"
          },
          {
            "source": "openalex_pdf",
            "kind": "http_status",
            "status_code": 403,
            "address": "https://repo.example.org/b.pdf"
          }
        ],
        "stored": {
          "schema_version": 2,
          "entries": [
            {
              "source": "unpaywall",
              "skipped": "not_configured"
            },
            {
              "source": "openalex_pdf",
              "address": "https://repo.example.org/b.pdf",
              "failure": {
                "kind": "http_status",
                "status_code": 403
              }
            }
          ]
        }
      },
      {
        "name": "two lookups are schema 2",
        "entries": [
          {
            "source": "unpaywall",
            "kind": "timeout",
            "status_code": null
          },
          {
            "source": "openalex",
            "kind": "http_status",
            "status_code": 503
          }
        ],
        "stored": {
          "schema_version": 2,
          "entries": [
            {
              "source": "unpaywall",
              "failure": {
                "kind": "timeout",
                "status_code": null
              }
            },
            {
              "source": "openalex",
              "failure": {
                "kind": "http_status",
                "status_code": 503
              }
            }
          ]
        }
      }
    ],
    "read": [
      {
        "name": "a schema 1 record is one entry",
        "stored": "{\"schema_version\":1,\"source\":\"unpaywall_pdf\",\"failure\":{\"kind\":\"http_status\",\"status_code\":403}}",
        "entries": [
          {
            "source": "unpaywall_pdf",
            "kind": "http_status",
            "status_code": 403
          }
        ]
      },
      {
        "name": "a schema 2 record",
        "stored": "{\"schema_version\":2,\"entries\":[{\"source\":\"unpaywall_pdf\",\"address\":\"https://walled.example.org/a.pdf\",\"failure\":{\"kind\":\"http_status\",\"status_code\":403}},{\"source\":\"openalex\",\"failure\":{\"kind\":\"timeout\",\"status_code\":null}}]}",
        "entries": [
          {
            "source": "unpaywall_pdf",
            "kind": "http_status",
            "status_code": 403,
            "address": "https://walled.example.org/a.pdf"
          },
          {
            "source": "openalex",
            "kind": "timeout",
            "status_code": null
          }
        ]
      },
      {
        "name": "an entry that is not an object reads as a failed request",
        "stored": "{\"schema_version\":2,\"entries\":[7,{\"source\":\"openalex\",\"failure\":{\"kind\":\"timeout\",\"status_code\":null}}]}",
        "entries": [
          {
            "source": "unpaywall",
            "kind": "request_failed",
            "status_code": null
          },
          {
            "source": "openalex",
            "kind": "timeout",
            "status_code": null
          }
        ]
      },
      {
        "name": "an unknown source reads as Unpaywall's",
        "stored": "{\"schema_version\":2,\"entries\":[{\"source\":\"quantum\",\"failure\":{\"kind\":\"timeout\",\"status_code\":null}}]}",
        "entries": [
          {
            "source": "unpaywall",
            "kind": "timeout",
            "status_code": null
          }
        ]
      },
      {
        "name": "a blank address is no address",
        "stored": "{\"schema_version\":2,\"entries\":[{\"source\":\"unpaywall_pdf\",\"address\":\"  \",\"failure\":{\"kind\":\"http_status\",\"status_code\":403}}]}",
        "entries": [
          {
            "source": "unpaywall_pdf",
            "kind": "http_status",
            "status_code": 403
          }
        ]
      },
      {
        "name": "no entries reads as a failed request",
        "stored": "{\"schema_version\":2,\"entries\":[]}",
        "entries": [
          {
            "source": "unpaywall",
            "kind": "request_failed",
            "status_code": null
          }
        ]
      },
      {
        "name": "entries that are not a list read as a failed request",
        "stored": "{\"schema_version\":2,\"entries\":{}}",
        "entries": [
          {
            "source": "unpaywall",
            "kind": "request_failed",
            "status_code": null
          }
        ]
      },
      {
        "name": "an unknown schema reads as a failed request",
        "stored": "{\"schema_version\":3,\"entries\":[]}",
        "entries": [
          {
            "source": "unpaywall",
            "kind": "request_failed",
            "status_code": null
          }
        ]
      },
      {
        "name": "a stored skip in schema 2",
        "stored": "{\"schema_version\":2,\"entries\":[{\"source\":\"unpaywall\",\"skipped\":\"not_configured\"}]}",
        "entries": [
          {
            "source": "unpaywall",
            "skipped": "not_configured"
          }
        ]
      }
    ]
  }
}
```

- [ ] **Step 2: The failing tests**

Create `tests/test_open_access_statement.py`:

```python
# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""What the reader is told once open-access PDFs were tried (#480, stage B).

The maintainer's decisions of 2026-10-05: when PDFs were tried and none
obtained, every source tried is listed, each PDF by host and by who named
it; a lookup-only shortfall keeps today's sentence; a PDF served but not
saved is a caching note of its own. The rows are the shared contract,
``doc/cross_platform/fulltext_parity/open_access_statement.json``; Python
reads its hosts, statements and notes (the stored list is the apps').
"""

import json
from pathlib import Path
from typing import Any

import pytest

from bmlibrarian_lite.analysis_failures import (
    TRIED_SOURCES_LEAD,
    address_host,
    not_saved_note,
    paywall_message,
    tried_sources_statement,
    unestablished_access_clause,
    with_unestablished_access,
)
from bmlibrarian_lite.constants import (
    SERVICE_OPENALEX,
    SERVICE_OPENALEX_PDF,
    SERVICE_UNPAYWALL,
    SERVICE_UNPAYWALL_LANDING_PAGE,
    SERVICE_UNPAYWALL_PDF,
)
from bmlibrarian_lite.data_models import (
    LookupRecord,
    LookupSkipReason,
    RequestFailure,
    RequestFailureKind,
    SourceLookupFailure,
    SourceLookupSkipped,
)

CONTRACT: dict[str, Any] = json.loads(
    (
        Path(__file__).resolve().parents[1]
        / "doc"
        / "cross_platform"
        / "fulltext_parity"
        / "open_access_statement.json"
    ).read_text(encoding="utf-8")
)

SERVICES = {
    "unpaywall": SERVICE_UNPAYWALL,
    "unpaywall_landing_page": SERVICE_UNPAYWALL_LANDING_PAGE,
    "unpaywall_pdf": SERVICE_UNPAYWALL_PDF,
    "openalex": SERVICE_OPENALEX,
    "openalex_pdf": SERVICE_OPENALEX_PDF,
}
_PDF = "https://repo.example.org/b.pdf"


def _record(entries: list[dict[str, Any]]) -> LookupRecord:
    """The record a contract row's entries describe, failures then skips."""
    failures, skipped = [], []
    for entry in entries:
        service, address = SERVICES[entry["source"]], entry.get("address")
        if entry.get("skipped"):
            skipped.append(SourceLookupSkipped(service, LookupSkipReason(entry["skipped"]), address))
        else:
            failure = RequestFailure(RequestFailureKind(entry["kind"]), entry["status_code"])
            failures.append(SourceLookupFailure(service, failure, address))
    return LookupRecord(tuple(failures), tuple(skipped))


def _not_saved(address: str = _PDF) -> LookupRecord:
    return LookupRecord(
        skipped=(SourceLookupSkipped(SERVICE_UNPAYWALL_PDF, LookupSkipReason.NOT_SAVED, address),)
    )


def test_every_contract_table_is_read_somewhere() -> None:
    """Python reads three tables; the apps read the stored list too."""
    assert set(CONTRACT) == {
        "schema_version", "description", "lead", "hosts", "statements",
        "not_saved_note", "persisted",
    }
    assert CONTRACT["lead"] == TRIED_SOURCES_LEAD


@pytest.mark.parametrize("row", CONTRACT["hosts"], ids=lambda row: row["address"])
def test_hosts(row: dict[str, Any]) -> None:
    assert address_host(row["address"]) == row["host"]


@pytest.mark.parametrize("row", CONTRACT["statements"], ids=lambda row: row["name"])
def test_statements(row: dict[str, Any]) -> None:
    """Each row's entries are told as the contract words them."""
    assert unestablished_access_clause(_record(row["entries"])) == row["statement"]


@pytest.mark.parametrize("row", CONTRACT["not_saved_note"], ids=lambda row: str(row["link_kept"]))
def test_not_saved_note(row: dict[str, Any]) -> None:
    assert not_saved_note(_not_saved(row["address"]), link_kept=row["link_kept"]) == row["note"]


def test_a_copy_not_saved_is_a_note_not_a_shortfall() -> None:
    """The copy exists, so access is not left open: only the note is told."""
    record = _not_saved()
    assert record.anything_unsettled, "absence is still not established"
    assert tried_sources_statement(record) == ""
    assert unestablished_access_clause(record) == not_saved_note(record)


def test_the_note_follows_the_statement() -> None:
    record = _record(CONTRACT["statements"][0]["entries"]).merged(_not_saved())
    assert unestablished_access_clause(record) == (
        f"{CONTRACT['statements'][0]['statement']} {not_saved_note(record)}"
    )


def test_a_refusal_with_tried_pdfs_lists_them() -> None:
    row = CONTRACT["statements"][1]
    message = paywall_message("Behind a paywall.", _record(row["entries"]))
    assert message == f"A source refused access to this document. {row['statement']}"


def test_a_claim_with_tried_pdfs_is_followed_by_the_list() -> None:
    row = CONTRACT["statements"][0]
    claim = "Failed to download PDF from any available source."
    assert with_unestablished_access(claim, _record(row["entries"])) == f"{claim} {row['statement']}"


def test_a_blank_address_is_none() -> None:
    failure = RequestFailure(RequestFailureKind.TIMEOUT)
    assert SourceLookupFailure(SERVICE_UNPAYWALL_PDF, failure, "  ").address is None
    assert SourceLookupFailure(SERVICE_UNPAYWALL_PDF, failure, f" {_PDF} ").address == _PDF


def test_the_contract_has_rows() -> None:
    assert len(CONTRACT["statements"]) >= 8
    assert len(CONTRACT["hosts"]) >= 5
```

Run: `pytest tests/test_open_access_statement.py -q`
Expected: FAIL. `ImportError: cannot import name 'TRIED_SOURCES_LEAD'`.

- [ ] **Step 3: The data model**

In `data_models.py`, `LookupSkipReason` gains:

```python
    #: The source served the PDF and this application could not save it: a
    #: fault of ours, not the source's answer. The copy exists, so it is told
    #: as a caching note of its own (``analysis_failures.not_saved_note``),
    #: never as an access shortfall; it is still unread, so it keeps the
    #: discovery from concluding the article has no full text (#480).
    NOT_SAVED = "not_saved"
```

and `_SKIP_REASONS` gains `LookupSkipReason.NOT_SAVED: "served, but could not be saved on this device"`.

`SourceLookupFailure` and `SourceLookupSkipped` each gain a last field, `address: str | None = None`, documented as:

```
        address: The PDF a lookup tried, for a PDF a source named that we
            could not obtain (#480, stage B); ``None`` for a service's own
            lookup. Stripped on construction; blank is ``None``. The reader
            is told its host (``analysis_failures.address_host``).
```

Each `__post_init__` gains:

```python
        if self.address is not None:
            stripped = self.address.strip()
            object.__setattr__(self, "address", stripped or None)
```

- [ ] **Step 4: The sentences**

In `analysis_failures.py`, import `urlsplit` from `urllib.parse`, `SERVICE_OPENALEX`, `SERVICE_OPENALEX_PDF`, `SERVICE_UNPAYWALL_LANDING_PAGE` and `SERVICE_UNPAYWALL_PDF` (check which are imported already), and `SourceLookupSkipped`. Then add, before `unestablished_access_clause`:

```python
#: The open-access chain's sources, in the order they are tried (#480): the
#: tried-sources statement names them in this order, after any other source.
_OPEN_ACCESS_CHAIN = (
    SERVICE_UNPAYWALL,
    SERVICE_UNPAYWALL_LANDING_PAGE,
    SERVICE_UNPAYWALL_PDF,
    SERVICE_OPENALEX,
    SERVICE_OPENALEX_PDF,
)

#: Who named a tried PDF, by the service it is recorded under.
_NAMED_BY = {
    SERVICE_UNPAYWALL_PDF: SERVICE_UNPAYWALL,
    SERVICE_OPENALEX_PDF: SERVICE_OPENALEX,
}

TRIED_SOURCES_LEAD = "Failed to obtain a PDF from the following tried sources: "
_TRIED_UNASKED_ENDING = (
    "A freely available copy may exist. Whether this document is open access "
    "was not established."
)
_TRIED_ANSWERED_ENDING = "Whether this document is open access was not established."


def address_host(address: str) -> str:
    """The name a tried PDF is told by: its host, else the address itself.

    Args:
        address: The PDF's address, as the source gave it.

    Returns:
        The host, lower-cased and without a port; an address with no host
        (a relative path, text that is no URL) trimmed, as given.
    """
    trimmed = address.strip()
    try:
        host = urlsplit(trimmed).hostname
    except ValueError:
        host = None
    return host or trimmed


def _without_not_saved(record: LookupRecord) -> LookupRecord:
    """The record without its caching notes, which are not access shortfalls."""
    return LookupRecord(
        record.failures,
        tuple(s for s in record.skipped if s.reason is not LookupSkipReason.NOT_SAVED),
    )


def _chain_rank(service: str) -> int:
    """Where a service sits in the open-access chain; -1 outside it."""
    return _OPEN_ACCESS_CHAIN.index(service) if service in _OPEN_ACCESS_CHAIN else -1


def tried_sources_statement(record: LookupRecord) -> str:
    """List every source tried, once open-access PDFs were tried (#480).

    The maintainer's decision of 2026-10-05: each PDF a source named that we
    could not obtain is told by its host and by who named it; each lookup
    that went unsettled once, with the reason :func:`_unsettled` picks; in
    chain order, any source outside the chain first. The ending follows the
    verbs, as :func:`_access_left_open`'s does.

    Args:
        record: What went unsettled; caching notes are ignored.

    Returns:
        Two sentences ending in a full stop, or ``""`` when no PDF was tried:
        a lookup-only record keeps :func:`_access_left_open`'s wording.
    """
    access = _without_not_saved(record)
    tried: list[SourceLookupFailure | SourceLookupSkipped] = [
        *(f for f in access.failures if f.address),
        *(s for s in access.skipped if s.address),
    ]
    if not tried:
        return ""
    lookups = LookupRecord(
        tuple(f for f in access.failures if not f.address),
        tuple(s for s in access.skipped if not s.address),
    )
    unasked, answered = _unsettled(lookups)
    reasons = {**answered, **unasked}
    services = list(dict.fromkeys(
        [f.service for f in lookups.failures] + [s.service for s in lookups.skipped]
    ))
    entries: list[tuple[int, int, str, bool]] = [
        (_chain_rank(service), position, f"{service} ({reasons[service]})", service in unasked)
        for position, service in enumerate(services)
    ]
    for position, item in enumerate(tried, start=len(entries)):
        if isinstance(item, SourceLookupFailure):
            reason, could_not_ask = item.failure.describe(), not item.failure.is_answer
        else:
            reason, could_not_ask = item.describe(), True
        named_by = _NAMED_BY.get(item.service, item.service)
        text = f"{address_host(item.address or '')}, named by {named_by} ({reason})"
        entries.append((_chain_rank(item.service), position, text, could_not_ask))
    entries.sort(key=lambda entry: (entry[0], entry[1]))
    ending = (
        _TRIED_UNASKED_ENDING if any(entry[3] for entry in entries) else _TRIED_ANSWERED_ENDING
    )
    return f"{TRIED_SOURCES_LEAD}{'; '.join(entry[2] for entry in entries)}. {ending}"


def not_saved_note(record: LookupRecord, link_kept: bool = False) -> str:
    """Tell the reader a PDF was served and could not be saved (#480).

    A fault of ours, not the source's answer, so it is a note of its own and
    never in the tried-sources list (the maintainer's decision, 2026-10-05).

    Args:
        record: What went unsettled; only its ``NOT_SAVED`` skips are read.
        link_kept: Whether the PDF's link is what the reader is given (the
            apps); the desktop has none to give.

    Returns:
        One sentence and its advice, or ``""`` when no PDF went unsaved.
    """
    addresses = [
        s.address for s in record.skipped
        if s.reason is LookupSkipReason.NOT_SAVED and s.address
    ]
    if not addresses:
        return ""
    outcome = "only its link is kept" if link_kept else "it could not be read"
    return (
        f"A PDF of this article was found at {address_host(addresses[0])} but "
        f"could not be saved on this device, so {outcome}. Check the free "
        "storage space and try again."
    )
```

Replace the four builders' bodies:

```python
def unestablished_access_clause(record: LookupRecord) -> str:
    # docstring as now, plus: "With tried PDFs, the tried-sources statement
    # (#480); a caching note follows whatever is said."
    access = _without_not_saved(record)
    sentences: list[str] = []
    if access.anything_unsettled:
        sentences.append(_with_nudge(
            tried_sources_statement(access) or _sentence_start(_access_left_open(access)),
            access,
        ))
    note = not_saved_note(record)
    if note:
        sentences.append(note)
    return " ".join(sentences)


def refused_access_sentence(record: LookupRecord) -> str:
    # docstring as now, plus the tried-sources form
    access = _without_not_saved(record)
    statement = tried_sources_statement(access)
    if statement:
        return f"A source refused access to this document. {statement}"
    return (
        f"A source refused access to this document{_set_against(access)}"
        f"{_access_left_open(access)}"
    )


def paywall_message(claim: str, record: LookupRecord) -> str:
    access = _without_not_saved(record)
    text = (
        _with_nudge(refused_access_sentence(access), access)
        if access.anything_unsettled else claim
    )
    note = not_saved_note(record)
    return f"{text} {note}" if note else text


def no_pdf_sources_message(record: LookupRecord) -> str:
    access = _without_not_saved(record)
    if not access.anything_unsettled:
        text = "No PDF sources found. The document may require institutional access."
    else:
        text = _with_nudge(
            f"No PDF sources found for this document{_set_against(access)}"
            f"{_access_left_open(access)}",
            access,
        )
    note = not_saved_note(record)
    return f"{text} {note}" if note else text
```

Keep each function's existing docstring, and add one line about the new behaviour. `with_unestablished_access` needs no change: it calls `unestablished_access_clause`. `unsettled_lookups_clause`, which the transparency analyser reads, is unchanged. It still names each service once.

- [ ] **Step 5: Run the tests, and the suites that pin today's sentences**

Run: `pytest tests/test_open_access_statement.py tests/test_open_access_unsettled_notice.py tests/test_analysis_failures*.py tests/test_answered_lookup_verb.py -q`
Expected: PASS. Every row with no address is worded exactly as before.

Run: `pytest tests/ -q 2>&1 | tail -3` and `python .github/scripts/lint_delta.py --base-ref origin/master`
Expected: 0 failures; no new findings.

- [ ] **Step 6: Commit**

```bash
git add doc/cross_platform/fulltext_parity/open_access_statement.json src/bmlibrarian_lite/data_models.py src/bmlibrarian_lite/analysis_failures.py tests/test_open_access_statement.py
git commit -m "feat(python): list every source tried once PDFs were tried; a caching note (#480)

The maintainer's decisions of 2026-10-05: each tried PDF by host and by who
named it, each unsettled lookup once, in chain order; a lookup-only
shortfall keeps today's sentence; a PDF served but not saved is a note of
its own, never an access shortfall.

Refs #480.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Swift: the shortfall as a list, its statement and the caching note

**Files:**
- Modify: `Packages/BioMedLit/Sources/BioMedLit/Models/OpenAccessShortfall.swift`
- Create: `Packages/BioMedLit/Tests/BioMedLitTests/OpenAccessStatementContractTests.swift`
- Modify (only where they now fail to compile): callers of `OpenAccessShortfall.reason`. Find them with `grep -rn "\.reason" Packages/BioMedLit/Sources ios/MedicalFactChecker/Sources | grep -i shortfall`.

**Interfaces:**
- Produces:

```swift
public struct OpenAccessShortfall: Sendable, Equatable, Hashable {
    public struct Entry: Sendable, Equatable, Hashable {
        public let source: OpenAccessSource
        public let reason: OpenAccessUnsettledReason
        public let address: String?          // trimmed; blank is nil
        public init(source: OpenAccessSource, failure: RequestFailure, address: String? = nil)
        public var failure: RequestFailure? { get }
    }
    public let entries: [Entry]              // never empty
    public init(source: OpenAccessSource, failure: RequestFailure, address: String? = nil)
    public static let unpaywallNotConfigured: OpenAccessShortfall
    public var source: OpenAccessSource { get }   // entries[0]'s, kept for callers that log one
    public var reason: OpenAccessUnsettledReason { get }
    public var failure: RequestFailure? { get }
    public func appending(_ other: OpenAccessShortfall) -> OpenAccessShortfall
    public static func adding(_ next: OpenAccessShortfall, to existing: OpenAccessShortfall?) -> OpenAccessShortfall
    public var notice: String { get }        // tried-sources statement, or the grouped sentence
    public static func notSavedNote(address: String, linkKept: Bool) -> String
    public static func host(of address: String) -> String
    public func persisted() -> String         // v1 for one entry without an address, else v2
    public static func restored(fromPersisted stored: String) -> OpenAccessShortfall
}
```

`OpenAccessShortfall(source:failure:)` keeps working, so the existing single-entry tests and rows pass unchanged.

- [ ] **Step 1: The failing contract tests**

Create `OpenAccessStatementContractTests.swift`. Load the fixture with the same walk as `OpenAccessShortfallContractTests` (L33), pointed at `open_access_statement.json`. Build entries from rows with a helper:

```swift
    /// The shortfall a row's entries describe, in the order given.
    private func shortfall(_ rows: [[String: Any]]) throws -> OpenAccessShortfall {
        let parts: [OpenAccessShortfall] = try rows.map { row in
            let source = try XCTUnwrap(OpenAccessSource(rawValue: row["source"] as! String))
            if row["skipped"] as? String == "not_configured" { return .unpaywallNotConfigured }
            let failure = try XCTUnwrap(SearchFailureReporting.restoredFailure(row))
            return OpenAccessShortfall(source: source, failure: failure, address: row["address"] as? String)
        }
        return parts.dropFirst().reduce(parts[0]) { $0.appending($1) }
    }
```

`restoredFailure` reads `{kind, status_code}`. Pass the row itself, or build a `[kind, status_code]` object as `OpenAccessShortfallContractTests` does. Copy its helper if it has one.

Tests:
- `testEveryContractTableIsReadHere`: the key set `["schema_version", "description", "lead", "hosts", "statements", "not_saved_note", "persisted"]`.
- `testEachHostRow`: `OpenAccessShortfall.host(of:)` gives the row's host.
- `testEachStatementRow`: `try shortfall(row["entries"]).notice` equals the row's statement.
- `testEachNotSavedNoteRow`: `notSavedNote(address:linkKept:)` equals the row's note.
- `testEachWrittenRow`: compare parsed JSON of `persisted()` with `stored`, as `OpenAccessShortfallContractTests.testEachWrittenRow` does.
- `testEachReadRow`: `restored(fromPersisted:)` equals `shortfall(row["entries"])`.
- `testEveryShortfallRoundTrips`: for each statement row, `restored(fromPersisted: s.persisted()) == s`.

Run: `cd Packages/BioMedLit && swift build --build-tests 2>&1 | tail -5`
Expected: FAIL. `value of type 'OpenAccessShortfall' has no member 'appending'`.

- [ ] **Step 2: The entries**

Restructure the struct. The old `source` and `reason` stored properties become `Entry`'s, and the struct holds `entries`:

```swift
    /// One lookup, or one PDF a source named, that left the question open.
    public struct Entry: Sendable, Equatable, Hashable {
        /// Which lookup, or whose PDF.
        public let source: OpenAccessSource
        /// Why: a failed lookup, or an Unpaywall that was not configured.
        public let reason: OpenAccessUnsettledReason
        /// The PDF's address, for a PDF a source named (#480); `nil` for a
        /// service's own lookup. Trimmed; blank is `nil`.
        public let address: String?

        public init(source: OpenAccessSource, failure: RequestFailure, address: String? = nil) {
            self.init(source: source, reason: .failed(failure), address: address)
        }

        fileprivate init(source: OpenAccessSource, reason: OpenAccessUnsettledReason, address: String?) {
            self.source = source
            self.reason = reason
            let trimmed = address?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.address = (trimmed?.isEmpty ?? true) ? nil : trimmed
        }

        /// The failure, or `nil` for a lookup that was never made.
        public var failure: RequestFailure? {
            if case .failed(let failure) = reason { return failure }
            return nil
        }

        /// Whether it could not be asked (#435), which decides the ending.
        var couldNotBeAsked: Bool { failure.map { !$0.isAnswer } ?? true }

        /// Its reason as the reader is told it.
        var described: String { failure?.describe() ?? OpenAccessShortfall.notConfiguredDescription }
    }

    /// What went unsettled, in the order it was met; never empty.
    public let entries: [Entry]

    public init(source: OpenAccessSource, failure: RequestFailure, address: String? = nil) {
        self.init(entries: [Entry(source: source, failure: failure, address: address)])
    }

    private init(entries: [Entry]) {
        precondition(!entries.isEmpty, "a shortfall names what went unsettled")
        self.entries = entries
    }

    public static let unpaywallNotConfigured = OpenAccessShortfall(
        entries: [Entry(source: .unpaywall, reason: .notConfigured, address: nil)]
    )

    /// The first entry's source, reason and failure, for callers that log one.
    public var source: OpenAccessSource { entries[0].source }
    public var reason: OpenAccessUnsettledReason { entries[0].reason }
    public var failure: RequestFailure? { entries[0].failure }

    /// This shortfall, then `other`'s entries.
    public func appending(_ other: OpenAccessShortfall) -> OpenAccessShortfall {
        OpenAccessShortfall(entries: entries + other.entries)
    }

    /// `next` added after whatever is held: how the chain records each
    /// lookup and each PDF that went unsettled, in the order met.
    public static func adding(_ next: OpenAccessShortfall, to existing: OpenAccessShortfall?) -> OpenAccessShortfall {
        existing?.appending(next) ?? next
    }
```

`notConfiguredDescription` goes from `private` to `fileprivate`.

- [ ] **Step 3: The notice**

Replace `notice` with the port of Python's two forms:

```swift
    /// The open-access chain's sources in the order they are tried (#480).
    private static let chainOrder: [OpenAccessSource] = [.unpaywall, .landingPage, .pdf, .openAlex, .openAlexPDF]
    /// Who named a tried PDF.
    private static func namedBy(_ source: OpenAccessSource) -> String {
        source == .openAlexPDF ? OpenAccessSource.openAlex.serviceName : OpenAccessSource.unpaywall.serviceName
    }
    private static let triedSourcesLead = "Failed to obtain a PDF from the following tried sources: "
    private static let mayExistEnding = "so a freely available copy may exist. Whether this document is open access was not established."
    private static let answeredEnding = "so whether this document is open access was not established."

    /// What the reader is told (Python's `unestablished_access_clause`, word
    /// for word): with a tried PDF, every source tried (#480); otherwise each
    /// lookup grouped by its verb (#435). One lookup reads as it always has.
    public var notice: String {
        let sentence = entries.contains { $0.address != nil } ? triedSourcesStatement : groupedStatement
        return withNudge(sentence)
    }

    /// Python's `_unsettled`: each service once, by its first failure unless
    /// a later one could not be asked; failures before skips; a skipped
    /// service is named only if it never failed.
    private static func unsettled(_ lookups: [Entry]) -> (unasked: [(String, String)], answered: [(String, String)]) {
        var unasked: [(String, String)] = []
        var answered: [(String, String)] = []
        let failures = lookups.filter { $0.failure != nil }
        let skips = lookups.filter { $0.failure == nil }
        for entry in failures {
            let name = entry.source.serviceName
            if unasked.contains(where: { $0.0 == name }) { continue }
            if entry.couldNotBeAsked {
                answered.removeAll { $0.0 == name }
                unasked.append((name, entry.described))
            } else if !answered.contains(where: { $0.0 == name }) {
                answered.append((name, entry.described))
            }
        }
        for entry in skips {
            let name = entry.source.serviceName
            if !answered.contains(where: { $0.0 == name }), !unasked.contains(where: { $0.0 == name }) {
                unasked.append((name, entry.described))
            }
        }
        return (unasked, answered)
    }

    /// Python's `_joined`: "A (x)", "A (x) and B (y)", "A (x), B (y) and C (z)".
    private static func joined(_ named: [(String, String)]) -> String {
        let clauses = named.map { "\($0.0) (\($0.1))" }
        guard clauses.count > 1 else { return clauses.first ?? "" }
        return clauses.dropLast().joined(separator: ", ") + " and " + clauses.last!
    }

    private var groupedStatement: String {
        let (unasked, answered) = Self.unsettled(entries)
        var clauses: [String] = []
        if !unasked.isEmpty { clauses.append("\(Self.joined(unasked)) could not be asked") }
        if !answered.isEmpty { clauses.append("\(Self.joined(answered)) did not serve it") }
        let ending = unasked.isEmpty ? Self.answeredEnding : Self.mayExistEnding
        return Self.sentenceStart("\(clauses.joined(separator: ", and ")), \(ending)")
    }

    private var triedSourcesStatement: String {
        let lookups = entries.filter { $0.address == nil }
        let (unasked, answered) = Self.unsettled(lookups)
        let reasons = Dictionary(answered + unasked, uniquingKeysWith: { _, last in last })
        var services: [OpenAccessSource] = []
        for entry in lookups.filter({ $0.failure != nil }) + lookups.filter({ $0.failure == nil })
        where !services.contains(entry.source) {
            services.append(entry.source)
        }
        var items: [(rank: Int, position: Int, text: String, unasked: Bool)] = services.enumerated().map {
            let name = $1.serviceName
            return (Self.chainOrder.firstIndex(of: $1) ?? -1, $0, "\(name) (\(reasons[name] ?? ""))",
                    unasked.contains { $0.0 == name })
        }
        for (offset, entry) in entries.filter({ $0.address != nil }).enumerated() {
            items.append((Self.chainOrder.firstIndex(of: entry.source) ?? -1, services.count + offset,
                          "\(Self.host(of: entry.address!)), named by \(Self.namedBy(entry.source)) (\(entry.described))",
                          entry.couldNotBeAsked))
        }
        items.sort { ($0.rank, $0.position) < ($1.rank, $1.position) }
        let ending = items.contains { $0.unasked }
            ? "A freely available copy may exist. Whether this document is open access was not established."
            : "Whether this document is open access was not established."
        return Self.triedSourcesLead + items.map(\.text).joined(separator: "; ") + ". " + ending
    }

    /// Python's `configuration_nudge`: only Unpaywall is ever not configured.
    private func withNudge(_ sentence: String) -> String {
        guard entries.contains(where: { $0.reason == .notConfigured }) else { return sentence }
        return "\(sentence) Configuring \(OpenAccessSource.unpaywall.serviceName) would add an open-access route this search did not have."
    }

    /// Python's `address_host`: the host, lower-cased and without a port;
    /// else the address trimmed.
    public static func host(of address: String) -> String {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        return URLComponents(string: trimmed)?.host?.lowercased().nilIfEmpty ?? trimmed
    }

    /// Python's `not_saved_note` (#480): a PDF served and not saved is ours to fix.
    public static func notSavedNote(address: String, linkKept: Bool) -> String {
        let outcome = linkKept ? "only its link is kept" : "it could not be read"
        return "A PDF of this article was found at \(host(of: address)) but could not be saved on this device, "
            + "so \(outcome). Check the free storage space and try again."
    }
```

If there is no `nilIfEmpty` helper, write `.flatMap { $0.isEmpty ? nil : $0 }`. Check the host rows for `"not a url"` and `" /bitstream/a.pdf "`: `URLComponents(string:)` returns `nil` or an empty host for both. A shortfall whose entries are `[unpaywallNotConfigured]` must still word itself exactly as today's row; `groupedStatement` plus `withNudge` does.

- [ ] **Step 4: The stored form**

`persisted()`: one entry with no address writes today's v1 object, unchanged. Otherwise it writes:

```swift
        [keySchemaVersion: 2, keyEntries: entries.map { entry -> [String: Any] in
            var object: [String: Any] = [keySource: entry.source.rawValue]
            if let address = entry.address { object[keyAddress] = address }
            switch entry.reason {
            case .failed(let failure): object[keyFailure] = SearchFailureReporting.failureObject(failure)
            case .notConfigured: object[keySkipped] = skippedNotConfigured
            }
            return object
        }]
```

with `keyEntries = "entries"`, `keyAddress = "address"` and `schemaVersionList: Int64 = 2`.

`restored(fromPersisted:)`:
- version 1 is read as today, one entry.
- version 2 maps each element of `entries`:
  - an element that is not an object becomes `Entry(source: .unpaywall, failure: .requestFailed)`;
  - a `skipped: not_configured` becomes `unpaywallNotConfigured`'s entry;
  - otherwise `source` (an unknown one is `.unpaywall`), the failure through `SearchFailureReporting.restoredFailure`, and the address only when it is a string.
- An `entries` that is not a non-empty list, and any other version, read as `uninterpretable`.

- [ ] **Step 5: Run the package suite**

Run: `cd Packages/BioMedLit && swift test --filter 'OpenAccess' && swift test 2>&1 | tail -5`
Expected: PASS. `OpenAccessShortfallContractTests`, the v1 rows, all pass unchanged.

- [ ] **Step 6: Commit**

```bash
git add Packages/BioMedLit
git commit -m "feat(swift): the open-access shortfall is a list, told as every source tried (#480)

Refs #480.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Kotlin: the shortfall as a list, its statement and the caching note

**Files:**
- Modify: `MAIN/domain/model/OpenAccessShortfall.kt`
- Create: `TEST/domain/model/OpenAccessStatementContractTest.kt`
- Modify (only where they no longer compile): destructuring or `copy()` of `OpenAccessShortfall`. Find them with `grep -rn "OpenAccessShortfall(" android/MedicalFactChecker/app/src`.

**Interfaces:**
- Produces:

```kotlin
data class OpenAccessShortfall(val entries: List<Entry>) {
    data class Entry(val source: OpenAccessSource, val reason: OpenAccessUnsettledReason, val address: String? = null)
    constructor(source: OpenAccessSource, reason: OpenAccessUnsettledReason)
    constructor(source: OpenAccessSource, failure: RequestFailure, address: String? = null)
    val source: OpenAccessSource        // entries.first()'s
    val reason: OpenAccessUnsettledReason
    val failure: RequestFailure?
    operator fun plus(other: OpenAccessShortfall): OpenAccessShortfall
    val notice: String
    fun toJson(): String                // v1 for one entry without an address, else v2
    companion object {
        val UNPAYWALL_NOT_CONFIGURED: OpenAccessShortfall
        fun fromJson(stored: String): OpenAccessShortfall
        fun host(address: String): String
        fun notSavedNote(address: String, linkKept: Boolean): String
        fun adding(next: OpenAccessShortfall, existing: OpenAccessShortfall?): OpenAccessShortfall
    }
}
```

`Entry`'s `init` trims the address; a blank one becomes `null` (`address?.trim()?.ifEmpty { null }`). `init { require(entries.isNotEmpty()) }`.

- [ ] **Step 1: The failing contract test**

Create `OpenAccessStatementContractTest.kt` the way `OpenAccessShortfallContractTest` reads its file (the walk to `.git`). Its tests mirror Task 4's list exactly:
- every table is read;
- each host row: `OpenAccessShortfall.host(address)`;
- each statement row: `notice`;
- each `not_saved_note` row;
- each written row: compare parsed `Json` elements;
- each read row: `fromJson`;
- every statement row round-trips.

Build a row's shortfall by mapping each entry and reducing with `+`:
- `skipped: not_configured` → `UNPAYWALL_NOT_CONFIGURED`;
- otherwise `OpenAccessShortfall(OpenAccessSource.fromPersisted(source), failureOf(entry), entry.string("address"))`, with `failureOf` built as `OpenAccessShortfallContractTest` builds a failure.

Run: `cd android/MedicalFactChecker && ./gradlew testDebugUnitTest --tests '*OpenAccessStatementContractTest*' -q`
Expected: FAIL (compile).

- [ ] **Step 2: The implementation**

Port Task 4, Steps 2–4, line for line:
- `entries`, `plus`, and `adding`.
- `notice`: `groupedStatement` or `triedSourcesStatement`, then the nudge.
- `unsettled`: use `LinkedHashMap`s for the two ordered maps; `remove` then `put` reproduces Python's `pop`-then-insert order.
- `joined`, `host`:

```kotlin
        fun host(address: String): String {
            val trimmed = address.trim()
            val parsed = runCatching { java.net.URI(trimmed).host }.getOrNull()
            return parsed?.lowercase(Locale.ROOT)?.takeIf { it.isNotEmpty() } ?: trimmed
        }
```

- `notSavedNote`.
- `toJson`: v1 for a single entry without an address, else `{"schema_version":2,"entries":[…]}` through `SearchFailureReporting.failureJson`.
- `fromJson`: version 1 as today; version 2 with each element degraded as in Task 4; anything else is `UNPAYWALL` + `REQUEST_FAILED`.

`java.net.URI("ftp://repo.example.org/x.pdf").host` is `repo.example.org`. `URI(" /bitstream/a.pdf ")` throws, because of the space, and the input is trimmed first anyway, so its host is null and the trimmed address is used. `URI("not a url")` throws too, which is the address as given. Check these against the host rows; that is what they are for.

- [ ] **Step 3: Run the Android suite**

Run: `cd android/MedicalFactChecker && ./gradlew testDebugUnitTest -q 2>&1 | tail -10`
Expected: 0 failures, apart from #490's flake. `OpenAccessShortfallContractTest`, the v1 rows, pass unchanged.

- [ ] **Step 4: Commit**

```bash
git add android/MedicalFactChecker/app/src
git commit -m "feat(android): the open-access shortfall is a list, told as every source tried (#480)

Refs #480.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Swift: try every Unpaywall PDF, list every failure, and tell a caching problem

**Files:**
- Modify: `Packages/BioMedLit/Sources/BioMedLit/Services/FullTextService.swift`. This covers the Unpaywall tier (L506–568), `fetchUnpaywallPDFWithRetry` (L1578), the Europe PMC render tier (L463–500), and the fallbacks (L570–640).
- Modify: `Packages/BioMedLit/Sources/BioMedLit/Models/FullTextModels.swift`: `FullTextResult` gains `pdfNotSavedFrom`; `noting(…)`.
- Create: `Packages/BioMedLit/Tests/BioMedLitTests/FullTextServiceUnpaywallLocationsTests.swift`
- Modify (the app):
  - `ios/MedicalFactChecker/Sources/Models/Document.swift`: `fullTextPDFNotSavedFrom`, written and cleared beside `fullTextOpenAccessShortfallJSON` (L258, L954, L1044, L1060, L1344)
  - `ios/MedicalFactChecker/Sources/Views/Components/ParseWarningBanner.swift`: a line for the note (L200, L284)
  - every caller passing `openAccessShortfall:` to `ParseWarningBannerContent` (`grep -rn "openAccessShortfall:" ios/MedicalFactChecker/Sources`)
  - `ios/MedicalFactChecker/Tests/StoreMigrationTests.swift`, `OpenAccessShortfallNoticeTests.swift`

**Interfaces:**
- Consumes: `UnpaywallLandingPage.pdfURLs(from:)` (Task 1); `OpenAccessShortfall.adding(_:to:)` and `notSavedNote(address:linkKept:)` (Task 4).
- Produces:
  - `FullTextResult.pdfNotSavedFrom: String?`, the PDF served and not saved.
  - `func noting(openAccessShortfall: OpenAccessShortfall?, pdfNotSavedFrom: String?) -> FullTextResult`, which replaces `noting(openAccessShortfall:)`.
  - `private func fetchUnpaywallPDFCandidates(doi: String) async throws -> [String]`
  - `private func tryOpenAccessPDFs(_:refusedAs:content:cacheKey:degradation:holdingAbstract:articleName:linkFallback:shortfall:notSavedFrom:tried:) async throws -> FullTextResult?`, which Task 12 reuses.
  - `static func settledOpenAccessShortfall(_:copyServed:) -> OpenAccessShortfall?`
  - App: `Document.fullTextPDFNotSavedFrom: String?` and `Document.storedPDFNotSavedNote: String?`

- [ ] **Step 1: The failing tests**

Create `FullTextServiceUnpaywallLocationsTests.swift`. Copy `setUp`, `tearDown`, the no-hit Europe PMC search body and the `ExtractingStub` construction from `UnpaywallLandingPageServiceTests`.
- `pdfBody` is `Data("%PDF-1.7\n".utf8) + Data(repeating: 0x30, count: 64)`.
- `fetch()` calls `FullTextService(email: "test@example.org", session:, europePMCService: EuropePMCService(session: session), extractor: ExtractingStub()).fetchFullText(pmcId: nil, doi: doi, pmid: "")`.

```swift
import XCTest
@testable import BioMedLit

/// Every PDF Unpaywall names is tried, in Unpaywall's order; every failure is
/// told; a copy served but not saved ends the walk with a caching note
/// (#480, stage B; the maintainer's decisions of 2026-10-05).
final class FullTextServiceUnpaywallLocationsTests: XCTestCase {
    private let doi = "10.1/locations"
    private let first = "https://walled.example.org/a.pdf"
    private let second = "https://repo.example.org/b.pdf"

    private func unpaywall(_ pdfs: [String]) -> Data {
        let locations = pdfs.map { ["url_for_pdf": $0, "url": $0] }
        let body: [String: Any] = ["best_oa_location": locations.first as Any, "oa_locations": locations]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    func testASecondLocationIsTriedWhenTheFirstIsRefused() async throws {
        StubURLProtocol.routes["unpaywall"] = (200, unpaywall([first, second]))
        StubURLProtocol.routes["walled.example.org"] = (403, Data())
        StubURLProtocol.routes["repo.example.org"] = (200, pdfBody)

        let result = try await fetch()

        XCTAssertEqual(result.content, .unpaywall(pdfURL: URL(string: second)!))
        XCTAssertNil(result.openAccessShortfall, "a served copy settles it")
    }

    func testEveryLocationRefusedIsToldEachByItsHost() async throws {
        StubURLProtocol.routes["unpaywall"] = (200, unpaywall([first, second]))
        StubURLProtocol.routes["walled.example.org"] = (403, Data())
        StubURLProtocol.routes["repo.example.org"] = (503, Data())

        let result = try await fetch()

        XCTAssertEqual(result.content, .doi(webURL: URL(string: "https://doi.org/\(doi)")!))
        XCTAssertEqual(
            result.openAccessShortfall,
            OpenAccessShortfall(source: .pdf, failure: .httpStatus(403), address: first)
                .appending(OpenAccessShortfall(source: .pdf, failure: .httpStatus(503), address: second))
        )
    }

    func testTheRepeatedBestLocationIsRequestedOnce() async throws {
        StubURLProtocol.routes["unpaywall"] = (200, unpaywall([first, first]))
        StubURLProtocol.routes["walled.example.org"] = (403, Data())

        _ = try await fetch()

        // A PDF download retries only transport errors (`.pdfDownload` with
        // `retryOnlyTransient`), so a 403 is one request: two would mean the
        // repeated location was tried twice
        XCTAssertEqual(StubURLProtocol.requestedURLs.filter { $0.contains("walled.example.org") }.count, 1)
    }

    func testAnUnfetchableAddressIsListedAndTheNextTried() async throws {
        StubURLProtocol.routes["unpaywall"] = (200, unpaywall(["ftp://repo.example.org/x.pdf", second]))
        StubURLProtocol.routes["repo.example.org"] = (200, pdfBody)

        let result = try await fetch()

        XCTAssertEqual(result.content, .unpaywall(pdfURL: URL(string: second)!))
        XCTAssertNil(result.openAccessShortfall)
    }

    /// `.notCached` needs a cache write that fails, which no test can cause
    /// (`pdfCacheDirectory` is a fixed location), so the rules are pinned
    /// where the chain applies them.
    func testAServedButUncachedCopySettlesTheQuestion() {
        let refused = OpenAccessShortfall(source: .pdf, failure: .httpStatus(403), address: first)
        XCTAssertNil(FullTextService.settledOpenAccessShortfall(refused, copyServed: true))
        XCTAssertEqual(FullTextService.settledOpenAccessShortfall(refused, copyServed: false), refused)
        let link = FullTextResult(content: .unpaywall(pdfURL: URL(string: second)!), degradation: nil)
            .noting(openAccessShortfall: nil, pdfNotSavedFrom: second)
        XCTAssertNil(link.openAccessShortfall, "the init's assert holds")
        XCTAssertEqual(link.pdfNotSavedFrom, second)
    }
}
```

Run: `cd Packages/BioMedLit && swift test --filter FullTextServiceUnpaywallLocationsTests`
Expected: FAIL (compile). `noting(openAccessShortfall:pdfNotSavedFrom:)` is missing.

- [ ] **Step 2: The result carries the caching note**

In `FullTextModels.swift`, `FullTextResult` gains:

```swift
    /// The PDF a source served that could not be saved on this device (#480):
    /// a fault of ours, told as a note of its own, never as a shortfall
    /// (`OpenAccessShortfall.notSavedNote`). `nil` when none was.
    public let pdfNotSavedFrom: String?
```

It is an `init` parameter defaulting to `nil`, placed after `openAccessShortfall`. Replace `noting(openAccessShortfall:)` with `noting(openAccessShortfall:pdfNotSavedFrom:)`, which copies every field and sets both. Its existing call sites pass `pdfNotSavedFrom: nil` until Step 4. Every other place that rebuilds a `FullTextResult` from another must carry the field; find them with `grep -n "FullTextResult(" Packages/BioMedLit/Sources`.

- [ ] **Step 3: Candidates from Unpaywall**

Change `fetchUnpaywallChoice(doi:)` to return both the candidates and the choice. At its end, replace `return UnpaywallLandingPage.choose(from: result)` with:

```swift
        return UnpaywallFetch(
            pdfURLs: UnpaywallLandingPage.pdfURLs(from: result),
            choice: UnpaywallLandingPage.choose(from: result)
        )
```

with, beside `UnpaywallTierFailure`:

```swift
    /// What Unpaywall's answer offers: every PDF URL it names, and the choice
    /// that picks the landing page when it names none.
    private struct UnpaywallFetch {
        let pdfURLs: [String]
        let choice: UnpaywallLandingPage.Choice
    }
```

Replace `fetchUnpaywallPDFWithRetry(doi:) -> URL` with:

```swift
    /// Every PDF address Unpaywall offers for a DOI, best location first,
    /// reading a landing page only when no location names a PDF (#464, #480).
    ///
    /// Addresses are returned as given: one the chain cannot fetch is refused
    /// by ``tryOpenAccessPDFs``, per address, so it no longer stops the
    /// locations after it.
    ///
    /// - Parameter doi: Digital Object Identifier.
    /// - Returns: The PDF addresses; empty when Unpaywall answered 404, named
    ///   no PDF, and no landing page declared one.
    /// - Throws: `UnpaywallTierFailure` when Unpaywall was not configured,
    ///   answered with any other error status or unreadably, or its landing
    ///   page could not be read or fetched; `CancellationError`; whatever else
    ///   the Unpaywall request throws.
    private func fetchUnpaywallPDFCandidates(doi: String) async throws -> [String] {
        let fetched: UnpaywallFetch
        do {
            fetched = try await RetryHelper.retry(
                config: .networkDefault,
                shouldRetry: RetryHelper.retryOnlyTransient
            ) {
                try await self.fetchUnpaywallChoice(doi: doi)
            }
        } catch FullTextError.noFullTextAvailable {
            return []
        }
        if !fetched.pdfURLs.isEmpty { return fetched.pdfURLs }
        guard case .page(let landing) = fetched.choice else { return [] }
        guard let pageURL = UnpaywallLandingPage.fetchableURL(landing) else {
            throw Self.unfetchableAddress(landing, source: .landingPage)
        }
        switch try await readLandingPage(pageURL) {
        case .declared(let pdfURL):
            return [pdfURL.absoluteString]
        case .declaresNone:
            return []
        case .unreachable(let failure):
            throw UnpaywallTierFailure.unsettled(
                OpenAccessShortfall(source: .landingPage, failure: failure)
            )
        }
    }
```

- [ ] **Step 4: The walk**

Add, after `pdfTierResult`:

```swift
    /// Try each PDF a source named, in order, until one is served (#480).
    ///
    /// An address already tried is skipped. An address the chain cannot
    /// fetch, or a download the source refused, is added to the shortfall
    /// under `source`, with its address: the reader is told every copy that
    /// went unassessed. **The first copy served ends the walk:** extracted, it
    /// is the result; served but not cached, its link becomes the link
    /// fallback (it beats any held), its address is the caching note, and no
    /// further candidate is asked, saving being our problem, not the source's.
    ///
    /// - Parameters:
    ///   - addresses: The PDF addresses, as the source gave them.
    ///   - source: Whose PDF a failure is recorded against (`.pdf`, `.openAlexPDF`).
    ///   - content: The result content for an address.
    ///   - cacheKey, degradation, holdingAbstract, articleName: As ``pdfTierResult``.
    ///   - linkFallback: The chain's link fallback.
    ///   - shortfall: What went unsettled so far; added to.
    ///   - notSavedFrom: Set to the address of a copy served but not cached.
    ///   - tried: Addresses already asked, across sources; updated.
    /// - Returns: The result to return, or `nil` to go on down the chain.
    /// - Throws: `CancellationError`.
    private func tryOpenAccessPDFs(
        _ addresses: [String],
        refusedAs source: OpenAccessSource,
        content: (URL) -> FullTextContent,
        cacheKey: ArticleCacheKey,
        degradation: FullTextDegradation?,
        holdingAbstract: Bool,
        articleName: String,
        linkFallback: inout FullTextResult?,
        shortfall: inout OpenAccessShortfall?,
        notSavedFrom: inout String?,
        tried: inout Set<String>
    ) async throws -> FullTextResult? {
        for address in addresses where tried.insert(address).inserted {
            guard let pdfURL = UnpaywallLandingPage.fetchableURL(address) else {
                shortfall = .adding(
                    OpenAccessShortfall(source: source, failure: .requestFailed, address: address),
                    to: shortfall
                )
                continue
            }
            let outcome = try await downloadAndExtract(from: pdfURL, key: cacheKey)
            switch outcome {
            case .downloadFailed(let failure):
                shortfall = .adding(
                    OpenAccessShortfall(source: source, failure: failure, address: address),
                    to: shortfall
                )
                BioMedLitLib.logger?.warning(
                    "\(source.serviceName) at \(OpenAccessShortfall.host(of: address)) could not be "
                        + "obtained (\(failure.describe()))",
                    category: .fullText
                )
                continue
            case .notCached:
                linkFallback = FullTextResult(content: content(pdfURL), degradation: degradation)
                notSavedFrom = address
                return nil
            default:
                if let result = pdfTierResult(
                    outcome: outcome,
                    content: content(pdfURL),
                    degradation: degradation,
                    holdingAbstract: holdingAbstract,
                    articleName: articleName,
                    linkFallback: &linkFallback
                ) {
                    return result
                }
            }
        }
        return nil
    }

    /// The shortfall the fallbacks carry (#480): a copy served but not cached
    /// settles the open-access question, so nothing that went unsettled is
    /// told then. `FullTextResult.init` asserts the same of the link itself.
    static func settledOpenAccessShortfall(
        _ shortfall: OpenAccessShortfall?, copyServed: Bool
    ) -> OpenAccessShortfall? {
        copyServed ? nil : shortfall
    }
```

`.noText` while an abstract is held returns `nil` from `pdfTierResult`, and the walk goes on to the next address. That copy yielded nothing readable, and another may.

Rewrite the Unpaywall tier body (L513–568):

```swift
        var openAccessShortfall: OpenAccessShortfall?
        // An open-access copy served but not cached (#480): it ends the walk,
        // settles the question, and is the caching note's address
        var openAccessNotSavedFrom: String?
        var triedPDFs = Set<String>()
        if let cacheKey, !unpaywallDOI.isEmpty {
            let doi = unpaywallDOI
            var candidates: [String] = []
            do {
                candidates = try await fetchUnpaywallPDFCandidates(doi: doi)
                if candidates.isEmpty {
                    BioMedLitLib.logger?.info("Unpaywall offers no PDF for DOI \(doi)", category: .fullText)
                }
            } catch where error.isCancellation {
                throw CancellationError()
            } catch {
                if let shortfall = Self.openAccessShortfall(for: error) {
                    openAccessShortfall = .adding(shortfall, to: openAccessShortfall)
                }
                BioMedLitLib.logger?.warning(
                    "Unpaywall failed for DOI \(doi) (\(Self.openAccessShortfall(for: error)?.notice ?? error.localizedDescription))",
                    category: .fullText
                )
            }
            if let result = try await tryOpenAccessPDFs(
                candidates,
                refusedAs: .pdf,
                content: { .unpaywall(pdfURL: $0) },
                cacheKey: cacheKey,
                degradation: degradation,
                holdingAbstract: abstractOnly != nil,
                articleName: articleName,
                linkFallback: &pdfLinkFallback,
                shortfall: &openAccessShortfall,
                notSavedFrom: &openAccessNotSavedFrom,
                tried: &triedPDFs
            ) {
                return result
            }
        }
        openAccessShortfall = Self.settledOpenAccessShortfall(
            openAccessShortfall, copyServed: openAccessNotSavedFrom != nil
        )
        // The note names the copy that settled it, else a render not saved
        let pdfNotSavedFrom = openAccessNotSavedFrom ?? renderNotSavedFrom
```

In the Europe PMC render tier, declare `var renderNotSavedFrom: String?` before it. When its `outcome` is `.notCached`, set `renderNotSavedFrom = pdfURL.absoluteString`, then call `pdfTierResult` as now; it still holds the link. A render is not an open-access copy, so it neither settles the shortfall nor stops the Unpaywall walk: a copy Unpaywall names may still be saved.

Every fallback below carries the note:
- `abstractOnly.noting(openAccessShortfall: openAccessShortfall, pdfNotSavedFrom: pdfNotSavedFrom)`
- the same for `pdfLinkFallback`
- the DOI link and PubMed results get `pdfNotSavedFrom: pdfNotSavedFrom` in their `FullTextResult(...)` init.

`exhaustedChainError` is unchanged. A not-saved copy always leaves a link fallback, so the chain never reaches it with one.

- [ ] **Step 5: The app stores and shows the note**

In `Document.swift`, beside `fullTextOpenAccessShortfallJSON` (L258):

```swift
    /// The PDF a source served that could not be saved on this device (#480),
    /// told as a caching note beside the full text. Written by every fetch,
    /// cleared by every fetch that does not leave one, as the shortfall is.
    var fullTextPDFNotSavedFrom: String?
```

- It is written where the shortfall is (L954): `fullTextPDFNotSavedFrom = result.pdfNotSavedFrom`.
- It is cleared where the shortfall is cleared (L1044, L1060).
- It is read through:

```swift
    /// The caching note for this document, if a PDF was served and not saved.
    var storedPDFNotSavedNote: String? {
        fullTextPDFNotSavedFrom.map {
            OpenAccessShortfall.notSavedNote(address: $0, linkKept: fullTextPDFPath == $0)
        }
    }
```

`ParseWarningBannerContent` gains a `pdfNotSavedNote: String?` line, shown as a note like the shortfall's. Every caller that passes `openAccessShortfall:` passes `pdfNotSavedNote:` beside it:
- from a stored document, `document.storedPDFNotSavedNote`;
- from a fresh result, the same expression on the result's PDF URL.

Find the callers with `grep -rn "openAccessShortfall:" ios/MedicalFactChecker/Sources`. Update the two previews.

`StoreMigrationTests` proves the new optional field with an **earlier build's store**, exactly as PR #473 did for `fullTextOpenAccessShortfallJSON`. Copy that test's snapshot model and add the field to the current-shape assertions. Read `git show 0894f79^2 -- ios/MedicalFactChecker/Tests/StoreMigrationTests.swift` first. Add to `OpenAccessShortfallNoticeTests` one test that a document holding `fullTextPDFNotSavedFrom` equal to its `fullTextPDFPath` shows the "only its link is kept" note.

- [ ] **Step 6: Run everything Swift**

Run, in one background job, because SwiftPM can stall behind `syspolicyd`:

```bash
cd Packages/BioMedLit && swift test 2>&1 | tail -5; cd ../../ios/MedicalFactChecker && swift test 2>&1 | tail -5 && xcodebuild -scheme MedicalFactChecker -destination 'platform=macOS' build 2>&1 | tail -3 && xcodebuild -scheme MedicalFactChecker -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -3
```

Expected: 0 failures, and both builds succeed. Use any installed simulator (`xcrun simctl list devices available`). The banner is compiled for iOS only by the simulator build.

Change no assertion that encodes a rule from `fulltext_retrieval.md`. A test that pinned a single refused PDF still passes: one refusal is a one-entry shortfall equal to `OpenAccessShortfall(source: .pdf, failure:)`, **except** that it now carries the address. Update such expectations to add `address:`, and change nothing else in them.

- [ ] **Step 7: Commit**

```bash
git add Packages/BioMedLit ios/MedicalFactChecker/Sources ios/MedicalFactChecker/Tests
git commit -m "feat(swift): try every PDF Unpaywall names; tell each failure, and a caching problem (#480)

The first copy served ends the walk: saved, it is read; not saved, its link
is kept with a caching note, stored on the document. Every PDF refused is
listed by host.

Refs #480.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Kotlin: try every Unpaywall PDF, list every failure, and tell a caching problem

**Files:**
- Modify: `MAIN/data/remote/fulltext/FullTextService.kt`. This covers the `FullTextResult` cases (L98–221), the Unpaywall step (L415–427), `tryUnpaywallPdf` (L545–654) and `getSourceConstant` (L949).
- Modify: `MAIN/data/remote/fulltext/FullTextRecording.kt`
- Modify: `MAIN/data/local/AppDatabase.kt` (Room 9), `MAIN/data/local/entity/DocumentEntity.kt`, `MAIN/data/local/dao/DocumentDao.kt` (the three clearing queries, L130, L155, L171)
- Modify: `MAIN/ui/fulltext/FullTextViewModel.kt` (`handleFullTextResult`, L297–342), and the places `OpenAccessShortfallNotice` is shown: the full-text web-link view, the fact-check document card, the report's document sheet.
- Modify: `MAIN/util/Constants.kt`
- Create: `TEST/data/remote/fulltext/OpenAccessStepsRecordingTest.kt`, and `TEST/data/local/Migration8To9Test.kt`, modelled on `Migration7To8Test.kt`.
- Modify: `TEST/data/remote/fulltext/FullTextServiceUnpaywallTest.kt`, `FullTextRecordingTest.kt`, `TEST/data/local/AppDatabaseMigrationsTest.kt`, and every test referencing `FullTextResult.UnpaywallPdf` (`grep -rl UnpaywallPdf android/MedicalFactChecker/app/src/test`).

**Interfaces:**
- Consumes: `UnpaywallLandingPage.pdfUrls` (Task 1); `OpenAccessShortfall.adding`, `plus` and `notSavedNote` (Task 5).
- Produces, in `FullTextService.kt`:

```kotlin
/** Who named an open-access PDF, which decides its source and its refusal's name. */
enum class PdfNamer(val fullTextSource: String, val label: String, val refusedAs: OpenAccessSource) {
    UNPAYWALL(Constants.FULLTEXT_SOURCE_UNPAYWALL, Constants.FULLTEXT_SOURCE_UNPAYWALL_LABEL, OpenAccessSource.PDF)
}

/** One step of the open-access phase, in chain order. */
sealed interface OpenAccessStep {
    data class Candidate(val pdfUrl: String, val namedBy: PdfNamer) : OpenAccessStep
    data class Unsettled(val shortfall: OpenAccessShortfall) : OpenAccessStep
}
```

  - `FullTextResult.OpenAccessPdfs(steps: List<OpenAccessStep>, doi: String, openAlexAsked: Boolean = false)`, holding at least one `Candidate`. Task 14 sets `openAlexAsked`.
  - `FullTextResult.OpenAccessPdf(pdfUrl: String, doi: String, namedBy: PdfNamer, notSaved: Boolean = false)`, which replaces `UnpaywallPdf`.
- `DocumentEntity.fullTextPdfNotSavedFrom: String?`, column `full_text_pdf_not_saved_from`, Room 9; `DocumentEntity.pdfNotSavedNote: String?`.
- `Constants.FULLTEXT_SOURCE_UNPAYWALL_LABEL = "Unpaywall"`, the string `FullTextViewModel` passes to `pdfOrLink` today.

- [ ] **Step 1: The failing recording tests**

Create `OpenAccessStepsRecordingTest.kt`. Build `DocumentEntity` as `FullTextRecordingTest` does; copy its fixture document.

```kotlin
class OpenAccessStepsRecordingTest {
    private val doi = "10.1/locations"
    private val first = "https://walled.example.org/a.pdf"
    private val second = "https://repo.example.org/b.pdf"
    private fun candidate(url: String) = OpenAccessStep.Candidate(url, PdfNamer.UNPAYWALL)
    private fun found(vararg steps: OpenAccessStep) = FullTextResult.OpenAccessPdfs(steps.toList(), doi)
    private fun refused(url: String, status: Int) =
        OpenAccessShortfall(OpenAccessSource.PDF, RequestFailure.forHttpStatus(status), url)

    @Test
    fun `a second candidate is downloaded when the first is refused`() = runTest {
        val asked = mutableListOf<String>()
        val recorded = document().recordingFullTextFetch(found(candidate(first), candidate(second))) { url ->
            asked += url
            if (url == first) PdfDownload.Failed(RequestFailure.forHttpStatus(403)) else PdfDownload.Saved("/cache/d.pdf")
        }
        assertEquals(listOf(first, second), asked)
        assertEquals(FullTextResult.OpenAccessPdf(second, doi, PdfNamer.UNPAYWALL), recorded.result)
        assertEquals("/cache/d.pdf", recorded.document.pdfPath)
        assertNull(recorded.document.fullTextOpenAccessShortfallJson)
    }

    @Test
    fun `every candidate refused is told, each by its address`() = runTest {
        val recorded = document().recordingFullTextFetch(found(candidate(first), candidate(second))) { url ->
            PdfDownload.Failed(RequestFailure.forHttpStatus(if (url == first) 403 else 503))
        }
        assertEquals(FullTextResult.DoiUrl(doiLink(doi), refused(first, 403) + refused(second, 503)), recorded.result)
    }

    @Test
    fun `an unsettled lookup before the candidates is told first`() = runTest {
        val lookup = OpenAccessShortfall(OpenAccessSource.LANDING_PAGE, RequestFailure(RequestFailureKind.TIMEOUT))
        val recorded = document().recordingFullTextFetch(found(OpenAccessStep.Unsettled(lookup), candidate(first))) {
            PdfDownload.Failed(RequestFailure.forHttpStatus(403))
        }
        assertEquals(FullTextResult.DoiUrl(doiLink(doi), lookup + refused(first, 403)), recorded.result)
    }

    @Test
    fun `a copy served but not saved ends the walk with a caching note and no shortfall`() = runTest {
        val asked = mutableListOf<String>()
        val recorded = document().recordingFullTextFetch(found(candidate(first), candidate(second))) { url ->
            asked += url; PdfDownload.NotSaved
        }
        assertEquals(listOf(first), asked, "saving is our problem: no further candidate")
        assertEquals(FullTextResult.OpenAccessPdf(first, doi, PdfNamer.UNPAYWALL, notSaved = true), recorded.result)
        assertNull(recorded.document.pdfPath)
        assertNull(recorded.document.fullTextOpenAccessShortfallJson)
        assertEquals(first, recorded.document.fullTextPdfNotSavedFrom)
    }

    @Test
    fun `a saved copy stops the walk and clears an earlier note`() = runTest {
        val asked = mutableListOf<String>()
        val recorded = document().copy(fullTextPdfNotSavedFrom = first)
            .recordingFullTextFetch(found(candidate(first), candidate(second))) { url ->
                asked += url; PdfDownload.Saved("/cache/d.pdf")
            }
        assertEquals(listOf(first), asked)
        assertNull(recorded.document.fullTextPdfNotSavedFrom)
    }

    @Test
    fun `a Europe PMC render served but not saved is noted too`() = runTest {
        val render = "https://europepmc.org/articles/PMC1/pdf"
        val recorded = document().recordingFullTextFetch(FullTextResult.EuropePmcPdf(render)) { PdfDownload.NotSaved }
        assertEquals(render, recorded.document.fullTextPdfNotSavedFrom)
    }

    @Test(expected = IllegalArgumentException::class)
    fun `steps with no candidate are refused`() {
        found(OpenAccessStep.Unsettled(OpenAccessShortfall.UNPAYWALL_NOT_CONFIGURED))
    }
}
```

Run: `cd android/MedicalFactChecker && ./gradlew testDebugUnitTest --tests '*OpenAccessStepsRecordingTest*' -q`
Expected: FAIL (compile).

- [ ] **Step 2: The types, and Room 9**

In `FullTextService.kt`:
- Add `PdfNamer` and `OpenAccessStep` at top level, as in Interfaces.
- Add `FULLTEXT_SOURCE_UNPAYWALL_LABEL` to `Constants.kt`.
- Replace `UnpaywallPdf` with:

```kotlin
        /**
         * The open-access PDFs to try, in chain order, with any lookup that went
         * unsettled before them (#480, stage B). Downloaded by
         * [recordingFullTextFetch], which resolves this to an [OpenAccessPdf] or,
         * when none could be obtained, the DOI link carrying every shortfall met.
         *
         * @property steps In chain order; at least one [OpenAccessStep.Candidate]
         * @property doi The DOI they were found for
         * @property openAlexAsked Whether OpenAlex's steps are already among them
         */
        data class OpenAccessPdfs(
            val steps: List<OpenAccessStep>,
            val doi: String,
            val openAlexAsked: Boolean = false
        ) : FullTextResult(hasContent = true) {
            init {
                require(steps.any { it is OpenAccessStep.Candidate }) { "nothing to try is not a PDF result" }
            }
        }

        /**
         * The open-access PDF obtained, or served but not saved (its link kept,
         * with a caching note).
         *
         * @property notSaved Whether it was served and could not be saved here
         */
        data class OpenAccessPdf(
            val pdfUrl: String,
            val doi: String,
            val namedBy: PdfNamer,
            val notSaved: Boolean = false
        ) : FullTextResult(hasContent = true)
```

In `getSourceConstant`:

```kotlin
            is FullTextResult.OpenAccessPdfs ->
                result.steps.filterIsInstance<OpenAccessStep.Candidate>().first().namedBy.fullTextSource
            is FullTextResult.OpenAccessPdf -> result.namedBy.fullTextSource
```

Room changes:
- `DocumentEntity` gains:

```kotlin
    /** The PDF a source served that could not be saved on this device (#480); told as a caching note. */
    @ColumnInfo(name = "full_text_pdf_not_saved_from")
    val fullTextPdfNotSavedFrom: String? = null,
```

  and a property:

```kotlin
    /** The caching note for this document, if a PDF was served and not saved. */
    val pdfNotSavedNote: String?
        get() = fullTextPdfNotSavedFrom?.let { OpenAccessShortfall.notSavedNote(it, linkKept = pdfPath == null) }
```

  `linkKept` holds when no file was saved and the link is what is shown. Check against how `FullTextViewModel` shows a link-only record; if a link-only record keeps its URL elsewhere, compare with that.
- `AppDatabase`: version 9, with a `MIGRATION_8_9` (`ALTER TABLE documents ADD COLUMN full_text_pdf_not_saved_from TEXT`) registered in `ALL_MIGRATIONS`, as #473's 7→8 is.
- `DocumentDao`'s three clearing queries also set `full_text_pdf_not_saved_from = NULL`.
- `Migration8To9Test` is copied from `Migration7To8Test`.
- `AppDatabaseMigrationsTest` gains the new migration as #473 added 7→8; read that commit with `git show 0894f79^2 --stat`.

- [ ] **Step 3: Recording walks the steps**

In `FullTextRecording.kt`, replace the `UnpaywallPdf` branch of `recordingFullTextFetch` with `is FullTextResult.OpenAccessPdfs -> obtainingOpenAccessPdf(result, downloadPdf)`. The `EuropePmcPdf` branch becomes:

```kotlin
    is FullTextResult.EuropePmcPdf -> when (val download = downloadPdf(result.pdfUrl)) {
        PdfDownload.NotSaved -> RecordedFetch(recording(result, null).copy(fullTextPdfNotSavedFrom = result.pdfUrl), result)
        else -> RecordedFetch(recording(result, download.savedPath), result)
    }
```

Add:

```kotlin
/**
 * Walk the open-access steps in chain order (#480, stage B).
 *
 * The first candidate served ends the walk: saved, it is the result; served but
 * not saved, its link is kept with a caching note, and nothing further is asked
 * (saving is our problem, not the source's), and a served copy settles the
 * open-access question, so no shortfall is recorded. Otherwise the DOI link
 * carries every shortfall met, in order: an unsettled lookup, or a candidate
 * refused under its namer's source with its address (#478's rule, the
 * maintainer's decision of 2026-10-05).
 */
private suspend fun DocumentEntity.obtainingOpenAccessPdf(
    result: FullTextResult.OpenAccessPdfs,
    downloadPdf: suspend (String) -> PdfDownload
): RecordedFetch {
    var shortfall: OpenAccessShortfall? = null
    for (step in result.steps) {
        when (step) {
            is OpenAccessStep.Unsettled -> shortfall = OpenAccessShortfall.adding(step.shortfall, shortfall)
            is OpenAccessStep.Candidate -> {
                val found = FullTextResult.OpenAccessPdf(step.pdfUrl, result.doi, step.namedBy)
                when (val download = downloadPdf(step.pdfUrl)) {
                    is PdfDownload.Saved -> return RecordedFetch(recording(found, download.path), found)
                    PdfDownload.NotSaved -> found.copy(notSaved = true).let { linked ->
                        return RecordedFetch(recording(linked, pdfPath = null), linked)
                    }
                    is PdfDownload.Failed -> shortfall = OpenAccessShortfall.adding(
                        OpenAccessShortfall(step.namedBy.refusedAs, download.failure, step.pdfUrl), shortfall
                    )
                }
            }
        }
    }
    val refused = FullTextResult.DoiUrl(doiLink(result.doi), shortfall)
    return RecordedFetch(recording(refused, pdfPath = null), refused)
}
```

Task 14 extends this function to ask OpenAlex. In `recording(...)`:
- every branch writes `fullTextPdfNotSavedFrom = null`, except `OpenAccessPdf` with `notSaved`, which writes its `pdfUrl`;
- `OpenAccessPdf` writes `fullTextSource = result.namedBy.fullTextSource`;
- `is FullTextResult.OpenAccessPdfs -> error("resolved by obtainingOpenAccessPdf before recording")`.

`NotEstablished` still returns `this`, unchanged.

In `FullTextViewModel.handleFullTextResult`:
- `is FullTextResult.OpenAccessPdf -> pdfOrLink(recorded.pdfPath, result.pdfUrl, doc.title, result.namedBy.label)`, with the document's `pdfNotSavedNote` passed wherever the web-link view takes `openAccessNotice`.
- `is FullTextResult.OpenAccessPdfs -> error("resolved by recording")`.

Wherever `OpenAccessShortfallNotice` is shown (the full-text web-link view, the fact-check document card, the report's document sheet), show `document.pdfNotSavedNote` beside it, as a note in the same style. The text is a string; no new composable is needed if the notice composable takes one.

- [ ] **Step 4: The service returns the steps**

Refactor `tryUnpaywallPdf` into `private suspend fun unpaywallSteps(doi: String, email: String?, pmid: String?): List<OpenAccessStep>`. Keep its body, its retry and its exception mapping, and change only its outputs:
- No usable email → `listOf(OpenAccessStep.Unsettled(OpenAccessShortfall.UNPAYWALL_NOT_CONFIGURED))`.
- Inside the retry, return the whole `body` instead of `chooseUrl(body)`.
- After it, `val pdfUrls = UnpaywallLandingPage.pdfUrls(body)`.
- If that is non-empty, map each URL with `candidateOrRefused(url, PdfNamer.UNPAYWALL)`.
- Otherwise read `UnpaywallLandingPage.chooseUrl(body).landingPage` as now:
  - `Declared(url)` → `listOf(candidateOrRefused(url, PdfNamer.UNPAYWALL))`;
  - `DeclaresNone` or no page → `emptyList()`;
  - `Unreachable(f)` → `listOf(Unsettled(OpenAccessShortfall(OpenAccessSource.LANDING_PAGE, f)))`.
- `FullTextUnavailableException` (404) → `emptyList()`.
- `OpenAccessUnsettledException(s)` → `listOf(Unsettled(s))`.
- Unexpected `Exception` → `listOf(Unsettled(OpenAccessShortfall(OpenAccessSource.UNPAYWALL, RequestFailure(RequestFailureKind.REQUEST_FAILED))))`.
- `CancellationException` is rethrown.

```kotlin
    /** A PDF address as a step: a candidate, or refused at once, with its address, when it cannot be requested (#478). */
    private fun candidateOrRefused(url: String, namer: PdfNamer): OpenAccessStep =
        if (url.toHttpUrlOrNull() == null) {
            OpenAccessStep.Unsettled(
                OpenAccessShortfall(namer.refusedAs, RequestFailure(RequestFailureKind.REQUEST_FAILED), url)
            )
        } else {
            OpenAccessStep.Candidate(url, namer)
        }
```

In `fetchFullText`, replace L415–427:

```kotlin
        var openAccessShortfall: OpenAccessShortfall? = null
        if (!doi.isNullOrEmpty()) {
            val steps = unpaywallSteps(doi, email, pmid)
            if (steps.any { it is OpenAccessStep.Candidate }) {
                return@withContext Result.success(FullTextResult.OpenAccessPdfs(steps, doi))
            }
            openAccessShortfall = steps.filterIsInstance<OpenAccessStep.Unsettled>()
                .fold(null as OpenAccessShortfall?) { held, step -> OpenAccessShortfall.adding(step.shortfall, held) }
        }
```

- [ ] **Step 5: Update the existing tests**

- In `FullTextServiceUnpaywallTest.kt`, every expected `FullTextResult.UnpaywallPdf(pdfUrl = X, doi = doi)` becomes `FullTextResult.OpenAccessPdfs(listOf(OpenAccessStep.Candidate(X, PdfNamer.UNPAYWALL)), doi)`.
- A refused unfetchable address now carries its address: `OpenAccessShortfall(OpenAccessSource.PDF, RequestFailure(RequestFailureKind.REQUEST_FAILED), url)`.
- Add a two-location test, with a helper `unpaywallLocations(urls)` modelled on `unpaywallAnswers` (L121):

```kotlin
    @Test
    fun `every location's PDF is a candidate, in Unpaywall's order, once`() = runTest {
        val a = server.url("/a.pdf").toString()
        val b = server.url("/b.pdf").toString()
        unpaywallLocations(listOf(a, a, b))
        assertEquals(
            FullTextResult.OpenAccessPdfs(
                listOf(OpenAccessStep.Candidate(a, PdfNamer.UNPAYWALL), OpenAccessStep.Candidate(b, PdfNamer.UNPAYWALL)),
                doi
            ),
            fetch()
        )
    }
```

- In `FullTextRecordingTest` and the ViewModel tests, replace the `UnpaywallPdf` given to recording with `OpenAccessPdfs(listOf(Candidate(url, PdfNamer.UNPAYWALL)), doi)`.
  - An expected recorded result becomes `OpenAccessPdf(url, doi, PdfNamer.UNPAYWALL)`.
  - A refused one is the `DoiUrl` whose shortfall carries the address.
  - A `NotSaved` one is `OpenAccessPdf(…, notSaved = true)` with `fullTextPdfNotSavedFrom` set.

- [ ] **Step 6: Run the Android suite and build**

Run: `cd android/MedicalFactChecker && ./gradlew testDebugUnitTest -q 2>&1 | tail -20 && ./gradlew assembleDebug -q 2>&1 | tail -5`
Expected: 0 failures, apart from #490's flake (re-run it alone), and the APK builds. Room's schema export, if the project exports schemas, gains `9.json`; commit it.

- [ ] **Step 7: Commit**

```bash
git add android/MedicalFactChecker/app
git commit -m "feat(android): try every PDF Unpaywall names; tell each failure, and a caching problem (#480)

The service returns the open-access steps in chain order; recording walks
them. The first copy served ends the walk: saved, it is read; not saved,
its link is kept with a caching note (Room 9). Every PDF refused is listed
by address.

Refs #480.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Python: record every copy not obtained; a copy not saved ends the walk

**Files:**
- Modify: `src/bmlibrarian_lite/pdf_discovery.py`:
  - `DiscoveryResult` (L468): a `not_saved` flag
  - `unobtained_unpaywall_pdf` (L619): renamed, with the address
  - `discover_and_download` (L745–913)
  - `_try_download`'s `OSError` arm (~L1859)
- Modify: `tests/test_unobtained_unpaywall_pdf.py`

**Interfaces:**
- Consumes: `SourceLookupFailure`/`SourceLookupSkipped(..., address)`, `LookupSkipReason.NOT_SAVED`, `not_saved_note` (Task 3).
- Produces:
  - `DiscoveryResult.not_saved: bool = False`, set by `_try_download` when the PDF was served and could not be written.
  - `unobtained_open_access_pdf(source, result) -> LookupRecord`, which replaces `unobtained_unpaywall_pdf` and records the address.
  - `_UNOBTAINED_PDF_SERVICE`, the map from `PDFSourceType` to the service a copy is recorded under. Task 10 adds OpenAlex to it.

- [ ] **Step 1: The failing tests**

In `tests/test_unobtained_unpaywall_pdf.py`:
- replace the import and every call of `unobtained_unpaywall_pdf` with `unobtained_open_access_pdf`;
- give `_pdf_failure` an address parameter that defaults to `UNPAYWALL_PDF`, since every recorded copy now carries one;
- rewrite `test_a_pdf_that_could_not_be_saved_is_unassessed_not_absent` and add tests:

```python
def _pdf_failure(failure: RequestFailure, address: str = UNPAYWALL_PDF) -> LookupRecord:
    """The record of an Unpaywall PDF that failed for ``failure``."""
    return LookupRecord(failures=(SourceLookupFailure(SERVICE_UNPAYWALL_PDF, failure, address),))


def test_a_pdf_that_could_not_be_saved_is_a_caching_note_not_absent(tmp_path: Path) -> None:
    """Our fault after the PDF was served: the copy exists, so it is a note,
    never an access shortfall, and still not an absence (#480)."""
    blocker = tmp_path / "blocker"
    blocker.write_text("a file where the cache directory should be")
    discoverer = PDFDiscoverer(unpaywall_email="test@example.com", use_browser_fallback=False)
    discoverer._discover_sources = lambda doi, pmid, pmcid: ([_unpaywall(), _unpaywall(PUBLISHER_PDF)], LookupRecord())  # type: ignore[method-assign]
    session = _Session({UNPAYWALL_PDF: _response(200, PDF_BYTES, "application/pdf", UNPAYWALL_PDF)})
    discoverer._session = session  # type: ignore[assignment]

    result = discoverer.discover_and_download(blocker / "a.pdf", doi="10.1/x")

    assert not result.success
    assert result.lookups == LookupRecord(
        skipped=(SourceLookupSkipped(SERVICE_UNPAYWALL_PDF, LookupSkipReason.NOT_SAVED, UNPAYWALL_PDF),)
    )
    assert session.requested == [UNPAYWALL_PDF], "saving is our problem: no further copy asked"
    assert result.error == not_saved_note(result.lookups)


def test_every_copy_refused_is_recorded_in_unpaywalls_order(tmp_path: Path) -> None:
    """Both refusals, each with its address, in Unpaywall's order whatever the
    priority order tried them in (the maintainer's decision, 2026-10-05)."""
    accepted = _unpaywall(UNPAYWALL_PDF, version="acceptedVersion")
    published = _unpaywall(PUBLISHER_PDF, version="publishedVersion")  # tried first: higher priority
    session = _Session({
        UNPAYWALL_PDF: _response(403, b"", "text/html", UNPAYWALL_PDF),
        PUBLISHER_PDF: _response(503, b"", "text/html", PUBLISHER_PDF),
    })

    result = _discover([accepted, published], tmp_path, session)

    assert result.lookups.failures == (
        SourceLookupFailure(SERVICE_UNPAYWALL_PDF, RequestFailure(RequestFailureKind.HTTP_STATUS, 403), UNPAYWALL_PDF),
        SourceLookupFailure(SERVICE_UNPAYWALL_PDF, RequestFailure(RequestFailureKind.HTTP_STATUS, 503), PUBLISHER_PDF),
    )
    assert "Failed to obtain a PDF from the following tried sources:" in (result.error or "")
```

Import `not_saved_note` from `bmlibrarian_lite.analysis_failures`. Every other expectation in the file built with `_pdf_failure(...)` now carries `UNPAYWALL_PDF` as its address by default. A test whose refused PDF is at another address passes it. A test that asserted only one of several refusals ("the earliest in Unpaywall's order") now asserts them all, in Unpaywall's order. Rewrite its docstring to say so.

Run: `pytest tests/test_unobtained_unpaywall_pdf.py -q`
Expected: FAIL. `ImportError: unobtained_open_access_pdf`.

- [ ] **Step 2: Implement**

In `pdf_discovery.py`, import `SourceLookupSkipped` (if not already) and `not_saved_note`.

`DiscoveryResult` gains `not_saved: bool = False`, documented as "The source served the PDF and it could not be written here: a fault of ours, told as a caching note (#480)". `__post_init__` refuses `success and not_saved`. In `_try_download`'s `OSError` arm, return:

```python
            return DiscoveryResult(
                success=False,
                error=f"The PDF could not be saved: {e}",
                not_saved=True,
            )
```

Replace the comment above it: the source served the PDF, so it is no answer about the copy. It is recorded as a `NOT_SAVED` skip with its address, which keeps the discovery from concluding there is no full text and is told as a caching note (#480).

Replace `unobtained_unpaywall_pdf` with:

```python
#: Whose PDF an unobtained open-access copy is recorded against (#478, #480).
_UNOBTAINED_PDF_SERVICE = {PDFSourceType.UNPAYWALL_OA: SERVICE_UNPAYWALL_PDF}


def unobtained_open_access_pdf(
    source: "PDFSource", result: "DiscoveryResult"
) -> LookupRecord:
    """Record an open-access PDF we could not obtain, with its address.

    A source answered with a copy; that we could not then obtain it is not an
    article without one (#478). It is recorded under the copy's own name, not
    the service's, which answered, and with its address, so the reader is
    told each copy tried by its host (#480). A PDF refused for its size is
    our limit, recorded as a lookup not made; a cancel records nothing.

    Args:
        source: The source the download tried.
        result: What the attempt came to.

    Returns:
        A record under the copy's service when ``source`` is a PDF an
        open-access source named and the attempt did not obtain it; empty
        otherwise.
    """
    service = _UNOBTAINED_PDF_SERVICE.get(source.source_type)
    if result.success or service is None:
        return LookupRecord()
    if result.failure is not None:
        return LookupRecord(failures=(SourceLookupFailure(service, result.failure, source.url),))
    if result.refused_for_size:
        return LookupRecord(
            skipped=(SourceLookupSkipped(service, LookupSkipReason.OVER_SIZE_LIMIT, source.url),)
        )
    return LookupRecord()
```

In `discover_and_download`:
- Rename `unpaywall_rank` to `copy_rank`.
- Replace the single `unobtained_pdf`/`unobtained_rank` pair with `unobtained: list[tuple[int, LookupRecord]] = []`. In the loop, after `result = self._try_download(...)`:

```python
            if result.not_saved:
                # Served, and not saved here: the copy exists, so nothing else
                # is asked (saving is our problem) and nothing is an access
                # shortfall; the reader gets the caching note (#480).
                saved_note = LookupRecord(skipped=(SourceLookupSkipped(
                    _UNOBTAINED_PDF_SERVICE.get(source.source_type, SERVICE_PDF_DOWNLOAD),
                    LookupSkipReason.NOT_SAVED,
                    source.url,
                ),))
                return DiscoveryResult(
                    success=False,
                    error=unestablished_access_clause(told.merged(saved_note)),
                    lookups=lookups.merged(saved_note),
                )

            record = unobtained_open_access_pdf(source, result)
            rank = copy_rank.get(source.url)
            if record.anything_unsettled and rank is not None:
                unobtained.append((rank, record))
```

  `told` and `lookups` carry the other unsettled lookups, so the clause says those and then the note. Import `unestablished_access_clause` and `SERVICE_PDF_DOWNLOAD`.
- Where the old code merged `unobtained_pdf` (the two paywall returns and the final failure), merge `self._ranked(unobtained)` instead, with:

```python
    @staticmethod
    def _ranked(unobtained: list[tuple[int, LookupRecord]]) -> LookupRecord:
        """Every copy not obtained, in chain order whatever order they were tried in."""
        merged = LookupRecord()
        for _rank, record in sorted(unobtained, key=lambda pair: pair[0]):
            merged = merged.merged(record)
        return merged
```

- The comment above `copy_rank` becomes: "Unpaywall's own order, then OpenAlex's (#480), before the priority sort reorders them: every copy not obtained is told, in this order".

- [ ] **Step 3: Run the tests and the suite**

Run: `pytest tests/test_unobtained_unpaywall_pdf.py tests/test_open_access_statement.py -q && pytest tests/ -q 2>&1 | tail -3`
Expected: PASS; 0 failures. A test elsewhere that pinned a single refusal's record now sees the address on it; add it there, and change nothing else in its expectation.

Run: `python .github/scripts/lint_delta.py --base-ref origin/master`
Expected: no new findings.

- [ ] **Step 4: Commit**

```bash
git add src/bmlibrarian_lite/pdf_discovery.py tests
git commit -m "feat(python): record every copy not obtained, by address; a copy not saved is a note (#480)

Refs #480.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: OpenAlex: the contract, Python's pure helpers and client

**Files:**
- Create: `doc/cross_platform/fulltext_parity/openalex_locations.json`
- Create: `src/bmlibrarian_lite/openalex.py`
- Modify: `src/bmlibrarian_lite/constants.py`. Add `OPENALEX_*` after `SERVICE_OPENALEX_PDF`. In `POLITE_RATE_CEILINGS`, the `"api.openalex.org": 10.0` line stays a literal.
- Create: `tests/test_openalex.py`

**Interfaces:**
- Consumes: `SERVICE_OPENALEX`, `SERVICE_OPENALEX_PDF` (Task 2).
- Produces, in `bmlibrarian_lite.openalex`:
  - `openalex_work_url(doi: str, mailto: str | None = None, base_url: str = OPENALEX_API_BASE_URL) -> str`
  - `openalex_pdf_urls(work: object) -> list[str]`, which raises `ValueError` for an unreadable work.
  - `untried_pdf_urls(pdf_urls: Sequence[str], tried: Iterable[str]) -> list[str]`
  - `OpenAlexWorkFetch` with `served(urls)`, `absent()`, `unreachable(failure)`, `.pdf_urls: tuple[str, ...] | None`, `.failure` and `.is_unreachable`.
  - `OpenAlexLocationsClient(mailto: str | None = None, base_url: str = OPENALEX_API_BASE_URL, max_retries: int = OPENALEX_MAX_RETRIES)`, with `.mailto` and `.fetch_pdf_urls(doi: str) -> OpenAlexWorkFetch`.
- Produces, in `constants`:
  - `OPENALEX_HOST = "api.openalex.org"`
  - `OPENALEX_API_BASE_URL = "https://api.openalex.org"`
  - `OPENALEX_REQUEST_TIMEOUT_SECONDS = 30`
  - `OPENALEX_MAX_RETRIES = 3`
  - `OPENALEX_ENCODING = "utf-8"`

- [ ] **Step 1: The fixture**

Create `doc/cross_platform/fulltext_parity/openalex_locations.json`:

```json
{
  "schema_version": 1,
  "description": "OpenAlex as a source of open-access PDFs (#480, stage B): the request for a DOI, the PDFs a work's locations name that Unpaywall did not, and what each status settles. Read by tests/test_openalex.py, Packages/BioMedLit OpenAlexContractTests and Android OpenAlexContractTest. The rules are in doc/cross_platform/fulltext_retrieval.md, 'OpenAlex's Locations (#480)'. work_url: the DOI and the contact email escaped with RFC 3986's unreserved set left bare (Python's quote(s, safe='')), so a DOI is one path segment; no mailto when there is no contact email. pdf_urls: every locations[].pdf_url that is a non-blank string, trimmed, kept once, in OpenAlex's order, whatever the location's is_oa; a location that is not an object is skipped; locations missing or null is no PDF; a work that is not an object, or locations that is not a list, is unreadable (malformed: true); then every URL in tried is dropped. status: 200 served, 404 absent, anything else unreachable with that status. Every case is asserted on all three platforms, and each platform asserts it reads every table: add a row here, not a test on one platform.",
  "service_name": "OpenAlex",
  "pdf_service_name": "OpenAlex's copy",
  "source": "openalex",
  "base_url": "https://api.openalex.org",
  "work_url": [
    {"name": "a DOI's slash is escaped", "doi": "10.1556/2006.2020.00040", "mailto": null,
     "url": "https://api.openalex.org/works/doi:10.1556%2F2006.2020.00040?select=locations"},
    {"name": "a contact email is sent, escaped", "doi": "10.1556/2006.2020.00040", "mailto": "researcher@example.org",
     "url": "https://api.openalex.org/works/doi:10.1556%2F2006.2020.00040?select=locations&mailto=researcher%40example.org"},
    {"name": "a SICI DOI is one path segment", "doi": "10.1002/(SICI)1097-0266(199708)18:7<509::AID-SMJ882>3.0.CO;2-Z", "mailto": null,
     "url": "https://api.openalex.org/works/doi:10.1002%2F%28SICI%291097-0266%28199708%2918%3A7%3C509%3A%3AAID-SMJ882%3E3.0.CO%3B2-Z?select=locations"},
    {"name": "a non-ASCII DOI is escaped as UTF-8", "doi": "10.1234/café", "mailto": null,
     "url": "https://api.openalex.org/works/doi:10.1234%2Fcaf%C3%A9?select=locations"},
    {"name": "a plus in the email is not a space", "doi": "10.1/x", "mailto": "a+b@example.org",
     "url": "https://api.openalex.org/works/doi:10.1%2Fx?select=locations&mailto=a%2Bb%40example.org"},
    {"name": "padding around the DOI is not part of it", "doi": "  10.1/x ", "mailto": null,
     "url": "https://api.openalex.org/works/doi:10.1%2Fx?select=locations"}
  ],
  "pdf_urls": [
    {"name": "every location's pdf_url, in OpenAlex's order, whatever its is_oa (10.1556/2006.2020.00040, live)",
     "work": {"locations": [
       {"is_oa": true, "pdf_url": "https://akjournals.com/downloadpdf/journals/2006/9/2/article-p187.pdf", "landing_page_url": "https://doi.org/10.1556/2006.2020.00040"},
       {"is_oa": false, "pdf_url": null, "landing_page_url": "https://pubmed.ncbi.nlm.nih.gov/32634111"},
       {"is_oa": false, "pdf_url": "http://real.mtak.hu/138217/1/article-p187.pdf", "landing_page_url": "http://real.mtak.hu/138217/1/article-p187.pdf"},
       {"is_oa": true, "pdf_url": null, "landing_page_url": "https://www.ncbi.nlm.nih.gov/pmc/articles/8939426"}]},
     "tried": [],
     "expected": ["https://akjournals.com/downloadpdf/journals/2006/9/2/article-p187.pdf", "http://real.mtak.hu/138217/1/article-p187.pdf"]},
    {"name": "a PDF Unpaywall named is not tried again",
     "work": {"locations": [{"pdf_url": "https://a.example.org/a.pdf"}, {"pdf_url": "https://b.example.org/b.pdf"}, {"pdf_url": "https://c.example.org/c.pdf"}]},
     "tried": ["https://b.example.org/b.pdf"],
     "expected": ["https://a.example.org/a.pdf", "https://c.example.org/c.pdf"]},
    {"name": "a repeated pdf_url once, a padded one trimmed, a blank or non-string one skipped",
     "work": {"locations": [{"pdf_url": " https://x.example.org/a.pdf "}, {"pdf_url": "https://x.example.org/a.pdf"}, {"pdf_url": "  "}, {"pdf_url": 7}]},
     "tried": [],
     "expected": ["https://x.example.org/a.pdf"]},
    {"name": "a location that is not an object is skipped",
     "work": {"locations": [null, "https://x.example.org/s.pdf", {"pdf_url": "https://x.example.org/b.pdf"}]},
     "tried": [],
     "expected": ["https://x.example.org/b.pdf"]},
    {"name": "no locations", "work": {"locations": []}, "tried": [], "expected": []},
    {"name": "locations missing", "work": {"id": "https://openalex.org/W1"}, "tried": [], "expected": []},
    {"name": "locations null", "work": {"locations": null}, "tried": [], "expected": []},
    {"name": "locations that are not a list are unreadable",
     "work": {"locations": {"pdf_url": "https://x.example.org/a.pdf"}}, "tried": [], "malformed": true},
    {"name": "a work that is not an object is unreadable",
     "work": ["https://x.example.org/a.pdf"], "tried": [], "malformed": true}
  ],
  "status": [
    {"status": 200, "outcome": "served"},
    {"status": 404, "outcome": "absent"},
    {"status": 400, "outcome": "unreachable"},
    {"status": 403, "outcome": "unreachable"},
    {"status": 410, "outcome": "unreachable"},
    {"status": 429, "outcome": "unreachable"},
    {"status": 500, "outcome": "unreachable"},
    {"status": 503, "outcome": "unreachable"}
  ]
}
```

The SICI DOI is real and was served by OpenAlex in exactly this escaped form on 2026-10-05 (HTTP 200).

- [ ] **Step 2: The failing tests**

Create `tests/test_openalex.py`:

```python
# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""OpenAlex's locations as PDF sources (#480, stage B).

The pure rules are the shared contract,
``doc/cross_platform/fulltext_parity/openalex_locations.json``, which the
Swift and Kotlin ports read too. The client is asked of a scripted loopback
server, never of OpenAlex.
"""

import json
from http import HTTPStatus
from pathlib import Path
from typing import Any

import pytest

from bmlibrarian_lite.constants import (
    OPENALEX_API_BASE_URL,
    OPENALEX_HOST,
    POLITE_RATE_CEILINGS,
    SERVICE_OPENALEX,
    SERVICE_OPENALEX_PDF,
)
from bmlibrarian_lite.data_models import RequestFailure, RequestFailureKind
from bmlibrarian_lite.openalex import (
    OpenAlexLocationsClient,
    OpenAlexWorkFetch,
    openalex_pdf_urls,
    openalex_work_url,
    untried_pdf_urls,
)
from tests.scripted_http_server import (
    ScriptedAnswer,
    json_answer,
    running,
    status_answer,
)

CONTRACT: dict[str, Any] = json.loads(
    (
        Path(__file__).resolve().parents[1]
        / "doc"
        / "cross_platform"
        / "fulltext_parity"
        / "openalex_locations.json"
    ).read_text(encoding="utf-8")
)

_DOI = "10.1/x"
_PATH = "/works/doi:10.1%2Fx"


def test_every_contract_table_is_read_here() -> None:
    """A table added to the contract and asserted nowhere would pin nothing."""
    assert set(CONTRACT) == {
        "schema_version", "description", "service_name", "pdf_service_name",
        "source", "base_url", "work_url", "pdf_urls", "status",
    }


def test_the_names_are_the_contracts() -> None:
    """The reader's names and the address are the contract's."""
    assert CONTRACT["service_name"] == SERVICE_OPENALEX
    assert CONTRACT["pdf_service_name"] == SERVICE_OPENALEX_PDF
    assert CONTRACT["base_url"] == OPENALEX_API_BASE_URL


def test_the_pacing_ceiling_is_pinned_to_the_host() -> None:
    """The ceiling table repeats the host as a literal; keep them in step."""
    assert POLITE_RATE_CEILINGS[OPENALEX_HOST] == 10.0


@pytest.mark.parametrize("row", CONTRACT["work_url"], ids=lambda row: row["name"])
def test_work_url(row: dict[str, Any]) -> None:
    """The DOI is one path segment, and the email a query value, escaped."""
    assert openalex_work_url(row["doi"], row["mailto"]) == row["url"]


@pytest.mark.parametrize("row", CONTRACT["pdf_urls"], ids=lambda row: row["name"])
def test_pdf_urls(row: dict[str, Any]) -> None:
    """The PDFs a work names that were not already tried, or unreadable."""
    if row.get("malformed"):
        with pytest.raises(ValueError):
            openalex_pdf_urls(row["work"])
        return
    assert untried_pdf_urls(openalex_pdf_urls(row["work"]), row["tried"]) == row["expected"]


def test_the_contract_has_rows() -> None:
    """Guard against an empty file making every parametrized test vanish."""
    assert len(CONTRACT["work_url"]) >= 5
    assert len(CONTRACT["pdf_urls"]) >= 8
    assert len(CONTRACT["status"]) >= 6


def _client(url: str, mailto: str | None = None, retries: int = 0) -> OpenAlexLocationsClient:
    """A client on the scripted server, without retries unless asked."""
    return OpenAlexLocationsClient(mailto=mailto, base_url=url, max_retries=retries)


_WORK = {"locations": [{"pdf_url": "https://repo.example.org/a.pdf"}]}


class TestFetchPdfUrls:
    """Each status, each body, and what each settles."""

    @pytest.mark.parametrize("row", CONTRACT["status"], ids=lambda row: str(row["status"]))
    def test_each_status_settles_what_the_contract_says(self, row: dict[str, Any]) -> None:
        """200 served, 404 absent, anything else unreachable with its status."""
        answer: ScriptedAnswer = (
            json_answer(_WORK) if row["status"] == 200 else status_answer(HTTPStatus(row["status"]))
        )
        with running({_PATH: [answer]}) as server:
            fetch = _client(server.url).fetch_pdf_urls(_DOI)

        expected = {
            "served": OpenAlexWorkFetch.served(["https://repo.example.org/a.pdf"]),
            "absent": OpenAlexWorkFetch.absent(),
            "unreachable": OpenAlexWorkFetch.unreachable(
                RequestFailure(RequestFailureKind.HTTP_STATUS, row["status"])
            ),
        }[row["outcome"]]
        assert fetch == expected

    def test_a_404_with_an_html_body_is_absent(self) -> None:
        """OpenAlex answers an unknown DOI with an HTML 404 (checked live)."""
        page = ScriptedAnswer(HTTPStatus.NOT_FOUND, b"<!doctype html><title>404 Not Found</title>", "text/html")
        with running({_PATH: [page]}) as server:
            assert _client(server.url).fetch_pdf_urls(_DOI) == OpenAlexWorkFetch.absent()

    def test_a_throttle_is_asked_again(self) -> None:
        """A 503 is retried, and the answer read."""
        with running({_PATH: [status_answer(HTTPStatus.SERVICE_UNAVAILABLE), json_answer(_WORK)]}) as server:
            fetch = _client(server.url, retries=1).fetch_pdf_urls(_DOI)
            asked = len(server.requests_to(_PATH))
        assert fetch == OpenAlexWorkFetch.served(["https://repo.example.org/a.pdf"])
        assert asked == 2

    def test_control_a_404_is_not_asked_again(self) -> None:
        """The same client: a 404 is an answer, not retried."""
        with running({_PATH: [status_answer(HTTPStatus.NOT_FOUND)]}) as server:
            _client(server.url, retries=1).fetch_pdf_urls(_DOI)
            assert len(server.requests_to(_PATH)) == 1

    @pytest.mark.parametrize(
        "body",
        [b"not json", b"[]", b'{"locations": {"pdf_url": "x"}}', b'{"locations": ["\xff"]}'],
        ids=["not json", "not an object", "locations not a list", "not utf-8"],
    )
    def test_an_answer_we_cannot_read_is_malformed(self, body: bytes) -> None:
        """Unreadable is not absent."""
        with running({_PATH: [ScriptedAnswer(HTTPStatus.OK, body)]}) as server:
            fetch = _client(server.url).fetch_pdf_urls(_DOI)
        assert fetch == OpenAlexWorkFetch.unreachable(RequestFailure(RequestFailureKind.MALFORMED_RESPONSE))

    def test_a_work_with_no_pdf_is_served_empty(self) -> None:
        """An answer naming no PDF is an answer: nothing to try, nothing unsettled."""
        with running({_PATH: [json_answer({"locations": []})]}) as server:
            assert _client(server.url).fetch_pdf_urls(_DOI) == OpenAlexWorkFetch.served([])

    def test_no_server_is_unreachable(self) -> None:
        """A transport failure is unreachable, of its own kind."""
        with running({}) as server:
            url = server.url
        fetch = _client(url).fetch_pdf_urls(_DOI)
        assert fetch.is_unreachable
        assert fetch.failure is not None
        assert fetch.failure.kind is not RequestFailureKind.HTTP_STATUS

    def test_the_request_asks_for_locations_and_names_the_contact(self) -> None:
        """select=locations, and mailto only when there is a contact."""
        with running({_PATH: [json_answer(_WORK)]}) as server:
            _client(server.url, mailto="researcher@example.org").fetch_pdf_urls(_DOI)
            _client(server.url).fetch_pdf_urls(_DOI)
            first, second = server.requests_to(_PATH)
        assert first.parameters == {"select": ["locations"], "mailto": ["researcher@example.org"]}
        assert second.parameters == {"select": ["locations"]}

    def test_a_blank_doi_is_never_asked(self) -> None:
        """No DOI, no question: absent without a request."""
        with running({}) as server:
            assert _client(server.url).fetch_pdf_urls("  ") == OpenAlexWorkFetch.absent()
            assert server.received == []


class TestFetchInvariants:
    """The states that would mean two things at once."""

    def test_served_and_unreachable_at_once_is_refused(self) -> None:
        with pytest.raises(ValueError):
            OpenAlexWorkFetch(pdf_urls=("https://x.org/a.pdf",), failure=RequestFailure(RequestFailureKind.TIMEOUT))
```

Run: `pytest tests/test_openalex.py -q`
Expected: FAIL. `ModuleNotFoundError: No module named 'bmlibrarian_lite.openalex'`.

- [ ] **Step 3: The constants**

In `constants.py`, after `SERVICE_OPENALEX_PDF`:

```python
OPENALEX_HOST = "api.openalex.org"
OPENALEX_API_BASE_URL = f"https://{OPENALEX_HOST}"
OPENALEX_REQUEST_TIMEOUT_SECONDS = 30
OPENALEX_MAX_RETRIES = 3
# OpenAlex serves JSON, which is UTF-8 (RFC 8259); nothing is guessed.
OPENALEX_ENCODING = "utf-8"
```

- [ ] **Step 4: The module**

Create `src/bmlibrarian_lite/openalex.py`:

```python
# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""OpenAlex's locations as open-access PDF sources (#480, stage B).

OpenAlex lists, for each work, the places a copy is hosted, some with a PDF
URL Unpaywall does not name: the #480 spike recovered 6 of the 290 failed
Unpaywall PDFs this way. Every ``locations[].pdf_url`` is a candidate,
whatever the location's ``is_oa``: the spike's ``real.mtak.hu`` copy is one
OpenAlex marks closed.

The pure functions here are pinned with the Swift and Kotlin ports by
``doc/cross_platform/fulltext_parity/openalex_locations.json``.
"""

from __future__ import annotations

import json
import logging
from collections.abc import Iterable, Mapping, Sequence
from dataclasses import dataclass
from typing import Any
from urllib.parse import quote

import requests
from urllib3.util.retry import Retry

from .constants import (
    EUROPEPMC_USER_AGENT,
    HTTP_NOT_FOUND,
    OPENALEX_API_BASE_URL,
    OPENALEX_ENCODING,
    OPENALEX_MAX_RETRIES,
    OPENALEX_REQUEST_TIMEOUT_SECONDS,
    RETRYABLE_HTTP_STATUSES,
)
from .data_models import RequestFailure, RequestFailureKind
from .polite_session import mount_politely
from .search_failures import request_failure_from_exception

logger = logging.getLogger(__name__)
_HTTP_OK = 200


def openalex_work_url(
    doi: str, mailto: str | None = None, base_url: str = OPENALEX_API_BASE_URL
) -> str:
    """The address OpenAlex is asked about one DOI at.

    The DOI is escaped whole, its ``/`` included, so it is one path segment
    whatever it holds (a SICI DOI holds ``<>;:()``); the email is escaped as
    a query value, so a ``+`` is not read as a space. Only ``locations`` is
    selected: it is all the chain reads.

    Args:
        doi: The DOI; surrounding whitespace is not part of it.
        mailto: The contact email for OpenAlex's polite pool, or ``None``.
        base_url: OpenAlex's address; tests point it at a local server.

    Returns:
        The URL.
    """
    url = (
        f"{base_url.rstrip('/')}/works/doi:{quote(doi.strip(), safe='')}"
        "?select=locations"
    )
    if mailto:
        url += f"&mailto={quote(mailto, safe='')}"
    return url


def _present(value: Any) -> str | None:
    """Return a string value trimmed, or ``None`` when it names nothing."""
    if not isinstance(value, str):
        return None
    trimmed = value.strip()
    return trimmed or None


def openalex_pdf_urls(work: object) -> list[str]:
    """Every PDF URL a work's locations name, in OpenAlex's order.

    Args:
        work: OpenAlex's decoded answer for one work, untrusted.

    Returns:
        Each location's ``pdf_url`` that is a non-blank string, trimmed, kept
        once where it first appears; a location that is not an object is
        skipped. Empty when ``locations`` is missing, null or empty.

    Raises:
        ValueError: If ``work`` is not a JSON object, or its ``locations`` is
            neither a list nor null: an answer we cannot read, never an
            absence.
    """
    if not isinstance(work, Mapping):
        raise ValueError("an OpenAlex work is a JSON object")
    locations = work.get("locations")
    if locations is None:
        return []
    if not isinstance(locations, list):
        raise ValueError("an OpenAlex work's locations are a list")
    urls: list[str] = []
    for location in locations:
        if not isinstance(location, Mapping):
            continue
        url = _present(location.get("pdf_url"))
        if url and url not in urls:
            urls.append(url)
    return urls


def untried_pdf_urls(pdf_urls: Sequence[str], tried: Iterable[str]) -> list[str]:
    """The PDF URLs not already tried, in their order.

    Args:
        pdf_urls: The candidates.
        tried: Addresses an earlier source named (Unpaywall's).

    Returns:
        ``pdf_urls`` without any in ``tried``.
    """
    seen = set(tried)
    return [url for url in pdf_urls if url not in seen]


@dataclass(frozen=True)
class OpenAlexWorkFetch:
    """What asking OpenAlex for a work's PDF locations produced.

    The sibling of ``pmc_open_data.PmcOpenDataFetch``. ``absent()`` is
    OpenAlex's answer that it knows no work by this DOI; ``served([])`` is a
    work naming no PDF. Both are answers. A failure is an answer we could not
    get, which leaves any copy OpenAlex knows of unassessed.

    Attributes:
        pdf_urls: The PDF URLs, when served.
        failure: Why it could not be read. ``None`` with no ``pdf_urls`` is absent.

    Raises:
        ValueError: On construction, if both are given.
    """

    pdf_urls: tuple[str, ...] | None
    failure: RequestFailure | None

    def __post_init__(self) -> None:
        """Refuse the state that would mean two things at once."""
        if self.pdf_urls is not None and self.failure is not None:
            raise ValueError("An OpenAlex fetch is served or unreachable, never both")

    @classmethod
    def served(cls, pdf_urls: Iterable[str]) -> OpenAlexWorkFetch:
        """OpenAlex answered with the work; it may name no PDF."""
        return cls(pdf_urls=tuple(pdf_urls), failure=None)

    @classmethod
    def absent(cls) -> OpenAlexWorkFetch:
        """OpenAlex knows no work by this DOI."""
        return cls(pdf_urls=None, failure=None)

    @classmethod
    def unreachable(cls, failure: RequestFailure) -> OpenAlexWorkFetch:
        """OpenAlex's answer is missing, of its real kind."""
        return cls(pdf_urls=None, failure=failure)

    @property
    def is_unreachable(self) -> bool:
        """Whether nothing about the work was established."""
        return self.failure is not None


class OpenAlexLocationsClient:
    """Asks OpenAlex which PDFs a work's locations name, paced per host."""

    def __init__(
        self,
        mailto: str | None = None,
        base_url: str = OPENALEX_API_BASE_URL,
        max_retries: int = OPENALEX_MAX_RETRIES,
    ) -> None:
        """Create the client.

        Args:
            mailto: The contact email for OpenAlex's polite pool, the one the
                transparency analysis already sends it; ``None`` asks without.
            base_url: OpenAlex's address; tests point it at a local server.
            max_retries: Retries for a 429 or 5xx; tests pass 0.
        """
        self._mailto = mailto
        self._base_url = base_url
        session = requests.Session()
        session.headers.update(
            {"User-Agent": EUROPEPMC_USER_AGENT, "Accept": "application/json"}
        )
        retry = Retry(
            total=max_retries,
            backoff_factor=1,
            status_forcelist=list(RETRYABLE_HTTP_STATUSES),
            allowed_methods=["GET"],
            raise_on_status=False,
        )
        self._session = mount_politely(session, retry=retry)

    @property
    def mailto(self) -> str | None:
        """The contact email sent with each request, if any."""
        return self._mailto

    def fetch_pdf_urls(self, doi: str) -> OpenAlexWorkFetch:
        """Ask OpenAlex for the PDFs a work's locations name.

        Args:
            doi: The work's DOI, cleaned of any resolver prefix.

        Returns:
            Served URLs (possibly none); absent for a 404 or a blank DOI,
            which is never asked; or unreachable, of its real kind.
        """
        if not doi.strip():
            return OpenAlexWorkFetch.absent()
        try:
            response = self._session.get(
                openalex_work_url(doi, self._mailto, self._base_url),
                timeout=OPENALEX_REQUEST_TIMEOUT_SECONDS,
            )
        except requests.exceptions.RequestException as error:
            return OpenAlexWorkFetch.unreachable(request_failure_from_exception(error))
        if response.status_code == HTTP_NOT_FOUND:
            return OpenAlexWorkFetch.absent()
        if response.status_code != _HTTP_OK:
            return OpenAlexWorkFetch.unreachable(
                RequestFailure(RequestFailureKind.HTTP_STATUS, response.status_code)
            )
        try:
            # Decoded explicitly, as JSON is UTF-8: ``.json()`` would guess
            urls = openalex_pdf_urls(
                json.loads(response.content.decode(OPENALEX_ENCODING))
            )
        except ValueError:  # includes UnicodeDecodeError, JSONDecodeError
            return OpenAlexWorkFetch.unreachable(
                RequestFailure(RequestFailureKind.MALFORMED_RESPONSE)
            )
        return OpenAlexWorkFetch.served(urls)
```

- [ ] **Step 5: Run the tests**

Run: `pytest tests/test_openalex.py -q`
Expected: PASS. `test_no_server_is_unreachable` binds a port and closes it; if the kind on this host is `request_failed` rather than `connection`, the assertion still holds.

Run: `ruff check src/bmlibrarian_lite/openalex.py tests/test_openalex.py && mypy src/bmlibrarian_lite/openalex.py`
Expected: no findings.

- [ ] **Step 6: Commit**

```bash
git add doc/cross_platform/fulltext_parity/openalex_locations.json src/bmlibrarian_lite/openalex.py src/bmlibrarian_lite/constants.py tests/test_openalex.py
git commit -m "feat(python): OpenAlex's PDF locations, pinned by a shared contract (#480)

Refs #480.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: OpenAlex in Python's PDF discovery

**Files:**
- Modify: `src/bmlibrarian_lite/pdf_discovery.py`. This covers `PDFSourceType` (L428), `_UNOBTAINED_PDF_SERVICE` (Task 8), `PDFDiscoverer.__init__` (L692), `discover_and_download` (L745–913), and a new `_discover_openalex` after `_discover_unpaywall`.
- Modify: `src/bmlibrarian_lite/fulltext_discovery.py`. This covers `FulltextDiscoverer.__init__` (L194), `_try_pdf_download` (L862) and `discover_fulltext` (L957).
- Modify: `src/bmlibrarian_lite/gui/workers.py` (`PDFDiscoveryWorker` L191, `FulltextDiscoveryWorker` L345), `src/bmlibrarian_lite/gui/document_interrogation_tab.py` (L601, L910), `src/bmlibrarian_lite/mcp_server.py` (L819), and `src/bmlibrarian_lite/study_transparency_analyzer/study_transparency_analyzer.py` (L2978).
- Modify: `tests/conftest.py`, `pyproject.toml` (`[tool.pytest.ini_options] markers`).
- Create: `tests/test_openalex_discovery.py`

**Interfaces:**
- Consumes: `OpenAlexLocationsClient`, `OpenAlexWorkFetch` and `untried_pdf_urls` (Task 9); `SERVICE_OPENALEX` and `SERVICE_OPENALEX_PDF` (Task 2); `_UNOBTAINED_PDF_SERVICE`, `unobtained_open_access_pdf`, `copy_rank` and `_ranked` (Task 8).
- Produces:
  - `PDFSourceType.OPENALEX_OA = "openalex_oa"`, added to `_UNOBTAINED_PDF_SERVICE` as `SERVICE_OPENALEX_PDF`.
  - `default_openalex_client(mailto: str | None) -> OpenAlexLocationsClient`, at module level, which conftest patches.
  - `PDFDiscoverer(..., openalex_email: str | None = None, openalex: OpenAlexLocationsClient | None = None)`
  - `FulltextDiscoverer(..., openalex_email: str | None = None)`
  - `discover_fulltext(..., openalex_email=None)`
  - Both workers take `openalex_email: Optional[str] = None` as a keyword after `parent`.

- [ ] **Step 1: The autouse guard**

Register the marker in `pyproject.toml`:

```toml
markers = [
    "integration: marks tests as integration tests requiring network access (deselect with '-m \"not integration\"')",
    "real_openalex_client: the PDF discoverer builds its real OpenAlex client (tests/conftest.py otherwise answers every DOI as unknown)",
]
```

Append to `tests/conftest.py`:

```python
class _OpenAlexKnowsNoWork:
    """OpenAlex knowing no work by any DOI: the answer that adds nothing."""

    mailto = None

    def fetch_pdf_urls(self, doi: str) -> Any:
        """Answer every DOI as unknown, without a request."""
        from bmlibrarian_lite.openalex import OpenAlexWorkFetch

        return OpenAlexWorkFetch.absent()


@pytest.fixture(autouse=True)
def _no_live_openalex(
    request: pytest.FixtureRequest, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Keep every PDF discovery off the real OpenAlex (#480, stage B).

    A discovery that exhausts its sources now asks OpenAlex; dozens of
    existing tests end there with a DOI. They get OpenAlex's "no such work",
    which records nothing, so their outcomes are what they were. A test that
    injects its own client is unaffected; one that needs the real default
    marks itself ``real_openalex_client``.
    """
    if request.node.get_closest_marker("real_openalex_client"):
        return
    monkeypatch.setattr(
        "bmlibrarian_lite.pdf_discovery.default_openalex_client",
        lambda mailto: _OpenAlexKnowsNoWork(),
    )
```

Make sure `Any` is imported in `conftest.py`; it already imports from `typing`.

- [ ] **Step 2: The failing tests**

Create `tests/test_openalex_discovery.py`:

```python
# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""OpenAlex inside PDF discovery (#480, stage B).

OpenAlex is asked once, for the PDFs Unpaywall did not name: after every
open-access source failed and before any source that is not open access,
or at once when nothing else was found. The first copy that went
unassessed, in chain order, is the one recorded.
"""

from pathlib import Path
from typing import Any

import pytest
import requests

from bmlibrarian_lite.constants import (
    FALLBACK_CONTACT_EMAIL,
    SERVICE_OPENALEX,
    SERVICE_OPENALEX_PDF,
    SERVICE_UNPAYWALL_PDF,
)
from bmlibrarian_lite.data_models import (
    LookupRecord,
    RequestFailure,
    RequestFailureKind,
    SourceLookupFailure,
)
from bmlibrarian_lite.openalex import OpenAlexLocationsClient, OpenAlexWorkFetch
from bmlibrarian_lite.pdf_discovery import (
    DiscoveryResult,
    PDFDiscoverer,
    PDFSource,
    PDFSourceType,
)

UNPAYWALL_PDF = "https://walled.example.org/a.pdf"
OPENALEX_PDF = "https://repo.example.org/b.pdf"
PUBLISHER_PDF = "https://publisher.example.org/c.pdf"
PDF_BYTES = b"%PDF-1.7\n" + b"0" * 64


def _response(status: int, body: bytes = b"", content_type: str = "application/pdf") -> requests.Response:
    """A response held in memory."""
    response = requests.Response()
    response.status_code = status
    response._content = body
    response._content_consumed = True
    response.headers["Content-Type"] = content_type
    return response


class _Session:
    """Answers each URL with a canned status; records what was asked."""

    def __init__(self, answers: dict[str, int], on_get: Any = None) -> None:
        self.answers = answers
        self.requested: list[str] = []
        self.on_get = on_get

    def get(self, url: str, **kwargs: Any) -> requests.Response:
        """Route one GET by URL: a 200 serves the PDF."""
        self.requested.append(url)
        if self.on_get:
            self.on_get()
        status = self.answers[url]
        response = _response(status, PDF_BYTES if status == 200 else b"")
        response.url = url
        return response


class _OpenAlex:
    """OpenAlex answering every DOI with one fetch; records each DOI asked."""

    mailto = None

    def __init__(self, fetch: OpenAlexWorkFetch) -> None:
        self.fetch = fetch
        self.asked: list[str] = []

    def fetch_pdf_urls(self, doi: str) -> OpenAlexWorkFetch:
        self.asked.append(doi)
        return self.fetch


def _unpaywall(url: str = UNPAYWALL_PDF) -> PDFSource:
    return PDFSource(url=url, source_type=PDFSourceType.UNPAYWALL_OA, is_open_access=True)


def _publisher(url: str = PUBLISHER_PDF) -> PDFSource:
    return PDFSource(url=url, source_type=PDFSourceType.DOI_DIRECT, is_open_access=False)


def _discover(
    tmp_path: Path,
    sources: list[PDFSource],
    openalex: _OpenAlex,
    answers: dict[str, int],
    doi: str | None = "10.1/x",
    on_get: Any = None,
) -> tuple[DiscoveryResult, _Session]:
    """Run discovery over ``sources``, every other lookup answered."""
    discoverer = PDFDiscoverer(
        unpaywall_email="test@example.com",
        use_browser_fallback=False,
        openalex=openalex,  # type: ignore[arg-type]
    )
    discoverer._discover_sources = lambda d, p, c: (list(sources), LookupRecord())  # type: ignore[method-assign]
    session = _Session(answers, on_get)
    discoverer._session = session  # type: ignore[assignment]
    return discoverer.discover_and_download(tmp_path / "a.pdf", doi=doi), session


def test_openalex_is_not_asked_when_an_unpaywall_pdf_serves(tmp_path: Path) -> None:
    openalex = _OpenAlex(OpenAlexWorkFetch.served([OPENALEX_PDF]))
    result, _ = _discover(tmp_path, [_unpaywall()], openalex, {UNPAYWALL_PDF: 200})
    assert result.success
    assert openalex.asked == []


def test_a_pdf_openalex_names_serves_when_unpaywalls_is_walled(tmp_path: Path) -> None:
    openalex = _OpenAlex(OpenAlexWorkFetch.served([OPENALEX_PDF]))
    result, _ = _discover(tmp_path, [_unpaywall()], openalex, {UNPAYWALL_PDF: 403, OPENALEX_PDF: 200})
    assert result.success
    assert result.source is not None and result.source.source_type is PDFSourceType.OPENALEX_OA
    assert result.lookups == LookupRecord(), "a served copy settles it"


def test_a_pdf_unpaywall_named_is_not_asked_again(tmp_path: Path) -> None:
    openalex = _OpenAlex(OpenAlexWorkFetch.served([UNPAYWALL_PDF, OPENALEX_PDF]))
    _, session = _discover(tmp_path, [_unpaywall()], openalex, {UNPAYWALL_PDF: 403, OPENALEX_PDF: 403})
    assert session.requested.count(UNPAYWALL_PDF) == 1


def test_with_no_source_at_all_openalex_is_asked_at_once(tmp_path: Path) -> None:
    openalex = _OpenAlex(OpenAlexWorkFetch.served([OPENALEX_PDF]))
    result, _ = _discover(tmp_path, [], openalex, {OPENALEX_PDF: 200})
    assert result.success


def test_an_unreachable_openalex_is_recorded_not_an_absence(tmp_path: Path) -> None:
    failure = RequestFailure(RequestFailureKind.HTTP_STATUS, 503)
    openalex = _OpenAlex(OpenAlexWorkFetch.unreachable(failure))
    result, _ = _discover(tmp_path, [], openalex, {})
    assert not result.success
    assert result.lookups.failures == (SourceLookupFailure(SERVICE_OPENALEX, failure),)
    assert "OpenAlex" in (result.error or "")


def test_control_openalex_knowing_no_work_records_nothing(tmp_path: Path) -> None:
    openalex = _OpenAlex(OpenAlexWorkFetch.absent())
    result, _ = _discover(tmp_path, [], openalex, {})
    assert not result.success
    assert result.lookups == LookupRecord()


def test_a_refused_openalex_pdf_is_recorded_under_its_copy(tmp_path: Path) -> None:
    openalex = _OpenAlex(OpenAlexWorkFetch.served([OPENALEX_PDF]))
    result, _ = _discover(tmp_path, [], openalex, {OPENALEX_PDF: 403})
    assert result.lookups.failures == (
        SourceLookupFailure(SERVICE_OPENALEX_PDF, RequestFailure(RequestFailureKind.HTTP_STATUS, 403), OPENALEX_PDF),
    )


def test_every_refusal_is_told_in_chain_order(tmp_path: Path) -> None:
    openalex = _OpenAlex(OpenAlexWorkFetch.served([OPENALEX_PDF]))
    result, _ = _discover(tmp_path, [_unpaywall()], openalex, {UNPAYWALL_PDF: 403, OPENALEX_PDF: 404})
    assert result.lookups.failures == (
        SourceLookupFailure(SERVICE_UNPAYWALL_PDF, RequestFailure(RequestFailureKind.HTTP_STATUS, 403), UNPAYWALL_PDF),
        SourceLookupFailure(SERVICE_OPENALEX_PDF, RequestFailure(RequestFailureKind.HTTP_STATUS, 404), OPENALEX_PDF),
    )
    assert (result.error or "").endswith(
        "walled.example.org, named by Unpaywall (HTTP 403 Forbidden); "
        "repo.example.org, named by OpenAlex (HTTP 404 Not Found). "
        "Whether this document is open access was not established."
    )


def test_openalex_comes_before_a_source_that_is_not_open_access(tmp_path: Path) -> None:
    openalex = _OpenAlex(OpenAlexWorkFetch.served([OPENALEX_PDF]))
    result, session = _discover(
        tmp_path, [_unpaywall(), _publisher()], openalex,
        {UNPAYWALL_PDF: 403, OPENALEX_PDF: 200, PUBLISHER_PDF: 200},
    )
    assert result.success
    assert session.requested == [UNPAYWALL_PDF, OPENALEX_PDF]


def test_no_doi_no_openalex(tmp_path: Path) -> None:
    openalex = _OpenAlex(OpenAlexWorkFetch.served([OPENALEX_PDF]))
    _discover(tmp_path, [], openalex, {}, doi=None)
    assert openalex.asked == []


def test_a_cancel_before_openalex_asks_nothing(tmp_path: Path) -> None:
    openalex = _OpenAlex(OpenAlexWorkFetch.served([OPENALEX_PDF]))
    holder: dict[str, PDFDiscoverer] = {}
    discoverer = PDFDiscoverer(unpaywall_email="test@example.com", use_browser_fallback=False, openalex=openalex)  # type: ignore[arg-type]
    discoverer._discover_sources = lambda d, p, c: ([_unpaywall()], LookupRecord())  # type: ignore[method-assign]
    holder["d"] = discoverer
    discoverer._session = _Session({UNPAYWALL_PDF: 403}, on_get=lambda: holder["d"].cancel())  # type: ignore[assignment]
    result = discoverer.discover_and_download(tmp_path / "a.pdf", doi="10.1/x")
    assert result.error == "Cancelled"
    assert openalex.asked == []


@pytest.mark.real_openalex_client
@pytest.mark.parametrize(
    ("configured", "sent"),
    [("researcher@example.org", "researcher@example.org"), (FALLBACK_CONTACT_EMAIL, None), ("  ", None), (None, None)],
)
def test_the_contact_email_reaches_openalex(configured: str | None, sent: str | None) -> None:
    discoverer = PDFDiscoverer(openalex_email=configured)
    assert isinstance(discoverer._openalex, OpenAlexLocationsClient)
    assert discoverer._openalex.mailto == sent


def test_fulltext_discovery_passes_the_contact_email(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    from bmlibrarian_lite import fulltext_discovery

    seen: dict[str, Any] = {}

    class _Recorder:
        def __init__(self, **kwargs: Any) -> None:
            seen.update(kwargs)

        def discover_and_download(self, **kwargs: Any) -> DiscoveryResult:
            return DiscoveryResult(success=False, error="none")

    monkeypatch.setattr(fulltext_discovery, "PDFDiscoverer", _Recorder)
    discoverer = fulltext_discovery.FulltextDiscoverer(openalex_email="researcher@example.org")
    discoverer._try_pdf_download({"doi": "10.1/x", "title": "T", "year": 2020}, None, None, "10.1/x", "T")
    assert seen["openalex_email"] == "researcher@example.org"
```

`_try_pdf_download` calls `generate_pdf_path(doc_dict)`. If that writes under the user's PDF directory, monkeypatch `fulltext_discovery.generate_pdf_path` to `lambda *a, **k: tmp_path / "a.pdf"` as well. Read `_try_pdf_download`'s first lines before running.

Run: `pytest tests/test_openalex_discovery.py -q`
Expected: FAIL. `TypeError: ... unexpected keyword argument 'openalex'`.

- [ ] **Step 3: Implement in `pdf_discovery.py`**

Imports: add `from collections import deque`, add `Iterable` to the `collections.abc` import, add `SERVICE_OPENALEX` and `SERVICE_OPENALEX_PDF` to the constants import, and add `from .openalex import OpenAlexLocationsClient, untried_pdf_urls`.

`PDFSourceType` gains:

```python
    OPENALEX_OA = "openalex_oa"  # A PDF an OpenAlex location names (#480)
```

Add `PDFSourceType.OPENALEX_OA: SERVICE_OPENALEX_PDF` to `_UNOBTAINED_PDF_SERVICE` (Task 8). A PDF OpenAlex named and we could not obtain is then recorded as OpenAlex's copy, with its address, by the same function. Add the seam:

```python
def default_openalex_client(mailto: str | None) -> OpenAlexLocationsClient:
    """The OpenAlex client a discoverer asks when none is injected.

    A module-level seam so ``tests/conftest.py`` can keep every discovery in
    the test suite off the real OpenAlex.

    Args:
        mailto: The contact email, already checked usable, or ``None``.

    Returns:
        A client on OpenAlex itself.
    """
    return OpenAlexLocationsClient(mailto=mailto)
```

`PDFDiscoverer.__init__` gains two parameters, after `browser_headless`:

```python
        openalex_email: Optional[str] = None,
        openalex: OpenAlexLocationsClient | None = None,
```

documented as:

```
            openalex_email: The contact email sent to OpenAlex, the one the
                transparency analysis already sends it; the application's
                placeholder counts as none, and OpenAlex is then asked
                without one (#480)
            openalex: The OpenAlex client; tests pass a stub
```

and, in the body:

```python
        # The placeholder test is Unpaywall's: a blank or placeholder address
        # is no contact, and OpenAlex is asked without one rather than skipped
        self._openalex = (
            openalex
            if openalex is not None
            else default_openalex_client(usable_unpaywall_email(openalex_email))
        )
```

Add `_discover_openalex` after `_discover_unpaywall`:

```python
    def _discover_openalex(
        self, doi: str, known_urls: Iterable[str]
    ) -> tuple[list[PDFSource], LookupRecord]:
        """The PDFs OpenAlex's locations name that no earlier source did (#480).

        Args:
            doi: The article's DOI.
            known_urls: Every address already found, tried or still to try.

        Returns:
            The new open-access sources, in OpenAlex's order, and the failure
            that left OpenAlex unasked, if any. No work, or a work naming no
            new PDF, is an answer: no source and nothing recorded.
        """
        fetch = self._openalex.fetch_pdf_urls(self._clean_doi(doi))
        if fetch.failure is not None:
            logger.warning(
                "OpenAlex could not be asked about DOI %s (%s), so any open-access "
                "copy it knows of is not assessed.",
                doi,
                fetch.failure.describe(),
            )
            return [], LookupRecord(
                failures=(SourceLookupFailure(SERVICE_OPENALEX, fetch.failure),)
            )
        urls = untried_pdf_urls(fetch.pdf_urls or (), known_urls)
        return [
            PDFSource(url=url, source_type=PDFSourceType.OPENALEX_OA, is_open_access=True)
            for url in urls
        ], LookupRecord()
```

In `discover_and_download`, after the first `if self._cancelled:` block and before `if not sources:`:

```python
        # OpenAlex is asked once, for the PDFs Unpaywall did not name (#480,
        # stage B): at once when nothing else was found, otherwise when the
        # next source to try is not an open-access copy (below).
        openalex_doi = doi
        if not sources and openalex_doi:
            found, openalex_lookups = self._discover_openalex(openalex_doi, ())
            openalex_doi = None
            sources = found
            lookups = lookups.merged(openalex_lookups)
            told = told.merged(openalex_lookups)
```

`copy_rank` and `unobtained` exist from Task 8. Replace `for source in sources:` and its first `if self._cancelled:` block with:

```python
        pending = deque(sources)
        while pending or openalex_doi:
            if self._cancelled:
                return DiscoveryResult(
                    success=False,
                    error="Cancelled",
                    lookups=lookups,
                )

            if openalex_doi and (not pending or not pending[0].is_open_access):
                found, openalex_lookups = self._discover_openalex(
                    openalex_doi, [s.url for s in sources]
                )
                openalex_doi = None
                lookups = lookups.merged(openalex_lookups)
                told = told.merged(openalex_lookups)
                first_rank = len(copy_rank)
                for offset, found_source in enumerate(found):
                    copy_rank[found_source.url] = first_rank + offset
                sources.extend(found)
                pending.extendleft(reversed(found))
                continue

            source = pending.popleft()
```

The rest of the loop body (Task 8's) stays as it is, now inside the `while`. A copy served but not saved returns from inside the loop, so OpenAlex is never asked after one (decision 1).

The non-OA paywall early return now comes after OpenAlex, because OpenAlex is asked before the first source that is not open access.

Update `discover_and_download`'s docstring list: "2. Unpaywall (if DOI and email available)" gains "2a. OpenAlex's locations not already found (if DOI), before any source that is not open access".

- [ ] **Step 4: Plumb the contact email**

- `fulltext_discovery.py`:
  - `FulltextDiscoverer.__init__` gains `openalex_email: Optional[str] = None`, documented "The contact email sent to OpenAlex (#480)", and stores `self.openalex_email = openalex_email`.
  - `_try_pdf_download` passes `openalex_email=self.openalex_email` to `PDFDiscoverer(...)`.
  - `discover_fulltext(...)` (L957) gains `openalex_email: Optional[str] = None` and passes it on.
- `gui/workers.py`: both workers' `__init__` gain `openalex_email: Optional[str] = None` after `parent`, stored and passed to the discoverer they build.
- `gui/document_interrogation_tab.py`: both worker constructions pass `openalex_email=self.config.pubmed.email or None`.
- `mcp_server.py` L819: `FulltextDiscoverer(unpaywall_email=config.pubmed.email, openalex_email=config.pubmed.email, use_browser_fallback=False)`.
- `study_transparency_analyzer.py` L2978: `FulltextDiscoverer(..., openalex_email=self.email)`. `self.email` is what its own `OpenAlexClient` already receives.

- [ ] **Step 5: Run the tests, then the suite**

Run: `pytest tests/test_openalex_discovery.py tests/test_unobtained_unpaywall_pdf.py tests/test_open_access_statement.py -q`
Expected: PASS.

Run: `pytest tests/ -q -x 2>&1 | tail -5`
Expected: 0 failures. A failure in a test that ends discovery with a DOI means the conftest guard is not reached. Check that the test builds its `PDFDiscoverer` through the module, and that `default_openalex_client` is looked up at call time; it is, because `__init__` reads the module global.

Run: `python .github/scripts/lint_delta.py --base-ref origin/master`
Expected: no new findings.

- [ ] **Step 6: Commit**

```bash
git add src/bmlibrarian_lite tests pyproject.toml
git commit -m "feat(python): ask OpenAlex for the PDFs Unpaywall did not name (#480)

Asked once, after every open-access source failed and before any that is
not open access, never after a copy was served. An unreachable OpenAlex is
recorded, never an absence; a PDF it named that we could not obtain is
recorded as OpenAlex's copy, with its address, after Unpaywall's.

Refs #480.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: Swift: OpenAlex's pure helpers and contract tests

**Files:**
- Create: `Packages/BioMedLit/Sources/BioMedLit/Services/OpenAlex.swift`
- Modify: `Packages/BioMedLit/Sources/BioMedLit/Utilities/Constants.swift`. Add an `// MARK: - OpenAlex` block after stage A's bucket constants (~L136).
- Create: `Packages/BioMedLit/Tests/BioMedLitTests/OpenAlexContractTests.swift`

**Interfaces:**
- Produces:
  - `public enum OpenAlex` with:
    - `static func workURL(doi: String, mailto: String?, baseURL: String = BioMedLitConstants.openAlexBaseURL) -> URL?`
    - `static func pdfURLs(fromWork data: Data) throws -> [String]`
    - `static func pdfURLs(fromWorkObject object: Any) throws -> [String]`
    - `static func untried(_ urls: [String], tried: Set<String>) -> [String]`
  - `enum OpenAlexFetch: Equatable { case served([String]); case absent; case unreachable(RequestFailure) }`
  - `BioMedLitConstants.openAlexBaseURL`, `openAlexServiceName`, `openAlexMinimumInterval`

- [ ] **Step 1: The failing contract tests**

Create `OpenAlexContractTests.swift`. Copy the fixture-loading walk from `PMCOpenDataContractTests` (its `enum PMCOpenDataContract`, which walks up from `#filePath` to `.git`), pointed at `openalex_locations.json`:

```swift
import XCTest
@testable import BioMedLit

enum OpenAlexContract {
    static func load() throws -> [String: Any] {
        // the same walk as PMCOpenDataContract.load(), for openalex_locations.json
    }
}

final class OpenAlexContractTests: XCTestCase {
    private func table(_ name: String) throws -> [[String: Any]] {
        try XCTUnwrap(OpenAlexContract.load()[name] as? [[String: Any]], name)
    }

    func testEveryContractTableIsReadHere() throws {
        XCTAssertEqual(
            Set(try OpenAlexContract.load().keys),
            ["schema_version", "description", "service_name", "pdf_service_name", "source",
             "base_url", "work_url", "pdf_urls", "status"]
        )
    }

    func testTheNamesAreTheContracts() throws {
        let contract = try OpenAlexContract.load()
        XCTAssertEqual(contract["service_name"] as? String, OpenAccessSource.openAlex.serviceName)
        XCTAssertEqual(contract["pdf_service_name"] as? String, OpenAccessSource.openAlexPDF.serviceName)
        XCTAssertEqual(contract["base_url"] as? String, BioMedLitConstants.openAlexBaseURL)
        XCTAssertEqual(BioMedLitConstants.openAlexServiceName, OpenAccessSource.openAlex.serviceName)
    }

    func testEachWorkURLRow() throws {
        let rows = try table("work_url")
        XCTAssertGreaterThanOrEqual(rows.count, 5)
        for row in rows {
            let name = row["name"] as? String ?? "?"
            let url = OpenAlex.workURL(doi: row["doi"] as! String, mailto: row["mailto"] as? String)
            XCTAssertEqual(url?.absoluteString, row["url"] as? String, name)
        }
    }

    func testEachPDFURLsRow() throws {
        let rows = try table("pdf_urls")
        XCTAssertGreaterThanOrEqual(rows.count, 8)
        for row in rows {
            let name = row["name"] as? String ?? "?"
            let work = row["work"] as Any
            if row["malformed"] as? Bool == true {
                XCTAssertThrowsError(try OpenAlex.pdfURLs(fromWorkObject: work), name)
                continue
            }
            let tried = Set(row["tried"] as? [String] ?? [])
            XCTAssertEqual(
                OpenAlex.untried(try OpenAlex.pdfURLs(fromWorkObject: work), tried: tried),
                row["expected"] as? [String],
                name
            )
        }
    }
}
```

Fill `OpenAlexContract.load()` by copying `PMCOpenDataContract.load()`'s body verbatim and changing only the file name. The `status` table is read in Task 12, by the service tests. Add `"status"` handling there, and keep this file's key-set test as written: it lists `status`, which the service test asserts.

Run: `cd Packages/BioMedLit && swift build --build-tests 2>&1 | tail -5`
Expected: FAIL. `cannot find 'OpenAlex' in scope`.

- [ ] **Step 2: Constants**

In `Constants.swift`:

```swift
    // MARK: - OpenAlex (#480, stage B)

    /// OpenAlex's API, asked by DOI for the PDFs its locations name.
    public static let openAlexBaseURL = "https://api.openalex.org"
    /// OpenAlex as the reader knows it; Python's `SERVICE_OPENALEX`.
    public static let openAlexServiceName = "OpenAlex"
    /// Ten requests a second, OpenAlex's published limit and Python's
    /// `POLITE_RATE_CEILINGS` entry; per service instance, as the bucket's (#489).
    public static let openAlexMinimumInterval: TimeInterval = 0.1
```

- [ ] **Step 3: The helpers**

Create `OpenAlex.swift`:

```swift
// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2026 Dr Horst Herb
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// OpenAlex's locations as open-access PDF sources (#480, stage B).
///
/// Pinned with Python's `openalex.py` by
/// `doc/cross_platform/fulltext_parity/openalex_locations.json`. Every
/// `locations[].pdf_url` is a candidate, whatever the location's `is_oa`: the
/// #480 spike recovered a copy OpenAlex marks closed.
public enum OpenAlex {
    /// RFC 3986's unreserved characters: all Python's `quote(s, safe="")`
    /// leaves bare. Everything else, `/` included, is escaped as UTF-8 bytes.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    /// Why an answer could not be read.
    enum ParseError: Error {
        case notAWork
        case locationsNotAList
    }

    private static func escaped(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    /// The address OpenAlex is asked about one DOI at: the DOI one path
    /// segment, only `locations` selected, the contact email a query value.
    ///
    /// - Parameters:
    ///   - doi: The DOI; surrounding whitespace is not part of it.
    ///   - mailto: The contact email, or `nil` (or empty) to ask without one.
    ///   - baseURL: OpenAlex's address.
    /// - Returns: The URL, or `nil` if it cannot be formed.
    public static func workURL(
        doi: String, mailto: String?, baseURL: String = BioMedLitConstants.openAlexBaseURL
    ) -> URL? {
        let trimmed = doi.trimmingCharacters(in: .whitespacesAndNewlines)
        var text = "\(baseURL)/works/doi:\(escaped(trimmed))?select=locations"
        if let mailto, !mailto.isEmpty {
            text += "&mailto=\(escaped(mailto))"
        }
        return URL(string: text)
    }

    /// Every PDF URL a work's locations name, from OpenAlex's JSON body.
    ///
    /// - Throws: `ParseError` or the decoder's error for a body we cannot read.
    static func pdfURLs(fromWork data: Data) throws -> [String] {
        try pdfURLs(fromWorkObject: try JSONSerialization.jsonObject(with: data))
    }

    /// Every PDF URL a decoded work's locations name: each `pdf_url` that is
    /// a non-blank string, trimmed, kept once, in OpenAlex's order; a location
    /// that is not an object is skipped; `locations` missing or null is none.
    ///
    /// - Throws: `ParseError.notAWork` unless an object;
    ///   `ParseError.locationsNotAList` for `locations` neither a list nor null.
    static func pdfURLs(fromWorkObject object: Any) throws -> [String] {
        guard let work = object as? [String: Any] else { throw ParseError.notAWork }
        let raw = work["locations"]
        if raw == nil || raw is NSNull { return [] }
        guard let locations = raw as? [Any] else { throw ParseError.locationsNotAList }
        var urls: [String] = []
        for case let location as [String: Any] in locations {
            guard let pdf = (location["pdf_url"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !pdf.isEmpty else { continue }
            if !urls.contains(pdf) { urls.append(pdf) }
        }
        return urls
    }

    /// The URLs not already tried, in their order.
    static func untried(_ urls: [String], tried: Set<String>) -> [String] {
        urls.filter { !tried.contains($0) }
    }
}

/// What asking OpenAlex for a work's PDF locations produced; the sibling of
/// ``PMCOpenDataFetch``. `absent` is OpenAlex knowing no work by the DOI;
/// `served([])` a work naming no PDF. Both are answers.
enum OpenAlexFetch: Equatable {
    case served([String])
    case absent
    case unreachable(RequestFailure)
}
```

`JSONSerialization` bridges a JSON number to `NSNumber`, so `as? String` skips `"pdf_url": 7` as the fixture requires. If the test shows it bridging to `String`, check `location["pdf_url"] is String` explicitly instead.

- [ ] **Step 4: Run, then commit**

Run: `cd Packages/BioMedLit && swift test --filter OpenAlexContractTests`
Expected: PASS.

```bash
git add Packages/BioMedLit/Sources/BioMedLit/Services/OpenAlex.swift Packages/BioMedLit/Sources/BioMedLit/Utilities/Constants.swift Packages/BioMedLit/Tests/BioMedLitTests/OpenAlexContractTests.swift
git commit -m "feat(swift): OpenAlex's PDF locations, pinned by the shared contract (#480)

Refs #480.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: Swift: the OpenAlex tier, and the app's source

**Files:**
- Modify: `Packages/BioMedLit/Sources/BioMedLit/Models/FullTextModels.swift`:
  - `FullTextSource` (L27, `displayName` L42)
  - `FullTextContent` (L419, `source` L434, `pdfURL` L472)
  - the init assert (L362–365)
- Modify: `Packages/BioMedLit/Sources/BioMedLit/Utilities/RetryHelper.swift` (`RetryConfiguration.openAlex`)
- Modify: `Packages/BioMedLit/Sources/BioMedLit/Services/FullTextService.swift`:
  - `init`, adding `openAlexRetry`
  - the pacing, replacing `nextBucketRequest` with a per-host map
  - `fetchOpenAlexPDFURLs`
  - the tier
- Modify: `Packages/BioMedLit/Tests/BioMedLitTests/FullTextServiceParseWarningsTests.swift` (`StubURLProtocol.fallbackRoutes`)
- Create: `Packages/BioMedLit/Tests/BioMedLitTests/FullTextServiceOpenAlexTests.swift`
- Modify: `Packages/BioMedLit/Tests/BioMedLitTests/PDFTierFallthroughTests.swift` (extend `testExtractionSwitchedOffStillReturnsTheFirstPDFURL`)
- Modify (the app):
  - `ios/MedicalFactChecker/Sources/Models/FullTextSource.swift`
  - `ios/MedicalFactChecker/Sources/Utilities/BioMedLitAdapters.swift` (L477, L499)
  - `ios/MedicalFactChecker/Sources/Views/Components/FullTextSourceBadge.swift` (L68)
  - `ios/MedicalFactChecker/Sources/macOS/MacConstants.swift` (L352)
  - `ios/MedicalFactChecker/Tests/FullTextSourceDisplayTests.swift`

**Interfaces:**
- Consumes: `OpenAlex`, `OpenAlexFetch` (Task 11); `tryOpenAccessPDFs`, `settledOpenAccessShortfall` (Task 6); `OpenAccessShortfall.adding(_:to:)` (Task 4); `OpenAccessSource.openAlex`/`.openAlexPDF` (Task 2).
- Produces:
  - `FullTextSource.openAlex = "openalex"`, display name "OpenAlex"
  - `FullTextContent.openAlex(pdfURL: URL)`
  - `func fetchOpenAlexPDFURLs(doi: String) async throws -> OpenAlexFetch`, internal so tests can call it
  - `AppFullTextSource.openAlex = "openalex"`

- [ ] **Step 1: Keep the existing suite off OpenAlex**

In `StubURLProtocol`, add:

```swift
    /// Answers consulted after ``routes`` and before ``stubbed``: sources a
    /// test did not mention get these, not the catch-all. OpenAlex is asked
    /// at the end of every chain with a DOI (#480, stage B); without this a
    /// catch-all 200 would read as an unreadable OpenAlex and put a shortfall
    /// on results that never asked about it. A test that wants OpenAlex sets
    /// a route for it, which wins.
    static var fallbackRoutes: [String: (status: Int, body: Data)] = defaultFallbackRoutes
    static let defaultFallbackRoutes: [String: (status: Int, body: Data)] = [
        "api.openalex.org": (404, Data()),
    ]
```

In `reset()`, add `fallbackRoutes = defaultFallbackRoutes`. In `startLoading`, after `let match = …`, add:

```swift
        let fallback = Self.fallbackRoutes
            .filter { url.contains($0.key) }
            .max { $0.key.count < $1.key.count }
```

and change the answer to `queued.map { … } ?? match?.value ?? fallback?.value ?? Self.stubbed`.

- [ ] **Step 2: The failing tests**

Create `FullTextServiceOpenAlexTests.swift`. Use the same setup as `FullTextServiceUnpaywallLocationsTests` (Task 6), with an `openAlex(_ urls: [String]) -> Data` helper writing `{"locations": [{"pdf_url": …}]}`.

```swift
final class FullTextServiceOpenAlexTests: XCTestCase {
    private let doi = "10.1/locations"
    private let walled = "https://walled.example.org/a.pdf"
    private let repo = "https://repo.example.org/b.pdf"

    func testOpenAlexIsNotAskedWhenUnpaywallsPDFServes() async throws {
        StubURLProtocol.routes["unpaywall"] = (200, unpaywall([repo]))
        StubURLProtocol.routes["repo.example.org"] = (200, pdfBody)
        _ = try await fetch()
        XCTAssertFalse(StubURLProtocol.requested("api.openalex.org"))
    }

    func testAPDFOpenAlexNamesServesWhenUnpaywallsIsRefused() async throws {
        StubURLProtocol.routes["unpaywall"] = (200, unpaywall([walled]))
        StubURLProtocol.routes["walled.example.org"] = (403, Data())
        StubURLProtocol.routes["api.openalex.org"] = (200, openAlex([repo]))
        StubURLProtocol.routes["repo.example.org"] = (200, pdfBody)
        let result = try await fetch()
        XCTAssertEqual(result.content, .openAlex(pdfURL: URL(string: repo)!))
        XCTAssertEqual(result.source, .openAlex)
        XCTAssertNil(result.openAccessShortfall)
    }

    func testAPDFBothNameIsRequestedOnce() async throws {
        StubURLProtocol.routes["unpaywall"] = (200, unpaywall([walled]))
        StubURLProtocol.routes["walled.example.org"] = (403, Data())
        StubURLProtocol.routes["api.openalex.org"] = (200, openAlex([walled]))
        _ = try await fetch()
        XCTAssertEqual(StubURLProtocol.requestedURLs.filter { $0.contains("walled.example.org") }.count, 1)
    }

    func testAnUnreachableOpenAlexIsTheShortfallWhenNothingElseIs() async throws {
        StubURLProtocol.routes["unpaywall"] = (404, Data())
        StubURLProtocol.routes["api.openalex.org"] = (503, Data())
        let result = try await fetch()
        XCTAssertEqual(result.content, .doi(webURL: URL(string: "https://doi.org/\(doi)")!))
        XCTAssertEqual(result.openAccessShortfall, OpenAccessShortfall(source: .openAlex, failure: .httpStatus(503)))
    }

    func testOpenAlexKnowingNoWorkAddsNothing() async throws {
        StubURLProtocol.routes["unpaywall"] = (404, Data())
        // the default fallback route answers OpenAlex 404
        let result = try await fetch()
        XCTAssertNil(result.openAccessShortfall)
        XCTAssertTrue(StubURLProtocol.requested("api.openalex.org"))
    }

    func testARefusedOpenAlexPDFIsRecordedUnderItsCopy() async throws {
        StubURLProtocol.routes["unpaywall"] = (404, Data())
        StubURLProtocol.routes["api.openalex.org"] = (200, openAlex([repo]))
        StubURLProtocol.routes["repo.example.org"] = (403, Data())
        let result = try await fetch()
        XCTAssertEqual(result.openAccessShortfall, OpenAccessShortfall(source: .openAlexPDF, failure: .httpStatus(403), address: repo))
    }

    func testEveryRefusalIsToldInChainOrder() async throws {
        StubURLProtocol.routes["unpaywall"] = (200, unpaywall([walled]))
        StubURLProtocol.routes["walled.example.org"] = (403, Data())
        StubURLProtocol.routes["api.openalex.org"] = (200, openAlex([repo]))
        StubURLProtocol.routes["repo.example.org"] = (404, Data())
        let result = try await fetch()
        XCTAssertEqual(
            result.openAccessShortfall?.notice,
            "Failed to obtain a PDF from the following tried sources: walled.example.org, named by Unpaywall "
                + "(HTTP 403 Forbidden); repo.example.org, named by OpenAlex (HTTP 404 Not Found). "
                + "Whether this document is open access was not established."
        )
    }

    func testTheRequestIsTheContracts() async throws {
        StubURLProtocol.routes["unpaywall"] = (404, Data())
        _ = try await fetch(email: "test@example.org")
        let asked = try XCTUnwrap(StubURLProtocol.requestedURLs.first { $0.contains("api.openalex.org") })
        XCTAssertEqual(
            asked,
            "https://api.openalex.org/works/doi:10.1%2Flocations?select=locations&mailto=test%40example.org"
        )
    }

    func testTheContractsStatuses() async throws {
        for row in try XCTUnwrap(OpenAlexContract.load()["status"] as? [[String: Any]]) {
            StubURLProtocol.reset()
            let status = row["status"] as! Int
            StubURLProtocol.routes["api.openalex.org"] = (
                status, status == 200 ? openAlex([repo]) : Data()
            )
            let fetch = try await makeService(retry: .noRetry).fetchOpenAlexPDFURLs(doi: doi)
            switch row["outcome"] as! String {
            case "served": XCTAssertEqual(fetch, .served([repo]), "\(status)")
            case "absent": XCTAssertEqual(fetch, .absent, "\(status)")
            default: XCTAssertEqual(fetch, .unreachable(.httpStatus(status)), "\(status)")
            }
        }
    }

    func testAnAnswerWeCannotReadIsMalformed() async throws {
        StubURLProtocol.routes["api.openalex.org"] = (200, Data("not json".utf8))
        let fetch = try await makeService(retry: .noRetry).fetchOpenAlexPDFURLs(doi: doi)
        XCTAssertEqual(fetch, .unreachable(.malformedResponse))
    }

    func testNoDOINoOpenAlex() async throws {
        _ = try? await makeService().fetchFullText(pmcId: nil, doi: nil, pmid: "123")
        XCTAssertFalse(StubURLProtocol.requested("api.openalex.org"))
    }
}
```

`makeService(retry:)` builds the service with `openAlexRetry:` set to a no-retry configuration. If `RetryConfiguration` has no `.noRetry`, use `RetryConfiguration(maxAttempts: 1, initialDelay: 0, maxDelay: 0, backoffMultiplier: 1, jitterFactor: 0)`, as `FullTextServicePMCOpenDataTests` does for the bucket; copy its form. A 503 that outlasts its retries arrives as `serverError` and must map to `.unreachable(.httpStatus(503))`.

In `PDFTierFallthroughTests.testExtractionSwitchedOffStillReturnsTheFirstPDFURL`, add at the end:

```swift
        XCTAssertFalse(StubURLProtocol.requested("api.openalex.org"), "a link in hand asks nothing more")
```

Run: `cd Packages/BioMedLit && swift build --build-tests 2>&1 | tail -5`
Expected: FAIL. `type 'FullTextContent' has no member 'openAlex'`.

- [ ] **Step 3: The model cases**

In `FullTextModels.swift`:
- `FullTextSource` gains `case openAlex = "openalex"` after `.unpaywall`, with `displayName` `"OpenAlex"`.
- `FullTextContent` gains:

```swift
    /// A PDF an OpenAlex location names, Unpaywall having named none that
    /// served (#480, stage B).
    case openAlex(pdfURL: URL)
```

  with `source` → `.openAlex` and `pdfURL` → its URL (`case .unpaywall(let url), .openAlex(let url): return url`). Every other `switch` on `FullTextContent` must now compile; give `.openAlex` the same arm as `.unpaywall` everywhere.
- The init assert becomes:

```swift
        assert(
            openAccessShortfall == nil
                || (content.source != .unpaywall && content.source != .openAlex),
            "an open-access copy's own link is never a shortfall's fallback"
        )
```

  Keep its existing message if it has one, adding OpenAlex to it.

In `RetryHelper.swift`, after `pmcOpenData`:

```swift
    /// Configuration for OpenAlex (#480, stage B): four attempts, as Python's.
    public static let openAlex = RetryConfiguration(
        maxAttempts: 4,
        initialDelay: 1.0,
        maxDelay: 30.0,
        backoffMultiplier: 2.0,
        jitterFactor: 0.2
    )
```

- [ ] **Step 4: Pacing per host, and the fetch**

In `FullTextService`, replace `private var nextBucketRequest: Date?` with:

```swift
    /// Hosts this service paces itself on: one slot each (#489 tracks making
    /// it per host across instances, as Python's).
    private enum PacedHost: Hashable {
        case pmcOpenData
        case openAlex

        var minimumInterval: TimeInterval {
            switch self {
            case .pmcOpenData: return BioMedLitConstants.pmcOpenDataMinimumInterval
            case .openAlex: return BioMedLitConstants.openAlexMinimumInterval
            }
        }
    }

    /// When the next request to each paced host may go; reserved before a
    /// request waits, so two fetches interleaving on this actor cannot both
    /// take the same slot.
    private var nextRequest: [PacedHost: Date] = [:]
```

Rename `bucketAttempt(_:)` to `pacedAttempt(_ url: URL, host: PacedHost)`. Its first lines become:

```swift
        let now = Date()
        let slot = max(now, nextRequest[host] ?? now)
        nextRequest[host] = slot.addingTimeInterval(host.minimumInterval)
```

`bucketGET` calls `pacedAttempt(url, host: .pmcOpenData)`. Add `openAlexRetry: RetryConfiguration = .openAlex` to `init`, stored as `private let openAlexRetry`, documented like `pmcOpenDataRetry`. Then add, after the bucket fetch:

```swift
    // MARK: - OpenAlex (#480, stage B)

    /// Ask OpenAlex which PDFs a work's locations name.
    ///
    /// The contact email is the service's `email`, the one CrossRef already
    /// receives; a blank one asks without `mailto`.
    ///
    /// - Parameter doi: The DOI, trimmed and non-empty.
    /// - Returns: Served URLs (possibly none); absent for a 404; or
    ///   unreachable, of its real kind (a body we cannot read is
    ///   `malformedResponse`).
    /// - Throws: `CancellationError` only.
    func fetchOpenAlexPDFURLs(doi: String) async throws -> OpenAlexFetch {
        let contact = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = OpenAlex.workURL(doi: doi, mailto: contact.isEmpty ? nil : contact) else {
            return .unreachable(.requestFailed)
        }
        let answer: (status: Int, body: Data)
        do {
            answer = try await RetryHelper.retry(
                config: openAlexRetry,
                shouldRetry: RetryHelper.retryOnlyTransient
            ) {
                try await self.pacedAttempt(url, host: .openAlex)
            }
        } catch where error.isCancellation {
            throw CancellationError()
        } catch FullTextError.serverError(let status) {
            return .unreachable(.httpStatus(status))
        } catch {
            return .unreachable(SearchTransport.failure(for: error))
        }
        switch answer.status {
        case BioMedLitConstants.httpStatusOK:
            do {
                return .served(try OpenAlex.pdfURLs(fromWork: answer.body))
            } catch {
                return .unreachable(.malformedResponse)
            }
        case BioMedLitConstants.httpStatusNotFound:
            return .absent
        default:
            return .unreachable(.httpStatus(answer.status))
        }
    }
```

Compare these catch arms with `fetchPMCOpenDataXML`'s (L958). Where the bucket maps an error differently, for example `invalidResponse`, follow the bucket's mapping so the two siblings agree.

- [ ] **Step 5: The tier**

In `fetchFullText`, inside `if let cacheKey, !unpaywallDOI.isEmpty { … }` and after Unpaywall's `tryOpenAccessPDFs` call:

```swift
            // OpenAlex, for the PDFs Unpaywall did not name (#480, stage B);
            // never once a copy was served: it cannot raise the odds then
            // (the maintainer's decision, 2026-10-05)
            if openAccessNotSavedFrom == nil {
            switch try await fetchOpenAlexPDFURLs(doi: doi) {
            case .served(let urls):
                if let result = try await tryOpenAccessPDFs(
                    OpenAlex.untried(urls, tried: triedPDFs),
                    refusedAs: .openAlexPDF,
                    content: { .openAlex(pdfURL: $0) },
                    cacheKey: cacheKey,
                    degradation: degradation,
                    holdingAbstract: abstractOnly != nil,
                    articleName: articleName,
                    linkFallback: &pdfLinkFallback,
                    shortfall: &openAccessShortfall,
                    notSavedFrom: &openAccessNotSavedFrom,
                    tried: &triedPDFs
                ) {
                    return result
                }
            case .absent:
                BioMedLitLib.logger?.info("OpenAlex knows no work by DOI \(doi)", category: .fullText)
            case .unreachable(let failure):
                openAccessShortfall = .adding(
                    OpenAccessShortfall(source: .openAlex, failure: failure), to: openAccessShortfall
                )
                BioMedLitLib.logger?.warning(
                    "OpenAlex could not be asked about DOI \(doi) (\(failure.describe())), so any "
                        + "open-access copy it knows of is not assessed",
                    category: .fullText
                )
            }
            }
```

Indent the `switch` inside the new `if`. Update the chain-order doc comment (L185) to read "… → Unpaywall PDFs → OpenAlex PDFs → DOI website".

- [ ] **Step 6: Run the package suite**

Run: `cd Packages/BioMedLit && swift test 2>&1 | tail -20`
Expected: 0 failures. A test with its own `URLProtocol`, such as `FullTextServiceUnpaywallURLTests.RecordingURLProtocol`, may now answer OpenAlex with its catch-all. If its assertion changes, answer `api.openalex.org` with 404 in that protocol, and never relax the assertion.

- [ ] **Step 7: The app's source**

- `FullTextSource.swift` (`AppFullTextSource`):
  - add `case openAlex = "openalex"`
  - `displayName` `"OpenAlex"`
  - `iconName` `"lock.open"`
  - add `.openAlex` to `canDisplayInApp`'s list
- `BioMedLitAdapters.swift`:
  - L477 becomes `case .europePMCPDF(let pdfURL), .unpaywall(let pdfURL), .openAlex(let pdfURL):`
  - `appSource(of:)` gains `case .openAlex: return .openAlex`
- `FullTextSourceBadge.swift`: `case .openAlex: return .green`.
- `MacConstants.swift`: `case .openAlex: return unpaywallTint`.
- `FullTextSourceDisplayTests.swift`: add

```swift
    func testOpenAlexHasItsOwnLabel() {
        XCTAssertEqual(AppFullTextSource(rawValue: "openalex")?.displayName, "OpenAlex")
    }
```

Run, chained in one background job, because SwiftPM can hang behind `syspolicyd`:

```bash
cd ios/MedicalFactChecker && swift test 2>&1 | tail -5 && xcodebuild -scheme MedicalFactChecker -destination 'platform=macOS' build 2>&1 | tail -3 && xcodebuild -scheme MedicalFactChecker -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -3
```

Expected: tests pass, and both builds report `** BUILD SUCCEEDED **`. The iOS badge is behind `#if os(iOS)`, which only the simulator build compiles. Use any installed simulator name (`xcrun simctl list devices available`).

- [ ] **Step 8: Commit**

```bash
git add Packages/BioMedLit ios/MedicalFactChecker/Sources ios/MedicalFactChecker/Tests
git commit -m "feat(swift): ask OpenAlex for the PDFs Unpaywall did not name (#480)

Refs #480.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 13: Kotlin: OpenAlex's helpers, service and contract tests

**Files:**
- Create: `MAIN/data/remote/fulltext/OpenAlex.kt`
- Modify: `MAIN/data/remote/fulltext/PmcOpenData.kt`. Lift `Answer.text()`'s strict decode to a top-level `internal fun ByteArray.strictUtf8(): String?` and use it in both services.
- Modify: `MAIN/util/Constants.kt`. Add an OpenAlex block after the PMC block (~L130), and `FULLTEXT_SOURCE_OPENALEX` with its label beside the other sources (~L349).
- Create: `TEST/data/remote/fulltext/OpenAlexContractTest.kt`, `OpenAlexServiceTest.kt`, `OpenAlexTestDoubles.kt`

**Interfaces:**
- Produces:
  - `object OpenAlex` with:
    - `fun workUrl(doi: String, mailto: String?, baseUrl: String = Constants.OPENALEX_BASE_URL): String`
    - `fun pdfUrls(json: String): List<String>`, which throws `IllegalArgumentException` (and so `SerializationException`)
    - `fun pdfUrls(work: JsonElement): List<String>`
    - `fun untried(urls: List<String>, tried: Collection<String>): List<String>`
  - `sealed interface OpenAlexFetch { Served(pdfUrls: List<String>); data object Absent; Unreachable(failure) }`
  - `@Singleton class OpenAlexService`, with `suspend fun fetchPdfUrls(doi: String): OpenAlexFetch`
  - `internal fun absentOpenAlex(): OpenAlexService`, for tests
- Constants:
  - `OPENALEX_BASE_URL = "https://api.openalex.org"`
  - `OPENALEX_SERVICE_NAME = "OpenAlex"`
  - `OPENALEX_MIN_INTERVAL_MS = 100L`
  - `OPENALEX_MAX_RETRIES = 3`
  - `OPENALEX_INITIAL_BACKOFF_MS`, the same value as the PMC one
  - `OPENALEX_REQUEST_TIMEOUT_SECONDS = 30L`
  - `OPENALEX_RETRYABLE_STATUSES = setOf(429, 500, 502, 503, 504)`
  - `FULLTEXT_SOURCE_OPENALEX = "openalex"`
  - `FULLTEXT_SOURCE_OPENALEX_LABEL = "OpenAlex"`

- [ ] **Step 1: The failing contract test**

Create `OpenAlexContractTest.kt`. Locate the fixture as `PmcOpenDataContractTest` does, by its walk up to `.git`:

```kotlin
class OpenAlexContractTest {
    private val contract: JsonObject by lazy { /* the PmcOpenDataContractTest walk, for openalex_locations.json */ }
    private fun table(name: String) = contract.getValue(name).jsonArray.map { it.jsonObject }
    private fun JsonObject.string(key: String) = (this[key] as? JsonPrimitive)?.takeUnless { it is JsonNull }?.contentOrNull

    @Test
    fun `every contract table is read here`() {
        assertEquals(
            setOf("schema_version", "description", "service_name", "pdf_service_name", "source",
                "base_url", "work_url", "pdf_urls", "status"),
            contract.keys
        )
    }

    @Test
    fun `the names are the contract's`() {
        assertEquals(contract.string("service_name"), OpenAccessSource.OPENALEX.serviceName)
        assertEquals(contract.string("pdf_service_name"), OpenAccessSource.OPENALEX_PDF.serviceName)
        assertEquals(contract.string("base_url"), Constants.OPENALEX_BASE_URL)
        assertEquals(contract.string("source"), Constants.FULLTEXT_SOURCE_OPENALEX)
        assertEquals(Constants.OPENALEX_SERVICE_NAME, OpenAccessSource.OPENALEX.serviceName)
    }

    @Test
    fun `each work_url row`() {
        for (row in table("work_url")) {
            assertEquals(row.string("name"), row.string("url"), OpenAlex.workUrl(row.string("doi")!!, row.string("mailto")))
        }
    }

    @Test
    fun `each pdf_urls row`() {
        for (row in table("pdf_urls")) {
            val name = row.string("name")
            val work = row.getValue("work")
            if ((row["malformed"] as? JsonPrimitive)?.booleanOrNull == true) {
                assertThrows(name, IllegalArgumentException::class.java) { OpenAlex.pdfUrls(work) }
                continue
            }
            val tried = row.getValue("tried").jsonArray.map { it.jsonPrimitive.content }
            assertEquals(name, row.getValue("expected").jsonArray.map { it.jsonPrimitive.content },
                OpenAlex.untried(OpenAlex.pdfUrls(work), tried))
        }
    }
}
```

Copy the `lazy` body from `PmcOpenDataContractTest`, changing only the file name.

Run: `cd android/MedicalFactChecker && ./gradlew testDebugUnitTest --tests '*OpenAlexContractTest*' -q`
Expected: FAIL (compile).

- [ ] **Step 2: The helpers, the fetch and the constants**

Add the constants listed in Interfaces, each with a one-line KDoc (the pacing one: "Ten requests a second, OpenAlex's published limit and Python's POLITE_RATE_CEILINGS entry").

Create `OpenAlex.kt`. It starts with the AGPL header the other files carry, then:

```kotlin
/**
 * OpenAlex's locations as open-access PDF sources (#480, stage B).
 *
 * Pinned with Python's `openalex.py` by
 * `doc/cross_platform/fulltext_parity/openalex_locations.json`. Every
 * `locations[].pdf_url` is a candidate, whatever the location's `is_oa`.
 */
object OpenAlex {
    /** RFC 3986's unreserved characters: all Python's `quote(s, safe="")` leaves bare. */
    private const val UNRESERVED = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    private const val BYTE_MASK = 0xFF
    private const val ASCII_LIMIT = 0x80

    /** [value] escaped as UTF-8 bytes, the unreserved characters left bare; never `+` for a space. */
    private fun escaped(value: String): String = buildString {
        for (byte in value.toByteArray(Charsets.UTF_8)) {
            val unsigned = byte.toInt() and BYTE_MASK
            val char = unsigned.toChar()
            if (unsigned < ASCII_LIMIT && char in UNRESERVED) append(char) else append("%%%02X".format(unsigned))
        }
    }

    /**
     * The address OpenAlex is asked about one DOI at: the DOI one path segment,
     * only `locations` selected, the contact email a query value.
     *
     * @param doi The DOI; surrounding whitespace is not part of it
     * @param mailto The contact email, or null (or empty) to ask without one
     */
    fun workUrl(doi: String, mailto: String?, baseUrl: String = Constants.OPENALEX_BASE_URL): String {
        val query = mailto?.takeIf { it.isNotEmpty() }?.let { "&mailto=${escaped(it)}" }.orEmpty()
        return "$baseUrl/works/doi:${escaped(doi.trim())}?select=locations$query"
    }

    /** Every PDF URL a work's JSON body names; see [pdfUrls]. */
    fun pdfUrls(json: String): List<String> = pdfUrls(Json.parseToJsonElement(json))

    /**
     * Every PDF URL a decoded work's locations name: each `pdf_url` that is a
     * non-blank string, trimmed, kept once, in OpenAlex's order.
     *
     * @throws IllegalArgumentException for a work that is not an object, or
     *   `locations` neither a list nor null: unreadable, never absent
     */
    fun pdfUrls(work: JsonElement): List<String> {
        val obj = work as? JsonObject ?: throw IllegalArgumentException("an OpenAlex work is a JSON object")
        val locations = when (val raw = obj["locations"]) {
            null, JsonNull -> return emptyList()
            is JsonArray -> raw
            else -> throw IllegalArgumentException("an OpenAlex work's locations are a list")
        }
        return locations
            .mapNotNull { (it as? JsonObject)?.get("pdf_url") as? JsonPrimitive }
            .filter { it.isString }
            .map { it.content.trim() }
            .filter { it.isNotEmpty() }
            .distinct()
    }

    /** The URLs not already tried, in their order. */
    fun untried(urls: List<String>, tried: Collection<String>): List<String> = urls.filterNot { it in tried }
}

/** What asking OpenAlex for a work's PDF locations produced. */
sealed interface OpenAlexFetch {
    /** OpenAlex answered with the work; it may name no PDF. */
    data class Served(val pdfUrls: List<String>) : OpenAlexFetch

    /** OpenAlex knows no work by this DOI. */
    data object Absent : OpenAlexFetch

    /** OpenAlex's answer is missing, of its real kind. */
    data class Unreachable(val failure: RequestFailure) : OpenAlexFetch
}
```

`"%%%02X".format(...)` formats with the default locale. Hex digits are the same in every locale, but use `String.format(Locale.ROOT, "%%%02X", unsigned)` to satisfy lint.

- [ ] **Step 3: The service, with its failing tests**

Create `OpenAlexServiceTest.kt`, modelled on `PmcOpenDataServiceTest`: a MockWebServer with a `Dispatcher` over `routes`, 404 by default, started on loopback. Build the service through the internal constructor:

```kotlin
    private fun service(maxRetries: Int = 0, mailto: String? = null) = OpenAlexService(
        PmcOpenDataService.bucketClient(OkHttpClient(), Constants.OPENALEX_REQUEST_TIMEOUT_SECONDS),
        server.url("").toString().trimEnd('/'),
        { mailto },
        RequestPacer(0L),
        maxRetries,
        0L
    )
    private val path = "/works/doi:10.1%2Fx"
```

Tests, each with `runBlocking`:
- `every status row of the fixture gets its outcome`: read the contract's `status` table. 200 serves `{"locations":[{"pdf_url":"https://repo.example.org/a.pdf"}]}`.
- `a 404 with an HTML body is absent`
- `a throttle is asked again` (503 then 200, `maxRetries = 1`; two requests)
- `a 404 is not asked again` (`maxRetries = 1`; one request)
- `an answer we cannot read is malformed`: `not json`; `[]`; locations an object; bytes `0xFF` (not UTF-8)
- `a work with no PDF is served empty`
- `no server is unreachable` (shut the server down first)
- `the request names the DOI as one segment and the contact`: assert `takeRequest().requestUrl!!.encodedPath == "/works/doi:10.1%2Fx"`, with query `select=locations&mailto=researcher%40example.org`, and without `mailto` when the contact is null
- `a blank DOI is never asked` (`requestCount == 0`)
- `every attempt takes a pacer slot`: copy the PMC test's form.

Then create the service, in `OpenAlex.kt`:

```kotlin
/**
 * Asks OpenAlex which PDFs a work's locations name, paced to 10 requests a second.
 *
 * @param httpClient Derived from the shared client with [PmcOpenDataService.bucketClient]:
 *   its own timeouts, no OkHttp replay
 * @param baseUrl OpenAlex's address; tests point it at a local server
 * @property contactEmail The contact sent as `mailto`, read per request; null asks without
 * @property pacer Every attempt, retries included, takes a slot
 * @property maxRetries Further attempts for a transport failure or a status in
 *   [Constants.OPENALEX_RETRYABLE_STATUSES]; tests pass 0
 * @property initialBackoffMs The wait before the first retry, doubling after
 */
@Singleton
class OpenAlexService internal constructor(
    private val httpClient: OkHttpClient,
    private val baseUrl: String,
    private val contactEmail: () -> String?,
    private val pacer: RequestPacer,
    private val maxRetries: Int,
    private val initialBackoffMs: Long
) {
    /**
     * The contact is the NCBI email, the one the transparency analysis sends
     * CrossRef; the placeholder or a blank one asks without `mailto` (#480).
     */
    @Inject
    constructor(httpClient: OkHttpClient, settingsRepository: SettingsRepository) : this(
        PmcOpenDataService.bucketClient(httpClient, Constants.OPENALEX_REQUEST_TIMEOUT_SECONDS),
        Constants.OPENALEX_BASE_URL,
        { UnpaywallContact.usableEmail(settingsRepository.getNcbiEmail()) },
        RequestPacer(Constants.OPENALEX_MIN_INTERVAL_MS),
        Constants.OPENALEX_MAX_RETRIES,
        Constants.OPENALEX_INITIAL_BACKOFF_MS
    )

    /**
     * Ask OpenAlex for the PDFs a work's locations name.
     *
     * @param doi The DOI; a blank one is never asked
     * @return Served URLs (possibly none); absent for a 404; or unreachable, of
     *   its real kind (a body that is not UTF-8 JSON of a work is malformed)
     * @throws kotlinx.coroutines.CancellationException if the caller cancelled
     */
    suspend fun fetchPdfUrls(doi: String): OpenAlexFetch {
        if (doi.isBlank()) return OpenAlexFetch.Absent
        val url = OpenAlex.workUrl(doi, contactEmail(), baseUrl).toHttpUrlOrNull()
            ?: return OpenAlexFetch.Unreachable(RequestFailure(RequestFailureKind.REQUEST_FAILED))
        return try {
            val (code, bytes) = get(url)
            when (code) {
                HTTP_OK -> {
                    val text = bytes.strictUtf8() ?: return malformed()
                    try {
                        OpenAlexFetch.Served(OpenAlex.pdfUrls(text))
                    } catch (e: IllegalArgumentException) {
                        malformed() // SerializationException is one
                    }
                }
                Constants.HTTP_NOT_FOUND -> OpenAlexFetch.Absent
                else -> OpenAlexFetch.Unreachable(RequestFailure.forHttpStatus(code))
            }
        } catch (e: RetryableStatusException) {
            OpenAlexFetch.Unreachable(RequestFailure.forHttpStatus(e.statusCode))
        } catch (e: IOException) {
            OpenAlexFetch.Unreachable(RequestFailure.fromException(e))
        }
    }

    private suspend fun get(url: HttpUrl): Pair<Int, ByteArray> {
        val request = Request.Builder().url(url).header("Accept", "application/json").build()
        return NetworkRetry.withExponentialBackoff(
            maxRetries = maxRetries,
            initialDelayMs = initialBackoffMs,
            shouldRetry = { NetworkRetry.isRetryableException(it) }
        ) {
            pacer.awaitTurn() // every attempt takes its own slot
            withContext(Dispatchers.IO) {
                httpClient.newCall(request).execute().use { response ->
                    if (response.code in Constants.OPENALEX_RETRYABLE_STATUSES) {
                        throw RetryableStatusException(response.code)
                    }
                    response.code to (response.body?.bytes() ?: ByteArray(0))
                }
            }
        }
    }

    private fun malformed() = OpenAlexFetch.Unreachable(RequestFailure(RequestFailureKind.MALFORMED_RESPONSE))

    private companion object {
        const val HTTP_OK = 200
    }
}
```

`PmcOpenDataService.bucketClient` is `internal` in a companion. If the compiler refuses the call from here, move it to a top-level `internal fun derivedClient(shared, timeoutSeconds)` in `PmcOpenData.kt`, used by both services. Check that `SettingsRepository` is injectable without a cycle: it must not depend on `FullTextService`.

Create `OpenAlexTestDoubles.kt`:

```kotlin
/** OpenAlex knowing no work by any DOI: the answer that adds nothing. Relaxed MockK returns null for a sealed suspend result, so it is stubbed. */
internal fun absentOpenAlex(): OpenAlexService = mockk { coEvery { fetchPdfUrls(any()) } returns OpenAlexFetch.Absent }
```

Run: `cd android/MedicalFactChecker && ./gradlew testDebugUnitTest --tests '*OpenAlex*' -q`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add android/MedicalFactChecker/app/src
git commit -m "feat(android): OpenAlex's PDF locations and their service (#480)

Refs #480.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 14: Kotlin: OpenAlex in the chain, asked only when it can help, and the app's source

**Files:**
- Modify: `MAIN/data/remote/fulltext/FullTextService.kt`: the constructor, `PdfNamer.OPENALEX`, a public `openAlexSteps`, and the no-candidate path in `fetchFullText`.
- Modify: `MAIN/data/remote/fulltext/FullTextRecording.kt`: `recordingFullTextFetch` gains the `askOpenAlex` hook, and the walk uses it.
- Modify: the three callers of `recordingFullTextFetch`: `MAIN/ui/factcheck/FactCheckViewModel.kt` (L585–597), `MAIN/ui/report/ReportViewModel.kt` (L433–445) and `MAIN/ui/fulltext/FullTextViewModel.kt` (L247–293).
- Modify: `MAIN/di/NetworkModule.kt` (`provideFullTextService`, L342–350)
- Modify: `MAIN/data/local/entity/DocumentEntity.kt` (`fullTextSourceDisplay`, L306–315), `MAIN/domain/model/FullTextLinkKind.kt` (`forStoredSource`, L65–68), `MAIN/ui/fulltext/components/FullTextSourceBadge.kt` (L45)
- Create: `TEST/data/remote/fulltext/FullTextServiceOpenAlexTest.kt`
- Modify: `TEST/data/remote/fulltext/OpenAccessStepsRecordingTest.kt`, `FullTextRecordingTest.kt`, the ViewModel tests, and every test that constructs `FullTextService`. Find the last with `grep -rln "FullTextService(" android/MedicalFactChecker/app/src/test`; each gains `absentOpenAlex()`.

**Interfaces:**
- Consumes: `OpenAlexService`, `OpenAlex.untried`, `OpenAlexFetch` (Task 13); `OpenAccessStep`, `PdfNamer`, `OpenAccessPdfs(…, openAlexAsked)`, `candidateOrRefused`, `obtainingOpenAccessPdf` (Task 7).
- Produces:
  - `PdfNamer.OPENALEX(Constants.FULLTEXT_SOURCE_OPENALEX, Constants.FULLTEXT_SOURCE_OPENALEX_LABEL, OpenAccessSource.OPENALEX_PDF)`
  - `suspend fun openAlexSteps(doi: String, tried: Collection<String>): List<OpenAccessStep>`, public on `FullTextService`
  - `suspend fun DocumentEntity.recordingFullTextFetch(result: FullTextResult, downloadPdf: suspend (String) -> PdfDownload, askOpenAlex: suspend (doi: String, tried: List<String>) -> List<OpenAccessStep>): RecordedFetch`

**Why a hook.** OpenAlex may be asked only when no Unpaywall PDF was served (maintainer's decision 1). Android learns that only in recording, where it downloads. So:
- **No Unpaywall candidate:** the service asks OpenAlex itself, and returns its steps with `openAlexAsked = true`, or the DOI link.
- **Otherwise:** recording asks OpenAlex through the hook, once every Unpaywall step was walked and none was served.

The hook has no default. A caller that forgot it would silently never ask OpenAlex.

- [ ] **Step 1: The failing tests**

Create `FullTextServiceOpenAlexTest.kt`, modelled on `FullTextServicePmcOpenDataTest`: MockK for Europe PMC (no record), `absentBucket()`, a mocked `unpaywallApi`, and `openAlex: OpenAlexService = mockk()`. Copy `unpaywallNames(urls)` and `unpaywallKnowsNothing()` from that file's way of stubbing `unpaywallApi.getWorkByDoi`.

```kotlin
    @Test
    fun `with Unpaywall's candidates in hand, OpenAlex is not asked yet`() = runTest {
        unpaywallNames(listOf(a))
        assertEquals(
            Result.success(FullTextResult.OpenAccessPdfs(listOf(OpenAccessStep.Candidate(a, PdfNamer.UNPAYWALL)), doi)),
            service.fetchFullText(null, doi, null, "researcher@example.org")
        )
        coVerify(exactly = 0) { openAlex.fetchPdfUrls(any()) }
    }

    @Test
    fun `with no Unpaywall candidate, OpenAlex's are returned, asked`() = runTest {
        unpaywallKnowsNothing()
        coEvery { openAlex.fetchPdfUrls(doi) } returns OpenAlexFetch.Served(listOf(b))
        assertEquals(
            Result.success(FullTextResult.OpenAccessPdfs(listOf(OpenAccessStep.Candidate(b, PdfNamer.OPENALEX)), doi, openAlexAsked = true)),
            service.fetchFullText(null, doi, null, "researcher@example.org")
        )
    }

    @Test
    fun `an unconfigured Unpaywall still asks OpenAlex, its skip first`() = runTest {
        coEvery { openAlex.fetchPdfUrls(doi) } returns OpenAlexFetch.Served(listOf(b))
        assertEquals(
            Result.success(FullTextResult.OpenAccessPdfs(listOf(
                OpenAccessStep.Unsettled(OpenAccessShortfall.UNPAYWALL_NOT_CONFIGURED),
                OpenAccessStep.Candidate(b, PdfNamer.OPENALEX)), doi, openAlexAsked = true)),
            service.fetchFullText(null, doi, null, null)
        )
    }

    @Test
    fun `with no candidate anywhere, the DOI link carries every shortfall`() = runTest {
        unpaywallKnowsNothing()
        val failure = RequestFailure(RequestFailureKind.TIMEOUT)
        coEvery { openAlex.fetchPdfUrls(doi) } returns OpenAlexFetch.Unreachable(failure)
        assertEquals(
            Result.success(FullTextResult.DoiUrl(doiLink(doi), OpenAccessShortfall(OpenAccessSource.OPENALEX, failure))),
            service.fetchFullText(null, doi, null, "researcher@example.org")
        )
    }

    @Test
    fun `OpenAlex knowing no work adds nothing`() = runTest {
        unpaywallKnowsNothing()
        coEvery { openAlex.fetchPdfUrls(doi) } returns OpenAlexFetch.Absent
        assertEquals(Result.success(FullTextResult.DoiUrl(doiLink(doi), null)),
            service.fetchFullText(null, doi, null, "researcher@example.org"))
    }

    @Test
    fun `OpenAlex's steps drop what was tried, and refuse an address that cannot be requested`() = runTest {
        coEvery { openAlex.fetchPdfUrls(doi) } returns OpenAlexFetch.Served(listOf(a, "ftp://x.example.org/c.pdf", b))
        assertEquals(
            listOf(
                OpenAccessStep.Unsettled(OpenAccessShortfall(OpenAccessSource.OPENALEX_PDF,
                    RequestFailure(RequestFailureKind.REQUEST_FAILED), "ftp://x.example.org/c.pdf")),
                OpenAccessStep.Candidate(b, PdfNamer.OPENALEX)
            ),
            service.openAlexSteps(doi, listOf(a))
        )
    }

    @Test
    fun `no DOI, no OpenAlex`() = runTest {
        service.fetchFullText(null, null, "123", null)
        coVerify(exactly = 0) { openAlex.fetchPdfUrls(any()) }
    }

    @Test
    fun `an OpenAlex PDF is recorded as OpenAlex's`() {
        assertEquals("openalex", service.getSourceConstant(FullTextResult.OpenAccessPdf(b, doi, PdfNamer.OPENALEX)))
    }
```

In `OpenAccessStepsRecordingTest.kt`, every existing call gains `askOpenAlex = noOpenAlex`, with `private val noOpenAlex: suspend (String, List<String>) -> List<OpenAccessStep> = { _, _ -> emptyList() }`. Add:

```kotlin
    private val openAlexPdf = "https://oa.example.org/c.pdf"

    @Test
    fun `OpenAlex is asked once every Unpaywall candidate failed, with what was tried`() = runTest {
        var askedWith: List<String>? = null
        val recorded = document().recordingFullTextFetch(
            found(candidate(first)),
            { url -> if (url == first) PdfDownload.Failed(RequestFailure.forHttpStatus(403)) else PdfDownload.Saved("/cache/d.pdf") },
            { _, tried -> askedWith = tried; listOf(OpenAccessStep.Candidate(openAlexPdf, PdfNamer.OPENALEX)) }
        )
        assertEquals(listOf(first), askedWith)
        assertEquals(FullTextResult.OpenAccessPdf(openAlexPdf, doi, PdfNamer.OPENALEX), recorded.result)
        assertEquals("openalex", recorded.document.fullTextSource)
    }

    @Test
    fun `OpenAlex is not asked when an Unpaywall copy was served, saved or not`() = runTest {
        for (download in listOf(PdfDownload.Saved("/cache/d.pdf"), PdfDownload.NotSaved)) {
            var asked = false
            document().recordingFullTextFetch(found(candidate(first)), { download }, { _, _ -> asked = true; emptyList() })
            assertFalse("$download", asked)
        }
    }

    @Test
    fun `OpenAlex already asked by the service is not asked again`() = runTest {
        var asked = false
        document().recordingFullTextFetch(
            FullTextResult.OpenAccessPdfs(listOf(OpenAccessStep.Candidate(openAlexPdf, PdfNamer.OPENALEX)), doi, openAlexAsked = true),
            { PdfDownload.Failed(RequestFailure.forHttpStatus(403)) },
            { _, _ -> asked = true; emptyList() }
        )
        assertFalse(asked)
    }

    @Test
    fun `every refusal is told in chain order, OpenAlex's lookup and copy after Unpaywall's`() = runTest {
        val timeout = OpenAccessShortfall(OpenAccessSource.OPENALEX, RequestFailure(RequestFailureKind.TIMEOUT))
        val recorded = document().recordingFullTextFetch(
            found(candidate(first)),
            { PdfDownload.Failed(RequestFailure.forHttpStatus(if (it == first) 403 else 404)) },
            { _, _ -> listOf(OpenAccessStep.Unsettled(timeout), OpenAccessStep.Candidate(openAlexPdf, PdfNamer.OPENALEX)) }
        )
        assertEquals(
            refused(first, 403) + timeout +
                OpenAccessShortfall(OpenAccessSource.OPENALEX_PDF, RequestFailure.forHttpStatus(404), openAlexPdf),
            (recorded.result as FullTextResult.DoiUrl).openAccessShortfall
        )
    }
```

Run: `cd android/MedicalFactChecker && ./gradlew testDebugUnitTest --tests '*OpenAlex*' --tests '*OpenAccessSteps*' -q`
Expected: FAIL (compile). `PdfNamer.OPENALEX`, `openAlexSteps` and the hook are missing.

- [ ] **Step 2: The service**

- Add `OPENALEX(Constants.FULLTEXT_SOURCE_OPENALEX, Constants.FULLTEXT_SOURCE_OPENALEX_LABEL, OpenAccessSource.OPENALEX_PDF)` to `PdfNamer`.
- Add `private val openAlex: OpenAlexService`, last, to `FullTextService`'s constructor, and pass it in `NetworkModule.provideFullTextService`.

```kotlin
    /**
     * OpenAlex's steps, for the PDFs Unpaywall did not name (#480, stage B):
     * its untried PDFs as candidates (an address that cannot be requested
     * refused at once), or OpenAlex itself unsettled. Called by the chain when
     * Unpaywall named no candidate, and by recording once every Unpaywall
     * candidate failed; never otherwise, as it could not raise the odds.
     *
     * @param doi The DOI
     * @param tried Addresses already named, which are dropped
     */
    suspend fun openAlexSteps(doi: String, tried: Collection<String>): List<OpenAccessStep> =
        when (val fetch = openAlex.fetchPdfUrls(doi)) {
            is OpenAlexFetch.Served -> OpenAlex.untried(fetch.pdfUrls, tried).map { candidateOrRefused(it, PdfNamer.OPENALEX) }
            OpenAlexFetch.Absent -> emptyList()
            is OpenAlexFetch.Unreachable -> {
                Log.w(TAG, "OpenAlex could not be asked about $doi (${fetch.failure.describe()})")
                listOf(OpenAccessStep.Unsettled(OpenAccessShortfall(OpenAccessSource.OPENALEX, fetch.failure)))
            }
        }
```

In `fetchFullText`, the open-access block becomes:

```kotlin
        if (!doi.isNullOrEmpty()) {
            val unpaywall = unpaywallSteps(doi, email, pmid)
            if (unpaywall.any { it is OpenAccessStep.Candidate }) {
                // OpenAlex waits: recording asks it only if none of these is served
                return@withContext Result.success(FullTextResult.OpenAccessPdfs(unpaywall, doi))
            }
            val steps = unpaywall + openAlexSteps(doi, emptyList())
            if (steps.any { it is OpenAccessStep.Candidate }) {
                return@withContext Result.success(FullTextResult.OpenAccessPdfs(steps, doi, openAlexAsked = true))
            }
            openAccessShortfall = steps.filterIsInstance<OpenAccessStep.Unsettled>()
                .fold(null as OpenAccessShortfall?) { held, step -> OpenAccessShortfall.adding(step.shortfall, held) }
        }
```

- [ ] **Step 3: Recording asks through the hook**

`recordingFullTextFetch` gains the third parameter `askOpenAlex`, documented as "Asks OpenAlex for its steps, given the DOI and the addresses tried; called at most once, and only when no Unpaywall copy was served (#480)", and passes it to `obtainingOpenAccessPdf`. Restructure the walk so the same loop runs over Unpaywall's steps and then, when needed, OpenAlex's:

```kotlin
private suspend fun DocumentEntity.obtainingOpenAccessPdf(
    result: FullTextResult.OpenAccessPdfs,
    downloadPdf: suspend (String) -> PdfDownload,
    askOpenAlex: suspend (String, List<String>) -> List<OpenAccessStep>
): RecordedFetch {
    var shortfall: OpenAccessShortfall? = null
    val tried = mutableListOf<String>()

    /** Walk [steps]; a recorded fetch when a copy was served, else null. */
    suspend fun walk(steps: List<OpenAccessStep>): RecordedFetch? {
        for (step in steps) {
            when (step) {
                is OpenAccessStep.Unsettled -> shortfall = OpenAccessShortfall.adding(step.shortfall, shortfall)
                is OpenAccessStep.Candidate -> {
                    tried += step.pdfUrl
                    val found = FullTextResult.OpenAccessPdf(step.pdfUrl, result.doi, step.namedBy)
                    when (val download = downloadPdf(step.pdfUrl)) {
                        is PdfDownload.Saved -> return RecordedFetch(recording(found, download.path), found)
                        PdfDownload.NotSaved -> found.copy(notSaved = true).let { linked ->
                            return RecordedFetch(recording(linked, pdfPath = null), linked)
                        }
                        is PdfDownload.Failed -> shortfall = OpenAccessShortfall.adding(
                            OpenAccessShortfall(step.namedBy.refusedAs, download.failure, step.pdfUrl), shortfall
                        )
                    }
                }
            }
        }
        return null
    }

    walk(result.steps)?.let { return it }
    if (!result.openAlexAsked) {
        walk(askOpenAlex(result.doi, tried.toList()))?.let { return it }
    }
    val refused = FullTextResult.DoiUrl(doiLink(result.doi), shortfall)
    return RecordedFetch(recording(refused, pdfPath = null), refused)
}
```

Each ViewModel passes `askOpenAlex = { doi, tried -> fullTextService.openAlexSteps(doi, tried) }` beside its `downloadPdf` lambda. In `FullTextRecordingTest` and the ViewModel tests, every call gains `askOpenAlex`. A MockK `fullTextService` stub needs `coEvery { fullTextService.openAlexSteps(any(), any()) } returns emptyList()` where the walk can reach it.

- [ ] **Step 4: Display**

- `DocumentEntity.fullTextSourceDisplay`: add `Constants.FULLTEXT_SOURCE_OPENALEX -> Constants.FULLTEXT_SOURCE_OPENALEX_LABEL`.
- `FullTextLinkKind.forStoredSource`: add `Constants.FULLTEXT_SOURCE_OPENALEX` to the `UNDOWNLOADED_PDF` arm.
- `FullTextSourceBadge`: give the OpenAlex label Unpaywall's colour.
- Add one test each where `forStoredSource` and `fullTextSourceDisplay` are tested (`DocumentEntityLinkOnlyTest` or its neighbours).

- [ ] **Step 5: Every constructor gets the double; run the suite and build**

Add `absentOpenAlex()` to each `FullTextService(...)` construction in the tests.

Run: `cd android/MedicalFactChecker && ./gradlew testDebugUnitTest -q 2>&1 | tail -20 && ./gradlew assembleDebug -q 2>&1 | tail -5`
Expected: 0 failures, apart from #490's flake (re-run it alone), and the APK builds. Hilt errors appear only at `assembleDebug`.

- [ ] **Step 6: Commit**

```bash
git add android/MedicalFactChecker/app/src
git commit -m "feat(android): ask OpenAlex only when no Unpaywall copy was served (#480)

The service asks it when Unpaywall named no candidate; otherwise recording
asks it through a hook once every Unpaywall candidate failed. Every refusal
is told in chain order.

Refs #480.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 15: The contract text, acceptance, verification, HANDOVER, PR

**Files:**
- Modify: `doc/cross_platform/fulltext_retrieval.md`
- Modify: `doc/cross_platform/polite_request_pacing.md` (the Swift and Android status rows, L18–19)
- Modify: `docs/superpowers/specs/2026-10-04-fulltext-machine-channels-design.md` (an "As built (stage B)" paragraph under "Stage B")
- Modify: `HANDOVER.md`

- [ ] **Step 1: The contract text**

In `fulltext_retrieval.md`:
- **Overview**, item 3: "**Europe PMC's PDF render, then every Unpaywall PDF, then OpenAlex's** - Open access PDFs".
- **Retrieval Priority** table: add `| OpenAlex | PDF URLs | Good (requires parsing) | locations Unpaywall does not list, by DOI |` after Unpaywall.
- Under "#### An unsettled open-access copy (#466)":
  - The first sentence's list gains "OpenAlex, or the PDF OpenAlex named (#480)".
  - Replace "Python tries every Unpaywall location, in its own priority order; it keeps one failure, that of the PDF earliest in Unpaywall's order (the best location's, the one PDF the apps try), and records it only when no source served the PDF." with:

    > **Every platform tries every PDF Unpaywall names; then, only if none was served, OpenAlex's** (#480, stage B; `unpaywall_pdf_urls` and `openalex_locations.json`). The apps try them in Unpaywall's order; Python by its own priority. **The first copy served ends the walk.** Saved, it is read. Not saved, its link is kept (apps) with a caching note, and nothing further is asked. **When none is obtained, every source tried is told** (see "Tried sources (#480)").

  - Replace the Android sentence ("Android records the DOI link (`FullTextResult.UnpaywallPdf.refused`, applied where the download happens, `recordingFullTextFetch`)") with:

    > Android's service returns the steps in chain order (`FullTextResult.OpenAccessPdfs`), and `recordingFullTextFetch` walks them, asking OpenAlex through its `askOpenAlex` hook only once no Unpaywall copy was served. It resolves to the PDF obtained or linked (`OpenAccessPdf`), or to the DOI link carrying every shortfall met.

  - Add, after that paragraph:

````markdown
#### Tried sources (#480)

The maintainer's decisions of 2026-10-05. Pinned by
`fulltext_parity/open_access_statement.json`, read by all three platforms.

- **With a tried PDF, every source tried is listed:**
  `"Failed to obtain a PDF from the following tried sources: "`, then the
  entries joined by `"; "`, then `". "`, then the ending.
  - A PDF entry reads `{host}, named by {Unpaywall|OpenAlex} ({reason})`.
    The host is the address's host, lower-cased, else the address trimmed.
  - A lookup entry reads `{name} ({reason})`, once per service, with the
    reason Python's `_unsettled` picks.
  - Entries come in chain order: other sources first, then `unpaywall`,
    `unpaywall_landing_page`, `unpaywall_pdf`, `openalex`, `openalex_pdf`
    (stable).
  - The ending is "A freely available copy may exist. Whether this document
    is open access was not established." if any entry could not be asked,
    else "Whether this document is open access was not established." The
    configuration nudge follows.
- **Without a tried PDF, today's grouped sentence is kept**
  (`unestablished_access_clause`; one lookup reads exactly as before).
- **A PDF served but not saved is a caching note, never a shortfall:**
  "A PDF of this article was found at {host} but could not be saved on this
  device, so {only its link is kept | it could not be read}. Check the free
  storage space and try again."
  - Python records it as a `NOT_SAVED` skip, which keeps the discovery from
    concluding there is no full text.
  - The apps store it as `Document.fullTextPDFNotSavedFrom` and
    `documents.full_text_pdf_not_saved_from` (Room 9). It is written and
    cleared by every fetch, as the shortfall is.
````

- In "Stored with the full text":
  - The sentence listing `source` values becomes "`source` is `unpaywall`, `unpaywall_landing_page`, `unpaywall_pdf`, `openalex` or `openalex_pdf`".
  - Add: "A single entry without an address is stored in this form (schema 1). Anything else is `{"schema_version": 2, "entries": [{"source", "address"?, "failure" | "skipped"}, …]}`. An entry that will not read becomes `{its source or unpaywall, request_failed}`; a missing or empty list, or any other schema, reads as `[{unpaywall, request_failed}]`."
- Add a new section before `## DOI Resolution`:

````markdown
## OpenAlex's Locations (#480)

OpenAlex lists the places a work is hosted, some with a PDF URL Unpaywall
does not name (6 of 290 failed Unpaywall PDFs in the #480 spike). It is asked
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

It is asked only when no Unpaywall PDF was served: it could not raise the
odds otherwise (the maintainer's decision, 2026-10-05). Candidates already in
Unpaywall's list are dropped. Each is tried as an Unpaywall PDF is: `%PDF`,
`.part`, and refused, never offered as a link, under **OpenAlex's copy**
(`openalex_pdf`), with its address. An unreachable OpenAlex is recorded under
**OpenAlex** (`openalex`). An absence or a work naming no new PDF adds nothing.

The contact email is the one each platform already sends OpenAlex and
CrossRef for the transparency analysis (Python: the PubMed email; iOS/macOS:
the NCBI email or the app's own address; Android: the NCBI email), the
application placeholder excluded, so no new party receives the user's address.

- **Python** asks in `PDFDiscoverer` (`_discover_openalex`), lazily.
- **Swift** asks in `FullTextService` after the Unpaywall tier.
- **Android** asks in `FullTextService.fetchFullText` when Unpaywall named no
  candidate, and otherwise in recording, through its `askOpenAlex` hook, once
  every Unpaywall candidate failed.
````

In `polite_request_pacing.md`:
- The Swift row adds ", and to OpenAlex, paced at 10 per second per service instance (#480, #489)".
- The Android row adds "`fulltext/OpenAlex.kt` (OpenAlex, #480) paces every attempt at 10 per second app-wide".

In the spec, under "## Stage B", add:

```markdown
**As built.** The binding rules are in `doc/cross_platform/fulltext_retrieval.md`
("OpenAlex's Locations") and `fulltext_parity/openalex_locations.json`; where
this section differs, they win.
- Every `pdf_url` counts, whatever its `is_oa`.
- OpenAlex is asked only once no Unpaywall PDF was served (Android through a
  hook in its download step).
- When no PDF is obtained, every source tried is told, each PDF by host and by
  who named it.
- The first copy served ends the walk. One not saved is a caching note of its
  own, stored on the document in the apps, never a shortfall.
- `select=locations` is asked for.
```

- [ ] **Step 2: Acceptance, live (manual)**

Write a throwaway script in the session scratchpad (not committed). For each spike row whose `openalex.outcome == "pdf"` (six DOIs; four in stratum `epmc-not-oa`), it runs:

```python
PDFDiscoverer(
    unpaywall_email=config.discovery.unpaywall_email or config.pubmed.email,
    openalex_email=config.pubmed.email,
    use_browser_fallback=False,
).discover_and_download(scratch / f"{i}.pdf", doi=row["doi"])
```

It reads the user's own `LiteConfig`, the addresses the app already sends. It records `result.success` and `result.source.source_type`. Run it once, paced. The spike's bar is **4 of the 4** not-open-access rows obtained. It also re-runs the 15 rows with `unpaywall.outcome == "pdf"`; the desktop already tries every location, so those check that nothing regressed. Report the counts in the PR, with any row that no longer serves and why: copies move, so a lower count needs the row's own answer, not a shrug.

- [ ] **Step 3: Full verification**

Run the whole set, chaining the Swift runs in one background job:

```bash
pytest tests/ -q
HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 NO_PROXY=127.0.0.1,localhost pytest tests/ -q   # no test reaches the network
python .github/scripts/lint_delta.py --base-ref origin/master
cd Packages/BioMedLit && swift test
cd ios/MedicalFactChecker && swift test && xcodebuild -scheme MedicalFactChecker -destination 'platform=macOS' build
cd android/MedicalFactChecker && ./gradlew test
```

Expected: 0 failures everywhere, except #490's flake, named if it appears. No new lint findings. Both runs of the Python suite pass the same set.

**Mutation check.** Drive it from Python with a verified restore, in a worktree, with `PYTHONDONTWRITEBYTECODE=1` and `PYTHONPATH` pinned (see the mutation memories). Assert a passing baseline first. Each of these must be CAUGHT:
- `_discover_openalex` returning `[], LookupRecord()` on a failure (dropping the unreachable record);
- `untried_pdf_urls` returning `list(pdf_urls)` (no dedupe);
- `openalex_pdf_urls` returning `[]` for `locations` not a list (malformed read as absent);
- `fetch_pdf_urls` returning `absent()` for any non-200 (unreachable read as absent);
- the `copy_rank` offset set to 0 for OpenAlex sources (OpenAlex's refusal told before Unpaywall's);
- `tried_sources_statement` returning `""` (the grouped sentence told for tried PDFs);
- `_chain_rank` returning 0 for every service (entries out of chain order);
- `address_host` returning the address unchanged (no host);
- the `not_saved` early return removed (a further copy asked after one was served; the note lost);
- `_without_not_saved` returning the record unchanged (the caching note told as a shortfall);
- `quote(..., safe="/")` in `openalex_work_url`;
- the splice condition `not pending[0].is_open_access` dropped (OpenAlex asked only at the very end, after the publisher).

- [ ] **Step 4: HANDOVER, push, PR**

Update `HANDOVER.md`. In "In flight", stage B becomes its PR, with the rules that now bind (tried-sources statement, caching note, OpenAlex only when it can help, the stored v2 list and Room 9), and **Next: stage C**. Write follow-ups found along the way as issues, never as TODOs. Prune to stay under 500 lines.

```bash
git add doc docs HANDOVER.md
git commit -m "docs(fulltext): OpenAlex and every Unpaywall location in the contract (#480)

Refs #480.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push -u origin feat/machine-channels-stage-b-480
gh pr create --base master --title "feat(all): every Unpaywall PDF in the apps, then OpenAlex's (#480, stage B)" --body-file <scratchpad>/pr-body.md
```

The PR body starts "Refs #480. Stage B of the machine-channels design; it does not close #480: stage C follows." It lists:
- what each platform does;
- the rules;
- the maintainer's decisions of 2026-10-05 it implements;
- the verification (counts per suite, the dead-proxy run, the mutation results, live acceptance).

It ends with the Claude Code line. **No closing keyword anywhere.** After the PR is opened, confirm #480 is still open.
