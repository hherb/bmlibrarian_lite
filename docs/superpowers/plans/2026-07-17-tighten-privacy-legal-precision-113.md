# Tighten privacy/legal restricted-tier precision (#113) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Broaden the data-availability full-open tier on Python + Swift with three open-availability affirmation patterns, so genuinely-open statements that name no repository classify FULL_OPEN instead of a false RESTRICTED, closing #113.

**Architecture:** Append three narrow affirmation regexes to the existing full-open pattern list on both platforms (byte-identical), then update the two pinned tradeoff tests to assert the intended FULL_OPEN flip plus a guard that an explicit strong refusal still wins. Pure pattern-list + test change; no control-flow changes.

**Tech Stack:** Python 3 (`re`, pytest), Swift (`BioMedLit` Swift package, XCTest).

## Global Constraints

- Parity is mandatory: the three new patterns must be **byte-identical** across Python `DATA_REPOSITORIES['full_open']` and Swift `DataRepositoryPatterns.fullOpenPatterns`.
- The three patterns, verbatim: `openly (?:available|shared|accessible)`, `freely (?:available|shared|accessible)`, `available (?:in|within|as|via|through) (?:the )?supplement`.
- Python is the canonical reference; Swift mirrors it.
- No changes to any tier other than adding to full-open. No change to the four #104 privacy/legal restricted patterns themselves.
- Branch: `fix/tighten-privacy-legal-precision-113`. Spec: `docs/superpowers/specs/2026-07-17-tighten-privacy-legal-data-restriction-precision-design.md`.

---

### Task 1: Python — add affirmation patterns + update tests

**Files:**
- Modify: `src/bmlibrarian_lite/study_transparency_analyzer/study_transparency_analyzer.py` (the `DATA_REPOSITORIES['full_open']` list, ~L285–292)
- Test: `tests/test_study_transparency_analyzer.py` (rewrite the `test_privacy_without_recognized_repository_is_restricted` method, ~L315–337; add two methods in class `TestAnalyzeDataAvailability`)

**Interfaces:**
- Consumes: `analyze_data_availability(text) -> DataAvailabilityInfo`, `DataDisclosureLevel` (existing).
- Produces: no new public symbols; `DATA_REPOSITORIES['full_open']` gains 3 entries.

- [ ] **Step 1: Rewrite the pinned tradeoff test and add guard/positive tests (failing)**

In `tests/test_study_transparency_analyzer.py`, replace the entire `test_privacy_without_recognized_repository_is_restricted` method (currently ~L315–337) with the following two methods:

```python
    def test_open_affirmation_without_repository_is_full_open(self) -> None:
        """Open-availability affirmations classify FULL_OPEN without a named
        repository (issue #113 fix).

        Full-open is inferred from open-availability affirmations
        ("openly shared", "available in the supplementary materials", "freely
        available"), not only from recognized repository keywords, so a
        reassuring privacy/legal token in a genuinely-open statement no longer
        produces a false RESTRICTED.
        """
        openly_shared = analyze_data_availability(
            "De-identified data are openly shared; no HIPAA-protected "
            "identifiers remain."
        )
        assert openly_shared.disclosure_level == DataDisclosureLevel.FULL_OPEN

        supplementary = analyze_data_availability(
            "All data are available in the supplementary materials; patient "
            "privacy was protected throughout."
        )
        assert supplementary.disclosure_level == DataDisclosureLevel.FULL_OPEN

        freely = analyze_data_availability(
            "The complete dataset is freely available to all researchers."
        )
        assert freely.disclosure_level == DataDisclosureLevel.FULL_OPEN

    def test_open_affirmation_with_strong_refusal_is_not_available(self) -> None:
        """An open affirmation cannot override an explicit strong refusal (#113).

        The up-front unavailability guard must still skip the full-open step, so
        a statement that both affirms availability and refuses access
        classifies NOT_AVAILABLE.
        """
        result = analyze_data_availability(
            "Data are freely available in summary form but the individual-level "
            "data cannot be shared."
        )
        assert result.disclosure_level == DataDisclosureLevel.NOT_AVAILABLE
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pytest tests/test_study_transparency_analyzer.py::TestAnalyzeDataAvailability::test_open_affirmation_without_repository_is_full_open tests/test_study_transparency_analyzer.py::TestAnalyzeDataAvailability::test_open_affirmation_with_strong_refusal_is_not_available -v`
Expected: `test_open_affirmation_without_repository_is_full_open` FAILS (currently classifies RESTRICTED); `test_open_affirmation_with_strong_refusal_is_not_available` PASSES already (the refusal guard predates this change — that is fine, it is a regression guard).

- [ ] **Step 3: Add the three affirmation patterns to the full-open list**

In `src/bmlibrarian_lite/study_transparency_analyzer/study_transparency_analyzer.py`, in `DATA_REPOSITORIES['full_open']`, immediately after the `r'yoda',` line, add:

