# Restore GDPR/HIPAA/privacy/patient-consent detection — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore detection of GDPR/HIPAA/privacy/patient-consent data-restriction statements as `RESTRICTED` on both the Python reference and the Swift BioMedLit package, keeping the two byte-identical.

**Architecture:** Append four word-anchored regex patterns (`\bgdpr\b`, `\bhipaa\b`, `\bprivacy\b`, `\bpatient consent\b`) plus their human-readable labels to the `restricted` tier's pattern list and label map on each platform. No analyzer logic changes — both analyzers already drive Step-3 (`RESTRICTED`) classification and label resolution from these constants. TDD, one platform per task.

**Tech Stack:** Python 3 (`re`, pytest, ruff, mypy), Swift (`NSRegularExpression`, XCTest, SwiftPM).

**Spec:** `docs/superpowers/specs/2026-07-17-restore-privacy-legal-data-restriction-detection-design.md`
**Issue:** #104

## Global Constraints

- The four patterns and their labels MUST be byte-identical across platforms (modulo `r"…"` vs `#"…"#` regex-literal syntax). Patterns: `\bgdpr\b`, `\bhipaa\b`, `\bprivacy\b`, `\bpatient consent\b`. Labels (in order): `GDPR restrictions`, `HIPAA restrictions`, `Privacy restrictions`, `Patient consent required`.
- Patterns are word-anchored (`\b…\b`) per the #106/#107 convention.
- Patterns are appended at the **end** of the existing `restricted` pattern list on each platform (they are NOT strong-refusal / effectively-unavailable members) — this preserves the order of all existing restriction labels.
- Target tier is `RESTRICTED` only. Do NOT add these to the strong-refusal or effectively-unavailable sets.
- Do NOT add a bare `informed consent` pattern (would over-match ~every clinical paper).
- Python: Google-style docstrings + type hints; no magic numbers. Swift: `///` doc comments on new public entries not required (they are data list/map members — follow the existing in-file comment style).
- Tests are mirrored: the same six cases on each platform.

---

### Task 1: Python — restore the four patterns + labels (reference platform)

**Files:**
- Modify: `src/bmlibrarian_lite/study_transparency_analyzer/study_transparency_analyzer.py` (the `DATA_REPOSITORIES['restricted']` list ~line 293–314 and the `_restriction_labels` dict inside `analyze_data_availability` ~line 1026–1060)
- Test: `tests/test_study_transparency_analyzer.py` (append to class `TestAnalyzeDataAvailability`)

**Interfaces:**
- Consumes: `analyze_data_availability(text: Optional[str]) -> DataAvailabilityInfo`, `DataDisclosureLevel` (both already imported in the test module).
- Produces: no new symbols — extends existing `DATA_REPOSITORIES['restricted']` and the `_restriction_labels` map. `DataAvailabilityInfo.disclosure_level: DataDisclosureLevel` and `DataAvailabilityInfo.restrictions: list[str]` are the fields under test.

- [ ] **Step 1: Write the failing tests**

Append these six methods to the end of class `TestAnalyzeDataAvailability` in `tests/test_study_transparency_analyzer.py`:

