# Desktop transparency certainty and high-risk explanation (#386)

The desktop app states how far each transparency rating can be relied on and
why a study was rated high risk, in the same words as the iOS/macOS and Android
apps. Those words become a shared contract that all three platforms assert.

## Why

PR #388 gave Swift and Android three things the desktop lacks:

1. **A certainty note.** Every rating made without the article's full text
   says "Limited certainty because of lack of full text access". This was the
   user's decision on 2026-09-24: full-text analysis is the gold standard.
2. **An explanation of each high rating.** It gives the rules that fired, the
   score's terms when the score was one of them, the other recorded concerns,
   and caveats.
3. **An "Unassessed" display** for a High whose every reason rests on
   statements in full text that was not searched.

The desktop shows unqualified ratings. A reader of a desktop report learns
that a study is "HIGH RISK" and which factors were present, but not which
rule decided it, nor that it was rated from metadata alone.

## What the desktop already does differently

Python fixed the underlying defect in its **scoring** (#352, #353, #359), where
Swift and Android fixed it in the **display**:

- COI `not_stated` (−5, and on its own a High) is recorded only when the full
  text was read *and* its end matter was parsed
  (`_analyze_coi`, `study_transparency_analyzer.py` ~3300). Otherwise it is
  `not_assessed`, which scores 0 and is not a trigger.
- Data availability `not_stated` (−5, and a trigger together with industry
  funding) is recorded only from a full text that was read and segmented, or
  from Europe PMC XML that was read and holds sections
  (`_analyze_data_availability`, ~3400-3520). Otherwise it is `unknown`, which
  is neutral.

So on the desktop **no High can rest on an absence nobody looked for**. Swift's
Unassessed rule (`isUnassessed` / `dependsOnFullText`) and its "(full text not
searched)" qualifiers could never fire here. **They are not ported** (user
decision, 2026-09-27). A test pins the invariant instead, and the parity README
records why.

The same study can therefore read "Unassessed" on Swift and "Low · limited"
(COI not assessed) on the desktop. That divergence is #357, not this change.

Two more things need no port:

- **Certainty is two-state on the desktop.** Every row the desktop shows is
  current (`is_current`, analyser ≥ 2.2); older rows are withheld as "Not
  assessed". `full_text_analyzed` is therefore always recorded on a shown row,
  and Swift's `unrecorded` state has no desktop counterpart.
- **The stale caveat.** A stale row is never shown.

Also not ported:

- **Swift's "No CrossRef record was retrieved" caveat.** The desktop row does
  not store which sources answered, and a CrossRef outage already reaches
  `warnings`. That caveat belongs with #391.
- **Swift's errors caveat.** Desktop rows store no `errors`.

## Design

### 1. One function for the score, one for the rating

`study_transparency_analyzer.py`:

- `ScoreComponent` is a frozen dataclass with `label: str`, `points: int` and
  `records_missing_statement: bool`. It gets `signed_points()`, which gives
  `"+5"` or `"-10"`.
- `score_components(report) -> list[ScoreComponent]` follows today's
  `calculate_transparency_score` term by term, in the same order. Its labels
  are Swift's, verbatim:
  - `Starting score` (+50)
  - `Data availability: <display name, lowercased>`. The display names are
    Fully Open / Available on Request / Restricted / Not Available / Not
    Stated / Unknown.
  - `Conflict of interest statement present` (+5), then, for a statement that
    discloses ties, `Conflict of interest statement discloses industry ties`
    (−5).
  - `No conflict of interest statement found` (−5). This is emitted for
    `NOT_STATED` only; `NOT_ASSESSED` has no term.
  - `Trial registered` (+10), then either `Trial results posted on time` (+5)
    or `Trial results not posted` (−10).
  - `Outcome switching detected` (−15)
  - `Industry ties with restricted or unavailable data` (−10)

  Zero-point terms are dropped, and the starting score always comes first.
- `calculate_transparency_score(report)` returns the sum of those components,
  clamped to 0-100. Its return type (float) and its values are unchanged.
- `TransparencyReport.score_components` is set where `transparency_score` is
  set.

`transparency/transparency_models.py`:

- `HighRiskTrigger` has three frozen variants: `ScoreBelowThreshold(score,
  threshold)`, `IndustryFundingWithWithheldData(data_level)` and
  `MissingCoiStatement()`.