```python
        # Open-availability affirmations (issue #113): genuinely-open statements
        # that name no repository but explicitly affirm open access. Deliberately
        # narrow — bare "available" is not matched, so "available upon request"
        # and "available from the corresponding author" stay RESTRICTED. Mirrors
        # the Swift ``DataRepositoryPatterns.fullOpenPatterns``.
        r'openly (?:available|shared|accessible)',
        r'freely (?:available|shared|accessible)',
        r'available (?:in|within|as|via|through) (?:the )?supplement',
```

- [ ] **Step 4: Run the full data-availability suite to verify pass + no regressions**

Run: `pytest tests/test_study_transparency_analyzer.py -v`
Expected: PASS — including the four unchanged privacy/legal true-positive tests (`test_gdpr_restriction_is_restricted`, `test_hipaa_restriction_is_restricted`, `test_privacy_restriction_is_restricted`, `test_patient_consent_restriction_is_restricted`), `test_privacy_does_not_override_full_open`, and `test_gdpr_with_strong_refusal_is_not_available`.

- [ ] **Step 5: Run the full test suite + linters**

Run: `pytest tests/` then `ruff check .` then `mypy src/`
Expected: pytest PASS. For ruff/mypy, no *new* errors versus the pre-existing baseline (repo is not clean — see the lint/typecheck debt memory).

- [ ] **Step 6: Commit**

```bash
git add src/bmlibrarian_lite/study_transparency_analyzer/study_transparency_analyzer.py tests/test_study_transparency_analyzer.py
git commit -m "fix(transparency): recognize open-availability affirmations as full-open (#113)

Broaden DATA_REPOSITORIES['full_open'] with three open-availability
affirmation patterns (openly/freely available|shared|accessible, available
in supplementary) so genuinely-open statements naming no repository classify
FULL_OPEN instead of a false RESTRICTED when a reassuring privacy/legal token
is present. Rewrites the pinned #113 tradeoff test to assert the FULL_OPEN
flip and adds a strong-refusal guard.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Swift — mirror affirmation patterns + update tests

**Files:**
- Modify: `Packages/BioMedLit/Sources/BioMedLit/Transparency/Models/TransparencyConstants.swift` (the `DataRepositoryPatterns.fullOpenPatterns` array, L353–375)
- Test: `Packages/BioMedLit/Tests/BioMedLitTests/Transparency/DataAvailabilityAnalyzerTests.swift` (rewrite `testPrivacyWithoutRecognizedRepositoryIsRestricted`, L218–240; add one method)
- Test: `Packages/BioMedLit/Tests/BioMedLitTests/Transparency/TransparencyConstantsTests.swift` (extend `testFullOpenPatternsMatch`, from L215)

**Interfaces:**
- Consumes: `DataAvailabilityAnalyzer.analyze(statement:) -> DataAvailabilityResult`, `DataDisclosureLevel`, `RegexHelper.anyMatch` (existing).
- Produces: no new public symbols; `DataRepositoryPatterns.fullOpenPatterns` gains 3 entries (byte-identical to Task 1).

- [ ] **Step 1: Rewrite the pinned tradeoff test and add a guard test (failing)**

In `Packages/BioMedLit/Tests/BioMedLitTests/Transparency/DataAvailabilityAnalyzerTests.swift`, replace the entire `testPrivacyWithoutRecognizedRepositoryIsRestricted` method (with its doc comment, L218–240) with:

```swift
    /// Open-availability affirmations classify `.fullOpen` without a named
    /// repository (issue #113 fix).
    ///
    /// Full-open is inferred from open-availability affirmations
    /// ("openly shared", "available in the supplementary materials", "freely
    /// available"), not only from recognized repository keywords, so a
    /// reassuring privacy/legal token in a genuinely-open statement no longer
    /// produces a false `.restricted`.
    func testOpenAffirmationWithoutRepositoryIsFullOpen() {
        let openlyShared = DataAvailabilityAnalyzer.analyze(
            statement: "De-identified data are openly shared; no "
                + "HIPAA-protected identifiers remain."
        )
        XCTAssertEqual(openlyShared.disclosureLevel, .fullOpen)

        let supplementary = DataAvailabilityAnalyzer.analyze(
            statement: "All data are available in the supplementary materials; "
                + "patient privacy was protected throughout."
        )
        XCTAssertEqual(supplementary.disclosureLevel, .fullOpen)

        let freely = DataAvailabilityAnalyzer.analyze(
            statement: "The complete dataset is freely available to all researchers."
        )
        XCTAssertEqual(freely.disclosureLevel, .fullOpen)
    }

    /// An open affirmation cannot override an explicit strong refusal (#113).
    func testOpenAffirmationWithStrongRefusalIsNotAvailable() {
        let result = DataAvailabilityAnalyzer.analyze(
            statement: "Data are freely available in summary form but the "
                + "individual-level data cannot be shared."
        )
        XCTAssertEqual(result.disclosureLevel, .notAvailable)
    }