```python
    def test_gdpr_restriction_is_restricted(self) -> None:
        """A GDPR-restricted statement classifies as RESTRICTED (issue #104)."""
        result = analyze_data_availability(
            "Individual patient data are restricted under GDPR."
        )
        assert result.disclosure_level == DataDisclosureLevel.RESTRICTED
        assert result.restrictions == ["GDPR restrictions"]

    def test_hipaa_restriction_is_restricted(self) -> None:
        """A HIPAA-restricted statement classifies as RESTRICTED (issue #104)."""
        result = analyze_data_availability(
            "Access to the dataset is limited by HIPAA."
        )
        assert result.disclosure_level == DataDisclosureLevel.RESTRICTED
        assert result.restrictions == ["HIPAA restrictions"]

    def test_privacy_restriction_is_restricted(self) -> None:
        """A privacy-restricted statement classifies as RESTRICTED (issue #104)."""
        result = analyze_data_availability(
            "Sharing is constrained by participant privacy considerations."
        )
        assert result.disclosure_level == DataDisclosureLevel.RESTRICTED
        assert result.restrictions == ["Privacy restrictions"]

    def test_patient_consent_restriction_is_restricted(self) -> None:
        """A patient-consent restriction classifies as RESTRICTED (issue #104)."""
        result = analyze_data_availability(
            "Data access requires patient consent."
        )
        assert result.disclosure_level == DataDisclosureLevel.RESTRICTED
        assert result.restrictions == ["Patient consent required"]

    def test_privacy_does_not_override_full_open(self) -> None:
        """A bare 'privacy' mention must not override a public repository.

        The four privacy/legal patterns are restricted-tier; full-open is
        checked first, so a deposit plus 'no privacy concerns' stays FULL_OPEN.
        """
        result = analyze_data_availability(
            "Data are deposited in Zenodo; no privacy concerns were identified."
        )
        assert result.disclosure_level == DataDisclosureLevel.FULL_OPEN

    def test_gdpr_with_strong_refusal_is_not_available(self) -> None:
        """GDPR plus an explicit refusal escalates to NOT_AVAILABLE (issue #104)."""
        result = analyze_data_availability(
            "The data are not publicly available owing to GDPR."
        )
        assert result.disclosure_level == DataDisclosureLevel.NOT_AVAILABLE
        assert "Data not publicly available" in result.restrictions
        assert "GDPR restrictions" in result.restrictions
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pytest tests/test_study_transparency_analyzer.py::TestAnalyzeDataAvailability -v -k "gdpr or hipaa or privacy or consent"`
Expected: the four positive tests + `test_gdpr_with_strong_refusal_is_not_available` FAIL (patterns absent → statements classify UNKNOWN / restrictions missing the new labels). `test_privacy_does_not_override_full_open` may already PASS (Zenodo already matches) — that's fine.

- [ ] **Step 3: Add the four patterns to `DATA_REPOSITORIES['restricted']`**

In `study_transparency_analyzer.py`, find the last entry of the `restricted` list:

```python
        r'data\s+custodians?\b',
```

Replace it with (append the four patterns after it, still inside the list):

```python
        r'data\s+custodians?\b',
        # Privacy/legal data-restriction detection (issue #104): GDPR/HIPAA/
        # privacy/patient-consent statements classify as RESTRICTED. Word-
        # anchored per #106/#107 to avoid substring over-match. Mirrors the
        # Swift ``DataRepositoryPatterns.restrictedPatterns``.
        r'\bgdpr\b',
        r'\bhipaa\b',
        r'\bprivacy\b',
        r'\bpatient consent\b',
```

- [ ] **Step 4: Add the four labels to `_restriction_labels`**

In `analyze_data_availability`, find this line in the `_restriction_labels` dict:

```python
        r'data\s+custodians?\b': "Data held by custodians (not authors)",
```

Replace it with (append the four label entries after it):

```python
        r'data\s+custodians?\b': "Data held by custodians (not authors)",
        r'\bgdpr\b': "GDPR restrictions",
        r'\bhipaa\b': "HIPAA restrictions",
        r'\bprivacy\b': "Privacy restrictions",
        r'\bpatient consent\b': "Patient consent required",
```

- [ ] **Step 5: Run the new tests to verify they pass**

Run: `pytest tests/test_study_transparency_analyzer.py::TestAnalyzeDataAvailability -v -k "gdpr or hipaa or privacy or consent"`
Expected: all PASS.

- [ ] **Step 6: Run the full Python gate**

Run: `pytest tests/ && ruff check . && mypy src/`
Expected: 0 test failures, ruff clean, mypy clean. (Confirms no existing test — e.g. `test_named_collaboration_lock_is_not_available` — regressed.)

- [ ] **Step 7: Commit**