- `high_risk_triggers(score, industry_funding, data_availability,
  coi_disclosure, settings) -> list[HighRiskTrigger]` returns every matching
  rule in check order, and honours the desktop's settings toggles.
- `calculate_risk_level` returns HIGH exactly when that list is non-empty.
  Otherwise the Medium/Low logic is unchanged.
- `high_risk_triggers_for(result, settings)` evaluates a stored row.
- `TransparencyResult.score_components: Optional[tuple[ScoreComponent, ...]] =
  None`, where `None` means not recorded. It goes through
  `to_dict`/`from_dict` as a list of `{label, points,
  records_missing_statement}`.

`transparency/assessment.py`:

- Copies the components onto the result.
- `full_text_supplied` becomes "non-blank", as Swift's is.

`storage.py`:

- A `score_components TEXT` column holding JSON. The `ALTER TABLE` migration
  mirrors the `sources_unreachable` one.
- The column is written by `save_transparency_result` and read by
  `_transparency_result_from_row`.
- An undecodable value makes the row undecodable, the same as any other
  column (the #374 path).

There is **no analyser version bump**. Scores, levels, indicators and caveats
are unchanged for the same inputs; the only difference is that new rows record
their terms.

### 2. The explanation

New pure module, `transparency/risk_explanation.py`:

- `TransparencyRiskExplanation.of(result, settings)` has these fields:
  - `score`
  - `reasons`: one sentence per trigger
  - `score_breakdown`: `result.score_components`, only when
    `ScoreBelowThreshold` is among the triggers
  - `breakdown_unrecorded`: true when the breakdown is wanted but the row has
    none
  - `other_concerns`
  - `caveats`
  - `certainty_note`: the limited note when `not result.full_text_analyzed`,
    else `None`
- **Reason sentences.** These are Swift's `.fullText` variants, which on the
  desktop are true whenever the trigger fires:
  - `Its transparency score of {score}/100 is below the high-risk cut-off of {threshold}.`
  - `Industry funding was detected, with {percent}% confidence, and {data phrase}.`
    - The funder names are omitted, because they are not stored. Swift's
      template already allows an empty funder list.
    - The data phrase is one of: `its data are available only with
      restrictions`, `its data are not available`, or `no data availability
      statement was found in the full text`.
    - The percentage is rounded half away from zero, as Swift's `.rounded()`
      does. Python's `round()` would not match it.
  - `No conflict of interest statement was found in the full text. A missing statement is enough on its own for a high rating.`
- **Other concerns** are `risk_indicators` plus `warnings`, de-duplicated, less
  the strings a stated reason already says:
  - The COI trigger removes `RISK_INDICATOR_MISSING_COI_STATEMENT`. Swift
    also removes its "Industry funding detected but no COI statement found"
    discrepancy warning, which Python never raises.
  - The industry-data trigger removes `RISK_INDICATOR_INDUSTRY_FUNDING` and
    `RISK_INDICATOR_INDUSTRY_RESTRICTED_DATA`.
- **Caveats**, in order:
  1. `None of the current high-risk rules matches this study's recorded
     findings, so the rating probably comes from an earlier version of the
     analysis. Re-analyse the study before relying on it.` This applies when
     the row is HIGH and no trigger matches under the current settings.
  2. The provisional caveat, when `sources_unreachable`.
  3. When the breakdown is wanted but not available: `How the score was
     reached is not available for this analysis; re-analyse the study to see
     it.` This applies both to a row stored before its terms were recorded and
     to one whose stored terms could not be read back. In the second case the
     unreadable-column caveat among the other concerns says why. This caveat
     is desktop-only and is not in the contract.

### 3. Surfaces

**Badge (`gui/transparency_badge.py`, `TransparencyBadge`)**

- The label gains ` · limited` when `not full_text_analyzed`, e.g. "High Risk
  · limited", or "High · limited" when compact.
- The tooltip carries the certainty note directly under "Risk Level". For a
  High, it adds a "Rated high risk because" list of the reasons. It adds an
  explicit provisional caveat line, instead of relying on `warnings` alone.
- The italic "Analysis includes full text" line is replaced by the absence of
  the note, as on Swift.

**Report reference annotation (`format_reference_risk_annotation`)**

- A certainty note line when the full text was not analysed.
- The provisional line uses the shared provisional caveat, replacing the
  desktop's own wording.

**Report section (`agents/reporting_agent.py`)**

- The new `## Why Studies Were Rated High Transparency Risk` section sits
  between References and Methodology.
- It covers every cited, shown (current, not withheld) row rated HIGH. It does
  not depend on `report_risk_threshold`, which governs warnings rather than
  what a High means.
- The section begins with the shared introduction, then one block per study:
  1. `N. <author reference>`, where N is the reference number.
  2. `Transparency score: S/100`.
  3. The certainty note, when there is one.
  4. The labelled lists: `Rated high risk because`, `How the score was
     reached` (`- <label>: <signed points>`), `Other concerns recorded` and
     `Caveats`.
- The section is omitted when no cited study is High.

**Methodology section**

- A limited-certainty line after the distribution: `N of M ratings were made
  without the full text. Limited certainty because of lack of full text
  access.`
- A provisional line: `**Provisional:** N ratings were made while a source the
  analysis needed could not be read; each rests on less than the full record
  and is re-analysed on the next pass.`
- Both come from new `TransparencyCounts.limited` and
  `TransparencyCounts.provisional` counts over the shown rows. They are carried
  on `ReportMetadata` and filled in `_record_transparency_counts`.

**Out of scope**

- The batch CSV and summary, which are #409 and #411.
- The analyser's own CLI.
- `TransparencyBadgeSmall`, which has no production caller.

### 4. The shared contract

New file: `doc/cross_platform/transparency_parity/risk_explanation_strings.json`.

- **`strings`:** exact constants.
  - The limited note and the badge suffix.
  - The section heading and the four labels.
  - The introduction's one-study and many-study forms.
  - The no-rule-matches caveat and the provisional caveat.
  - Every score-component label, and every data phrase.
  - The reason sentences, as templates with named `{placeholders}`.
- **`cases`:** a handful of platform-neutral inputs (score, industry funding
  and confidence, data level, COI `disclosed`/`not_stated`,
  `full_text_searched`, provisional, components) and the expected reasons,
  breakdown lines and caveats. Each platform builds a result from a case and
  compares its explanation.
  - Cases that exercise a missing statement use `full_text_searched: true`,
    the only form the desktop can produce.
- **Swift/Kotlin-only strings** are listed under a key that names the
  platforms it binds: the unrecorded note, the unassessed label, note and
  summary, and the limited/unrecorded sentence variants.

Tests:

- Python: `tests/test_transparency_parity.py`, or a sibling test file.
- Swift: `Packages/BioMedLit`, next to `TransparencyRiskExplanationTests`.
- Kotlin: next to `TransparencyRiskExplanationTest`.

Swift and Kotlin sources change only if a string differs. None is expected
to, apart from possibly the provisional caveat.

The parity README gains the file's description and the "why Python has no
Unassessed rule" note.

### 5. Testing (test-first)

- The components sum to the score, clamped, across a table of varied reports.
- The labels match the contract.
- The triggers are non-empty exactly when `calculate_risk_level` returns HIGH,
  under default and toggled settings.
- **Invariant:** a missing statement is only ever charged against text that
  was read.
  - COI `not_stated` implies `full_text_analyzed`.
  - Data `not_stated` implies the full text or Europe PMC XML sections were
    read.
  - An analysis that read neither never produces a missing-statement trigger.

  This is why the explanation needs no "not searched" variants. The Europe PMC
  XML path can record data `not_stated` while `full_text_analyzed` is False: the
  data sentence then still reads "in the full text", truthfully, while the
  certainty note says the rating as a whole is limited, since COI was not read
  from that text.
  - This is driven through the analyser with stubbed sources.
  - It is mutation-checked: forcing `not_stated` in the no-full-text branch
    must fail it.
- Storage round-trip, the migration of an old table, and `None` for rows
  without the column.
- The badge label and tooltip, both limited and full text.
- The report section and methodology lines, asserted as whole built sentences.
  They are absent when there is nothing to say.
- A HIGH row that no current rule matches, after a settings change, gets the
  caveat.
- Gates: the full `pytest`, `lint_delta.py`, `swift test` in
  `Packages/BioMedLit`, and `./gradlew test`.
