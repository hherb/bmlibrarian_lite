# Transparency parity contract

Shared, language-neutral fixtures pinning the data-availability classifier to
identical behaviour on Python, Swift and Kotlin (issue #105).

## Why this exists

The classifier is implemented three times:

| Platform | Patterns | Analyzer |
| --- | --- | --- |
| Python (canonical) | `src/bmlibrarian_lite/study_transparency_analyzer/study_transparency_analyzer.py` | `analyze_data_availability` |
| Swift (BioMedLit) | `Packages/BioMedLit/Sources/BioMedLit/Transparency/Models/TransparencyConstants.swift` | `DataAvailabilityAnalyzer.analyze` |
| Kotlin (Android) | `android/…/domain/transparency/DataRepositoryPatterns.kt` | `DataAvailabilityAnalyzer.analyze` |

Each carries its own transcription of the same regex strings. Until this
contract existed, parity was maintained *by convention*: every platform asserted
only its own literals, so an edit to one language diverged from the other two
without a single test failing. Issues #117 and #125 each had to run a throwaway
byte-identity check across the three lists to confirm they still agreed. This
directory makes that check permanent.

A third fixture, `funder_names.json`, is a *measurement* corpus rather than a
pattern contract — see [The funder-name corpus](#the-funder-name-corpus) below.

## The two fixtures

### `data_availability_patterns.json` — the strings

The five pattern tiers and the pattern→label map, asserted **string-for-string
and order-sensitively** by all three suites. Order matters: it determines the
order in which a statement accumulates restriction labels.

Catches an edit to one platform immediately, and names the exact index that
drifted.

### `data_availability_cases.json` — the behaviour

Worked `statement -> (disclosure level, ordered restrictions)` cases, run
through each platform's own analyzer.

Catches what a string comparison cannot see: a regex-engine difference, a
missing compile flag, or a tier-ordering change where every pattern is still
spelled identically.

**Both halves are load-bearing.** Mutation checks confirm neither subsumes the
other:

- Reordering two Kotlin patterns fails only the string comparison — no fixture
  case distinguishes `\bgdpr\b` from `\bhipaa\b` by position.
- Dropping `RegexHelper`'s `(?U)` flag leaves every pattern byte-identical and
  all six string comparisons green; only
  `restricted-negated-openness-unicode-intervening-word` fails, because `\w`
  silently stops matching non-ASCII and an accented intervening word lets a
  negated statement escape to `full_open` — the dangerous over-stating-openness
  direction.

## The funder-name corpus

### `funder_names.json` — industry-funder matching

816 unique real funder names sampled from CrossRef `funder[].name` (431) and
PubMed `<Grant><Agency>` (402) — 17 names appear in both — of which 417 are
hand-labelled `industry` / `not_industry` / `ambiguous`. Lifted **byte-identical**
from bmlib's `tests/data/funder_names.json` (issue #36), so drift between the two
repositories is a one-line `diff`:

```bash
diff "${BMLIB:-$HOME/src/bmlib}/tests/data/funder_names.json" \
     doc/cross_platform/transparency_parity/funder_names.json
```

Unlike the two data-availability fixtures, this one does **not** pin strings. It
pins *measured quality*, on both platforms:

| Platform | Classifier | Lists | Measurement |
| --- | --- | --- | --- |
| Python (canonical) | `study_transparency_analyzer.classify_funder_name` | `FUNDER_NAME_STEMS` / `FUNDER_NAME_WORDS` | `tests/test_funder_classification.py` |
| Swift (BioMedLit) | `FundingAnalyzer.classifyFunder` | `IndustryPatterns.funderNameStems` / `funderNameWords` | `FunderClassificationTests` |

Each asserts floors of precision 0.90 and recall 0.30, plus that it beats the
substring matcher it replaced (precision 0.455 / recall 0.167). Current measured
figures on both platforms: **precision 0.909, recall 0.333** — the same ten true
positives, the same single false positive and the same twenty misses, pinned by
name in `TestCorpusComposition` and `FunderCorpusCompositionTests`. That is what
makes this a parity check rather than two independent claims: the two platforms
cannot drift apart without one of them failing its own copy of the composition.

The distinction matters because the classifier is asymmetric:
`industry_funding_detected` / `industryFundingDetected` feeds a HIGH-risk rule and
HIGH downgrades a paper's quality tier, so a false positive costs more than a
false negative. Ties go to precision, and a floors-based guard is what keeps a
recall-chasing edit honest.

Ambiguous entries carry a `reason` and are excluded from the metrics — scoring an
undecidable name would only add noise.

**What #143 fixed here.** Until then, "Python" in this section meant bmlib's
`_is_industry_funder` (`bmlib/transparency/analyzer.py`, a separate repository)
and nothing else: the canonical desktop implementation named in the table at the
top of this file classified funders with a positional `INDUSTRY_KEYWORDS[:6]`
slice, never read this corpus, and had never been measured against it. It scored
**precision 0.444 / recall 0.133** — worse than the matcher bmlib replaced. Four
of its five false positives were public research bodies (India's Department of
Biotechnology in three spellings, and the UK's Biotechnology and Biological
Sciences Research Council), each of which set `industry_funding_detected`, fed
the HIGH-risk rule, and so downgraded the quality tier of every paper they fund.
The canonical Python now carries the calibrated lists and reads this file.

Android has no funder classifier yet. When one is added it should read the same
file and assert the same floors.

**Adding a name to the corpus is not free.** Every published figure above is a
fraction of its counts, so an edit moves precision, recall and composition on
both platforms at once — while both suites stay green, because they would simply
be measuring something else. `TestFunderCorpusContract` in
`tests/test_transparency_parity.py` pins the counts, the label and source
vocabularies, and that only ambiguous entries carry a reason, so that edit has to
be deliberate. The corpus is also lifted byte-identical from bmlib, so a change
here means the two repositories have drifted.

## Changing a pattern

1. Edit `data_availability_patterns.json`.
2. Make the same edit in all three platform sources.
3. Add or update cases in `data_availability_cases.json` covering the new
   behaviour, then run all three suites.

Do **not** regenerate either file mechanically from one platform. The friction is
the feature: a change that does not touch all three is meant to fail.

```bash
pytest tests/test_transparency_parity.py
cd Packages/BioMedLit && swift test --filter TransparencyParityTests
cd android/MedicalFactChecker && ./gradlew test --tests '*TransparencyParityTest'
```

Changing a *funder* pattern is a different workflow: edit the lists on **both**
platforms — `FUNDER_NAME_STEMS` / `FUNDER_NAME_WORDS` in
`study_transparency_analyzer.py` and `IndustryPatterns.funderNameStems` /
`funderNameWords` in `TransparencyConstants.swift` — then re-run the measurement
rather than a string comparison.

```bash
pytest tests/test_funder_classification.py
cd Packages/BioMedLit && swift test --filter 'Funder|IndustryPattern'
```

Each platform holds the floors (`TestCorpusMeasurement`,
`FunderClassificationTests`) and pins *which* names are matched, missed and
wrongly matched (`TestCorpusComposition`, `FunderCorpusCompositionTests`). The
floors alone cannot see a swap — one recognised funder traded for another leaves
both metrics identical — and the recall floor of 0.30 against a measured 10/30
tolerates losing a true positive outright. All three name lists are expected to
change; the point is that changing one is a deliberate edit with the funder's
name in the diff.

`TestPatternStructure` and `IndustryPatternStructureTests` cover the third gap: a
pattern that matches *nothing* moves no metric, so a `\b`-anchored string placed
in the substring list (where it becomes a literal search for a backslash and a
"b") or an uppercase stem (which can never match a lowercased name) would
otherwise ship green and silently stop flagging funders.

An invalid regex is the one case where the two platforms differ rather than
mirror: Python raises `re.error` at classification time, a crash rather than a
silent no-op, while Swift's `RegexHelper` turns it into `nil` via `try?` and
skips it for good. Both suites check that every pattern compiles, which is what
keeps the lists interchangeable despite that.

The fixtures are read from this directory by path — deliberately not copied into
per-platform test resources, since all three must read the same bytes and a copy
would reintroduce the divergence the guard exists to prevent.

Because the fixtures sit outside every Gradle source set, `app/build.gradle.kts`
declares this directory as an input of the Android test tasks. Without that
declaration Gradle sees no changed input when only the contract is edited,
reports `UP-TO-DATE`, and skips the Android parity test entirely — silently
passing the exact incomplete-edit case the guard exists to catch. Do not remove
it. (Gradle hashes content, not timestamps, so `touch` alone will still not
re-run the task; that is correct.)

## Invariants the Python suite also pins

`TestManifestSelfConsistency` asserts structural properties of the contract
itself, so a future edit cannot reintroduce a known trap on all three platforms
at once:

- **Strong refusal is a subset of restricted.** Escalation to `not_available`
  must not bypass the restricted tier's labels.
- **Negated openness is an ordered *suffix* of restricted.** This is the Kotlin
  declaration-order trap: `negatedOpennessPatterns` must be declared before
  `restrictedPatterns`, because Kotlin initialises `object` properties in
  declaration order and a forward reference silently appends nothing.
- **Every pattern feeding the up-front unavailability probe is reachable from a
  later tier.** A pattern added to the probe alone suppresses Step 1 without
  supplying a replacement tier, so a matching statement silently lands in
  `unknown` instead of `full_open`.
- **Every restriction-tier pattern has a label, and every label belongs to a
  tier.** An unlabelled pattern surfaces its raw regex to the user; an orphaned
  label is dead weight that reads as live behaviour.
- **Every pattern compiles**, and every reachable disclosure level, every
  restriction label and every individual *pattern* is exercised by at least one
  case — so the behavioural half cannot develop a blind spot as patterns are
  added.

Per-pattern coverage is deliberately stricter than per-label coverage, and the
difference is load-bearing. All four negated-openness patterns emit the single
label "Data not openly available", so a label-keyed guard is satisfied by any one
of them while the other three stay behaviourally untested on every platform. That
was not hypothetical: the neither/nor supplement variant shipped with no covering
case, and only the per-pattern guard found it.

Adding a pattern under an existing label therefore also requires a case that
matches that pattern specifically.

`AVAILABLE_ON_REQUEST` is deliberately unreachable: on-request phrasing maps to
`RESTRICTED`. The level exists for scoring and externally-constructed results,
and all three platforms agree on that.

## Care when editing cases

Several statements pin a regex window or barrier at an exact token distance and
lose their discriminating power if the wording shifts by a word — a window pin
must sit exactly one token past the bound so the *first* widening step fails it.
Those cases carry a `why` field. Do not reword them; add a new case instead.