```bash
git add src/bmlibrarian_lite/study_transparency_analyzer/study_transparency_analyzer.py tests/test_study_transparency_analyzer.py
git commit -m "$(cat <<'EOF'
feat(transparency): restore GDPR/HIPAA/privacy/consent detection in Python (#104)

Append four word-anchored restricted-tier patterns (\bgdpr\b, \bhipaa\b,
\bprivacy\b, \bpatient consent\b) plus labels to DATA_REPOSITORIES['restricted']
and _restriction_labels. Such statements now classify RESTRICTED (was UNKNOWN),
shifting scores downward for affected studies. Mirrors the Swift change.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Swift — restore the four patterns + labels (mirror)

**Files:**
- Modify: `Packages/BioMedLit/Sources/BioMedLit/Transparency/Models/TransparencyConstants.swift` (`DataRepositoryPatterns.restrictedPatterns` ~line 382–402 and `DataRepositoryPatterns.restrictionLabels` ~line 435–466)
- Test: `Packages/BioMedLit/Tests/BioMedLitTests/Transparency/DataAvailabilityAnalyzerTests.swift` (add methods to `DataAvailabilityAnalyzerTests`)

**Interfaces:**
- Consumes: `DataAvailabilityAnalyzer.analyze(statement: String?) -> DataAvailabilityResult`; `result.disclosureLevel: DataDisclosureLevel` (`.restricted`, `.fullOpen`, `.notAvailable`); `result.restrictions: [String]`.
- Produces: no new symbols — extends `DataRepositoryPatterns.restrictedPatterns` and `.restrictionLabels`. The existing `testRestrictionLabelLookup` will auto-verify every new pattern has a label.

- [ ] **Step 1: Write the failing tests**

Add these six methods inside `final class DataAvailabilityAnalyzerTests` in `DataAvailabilityAnalyzerTests.swift` (e.g. after `testAnalyzeIRBRestriction`):

```swift
    /// GDPR-restricted statement classifies as restricted (issue #104).
    func testAnalyzeGDPRRestriction() {
        let result = DataAvailabilityAnalyzer.analyze(
            statement: "Individual patient data are restricted under GDPR."
        )
        XCTAssertEqual(result.disclosureLevel, .restricted)
        XCTAssertEqual(result.restrictions, ["GDPR restrictions"])
    }

    /// HIPAA-restricted statement classifies as restricted (issue #104).
    func testAnalyzeHIPAARestriction() {
        let result = DataAvailabilityAnalyzer.analyze(
            statement: "Access to the dataset is limited by HIPAA."
        )
        XCTAssertEqual(result.disclosureLevel, .restricted)
        XCTAssertEqual(result.restrictions, ["HIPAA restrictions"])
    }

    /// Privacy-restricted statement classifies as restricted (issue #104).
    func testAnalyzePrivacyRestriction() {
        let result = DataAvailabilityAnalyzer.analyze(
            statement: "Sharing is constrained by participant privacy considerations."
        )
        XCTAssertEqual(result.disclosureLevel, .restricted)
        XCTAssertEqual(result.restrictions, ["Privacy restrictions"])
    }

    /// Patient-consent restriction classifies as restricted (issue #104).
    func testAnalyzePatientConsentRestriction() {
        let result = DataAvailabilityAnalyzer.analyze(
            statement: "Data access requires patient consent."
        )
        XCTAssertEqual(result.disclosureLevel, .restricted)
        XCTAssertEqual(result.restrictions, ["Patient consent required"])
    }

    /// A bare 'privacy' mention must not override a public repository (issue #104).
    func testPrivacyDoesNotOverrideFullOpen() {
        let result = DataAvailabilityAnalyzer.analyze(
            statement: "Data are deposited in Zenodo; no privacy concerns were identified."
        )
        XCTAssertEqual(result.disclosureLevel, .fullOpen)
    }

    /// GDPR plus an explicit refusal escalates to notAvailable (issue #104).
    func testGDPRWithStrongRefusalIsNotAvailable() {
        let result = DataAvailabilityAnalyzer.analyze(
            statement: "The data are not publicly available owing to GDPR."
        )
        XCTAssertEqual(result.disclosureLevel, .notAvailable)
        XCTAssertTrue(result.restrictions.contains("Data not publicly available"))
        XCTAssertTrue(result.restrictions.contains("GDPR restrictions"))
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Packages/BioMedLit && swift test --filter DataAvailabilityAnalyzerTests`
Expected: the four positive tests + `testGDPRWithStrongRefusalIsNotAvailable` FAIL (new patterns/labels absent). `testPrivacyDoesNotOverrideFullOpen` may already PASS.

- [ ] **Step 3: Add the four patterns to `restrictedPatterns`**

In `TransparencyConstants.swift`, find the last entry of `restrictedPatterns`:

```swift
        #"data\s+custodians?\b"#,
    ]
```

Replace with:

```swift
        #"data\s+custodians?\b"#,
        // Privacy/legal data-restriction detection (issue #104): GDPR/HIPAA/
        // privacy/patient-consent statements classify as `.restricted`. Word-
        // anchored per #106/#107. Mirrors Python's DATA_REPOSITORIES['restricted'].
        #"\bgdpr\b"#,
        #"\bhipaa\b"#,
        #"\bprivacy\b"#,
        #"\bpatient consent\b"#,
    ]
