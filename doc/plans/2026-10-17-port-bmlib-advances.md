# Port bmlib's advances into bmlibrarian_lite — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close every gap where bmlib (`~/src/bmlib`, commit `f4b7c52`, 0.10.0 + `[Unreleased]`) is ahead of bmlibrarian_lite's desktop Python, Swift (`Packages/BioMedLit`, iOS/macOS app) and Android ports, and put a ledger in place so the two never drift unnoticed again.

**Architecture:** Phase 0 builds the sync ledger and its CI check. Phase 1 fixes the defects that give wrong results today (full TDD tasks below). Phase 2 is a gate: a spike that decides whether Swift and Android take bmlib's Rust crate through UniFFI instead of hand-porting. Phases 3–7 are work packages; each is expanded into its own plan with this document's conventions when it is picked up, and Phase 4 (JATS on mobile) is shaped by the Phase 2 decision. Every rule shared by more than one platform gets a contract JSON under `doc/cross_platform/` that all three test suites read.

**Tech Stack:** Python 3.12 / pytest / ElementTree; Swift 6 / SwiftPM / XCTest; Kotlin / JUnit / kxml2 (JVM tests); Rust + UniFFI (Phase 2 only).

**Spec:** The 2026-10-17 audit of bmlib `[Unreleased]` against all three ports, recorded as the gap register in [Appendix A](#appendix-a-gap-register). The bmlib side of each rule is its `CHANGELOG.md` entry, cited by bmlib issue number (`bmlib#N`). The earlier gap list is `doc/cross_platform/ios_bmlib_alignment.md` (dated 2026-08-20). The opposite direction is `~/src/bmlib/docs/superpowers/plans/2026-10-17-adopt-bmlibrarian-lite-advances.md`.

## Global Constraints

- Issue numbers in bmlib and here are different trackers. Write bmlib's as `bmlib#N` in code comments, commits and docs.
- **Never put a closing keyword before a deferred issue number.** Write "Deferred: #N", never "not fixed: #N" (HANDOVER, Verify).
- Within this repo, Python is canonical. A rule that lives on more than one platform has one contract JSON under `doc/cross_platform/`, and all three suites assert against it.
- Code style: Google-style docstrings, mandatory type hints, no magic numbers (use `constants.py`, `Constants.kt`, `BioMedLitConstants`), pure functions in focused modules.
- **Unreachable is not absent, and unparsed is not absent either.** A remote answer we cannot use is `RecordFetch.unreachable(...)` or a typed failure, never `absent()`. Keep a control test for every such branch.
- A caller's bad input is the caller's (refuse it with a log line naming it). A remote's bad value costs the step, never the analysis.
- Bump `TRANSPARENCY_ANALYZER_VERSION` (and the Swift and Kotlin analyser versions) whenever a stored transparency score or indicator can move.
- Bump `JATS_MARKDOWN_CONVERTER_VERSION` whenever the desktop rendering changes. Touching a JATS parser means regenerating the corpus digests with `UPDATE_JATS_DIGESTS=1` and reading `git diff doc/cross_platform/jats_corpus/` line by line.
- Mutation-test new rules with `cp` backups, never `git checkout`, and with `PYTHONDONTWRITEBYTECODE=1`.
- Gates: `pytest tests/`; `swift test` in `Packages/BioMedLit` and in `ios/MedicalFactChecker`; `./gradlew test` in `android/MedicalFactChecker`; `python .github/scripts/lint_delta.py --base-ref origin/master` must report no new findings.
- One branch and one PR per task, cut from `master`. Never stack.

## Review Focus

1. **A PubMed record whose own `ArticleIdList` has no DOI, while its `ReferenceList` does:** the DOI is `None`, never a reference's. Pinned in Task 1.
2. **A PMID that arrives padded, as an integer, as `"PMC7745181"`, or as `"1 OR 2"` through the MCP tool:** padded is canonicalised; the PMC ID is used as the PMC ID; the rest is refused with a WARNING and no request is made. Pinned in Task 2.
3. **A model reply carrying the bare JSON tokens `NaN` or `Infinity`** (Python's `json.loads` accepts both): read as a refused value, never as confidence 1.0 or an `OverflowError`. Pinned in Task 4.
4. **Android: a well-formed JSON reply whose `score` is `"high"`, `true`, `7` or `2.5`:** a parse failure that is retried, and the document is never treated as relevant. Pinned in Task 3.
5. **A Europe PMC PDF entry carrying `availabilityCode: "OA"` and no `availability` label:** accepted, because the code decides. Pinned in Task 5.

---

## Phase 0 — The sync ledger

### Task 0: A ledger of every bmlib change, checked in CI

**Files:**
- Create: `doc/cross_platform/bmlib_sync/ledger.json`
- Create: `doc/cross_platform/bmlib_sync/README.md`
- Create: `scripts/check_bmlib_ledger.py`
- Create: `tests/test_bmlib_ledger.py`
- Modify: `.github/workflows/` (the Python CI workflow: one step)

**Interfaces:**
- Produces: `ledger.json` with schema
  `{"schema": 1, "bmlib_commit": "<sha>", "from_bmlib": [Entry], "to_bmlib": [Entry]}`, where an `Entry` is
  `{"id": "bmlib#474" | "lite:<contract or feature>", "title": str, "python": Status, "swift": Status, "android": Status, "bmlib": Status, "issue": "#N" | null, "note": str}`.
  `Status` is one of `"owed" | "ported" | "equivalent" | "n/a" | "declined"`. In `from_bmlib` entries the `bmlib` key is omitted; in `to_bmlib` entries only `bmlib` is required.
- Produces: `scripts/check_bmlib_ledger.py --bmlib <path>` exits 1 when a bmlib issue number referenced in the bold title line of any `CHANGELOG.md` entry newer than `## [0.10.0]` has no `from_bmlib` entry. It prints the missing numbers, then counts of `owed` per platform.
- Produces: `missing_entries(changelog_text: str, ledger: dict) -> list[str]` and `changelog_issue_ids(changelog_text: str) -> set[str]` in the script, importable for tests.

- [ ] **Step 1: Write the failing tests** in `tests/test_bmlib_ledger.py`:

```python
CHANGELOG = """## [Unreleased]
### Fixed
- **The PubMed record read is the one asked about** (`transparency`, #474).
  Body mentioning #999 in prose only.
## [0.10.0] — 2026-08-15
- **Old entry** (#79).
"""

def test_ids_come_from_entry_titles_newer_than_0_10_0() -> None:
    assert changelog_issue_ids(CHANGELOG) == {"bmlib#474"}

def test_an_unledgered_id_is_missing() -> None:
    assert missing_entries(CHANGELOG, {"from_bmlib": []}) == ["bmlib#474"]

def test_a_ledgered_id_is_not_missing() -> None:
    ledger = {"from_bmlib": [{"id": "bmlib#474"}]}
    assert missing_entries(CHANGELOG, ledger) == []

def test_the_committed_ledger_is_well_formed() -> None:
    ledger = json.loads(LEDGER_PATH.read_text())
    statuses = {"owed", "ported", "equivalent", "n/a", "declined"}
    for e in ledger["from_bmlib"]:
        assert {e["python"], e["swift"], e["android"]} <= statuses
    for e in ledger["to_bmlib"]:
        assert e["bmlib"] in statuses
    for e in ledger["from_bmlib"] + ledger["to_bmlib"]:
        assert e["id"] and e["title"]
        assert "declined" not in e.values() or e["note"]
```

A title line is a line beginning `- **`, together with its continuation lines up to the first line that does not end inside the parenthesised group. Take the issue numbers from that group only.

- [ ] **Step 2:** Run `pytest tests/test_bmlib_ledger.py -v`. Expected: FAIL (module not found).
- [ ] **Step 3:** Implement the script. Seed `ledger.json` from [Appendix A](#appendix-a-gap-register) (`from_bmlib`) and from the bmlib plan's Appendix (`to_bmlib`), with `bmlib_commit: "f4b7c52"`. The README says: bumping `bmlib_commit` is how a sync starts; every new id must be triaged before CI passes; `declined` needs a `note` giving the reason.
- [ ] **Step 4:** Run `pytest tests/test_bmlib_ledger.py -v` and `python scripts/check_bmlib_ledger.py --bmlib ~/src/bmlib`. Expected: PASS, then exit 0.
- [ ] **Step 5:** Add a CI step that checks out `hherb/bmlib` at `bmlib_commit` and runs the script. If the repository is private, the step needs a read token, and the README must say which secret holds it.
- [ ] **Step 6:** Commit: `feat(sync): a ledger of bmlib's changes and their port status, checked in CI`.

---

## Phase 1 — Defects that give wrong results today

### Task 1: A PubMed record's own identifiers, from the record asked about

bmlib#474, plus a defect bmlib never had. `study_transparency_analyzer.py:1527` takes `.//ArticleId` with the last match winning, which walks into `PubmedData/ReferenceList`. Live: PMID 33301246 yields a cited paper's PMC7289658 and DOI. `pubmed/search_client.py:~894` and `:~900` take the first `.//ArticleId` (wrong whenever the record's own list lacks that type). `_parse_pubmed_xml` reads the first `PubmedArticle` whatever PMID it names. Android's `PubMedService.kt:751` has no `<Reference>` guard (lite #404).

**Files:**
- Create: `src/bmlibrarian_lite/pubmed/record_ids.py`
- Modify: `src/bmlibrarian_lite/study_transparency_analyzer/study_transparency_analyzer.py:1419-1540`
- Modify: `src/bmlibrarian_lite/pubmed/search_client.py:~890-905`
- Modify: `android/MedicalFactChecker/app/src/main/java/com/bmlibrarian/factchecker/data/remote/pubmed/PubMedService.kt:~650-790`
- Test: `tests/test_pubmed_record_ids.py`, `tests/test_pubmed_inline_markup.py` (existing callers), Android `.../data/remote/pubmed/PubMedArticleIdTest.kt`

**Interfaces:**
- Produces: `own_article_ids(pubmed_article: ET.Element) -> dict[str, str]`. It reads only `PubmedData/ArticleIdList/ArticleId` (a fixed path, never `.//`). Keys are the lower-cased `IdType`; the first non-blank, stripped value per type wins.
- Produces: `record_for_pmid(root: ET.Element, pmid: str) -> ET.Element | None`, the `PubmedArticle` whose **direct-child** `MedlineCitation/PMID` text, stripped, equals `pmid`.
- Produces: `served_pmids(root: ET.Element) -> list[str]`, used for the WARNING.
- Changes: `PubMedClient._parse_pubmed_xml(self, xml_text: str, pmid: str) -> RecordFetch`. `fetch_article` passes its `pmid`.

- [ ] **Step 1: Write the failing tests** in `tests/test_pubmed_record_ids.py`. Build the fixture from a trimmed real efetch body (PMID 33301246: its own ids `PMC7745181` / `10.1056/NEJMoa2034577`, plus one `<Reference>` carrying `PMC7289658` / `10.1056/NEJMoa2027906`).

```python
def test_a_reference_id_is_never_the_articles() -> None:
    assert own_article_ids(record) == {"pubmed": "33301246", "pmc": "PMC7745181", "doi": "10.1056/NEJMoa2034577"}

def test_a_doi_only_a_reference_carries_is_no_doi() -> None:
    assert "doi" not in own_article_ids(record_without_own_doi)

def test_the_transparency_record_keeps_its_own_pmcid_and_doi() -> None:
    fetch = PubMedClient("t@example.com")._parse_pubmed_xml(BODY, "33301246")
    assert fetch.record["pmcid"] == "PMC7745181"
    assert fetch.record["doi"] == "10.1056/NEJMoa2034577"

def test_the_matching_record_is_read_not_the_first() -> None:
    fetch = PubMedClient("t@example.com")._parse_pubmed_xml(TWO_RECORDS_OTHER_FIRST, "33301246")
    assert fetch.record["pmcid"] == "PMC7745181"

def test_a_record_for_another_pmid_is_not_this_paper(caplog) -> None:
    fetch = PubMedClient("t@example.com")._parse_pubmed_xml(BODY, "1")
    assert fetch.failure.kind is RequestFailureKind.MALFORMED_RESPONSE   # never absent()
    assert "33301246" in caplog.text                                     # WARNING names what was served

def test_comments_corrections_pmids_do_not_match() -> None:
    # record 1 is PMID 2 and names PMID 33301246 only inside CommentsCorrections
    root = ET.fromstring(OTHER_RECORD_CITING_33301246)
    assert record_for_pmid(root, "33301246") is None

def test_no_pubmed_article_is_still_absent() -> None:   # control
    assert PubMedClient("t@example.com")._parse_pubmed_xml(EMPTY_SET, "1").is_absent
```

Use the existing accessor names on `RecordFetch` in `data_models.py:224`. Add one test for `search_client` that parses the same body and asserts the article's own `doi` and `pmc_id`.

- [ ] **Step 2:** Run `pytest tests/test_pubmed_record_ids.py -v`. Expected: FAIL.
- [ ] **Step 3:** Implement `record_ids.py`. Use it in `_parse_pubmed_xml`: select the record with `record_for_pmid`; when PubMed served records and none matches, return `RecordFetch.unreachable(RequestFailure(RequestFailureKind.MALFORMED_RESPONSE))` with a WARNING naming `served_pmids`. Replace both `.//ArticleId` loops in `search_client.py` with `own_article_ids`.
- [ ] **Step 4:** Run `pytest tests/ -q -k "pubmed or transparency or absence"`. Expected: PASS. Bump `TRANSPARENCY_ANALYZER_VERSION`, because stored COI and data ratings can move.
- [ ] **Step 5: Android.** Write `PubMedArticleIdTest.kt`, asserting that the same body (as a test resource) yields the article's own DOI and PMC ID. Run `./gradlew test --tests '*PubMedArticleIdTest*'` and expect FAIL. Then track `ReferenceList` depth in the pull parser and ignore `ArticleId` while the depth is above 0; the first value per type wins. Expect PASS.
- [ ] **Step 6:** Mutation-sweep `record_ids.py` (the fixed path, direct-child PMID, strip, first-wins). Every mutant must be killed.
- [ ] **Step 7:** Commit: `fix(pubmed): read a record's own ids, from the record asked about (bmlib#474)`. Tag lite #404 for the Android half.

### Task 2: A PMID is canonical ASCII digits, or it is not sent

bmlib#470, bmlib#472, bmlib#478. Python passes PMIDs unchecked into `europepmc.py:693` (`ext_id:{pmid} src:med`), the ID Converter URL (`pdf_discovery.py:1418`), efetch (`fetch_article`), and through the MCP tool (`mcp_server.py:639`). Swift validates only `.pubmed` kinds (`ArticleIdentifierKind.swift:206`). Android: `FullTextService.kt:~1005`.

**Files:**
- Create: `doc/cross_platform/fulltext_parity/pmid_canonical.json`
- Create: `src/bmlibrarian_lite/identifiers.py`
- Modify: `src/bmlibrarian_lite/mcp_server.py:~639`, `src/bmlibrarian_lite/fulltext_discovery.py:345` (`discover_fulltext` entry), `src/bmlibrarian_lite/study_transparency_analyzer/study_transparency_analyzer.py:2868` (`analyze` entry), `src/bmlibrarian_lite/europepmc.py:~693`, `src/bmlibrarian_lite/pdf_discovery.py:~1418`; change `\d` to `[0-9]` at `pdf_discovery.py:~1812,~1817`
- Modify: `Packages/BioMedLit/Sources/BioMedLit/Services/ArticleIdentifierKind.swift`; `isNumber` to ASCII at `JATSXMLParser.swift:~2538,~2628`
- Modify: `android/.../data/remote/fulltext/FullTextService.kt:~1005`
- Test: `tests/test_identifiers.py`, `Packages/BioMedLit/Tests/BioMedLitTests/PMIDCanonicalTests.swift`, `android/.../data/remote/fulltext/PmidCanonicalTest.kt`

**Interfaces:**
- Produces: the contract `pmid_canonical.json`: `{"schema": 1, "source": "bmlib#470/bmlib#472/bmlib#478 at f4b7c52", "cases": [{"input": str, "pmid": str|null, "pmc_id": str|null, "refused": bool}]}`. It must contain at least these cases:
  - `"33301246"`: kept as is.
  - `" 33301246 "` and `"0033301246"`: both become `"33301246"`.
  - `""`: no PMID, not refused.
  - `"0000"`: refused.
  - `"PMID:33301246"`, `"33301246abc"`, `"1 OR 2"`, `"1١٢"`, `"-5"`: all refused.
  - `"PMC7745181"`: becomes `pmc_id` `"PMC7745181"`, `pmid` null, not refused.
- Produces: `canonical_pmid(value: object) -> PmidReading` in `identifiers.py`, where `PmidReading` is a frozen dataclass `(pmid: str | None, pmc_id: str | None, refused: bool)`. An `int` is its digits; `0` is no PMID; `bool` is refused.
- Swift: `PMID.canonical(_ raw: String) -> PMIDReading`. Kotlin: `Pmid.canonical(raw: String): PmidReading`. Same three fields.

- [ ] **Step 1:** Write `tests/test_identifiers.py`. It loads the contract and asserts every case, plus Python-only cases: `canonical_pmid(33301246).pmid == "33301246"`, `canonical_pmid(0).pmid is None and not canonical_pmid(0).refused`, `canonical_pmid(True).refused`. Add an MCP test: `get_document_fulltext({"pmid": "1 OR 2"})` makes no request (a mocked session asserts no call) and the result names the refused value.
- [ ] **Step 2:** Run `pytest tests/test_identifiers.py tests/test_mcp_server.py -v`. Expected: FAIL.
- [ ] **Step 3:** Implement `canonical_pmid` with `[0-9]+` and `re.ASCII`, then `lstrip("0")`. An all-zeros value is refused. Call it at the three entry points. A refused PMID logs a WARNING naming the value and proceeds as if no PMID were given, the way a malformed `pmcid` does. A PMC ID given as `pmid` fills `pmcid` only when the caller gave none. The Europe PMC lookup and the ID Converter assert they receive canonical input, which is a programming error otherwise.
- [ ] **Step 4:** Run `pytest tests/ -q`. Expected: PASS.
- [ ] **Step 5:** In Swift, write `PMIDCanonicalTests.swift` reading the same JSON from `doc/cross_platform/fulltext_parity/`, the way the existing fulltext-parity tests locate it. Run `swift test --filter PMIDCanonical` and expect FAIL. Implement it, use it wherever a `.unknown`-kind identifier reaches a URL, and expect PASS.
- [ ] **Step 6:** Do the same on Android: `PmidCanonicalTest.kt`, then `./gradlew test --tests '*PmidCanonical*'`.
- [ ] **Step 7:** Mutation-sweep `identifiers.py`. Commit: `fix(identifiers): send a PMID canonical or not at all, on all three platforms (bmlib#470, bmlib#472, bmlib#478)`.

### Task 3: One rule for reading a relevance score, on all three platforms

Android invents a score of 3 for any unreadable reply (`util/ResponseParser.kt:101-103`, `DEFAULT_SCORE`). With the default threshold, that makes an unreadable reply "relevant", and the parse-retry loop (`ParallelScoringService.kt:317`) never fires. Swift accepts a JSON `true` as 1 through `NSNumber` bridging, and traps on `Int(1e300)` (`ResponseParser.swift:77-82`). The desktop's `_score_on_scale` (`agents/scoring_agent.py:103`) is already right and becomes the reference.

**Files:**
- Create: `doc/cross_platform/llm_parity/score_values.json`
- Modify: `android/.../util/ResponseParser.kt:56-110,~354`, `android/.../data/remote/llm/LLMService.kt:~288`
- Modify: `Packages/BioMedLit/Sources/BioMedLit/Utilities/ResponseParser.swift:~70-100`
- Test: `tests/test_score_parity.py`, `android/.../util/ResponseParserTest.kt` (rewrite the clamp tests), `Packages/BioMedLit/Tests/BioMedLitTests/ScoreParityTests.swift`

**Interfaces:**
- Produces: the contract `{"schema": 1, "cases": [{"reply": "<raw model text>", "score": int|null}]}`. It must contain at least these cases:

  | `score` value in the reply | expected `score` |
  |---|---|
  | `4`, `4.0`, `"4"`, `" 4 "` | 4 |
  | `0`, `6`, `-3` | null (off-scale, never clamped) |
  | `true` | null |
  | `2.5` | null |
  | `"high"` | null |
  | `null`, or the key missing | null |
  | `1e300` | null |
  | a reply that is not JSON | null |

- Android: `ScoreResult(score: Int?, rationale: String, parseFailed: Boolean)`. `LLMService.scoreDocument` maps `parseFailed` to `Result.failure(IllegalStateException("parse: <reason>"))`, so `isParseError` retries it.
- Remove `DEFAULT_SCORE`.

- [ ] **Step 1:** Write `tests/test_score_parity.py`. Assert every contract case against `parse_score_response(response: str) -> tuple[int, str] | None` in `agents/scoring_agent.py:147`, so that the not-JSON and missing-key cases are covered too. The desktop also reads a score from prose (`_prose_score`, e.g. "Score: 4/5"), which the apps do not. The contract's not-JSON case must therefore carry no score in prose ("I cannot assess this document."). Record the prose fallback as a desktop-only divergence in the contract's `description`. Run it; expect PASS, because the desktop is the reference. If a case fails, the contract is wrong, not the code.
- [ ] **Step 2:** Write Android `ResponseParserTest` cases from the contract. Add `` `an unreadable score is retried and never relevant` ``, driving `ParallelScoringService` with a fake `LLMService` that answers `{"score": "high"}` `MAX_PARSE_RETRIES` times; assert a failed `ScoringResult`, not a success. Run `./gradlew test --tests '*ResponseParserTest*' --tests '*ParallelScoring*'`. Expected: FAIL.
- [ ] **Step 3:** Implement on Android. Kotlin's `jsonPrimitive.isString` distinguishes `"4"` from `4`. Refuse booleans (`booleanOrNull != null` on an unquoted primitive). Accept a double only when it is finite and integral.
- [ ] **Step 4:** Write Swift `ScoreParityTests` from the contract, run `swift test --filter ScoreParity`, and expect FAIL on `true` and `1e300`. Fix it: check `CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()` before the numeric cases, and require `doubleScore.isFinite && doubleScore.rounded() == doubleScore` with the value inside `Int`'s range before converting. Expect PASS.
- [ ] **Step 5:** Commit: `fix(scoring): an unreadable relevance score is a parse failure on every platform`.

### Task 4: The desktop quality tiers narrow every value a model sends

bmlib#295, bmlib#320. In `quality/quality_agent.py:195-262` and `quality/study_classifier.py:405-660`:
- a `null` `study_design`, `design_characteristics` or `bias_risk` raises, and the assessment becomes UNCLASSIFIED;
- `int(True)` is n=1, and `int(inf)` raises an `OverflowError` that nothing catches;
- `max(0, min(1, nan))` is **1.0**;
- design flags are stored raw, so `"no"` and `"unclear"` pass `require_randomization` (`quality/data_models.py:501`);
- `strengths`, `limitations` and `evidence_level` are stored raw.

`quality_manager.py:132` also replaces a confident Tier-1 answer with a failed Tier-3 one.

**Files:**
- Create: `src/bmlibrarian_lite/quality/json_fields.py`
- Modify: `src/bmlibrarian_lite/quality/quality_agent.py:195-377`, `src/bmlibrarian_lite/quality/study_classifier.py:405-660`, `src/bmlibrarian_lite/quality/quality_manager.py:~126-136`
- Test: `tests/test_quality_narrowing.py`

**Interfaces:**
- Produces, ported from bmlib `bmlib/quality/_json_fields.py` with the same semantics and DEBUG logging of refused non-null values:
  - `as_dict(value: object, field: str | None = None) -> dict[str, Any]`
  - `as_text(value, field=None) -> str | None`
  - `text_or(value, default: str, field=None) -> str`
  - `as_int(value, field=None) -> int | None`: refuses `bool` and non-finite values.
  - `as_float(value, field=None) -> float | None`: refuses `bool` and non-finite values.
  - `as_bool(value, field=None) -> bool | None`: only a JSON boolean counts.
  - `as_str_list(value, field=None) -> list[str] | None`
- Each `_parse_*` helper keeps its signature and default, and reads through these.

- [ ] **Step 1:** Write `tests/test_quality_narrowing.py`, porting the relevant tests by name from bmlib's `tests/test_quality_narrowing.py`:
  - `test_as_int`, `test_as_float`, `test_as_bool` (parametrised; include `True`, `float("nan")`, `float("inf")`, `"3"`, `"true"`);
  - `test_a_null_design_characteristics`, `test_a_null_bias_risk`, `test_a_null_study_design` (each assessment keeps its other fields);
  - `test_a_boolean_sample_size_is_not_a_count`, `test_an_infinite_sample_size_does_not_take_the_assessment_down`;
  - `test_a_string_flag_is_not_a_boolean` (parametrise `"yes"`, `"no"`, `"unclear"`; assert `is_randomized is None` and that a filter with `require_randomization=True` rejects it);
  - `test_a_string_is_not_a_list_of_strengths`, `test_a_numeric_evidence_level_is_not_a_level`.

  Add lite-specific tests:
  - `test_a_nan_confidence_takes_the_default`: feed the raw reply text `'{"confidence": NaN, ...}'` through `_parse_response`; assert confidence is the documented default, never `1.0`.
  - `test_a_failed_tier_3_keeps_a_confident_tier_1`: `QualityManager` with a metadata-confirmed RCT and an agent stub returning UNCLASSIFIED at confidence 0; assert the RCT result is kept and the failure is logged.

  Apply the same narrowing tests to `StudyClassifier._parse_response`.
- [ ] **Step 2:** Run `pytest tests/test_quality_narrowing.py -v`. Expected: FAIL.
- [ ] **Step 3:** Implement `json_fields.py` and route both parsers through it. In `quality_manager`, return the metadata result when Tier 3 yields `UNCLASSIFIED`.
- [ ] **Step 4:** Run `pytest tests/ -q -k quality`. Expected: PASS, including the existing benchmark tests.
- [ ] **Step 5:** Mutation-sweep `json_fields.py`. Commit: `fix(quality): narrow every value a model sends (bmlib#295, bmlib#320)`.

### Task 5: Europe PMC's free-PDF allow-list, as a contract

bmlib#79 (0.9.1). Python (`europepmc.py:130`, `_extract_free_pdf_url`) and Android (`FullTextService.kt:354`) accept only `availability == "Free"`, which is about 4% of free PDFs. Swift already implements the rule (`EuropePMCService.swift:~423-580`, `EuropePMCFreePDFTests.swift`).

**Files:**
- Create: `doc/cross_platform/fulltext_parity/europepmc_free_pdf.json`
- Modify: `src/bmlibrarian_lite/europepmc.py:130-148`; `android/.../data/remote/europepmc/EuropePMCModels.kt:~263-280` (add `availabilityCode: String? = null`); `android/.../data/remote/fulltext/FullTextService.kt:~354`
- Test: `tests/test_europepmc_free_pdf.py`, `android/.../data/remote/fulltext/EuropePmcFreePdfTest.kt`, and convert `Packages/BioMedLit/Tests/BioMedLitTests/EuropePMCFreePDFTests.swift` to read the contract

**Interfaces:**
- Produces: the contract `{"schema": 1, "source": "bmlib#79", "cases": [{"name": str, "fullTextUrl": [entry...], "expected_url": str|null}]}`, lifted case for case from the twelve Swift tests (`testOpenAccessPDFIsAccepted` … `testEntryWithoutURLIsSkipped`). The rule:
  - `availabilityCode` in `{"OA", "F"}` is accepted.
  - A present, non-empty, unrecognised code is rejected without consulting the label.
  - A missing or empty code falls back to the label being in `{"Open access", "Free"}`.
  - Only `documentStyle == "pdf"` counts; an entry without a URL is skipped; the first accepted entry wins.
- Constants: `EUROPE_PMC_FREE_PDF_CODES`, `EUROPE_PMC_FREE_PDF_LABELS` in each platform's constants file.

- [ ] **Step 1:** Write the contract from the Swift tests, then make all three suites read it. Run them. Expected: Python and Android FAIL; Swift PASS.
- [ ] **Step 2:** Implement in Python and Android, logging an unrecognised code at WARNING with its label, as Swift does.
- [ ] **Step 3:** Run all three suites. Expected: PASS.
- [ ] **Step 4:** Commit: `fix(fulltext): Europe PMC's open-access PDFs are free PDFs, on all three platforms (bmlib#79)`.

### Task 6: An author role declared on the contributor group

bmlib#111: about 57% of open-access articles declare `content-type="author"` on `<contrib-group>` and leave the `<contrib>` children bare. Desktop `jats_markdown.py:~308-319` reads only the first group's `contrib[@contrib-type='author']`, so those articles have no author line (verified 2026-10-17). Android is the same. Swift already implements the rule.

**Files:**
- Modify: `src/bmlibrarian_lite/jats_markdown.py:~300-320`, `JATS_MARKDOWN_CONVERTER_VERSION`
- Modify: `android/.../util/jats/JATSXMLParser.kt` (contrib handling)
- Test: `tests/test_jats_author_roles.py`, `android/.../util/jats/JATSAuthorRoleTest.kt`

**Interfaces:**
- Produces: `_article_authors(article_meta: ET.Element) -> list[str]` in `jats_markdown.py`, applying bmlib's `_is_author_contrib` rule (`bmlib/fulltext/jats_parser.py:8079`):
  - a contributor's own `contrib-type`, when non-empty, decides on its own;
  - otherwise the innermost enclosing `contrib-group` with a non-empty `content-type` decides;
  - no declaration at any level means author;
  - comparison folds case;
  - every `contrib-group` under `article-meta` is read, not only the first.

- [ ] **Step 1:** Write the tests:
  - `test_a_group_role_makes_bare_contribs_authors`
  - `test_an_editor_group_is_not_authors`
  - `test_a_contribs_own_editor_role_wins_inside_an_author_group`
  - `test_role_case_is_folded` (`"Author"`)
  - `test_an_empty_attribute_declares_nothing`
  - `test_every_group_is_read`
  - control: `test_contrib_type_author_still_reads`

  Use minimal JATS like the probe already run (`<contrib-group content-type="author"><contrib><name>…`).
- [ ] **Step 2:** Run `pytest tests/test_jats_author_roles.py -v`. Expected: FAIL on the group-role tests.
- [ ] **Step 3:** Implement with a recursive walk carrying the stack of declared group types. Bump `JATS_MARKDOWN_CONVERTER_VERSION` so cached renders are re-made.
- [ ] **Step 4:** Run `pytest tests/ -q -k jats`. Expected: PASS.
- [ ] **Step 5:** Port the same tests to Kotlin. Run `./gradlew test --tests '*JATSAuthorRole*'` (FAIL), implement, run again (PASS). Regenerate and read the corpus digests as the Global Constraints require.
- [ ] **Step 6:** Commit: `fix(jats): an author role declared on the group (bmlib#111)`.

---

## Phase 2 — Gate: does mobile take bmlib's Rust crate?

### WP-2: UniFFI spike (decides how Phase 4 is done)

bmlib's Rust crate (`~/src/bmlib/rust/bmlib`, published 0.2.0) is a functionally complete port of bmlib, kept in step with the Python library and checked by a differential oracle. Its dependencies are pure Rust (`roxmltree`, `regex`, `serde_json`), plus `rusqlite`, `ureq`, and `pdfium` behind a feature flag. Its HTTP goes through an `HttpClient` trait. If Swift and Android can call it, the JATS, reference, quality-extractor, JSON-repair, citation-formatting and retraction work in Phases 4, 6 and 7 is never hand-ported twice.

The bmlib half (an `ffi` crate) is WP-B9 in the bmlib plan.

**Acceptance (all must hold; record the numbers in `doc/cross_platform/bmlib_sync/README.md`):**
1. `parse_jats(xml: String) -> JatsArticle` is callable from `Packages/BioMedLit` and from Android JVM unit tests.
2. Over `doc/cross_platform/jats_corpus/`, the Rust output, mapped into BioMedLit's `JATSModels`, either reproduces the committed digests or each difference is a defect bmlib has fixed (list them).
3. The binary size added per architecture (iOS arm64, simulator, macOS arm64; Android arm64-v8a, x86_64) is measured and the maintainer accepts it.
4. An Xcode Cloud fresh-clone build still archives, with no package reference outside this repository (HANDOVER, Xcode Cloud contract). Choose between a committed `binaryTarget(path:)` xcframework and a `ci_scripts/ci_post_clone.sh` Rust build, and record which.
5. The Gradle build on CI produces the `.so` files (cargo-ndk) without a manual step.

**Outcome:** a written decision in `doc/cross_platform/bmlib_sync/README.md`: either "Phase 4 consumes Rust" (Phase 4 becomes adapter work), or "Phase 4 hand-ports", with the reason.

---

## Phase 3 — Transparency (work packages)

Each becomes its own plan. All of them bump the analyser versions on all three platforms.

- **WP-3.1 Trial registration from the full text.** bmlib scans the text for a registration cue (±60 chars around "registered at/with", "trial registration") and caps a paper at 2 of its own ids. Python reads only `<DataBankList>`; Swift and Android read only NCT ids in the title. This needs a contract `transparency_parity/trial_registration_text.json`. Decide whether to keep lite's no-cap rule (it differs from bmlib) and record the decision in the ledger.
- **WP-3.2 PubMed `efetch` on mobile** (alignment doc §2.1). Read `CoiStatement` and `GrantList` in Swift (`parsePubMedGrants` exists and only tests call it) and on Android (which never calls PubMed on the transparency path). Build on Task 1's own-record rule.
- **WP-3.3 Android transparency reads no full text.** `analyzableFullText` always returns null, so COI and data availability are never assessed. Wire the full-text result through, as iOS does.
- **WP-3.4 Posted results with mixed answers** (bmlib#206): one "no results" trial plus one unreachable trial is charged −10 on all three platforms. Make it provisional.
- **WP-3.5 A wrong-typed `hasResults`** (bmlib#209, bmlib#226) silently becomes MISSING and −10 on all three. Refuse it and add a caveat.
- **WP-3.6 Desktop resolves DOI → PMID after the PubMed step** (`study_transparency_analyzer.py:~3208`), so a DOI-only paper never gets its `CoiStatement` or grants. Move the resolution first.
- **WP-3.7 CrossRef `funder` entries read with unguarded `.get()`** (bmlib#199, Python only).
- **WP-3.8 Decisions to record, not code:**
  - `<DataBankList>` deposition credit (alignment doc §2.2; Python deliberately excludes GEO-type banks);
  - `pty` in the industry words (lite declined: no corpus evidence);
  - the scoring-model difference (§2.7).

## Phase 4 — JATS (work packages; shaped by WP-2)

If WP-2 says "consume Rust", the mobile rows below become one adapter task per platform, plus corpus-digest review. Otherwise each bullet is a hand-port with Swift first and Android following, under `UPDATE_JATS_DIGESTS` review.

- **WP-4.1 Desktop:**
  - the article year from the publication date, never `nihms-submitted` (bmlib#261);
  - cell and alt text kept out of sentences (#243, #241, #248);
  - an NLM 2.x `<citation>` is a reference (#390);
  - `element-citation` rendered with separators, not glued;
  - `award-group` funders and award numbers (#284);
  - exhibit footnotes (#124);
  - the nested `<fig>` (#115);
  - note markers out of titles and names (#423, #425, #429).
- **WP-4.2 Swift references:**
  - `<etal/>` (#406), `pub-id` by declared type (#397), page ranges (#413);
  - the nested citation note (#414), `string-name` (#415), a bare `<name>` (#382, #276);
  - `citation-alternatives` read as one work (#407, lite #406);
  - an empty `<citation>` is no blank entry (lite #407);
  - related-work ownership (#270, lite #257).
- **WP-4.3 Swift article metadata:**
  - metadata only where the article deposits it (#254, #259); the year (#261);
  - empty repeated `fpage`/`volume`/`issue` (#272);
  - `elocation-id` (#265, lite #272);
  - unnumbered exhibits (#162, lite #174); a table deposited as a graphic (#127, lite #172);
  - cell text (#243); definitions (#228).
- **WP-4.4 Front-matter funding and COI statements reach the mobile analysers** (bmlib#230, bmlib#234, bmlib#257; lite #423). This moves transparency scores.
- **WP-4.5 Android catch-up:**
  - everything Swift has that Android lacks: caption and section routing (lite #401, #165), unsectioned body and back matter (#224), container headings (#231), sub-articles (#110, #119), identifiers by declared type, the end-of-parse audit (#134);
  - errors no longer swallowed (lite #121);
  - then WP-4.2 to WP-4.4.
- **WP-4.6 A renderer version stamp on the mobile caches** (bmlib#172). Without it, any parser fix reaches only articles not cached yet. Do this **before** WP-4.2 to WP-4.5 ship.
- **WP-4.7 Display formulas** (lite #399): port bmlib's formula renderer, never raw MathML.

## Phase 5 — Full-text retrieval (work packages)

- **WP-5.1 Closed-access Europe PMC 500 on mobile** (lite #450, bmlib#457/bmlib#462): skip on `isOpenAccess: N`, as Python does. The PMC9391270 exception is accepted and recorded.
- **WP-5.2 A malformed or stale caller PMC ID gives way to the search hit's** (bmlib#304), on all three platforms. Feed the ID Converter's PMC ID back into the XML and bucket tiers (Python).
- **WP-5.3 Swift PDF text gets paragraph structure:** port bmlib's `fulltext/segmenter.py` section segmentation so the `(?=\n\n|\z)` COI and data regexes stop over-capturing (`TransparencyAnalysisService.swift:496-523`, `PDFTextExtractor.swift:244`).
- **WP-5.4 PubMed parsers:**
  - the year from `PubDate` (lite #402);
  - no translated `<OtherAbstract>` (lite #403), and the same `.//AbstractText` shape in Python `search_client.py:~996`.

## Phase 6 — LLM plumbing (work packages)

- **WP-6.1 JSON location and repair.** Port bmlib's `llm/utils.py` span locator (whole span beats nested fragment, bmlib#33) and `llm/json_repair.py`:
  - on the desktop, replace the copy-pasted extractors, including the two-level-nesting regex at `study_classifier.py:535` and `benchmarking/quality_runner.py:934`, or simply import from bmlib (Phase 8);
  - in Swift, locate top-level arrays in `ResponseParser`;
  - on Android, retire the regex salvage at `ResponseParser.kt:327-338`.
- **WP-6.2 Truncated output is detected** (bmlib#300): read `stop_reason` / `finishReason` / `done_reason` on all three platforms, and treat a reply cut off at `max_tokens` as a failure, never as complete. The desktop Ollama provider must stop hard-coding `"stop"` (`ollama.py:209`).
- **WP-6.3 Small desktop defects:**
  - only the last system message reaches Anthropic (`providers/anthropic.py:183`, #315);
  - `get_recent_records(0)` returns every record (`token_tracker.py:186`, #308);
  - the provider name is not lower-cased (`llm/client.py:123`, #302);
  - a bool is accepted as the Ollama context length (`ollama.py:290`, #313).

## Phase 7 — Capabilities bmlib has and lite lacks (decide first)

These are product decisions. Each needs a yes or no before a plan is written.

**Decided 2026-10-17 (maintainer):** retraction checking goes ahead first. The other items stay deferred until it has landed.

- **Retraction checking** (`bmlib.publications.retractions`, Retraction Watch). No platform warns about a retracted paper. Highest value of the group. **Approved; write its plan next.**
- **Citation styles** (`bmlib.citations`: Vancouver, APA, Harvard, Chicago).
- **`context_processor`** (map-reduce over long content); **Gemini**; the cross-provider `think`; tool calling.

## Phase 8 — The desktop depends on bmlib

Both projects are Python, AGPL-3.0, and by the same author; bmlib's core dependency is `jinja2` alone. Once the bmlib plan's Task B1 (an injectable HTTP client) has landed, replace lite's copies with imports, one module per PR, keeping lite's API as a thin adapter. Order of least coupling first:

1. `quality` narrowing and `llm` JSON (after Tasks 4 and 6.1, adopt bmlib's and delete lite's);
2. the citations formatter;
3. the JATS parser, with `jats_markdown.py` becoming a renderer over bmlib's `JATSArticle`, after the bmlib plan's WP-B7 and WP-B8 move the desktop's statement-heading layer upstream;
4. full-text retrieval, after bmlib's Tasks B2 and B3 and WP-B4 to WP-B6 upstream lite's sources, wall recognition, title check and pacing;
5. transparency last: lite's scoring model is the mobile parity reference, and this needs the §2.7 decision.

Each step deletes a lite module, its ledger rows become `"python": "ported"` permanently, and the corresponding mobile contract fixtures move upstream into bmlib.

---

## Appendix A: Gap register

Audit of 2026-10-17, bmlib `f4b7c52`, lite `ca9de635`. **Status:** N = not ported, P = partial, Y = done, — = not applicable. **WP** = the task or work package that closes the row.

| bmlib | Change | Py | Swift | Android | WP |
|---|---|---|---|---|---|
| (none) | PubMed `ArticleId` from the reference list | **N** | Y | N (#404) | T1 |
| #474 | The PubMed record read is the one asked about | N | P | — | T1 |
| #470 #472 #478 | PMID canonical ASCII digits | N | P | N | T2 |
| #472 | PMC ids ASCII (leftovers: `pdf_discovery` `\d`, Swift `isNumber`) | P | P | Y | T2 |
| (lite) | Android invents score 3; Swift bool and `1e300` scores | Y | P | **N** | T3 |
| #295 #320 | Quality JSON narrowing; NaN read as 1.0; string flags | **N** | — | — | T4 |
| #79 | Europe PMC free-PDF allow-list | N | Y | N | T5 |
| #111 | Author role on the contrib-group | **N** | Y | N | T6 |
| #474 | Europe PMC PMID-only lookup within `SRC:MED` | Y | Y | Y | — |
| §2.5 | Trial ids from the full text | N | N | N | 3.1 |
| §2.1 | PubMed `CoiStatement` / `GrantList` | Y | N | N | 3.2 |
| §2.3 | Full text on the transparency path | Y | Y | N | 3.3 |
| #206 | Partly answered posted results | P | P | P | 3.4 |
| #209 #226 | A wrong-typed value is reported | N | N | N | 3.5 |
| #199 | No JSON shape escapes `analyze()` | P | Y | Y | 3.7 |
| #284 | Structured funding (`award-group`) | N | N | N | 4.1 |
| #257 #230 #234 | Funding and front-matter statements | Y | N | N | 4.4 |
| #261 #254 #259 #272 | Article year, metadata, empty repeated elements | N | N | N | 4.1 / 4.3 |
| #243 #241 #248 | Cell text and object metadata stay out of prose | N | N | N | 4.1 / 4.3 |
| #390 | NLM 2.x `<citation>` | N | N | N | 4.1 / 4.2 |
| #406 #397 #413 #414 #415 #382 #276 #270 #385 #149 | Reference fields | — | N | N | 4.2 |
| #407 | `citation-alternatives` | — | P | P | 4.2 |
| #265 | `elocation-id` | — | N | N | 4.3 |
| #162 #127 | Unnumbered exhibits; table as a graphic | Y | N | N | 4.3 |
| #228 | Definitions | Y | N | N | 4.3 |
| #224 #231 | Unsectioned back matter; container heading | Y | Y | N | 4.5 |
| #110 #119 | Sub-article; reviewer disclosure | Y | Y | N | 4.5 |
| #115 #116 #117 #123 #125 #130 | Nested exhibits, labels, captions, graphics | P | Y | N | 4.1 / 4.5 |
| #124 | Exhibit footnotes | N | Y | N | 4.1 / 4.5 |
| #423 #425 #429 | Note markers and rosters out of titles and names | N | N | N | 4.1 / 4.2 |
| #172 | Re-render when the renderer changes | Y | N | N | 4.6 |
| #147 | Formulas | P | P | P | 4.7 |
| #457 #462 | Europe PMC 500 for closed access | Y | N | N | 5.1 |
| #304 | A stale caller PMC ID gives way | N | N | N | 5.2 |
| 0.8.0 | PDF section segmentation | P | N | — | 5.3 |
| (lite) | PubMed year (#402), `OtherAbstract` (#403) | P | N | N | 5.4 |
| #33 0.9.x | JSON span locator and repair | N | N | N | 6.1 |
| #300 | Truncated output detected | N | N | N | 6.2 |
| #302 #308 #313 #315 | Small LLM defects | N | — | — | 6.3 |
| 0.7.0 | Retraction Watch | N | N | N | 7 |
| 0.8.0 | Citation styles | N | N | N | 7 |
| 0.7.0 | `context_processor`; Gemini; `think`; tool calling | N | N | N | 7 |
