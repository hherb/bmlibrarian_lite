# Restore GDPR/HIPAA/privacy/patient-consent data-restriction detection

**Issue:** #104
**Date:** 2026-07-17
**Platforms:** Python (reference) + Swift (BioMedLit). Android out of scope.

## Problem

PR #103 (Swift↔Python transparency parity, closes #101) dropped four Swift-only
data-restriction patterns from `DataAvailabilityAnalyzer.restrictionMappings` to
achieve exact classification parity with the canonical Python reference, which
never had them:

| Original pattern | Original label |
|---|---|
| `privacy` | Privacy restrictions |
| `patient consent` | Patient consent required |
| `gdpr` | GDPR restrictions |
| `hipaa` | HIPAA restrictions |

As a result, a data-availability statement such as *"restricted under GDPR"*,
*"withheld due to HIPAA"*, *"patient privacy concerns"*, or *"patient consent
required"* now falls through to `.unknown` on iOS/macOS where it previously
surfaced a restriction — a deliberate but real detection-breadth regression on
Swift. Python never detected these at all.

## Goal

Add the four patterns to the `restricted` tier on **both** platforms in one
change, so they classify identically and don't re-diverge. Statements matching
them (and no stronger refusal) classify as `RESTRICTED`.

## Scope decision

**Faithful + word-anchored.** Restore exactly the four original patterns,
word-anchored per the #106/#107 convention, reusing the original labels. No
broadening. Bare `informed consent` is explicitly **excluded** — it appears in
nearly every clinical paper ("informed consent was obtained") and would produce
massive false `RESTRICTED` classifications.

### The four patterns + labels

| Pattern (Python `r"…"` / Swift `#"…"#`) | Label |
|---|---|
| `\bgdpr\b` | `GDPR restrictions` |
| `\bhipaa\b` | `HIPAA restrictions` |
| `\bprivacy\b` | `Privacy restrictions` |
| `\bpatient consent\b` | `Patient consent required` |

## Design

### Python — `src/bmlibrarian_lite/study_transparency_analyzer/study_transparency_analyzer.py`

1. Append the four patterns to `DATA_REPOSITORIES['restricted']`, at the end
   (after `data\s+custodians?\b`).
2. Add the four label entries to the `_restriction_labels` map inside
   `analyze_data_availability`.

### Swift — `Packages/BioMedLit/Sources/BioMedLit/Transparency/Models/TransparencyConstants.swift`

1. Append the same four patterns to `DataRepositoryPatterns.restrictedPatterns`
   (same order).
2. Add the four entries to `DataRepositoryPatterns.restrictionLabels`.

No analyzer logic changes are needed on either platform:
`analyze_data_availability` (Python) and `DataAvailabilityAnalyzer.analyze`
(Swift) already drive Step 3 classification and label resolution from these
constants.

### Placement rationale — append at end

The four patterns are **not** members of the strong-refusal or
effectively-unavailable sets, so appending them at the end of the `restricted`
list:
- keeps the ordering of every existing restriction label unchanged (existing
  exact-order tests stay green), and
- keeps the two platforms' lists in identical order (parity).

## Behavior (verified against the priority pipeline)

| Statement | Result | Restrictions |
|---|---|---|
| `restricted under GDPR` | RESTRICTED | `["GDPR restrictions"]` |
| `withheld due to HIPAA` | RESTRICTED | `["HIPAA restrictions"]` |
| `access limited by patient privacy concerns` | RESTRICTED | `["Privacy restrictions"]` |
| `patient consent required for data access` | RESTRICTED | `["Patient consent required"]` |
| `data deposited in GEO; no privacy concerns` | **FULL_OPEN** | — (full-open checked first; a bare `privacy` mention never overrides open data) |
| `data cannot be shared due to GDPR` | **NOT_AVAILABLE** | includes both `Data cannot be shared` and `GDPR restrictions` (existing `cannot be shared` strong-refusal escalates) |

`RESTRICTED` is the semantically correct tier: GDPR/HIPAA-protected data is
typically available under controlled/managed access — not fully open, not fully
refused.

## Score impact (intended — requires release note)

A statement that previously classified `UNKNOWN` (0 score adjustment) now
classifies `RESTRICTED` (−5), plus the existing −10 combined penalty when
industry ties co-occur. Transparency scores therefore shift **downward on both
Python and mobile** for affected studies. This is the deliberate, documented
consequence of the parity fix and must be called out in the PR description and
`HANDOVER.md` (the repo has no CHANGELOG).

## Testing

Six mirrored cases per platform.

**Python** — new methods in `TestAnalyzeDataAvailability`
(`tests/test_study_transparency_analyzer.py`):
- gdpr → RESTRICTED + label
- hipaa → RESTRICTED + label
- privacy → RESTRICTED + label
- patient consent → RESTRICTED + label
- privacy does **not** override full-open (repo + "no privacy concerns" → FULL_OPEN)
- gdpr + strong refusal → NOT_AVAILABLE (both labels present)

**Swift** — mirror the same six in `DataAvailabilityAnalyzerTests`.

**Auto-validated invariant:** Swift `testRestrictionLabelLookup` iterates every
`restrictedPatterns` entry and asserts a matching `restrictionLabels` value —
this fails if any new pattern lacks a label, pinning pattern↔label parity for
free.

### Regression safety (already checked against existing tests)

- Python `test_named_collaboration_lock_is_not_available` pins an exact
  restrictions list, but its statement contains none of the four tokens →
  unaffected. The two existing Python "privacy" tests assert only the disclosure
  *level* → unaffected.
- Swift `testExtractRestrictionsOrderedAndDeduplicated` pins an exact ordered
  list; appending the four at the end leaves it unchanged. The existing Swift
  "privacy" tests assert only `.notAvailable` → unaffected.

## Verification gate

- `pytest tests/` → 0 failures
- `ruff check .` → clean
- `mypy src/` → clean
- `cd Packages/BioMedLit && swift test` → 0 failures

(No iOS/macOS **app** sources change — only the shared BioMedLit package — so the
app build check is not required, though the package must compile.)

## Out of scope

- Android (no data-availability classifier exists yet — separate follow-up).
- Broadening beyond the four patterns (chose faithful restoration).
- Strong-refusal escalation for GDPR/HIPAA alone (kept `RESTRICTED`; combining
  with an existing strong-refusal signal still escalates correctly).