```

- [ ] **Step 2: Run the tests to verify the flip fails**

Run: `cd Packages/BioMedLit && swift test --filter testOpenAffirmationWithoutRepositoryIsFullOpen`
Expected: FAIL (currently classifies `.restricted`).

- [ ] **Step 3: Add the three affirmation patterns to `fullOpenPatterns`**

In `TransparencyConstants.swift`, in `DataRepositoryPatterns.fullOpenPatterns`, immediately after the `"yoda",` line (L374), add:

```swift
        // Open-availability affirmations (issue #113): genuinely-open statements
        // that name no repository but explicitly affirm open access. Deliberately
        // narrow — bare "available" is not matched. Mirrors Python's
        // DATA_REPOSITORIES['full_open'].
        #"openly (?:available|shared|accessible)"#,
        #"freely (?:available|shared|accessible)"#,
        #"available (?:in|within|as|via|through) (?:the )?supplement"#,
```

- [ ] **Step 4: Extend the pattern-list test with the affirmations**

In `TransparencyConstantsTests.swift`, inside `testFullOpenPatternsMatch()` (after the existing `XCTAssertTrue(... )` blocks, before the closing brace), add:

```swift
        // #113 open-availability affirmations
        XCTAssertTrue(RegexHelper.anyMatch(
            patterns: patterns,
            in: "Data are openly shared"
        ))
        XCTAssertTrue(RegexHelper.anyMatch(
            patterns: patterns,
            in: "available in the supplementary materials"
        ))
        XCTAssertTrue(RegexHelper.anyMatch(
            patterns: patterns,
            in: "the dataset is freely available"
        ))
```

- [ ] **Step 5: Run the BioMedLit test suite**

Run: `cd Packages/BioMedLit && swift test`
Expected: PASS — including the unchanged privacy/legal true-positive tests and `testExtractRestrictionsNone` (which exercises `extractRestrictions`, unaffected by full-open additions).

- [ ] **Step 6: Verify the macOS app still builds**

Run: `cd ios/MedicalFactChecker && xcodebuild -scheme MedicalFactChecker -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add Packages/BioMedLit/Sources/BioMedLit/Transparency/Models/TransparencyConstants.swift Packages/BioMedLit/Tests/BioMedLitTests/Transparency/DataAvailabilityAnalyzerTests.swift Packages/BioMedLit/Tests/BioMedLitTests/Transparency/TransparencyConstantsTests.swift
git commit -m "fix(transparency): mirror #113 open-availability affirmations in Swift

Add the same three open-availability affirmation patterns to
DataRepositoryPatterns.fullOpenPatterns (byte-identical to Python) so
BioMedLit classifies genuinely-open statements FULL_OPEN. Rewrites the pinned
tradeoff test to assert the FULL_OPEN flip, adds a strong-refusal guard, and
pins the new patterns in the constants test.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Update HANDOVER + open PR

**Files:**
- Modify: `HANDOVER.md` (move #113 out of "Potential follow-ups"; add a short "Recently landed" entry)

- [ ] **Step 1: Update HANDOVER.md**

Remove the "Tighten privacy/GDPR/HIPAA restricted-tier precision (issue #113)" bullet from the "Potential follow-ups" section, and add a "Recently landed" entry summarizing the fix (open-availability affirmations added to full-open on both platforms; the two pinned tradeoff tests flipped to assert FULL_OPEN; #113 closed).

- [ ] **Step 2: Commit HANDOVER**

```bash
git add HANDOVER.md
git commit -m "docs(handover): record #113 open-data precision fix"
```

- [ ] **Step 3: Push and open the PR (closes #113)**

```bash
git push -u origin fix/tighten-privacy-legal-precision-113
gh pr create --base master --title "fix(transparency): recognize open-availability affirmations as full-open (#113)" --body "Closes #113. Broadens the data-availability full-open tier on Python (canonical) and Swift (BioMedLit) with three byte-identical open-availability affirmation patterns so genuinely-open statements naming no repository classify FULL_OPEN instead of a false RESTRICTED. Rewrites the two pinned tradeoff tests to assert the intended FULL_OPEN flip and adds strong-refusal guards. User-visible upward transparency-score shift for the affected statement shapes — see spec. Android port (#116) builds on this.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

## Self-Review

- **Spec coverage:** three affirmation patterns added on both platforms (Tasks 1, 2 Step 3); pinned tests flipped to FULL_OPEN (Tasks 1, 2 Step 1); strong-refusal guard added (Tasks 1, 2); true-positive restricted tests kept (verified in Tasks 1, 2 Step 4/5); pattern-list assertion updated (Task 2 Step 4). Verification commands present (pytest, swift test, xcodebuild). Covered.
- **Placeholder scan:** none — all steps carry exact code/commands.
- **Type consistency:** patterns byte-identical between Task 1 (Python `r'...'`) and Task 2 (Swift `#"..."#`); test method names consistent within each platform.
