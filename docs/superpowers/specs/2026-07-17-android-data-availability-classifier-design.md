# Android data-availability transparency classifier (Slice 1)

**Issue:** #116 (Android transparency parity — multi-slice; this is Slice 1)
**Date:** 2026-07-17
**Platforms:** Android (Kotlin). Python is the canonical reference; Swift (BioMedLit) is the existing mirror.

## Context

The Python desktop app (`study_transparency_analyzer.py`) and the Swift
`BioMedLit` package both classify a study's data-availability statement into a
`DataDisclosureLevel` and a list of human-readable restriction labels. Swift
mirrors the canonical Python byte-for-byte; a series of parity fixes (#101,
#104, #106, #107, #108, #114) keeps the pattern lists, restriction labels, and
tier logic identical across the two.

**Android has none of it.** A repo-wide search for
`transparency|data.?avail|conflict.?of.?interest|COI|funding` over the Kotlin
sources returns zero matches. The `Document` model and `DocumentEntity` carry no
transparency fields; `DocumentCard` renders relevance/embedding scores only; the
JATS parser extracts no data-availability/funding/COI/trial sections. The
"DocumentCard (with transparency)" note in `CLAUDE.md`/`README.md` is
aspirational — it refers to the Python/Swift implementations.

Bringing Android to full transparency parity is a multi-slice effort. **This
spec covers Slice 1 only: the pure data-availability classifier.** It is the
foundation every later piece consumes (scoring, risk indicators, UI).

## Goal

Port the canonical data-availability classifier to Kotlin so an identical
statement classifies to the identical `disclosureLevel` and `restrictions` on
Android, Python, and Swift. Pure Kotlin — no network, UI, Room, JATS, or DI
changes. Enforced by mirrored JUnit4 tests.

## Scope

### In scope (Slice 1)

The pure classification logic and its output model, in a new self-contained
package:

```
app/src/main/java/com/bmlibrarian/factchecker/domain/transparency/
  DataDisclosureLevel.kt      # enum, 6 cases, raw values match Swift/Python
  DataAvailabilityResult.kt   # analyzer output data class
  DataRepositoryPatterns.kt   # byte-identical pattern lists + label map + regexes
  RegexHelper.kt              # anyMatch / first-match / first-group helpers
  DataAvailabilityAnalyzer.kt # analyze() + extraction/label helpers
app/src/test/java/com/bmlibrarian/factchecker/domain/transparency/
  DataAvailabilityAnalyzerTest.kt
  DataRepositoryPatternsTest.kt
```

`RegexHelper` is its own file because later slices (COI analyzer, scorer,
funding, trial) reuse it — mirroring Swift's `RegexHelper` role.

### Explicitly out of scope (later slices)

Scoring (`calculate_transparency_score`), risk indicators
(`_identify_risk_indicators` / `RISK_INDICATOR_*`), the COI/funding/trial
analyzers, the aggregate `TransparencyResult`, JATS statement extraction, Room
persistence + migration, workflow wiring (an `ANALYZING_TRANSPARENCY` step), and
the `DocumentCard` transparency UI. Each is its own future slice.

## Canonical source of truth

The Kotlin port copies pattern literals **verbatim from the Python source** —
the spec deliberately does not re-transcribe every list (a third copy would
drift). Authoritative locations in
`src/bmlibrarian_lite/study_transparency_analyzer/study_transparency_analyzer.py`:

| Kotlin symbol | Python source | Notes |
|---|---|---|
| `DataRepositoryPatterns.fullOpenPatterns` | `DATA_REPOSITORIES['full_open']` (~L285–292, 21 patterns) | short tokens word-anchored (`\bgeo\b`, `\bpdb\b`, `\bsra\b`, `\bena\b`) |
| `DataRepositoryPatterns.restrictedPatterns` | `DATA_REPOSITORIES['restricted']` (~L293–322, 23 patterns) | includes the #104 privacy/legal set (`\bgdpr\b`, `\bhipaa\b`, `\bprivacy\b`, `\bpatient consent\b`) |
| `DataRepositoryPatterns.effectivelyUnavailablePatterns` | `DATA_REPOSITORIES['effectively_unavailable']` (~L325–332, 3 patterns) | |
| `DataRepositoryPatterns.strongRefusalPatterns` | `STRONG_REFUSAL_PATTERNS` (~L338–346, 7 patterns) | subset of restricted |
| `DataRepositoryPatterns.restrictionLabels` | `_restriction_labels` (~L1034–1072) | pattern→label map |

**List order is significant** and must match Python: restriction labels are
produced by iterating the pattern lists in order, and distinct patterns can
share a label. Use ordered Kotlin collections (`listOf`, and a plain `mapOf` for
labels keyed by pattern string).

The `repositoryMappings` display list (20 entries, word-anchored short tokens)
is copied from the **Swift** `DataAvailabilityAnalyzer.repositoryMappings` — it
is a Swift-only display path (#107) with no Python counterpart. Small fixed
regexes:

- `urlPattern = "https?://[^\\s<>\"]+"`
- `accessionPattern = "(?:accession|identifier)[:\\s]+([A-Z0-9]+)"`
- `restrictionLabel(pattern) = restrictionLabels[pattern] ?: pattern`

## Data model

```kotlin
enum class DataDisclosureLevel(val rawValue: String, val displayName: String) {
    FULL_OPEN("full_open", "Fully Open"),
    AVAILABLE_ON_REQUEST("on_request", "Available on Request"), // never emitted by analyze; retained for later scoring / external LLM producers
    RESTRICTED("restricted", "Restricted"),
    NOT_AVAILABLE("not_available", "Not Available"),
    NOT_STATED("not_stated", "Not Stated"),
    UNKNOWN("unknown", "Unknown");
}

data class DataAvailabilityResult(
    val statement: String? = null,
    val disclosureLevel: DataDisclosureLevel = DataDisclosureLevel.UNKNOWN,
    val repositoryName: String? = null,
    val repositoryUrl: String? = null,   // String (canonical Python), NOT java.net.URL
    val accessionNumber: String? = null,
    val restrictions: List<String> = emptyList(),
) {
    companion object {
        val NOT_STATED = DataAvailabilityResult(disclosureLevel = DataDisclosureLevel.NOT_STATED)
    }
}
```

Raw values are identical to Swift/Python so a later JSON/Room round-trip stays
cross-platform compatible. One deliberate divergence from Swift: `repositoryUrl`
is `String?` (Python stores the raw matched string), avoiding the parse
divergence Swift's `URL(string:)` could introduce.

## Classifier logic (`DataAvailabilityAnalyzer.analyze`)

Exact tier order from Python `analyze_data_availability` / Swift
`DataAvailabilityAnalyzer.analyze`:

1. `statement` null or empty → `DataAvailabilityResult.NOT_STATED`.
2. Compute `hasUnavailabilitySignal` = `anyMatch(effectivelyUnavailable + strongRefusal, statementLower)`.
3. **Tier 1 — Full open** (only if `!hasUnavailabilitySignal`): first matching
   `fullOpenPatterns` entry → `FULL_OPEN`, extracting `repositoryUrl` +
   `accessionNumber` (from the original-case statement) and `repositoryName`
   (from the lowercased statement). A repository name alone does **not** win if a
   refusal co-occurs.
4. **Tier 2 — Not available**: if `effectivelyUnavailableSignals` (ordered
   labels) is non-empty **or** a strong-refusal matches → `NOT_AVAILABLE`, with
   `restrictions` = effectively-unavailable labels followed by any restricted
   labels not already present.
5. **Tier 3 — Restricted**: if `extractRestrictions(statementLower)` is
   non-empty → `RESTRICTED` (order-preserving dedup).
6. **Tier 4 — Unknown**: statement exists but nothing matched → `UNKNOWN`.

Helpers mirror Swift: `checkFullOpenAccess`, `extractUrl`,
`extractAccessionNumber`, `detectRepositoryName`, `extractRestrictions`, and a
private `orderedRestrictionLabels(patterns, text)` that appends each matched
pattern's label, skipping labels already present.

### Regex rules (parity-critical)

- **Classification matching** is on the **lowercased** statement against the
  lowercase patterns with **no** `IGNORE_CASE` — mirrors Python's
  `re.search(pattern, text_lower)`. `RegexHelper.anyMatch` →
  `Regex(pattern).containsMatchIn(text)`.
- **Accession extraction** uses `IGNORE_CASE` and capture group 1 on the
  **original** text — mirrors Python's `re.search(..., re.I).group(1)`.
- **URL extraction** uses capture group 0, case-sensitive, on the original text.
- Swift's `.contains(pattern) || regex` fast-path is **not** replicated; pure
  regex is Python-canonical and behaviorally identical here.
- No compiled-regex caching (parity-first; single-statement labeling is not a
  hot path — same reasoning as the Swift #111 follow-up). Revisit only if it
  moves onto a hot path.

Java/Kotlin regex syntax supports every construct used (`\b`, `(?:…)`, `.*`,
`\s`, `\w`, `+`, `?`), so the Python literals port unchanged (backslashes
escaped for Kotlin string literals).

## Testing

JUnit4, backtick method names, static `assertEquals`/`assertTrue`/`assertFalse`,
`// ==== section ====` banners — matching the existing `CostCalculatorTest`
convention. Directory mirrors the main package path.

`DataAvailabilityAnalyzerTest` mirrors Python `TestAnalyzeDataAvailability` and
the Swift `DataAvailabilityAnalyzerTests` classification/extraction subset:

- empty/blank → `NOT_STATED`
- public repository → `FULL_OPEN`
- `upon reasonable request` / `ethics committee` → `RESTRICTED`
- strong refusal / sponsor confidentiality / named-collaboration lock → `NOT_AVAILABLE`
- ambiguous statement → `UNKNOWN`
- over-match guards: `geographic` and `phenomena` words do **not** trigger
  full-open; embedded short tokens (`sra`/`pdb` inside a word) do not; standalone
  short tokens still do
- repository named but access refused / not publicly available → `NOT_AVAILABLE`
- repository + soft on-request restriction → stays `FULL_OPEN`
- `\bgdpr\b` / `\bhipaa\b` / `\bprivacy\b` / `\bpatient consent\b` → `RESTRICTED`
- privacy token does not override a genuine full-open repository mention
- GDPR co-occurring with a strong refusal → `NOT_AVAILABLE`
- privacy without a recognized repository → `RESTRICTED` (the #113 tradeoff — see below)
- restricted label-sharing patterns deduplicated (e.g. `institutional review
  board` + `irb approval` → single "Requires IRB approval")
- `detectRepositoryName`: GenBank not over-matched by "geographic"; short-token
  carrier word → null; standalone short tokens still detected
- URL and accession extraction

`DataRepositoryPatternsTest` pins the pattern-list contents/counts and the
`restrictionLabel` lookup for representative patterns.

## Inherited cross-platform behavior (not "fixed" here)

The known #113 tradeoff — a privacy/legal token (`\bprivacy\b` is loosest) in an
otherwise-open statement that names no *recognized* repository is flagged
`RESTRICTED` (an open-data false positive) — is **inherited by parity** and
pinned by the `privacy_without_recognized_repository → RESTRICTED` test. Android
matches Python/Swift; it does not diverge to "fix" it. Any precision change is a
cross-platform decision made on all three platforms together (#113).

## Non-goals / constraints

- Byte-identical parity with Python (canonical) is mandatory; Swift is the
  ready-made mirror to cross-check against.
- No changes outside the new package and its tests.
- No new dependencies; Kotlin stdlib `Regex` only.

## Verification

- `cd android/MedicalFactChecker && ./gradlew test` → new tests pass, no
  regressions.
- Cross-check the ported pattern lists against the Python source line ranges
  above (and the Swift `DataRepositoryPatterns` mirror) for byte-identity.
