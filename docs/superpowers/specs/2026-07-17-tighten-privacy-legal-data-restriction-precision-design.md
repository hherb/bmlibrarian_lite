# Tighten privacy/GDPR/HIPAA restricted-tier precision (open-data false positives)

**Issue:** #113 (closes)
**Date:** 2026-07-17
**Platforms:** Python (reference) + Swift (BioMedLit). Android (#116, Slice 1) then ports the corrected behavior.

## Problem

The #104 privacy/legal patterns (`\bgdpr\b`, `\bhipaa\b`, `\bprivacy\b`,
`\bpatient consent\b`) are restricted-tier and fire standalone. Because full-open
is inferred **only from a recognized repository keyword**, an openly-available
statement that names no repository but happens to mention a privacy/legal token
*reassuringly* is wrongly classified `RESTRICTED`.

Two false positives, currently pinned by
`test_privacy_without_recognized_repository_is_restricted` (Python) /
`testPrivacyWithoutRecognizedRepositoryIsRestricted` (Swift):

| Statement | Current (wrong) |
|---|---|
| "De-identified data are openly shared; no HIPAA-protected identifiers remain." | RESTRICTED — "HIPAA restrictions" |
| "All data are available in the supplementary materials; patient privacy was protected throughout." | RESTRICTED — "Privacy restrictions" |

In both, the data is genuinely open and the privacy/legal token is a
reassurance, not a restriction.

## Goal

Classify genuinely-open statements as `FULL_OPEN` while keeping real
privacy/legal restrictions `RESTRICTED`. Applied to **both** Python and Swift in
one change so they stay byte-identical; Android's Slice 1 (#116) then ports the
corrected classifier.

## Scope decision

**Broaden the full-open tier with open-availability affirmations** (root-cause
fix). The full-open detector currently recognizes only repository *names*; it
should also recognize explicit open-availability affirmations, so such
statements classify `FULL_OPEN` in Step 1 — before the restricted tier ever
sees the reassuring privacy token.

Rejected alternative: *require a co-occurring restriction cue for the privacy
tokens.* It turns the false positives into `UNKNOWN` (not `FULL_OPEN`, so it
under-recognizes genuinely-open data) and introduces a new fuzzy
"restriction cue" list that could itself misfire.

### Patterns added (byte-identical, Python + Swift)

Appended to `DATA_REPOSITORIES['full_open']` (Python) and
`DataRepositoryPatterns.fullOpenPatterns` (Swift), with a comment marking them
as the #113 open-availability affirmation set:

```
openly (?:available|shared|accessible)
freely (?:available|shared|accessible)
available (?:in|within|as|via|through) (?:the )?supplement
```

Deliberately narrow: **bare `available` is not matched**, so "available upon
request" and "available from the corresponding author" stay `RESTRICTED`. No new
category is introduced — these live in the existing full-open list, which drives
Step 1 classification (any full-open match ⇒ `FULL_OPEN`). They are **not** added
to `repositoryMappings`, so `detectRepositoryName` still returns `nil` for them
(an affirmation yields `FULL_OPEN` with no repository name, summarized as "Data
publicly available").

## Behavior change

| Statement | Before | After |
|---|---|---|
| "restricted under GDPR" | RESTRICTED | RESTRICTED (unchanged) |
| "limited by HIPAA" | RESTRICTED | RESTRICTED (unchanged) |
| "constrained by … privacy considerations" | RESTRICTED | RESTRICTED (unchanged) |
| "Data access requires patient consent" | RESTRICTED | RESTRICTED (unchanged) |
| **"openly shared; no HIPAA-protected identifiers remain"** | **RESTRICTED** | **FULL_OPEN** |
| **"available in the supplementary materials; privacy was protected"** | **RESTRICTED** | **FULL_OPEN** |
| "deposited in Zenodo; no privacy concerns" | FULL_OPEN | FULL_OPEN (unchanged) |
| "not publicly available owing to GDPR" | NOT_AVAILABLE | NOT_AVAILABLE (unchanged — the refusal guard still skips Step 1) |

This is a **user-visible upward** transparency-score shift for the two affected
statement shapes (FULL_OPEN scores +20 vs. RESTRICTED −5, a +25 swing plus
removal of any industry+restricted combined penalty). Call it out in release
notes as an intended precision improvement.

## Test changes

Python (`tests/test_study_transparency_analyzer.py`), mirrored in Swift
(`DataAvailabilityAnalyzerTests.swift`) and pinned in the pattern-list tests
(`DataRepositoryPatternsTest` / `TransparencyConstantsTests`):

- **Rewrite** the two `..._privacy_without_recognized_repository_is_restricted`
  pins to `..._open_affirmation_without_repository_is_full_open`, asserting
  `FULL_OPEN` for both statements. This is the intentional, visible flip the pin
  was created to surface.
- **Keep** the four true-positive tests (`gdpr`/`hipaa`/`privacy`/`patient
  consent` → `RESTRICTED`) unchanged — they guard against over-broadening.
- **Add** a guard test that an open affirmation combined with an explicit strong
  refusal still classifies `NOT_AVAILABLE` (e.g. "data are freely available in
  summary form but the individual-level data cannot be shared" — an affirmation
  match plus the `cannot be shared` refusal) — the up-front unavailability guard
  must still skip Step 1 and win.
- **Add** the three new patterns to the full-open pattern-list assertions.

## Non-goals

- No change to scoring, risk indicators, or any tier other than the addition to
  full-open.
- No change to the four #104 privacy/legal restricted patterns themselves — they
  remain, and still fire when no open affirmation (and no stronger refusal) is
  present.
- The residual soft-restriction ambiguity (an open affirmation co-occurring with
  a *soft* on-request restriction) stays deterministically `FULL_OPEN`, matching
  the existing repository + soft-restriction policy (LLM disambiguation tracked
  in #109).

## Verification

- `pytest tests/` → 0 failures (Python is the reference).
- `cd Packages/BioMedLit && swift test` → 0 failures.
- macOS app still builds: `xcodebuild -scheme MedicalFactChecker -destination
  'platform=macOS' build` from `ios/MedicalFactChecker/`.
- Byte-diff the three new patterns between the Python and Swift full-open lists.