```

- [ ] **Step 4: Add the four labels to `restrictionLabels`**

Find this entry in the `restrictionLabels` map:

```swift
        #"data\s+custodians?\b"#: "Data held by custodians (not authors)",
```

Replace with:

```swift
        #"data\s+custodians?\b"#: "Data held by custodians (not authors)",
        #"\bgdpr\b"#: "GDPR restrictions",
        #"\bhipaa\b"#: "HIPAA restrictions",
        #"\bprivacy\b"#: "Privacy restrictions",
        #"\bpatient consent\b"#: "Patient consent required",
```

- [ ] **Step 5: Run the full Swift package test suite**

Run: `cd Packages/BioMedLit && swift test`
Expected: 0 failures — the six new tests pass, and existing tests (`testRestrictionLabelLookup`, `testExtractRestrictionsOrderedAndDeduplicated`, the privacy-mentioning analyzer tests) stay green.

- [ ] **Step 6: Commit**

```bash
git add Packages/BioMedLit/Sources/BioMedLit/Transparency/Models/TransparencyConstants.swift Packages/BioMedLit/Tests/BioMedLitTests/Transparency/DataAvailabilityAnalyzerTests.swift
git commit -m "$(cat <<'EOF'
feat(transparency): restore GDPR/HIPAA/privacy/consent detection in Swift (#104)

Mirror the Python change: append four word-anchored restricted-tier patterns
plus labels to DataRepositoryPatterns.restrictedPatterns / restrictionLabels.
Such statements now classify .restricted (was .unknown) on iOS/macOS, matching
the canonical Python reference byte-for-byte.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Document the score-shift and update HANDOVER

**Files:**
- Modify: `HANDOVER.md` (move #104 out of "Potential follow-ups" into "Recently landed"; note the intended score shift)

**Interfaces:** none (documentation only).

- [ ] **Step 1: Update HANDOVER.md**

In `HANDOVER.md`, remove the `#104` bullet from the "Potential follow-ups" section and add a "Recently landed" entry summarising: four word-anchored privacy/legal patterns (gdpr/hipaa/privacy/patient consent) added to the `restricted` tier on both platforms; statements now classify RESTRICTED (was UNKNOWN on Python / on Swift), an **intended downward score shift** for affected studies; mirrored six-case tests on both sides; closes #104. Keep the file under 500 lines (prune the oldest "Recently landed" context entry if needed).

- [ ] **Step 2: Commit**

```bash
git add HANDOVER.md
git commit -m "$(cat <<'EOF'
docs(handover): record restored GDPR/HIPAA/privacy/consent detection (#104)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 3: Final full verification gate**

Run: `pytest tests/ && ruff check . && mypy src/ && (cd Packages/BioMedLit && swift test)`
Expected: all green. Then push the branch and open a PR to `master`, linking issue #104, with a description that explicitly calls out the intended transparency-score decrease for affected studies (release note).

---

## Self-Review

**Spec coverage:**
- Four patterns + labels on both platforms → Tasks 1 & 2. ✓
- Word-anchored, appended at end, RESTRICTED tier → Steps 1.3/1.4/2.3/2.4. ✓
- Six mirrored test cases per platform (four positives + privacy-not-override-full-open + gdpr+strong-refusal→NOT_AVAILABLE) → Steps 1.1/2.1. ✓
- Auto-validated label invariant (Swift `testRestrictionLabelLookup`) → covered by Step 2.5 full-suite run. ✓
- Regression safety (exact-list tests unaffected) → verified by full-suite Steps 1.6/2.5. ✓
- Score-shift release note → Task 3 + PR description. ✓
- Android out of scope → not in plan. ✓

**Placeholder scan:** none — every code/label/command is concrete.

**Type consistency:** Python uses `analyze_data_availability` / `DataDisclosureLevel.{RESTRICTED,FULL_OPEN,NOT_AVAILABLE}` / `result.restrictions`. Swift uses `DataAvailabilityAnalyzer.analyze(statement:)` / `.restricted,.fullOpen,.notAvailable` / `result.restrictions`. Consistent with the read source and test files.
