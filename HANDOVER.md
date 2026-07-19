# HANDOVER

Working notes for picking up in-flight work. Each section is one self-contained
slice: what's known, where to start, and how to verify. Remove a section once
its slice has landed; add a new section when handing off new work.

---

## Recently landed (context)

- **Data-availability negation scope** (2026-07-19, closes #117): detached
  negators no longer over-match FULL_OPEN. The `(?<!not )` lookbehind on the
  full-open affirmations is *fixed-width*, so it only suppressed an
  **immediately** negated affirmation; an intervening word ("not currently
  openly available"), an alternate negator ("never openly shared"), doubled
  whitespace, or a modal outside the strong-refusal `(?:would|will|shall)`
  alternation ("could not be openly shared") all escaped it and reported the
  study as fully open. The supplement affirmation had the same hole ("not
  currently available in the supplementary materials").
  - **Why not a wider lookbehind:** Python's `re` forbids variable-length
    lookbehind, and the patterns must stay byte-identical Python↔Swift↔Android.
    The guard is therefore a *forward* match — `NEGATED_OPENNESS_PATTERNS` /
    `negatedOpennessPatterns`: negator, ≤2 intervening words, affirmation.
  - **The `(?!and\b|but\b|or\b)` barrier is load-bearing**, as is the bounded
    window. Both stop the scope reaching across a conjunction into an
    affirmation the negator does not govern — "data were not embargoed **and**
    were openly shared" must stay FULL_OPEN. Removing either under-reports
    genuinely open data. Pinned by
    `test_negation_scope_stops_at_coordinating_conjunction` and
    `test_negation_scope_window_is_bounded` on all three platforms.
  - **The pins only work at specific sentence shapes — do not reword them.**
    As first written (PR #124) neither test actually exercised its guard: both
    passed for unrelated reasons, and the barrier could be deleted from all
    three platforms with the entire tri-platform suite staying green. Fixed in
    review; mutation-verified on Python, Swift *and* Kotlin (each guard removed
    in turn ⇒ exactly its own test fails). The two traps:
    - The **conjunction must sit inside the two-word window**, immediately
      before the affirmation ("not embargoed **and** openly shared"). In "not
      embargoed and *were* openly shared" the affirmation is three words out, so
      `{0,2}` blocks it first and the barrier is never consulted.
    - The window pin needs a **real negator** — `not`/`never`/`cannot`. "No" is
      not in the alternation, so a sentence negated only by "No" matches nothing
      at any window size. It also needs **no punctuation** between negator and
      affirmation, because `\w+` cannot cross punctuation and the punctuation
      would become what holds the line instead of the bound.
  - **Invariant now documented at each `has_unavailability_signal` site:** every
    list joined there must also be reachable from Step 2 or Step 3. A pattern
    added to the signal check alone suppresses Step 1 without supplying a
    replacement tier, silently landing the statement in UNKNOWN rather than
    FULL_OPEN — a regression no existing test would catch.
  - Tiering: negated openness is in the **restricted** tier, not
    `STRONG_REFUSAL_PATTERNS`. It suppresses the affirmation and adds the label
    "Data not openly available"; escalation to NOT_AVAILABLE still requires an
    independent strong refusal. This keeps the #113-pinned "not openly
    accessible without IRB approval" → RESTRICTED. Two existing tests gained
    the new label in their expected `restrictions` lists (tiers unchanged).
  - **Kotlin gotcha:** `negatedOpennessPatterns` must be declared *before*
    `restrictedPatterns` — Kotlin initialises `object` properties in declaration
    order, so a forward reference appends nothing and silently leaves the bug
    unfixed. `DataRepositoryPatternsTest` pins list size 25 + `containsAll` to
    catch that. Swift statics are lazy and Python is module-order, so only
    Kotlin is exposed.
- **Android PubMed XML parsing** (2026-07-18, #119/PR #122): `parseArticleXml`
  moved off Android's `XmlPullParser` (which throws "not mocked" under plain
  JUnit, and whose exception the broad catch swallowed into an empty result) to
  a pure-JVM JAXP SAX parser, so it runs in unit tests *and* on-device. Two
  traps worth preserving if this is touched again:
  - **`setXIncludeAware` is deliberately not called** — JAXP's base
    implementation throws `UnsupportedOperationException`, which the outer catch
    would swallow into an empty result on-device while JVM tests stayed green:
    the #119 failure mode exactly.
  - **The XXE tests point `systemId` at a closed loopback port
    (`http://127.0.0.1:1/…`), not the real `dtd.nlm.nih.gov` URL.** An
    unhardened parser *fetches* the real NLM systemId successfully (11.2s vs
    1ms), so a realistic systemId passes either way and guards nothing.
- **Transparency parity, earlier slices** (2026-07-16/18, all merged): Swift↔Python
  data-availability parity (#101/#103); full-open over-match + refusal precedence
  (#106, #107); GDPR/HIPAA/privacy/patient-consent restore (#104); Python Step-3
  label dedup (#114); privacy/legal open-data false-positive + negation guards
  (#113); Android data-availability classifier port (#116 slice 1, PR #120) —
  `RegexHelper` compiles with `(?U)` so `\w\s\b\d` match Unicode like
  Python/Swift; **reused slices must keep this** or non-ASCII input diverges.
  Python `study_transparency_analyzer.py` is the canonical reference; Swift
  `BioMedLit` and Android `domain.transparency` mirror it byte-for-byte.

## Potential follow-ups

- **#123 — Android parse errors are swallowed (golden rule 8)**: `parseArticleXml`
  ends its catch with `printStackTrace()` — the only such call left in
  `app/src/main` — so a truncated EFetch batch silently under-reports articles and
  a genuine parser defect looks identical to malformed input. Blocked on a
  JVM-portable logging seam: a plain `Log.e` would reintroduce the untestable
  Android dependency #119 was about (no `testOptions` ⇒ `Log` throws "not mocked"
  under JUnit). Overlaps #121.
- **#121 — JATS parser untestable like PubMed was**: `util.jats.JATSXMLParser`
  also uses Android `XmlPullParser`, so its only coverage is a network-gated
  integration test (`Assume.assumeTrue(INTEGRATION_TESTS==1)`). Migrating it to
  the JAXP SAX approach used for `PubMedService` would make it unit-testable
  offline — see the two traps noted above.
- **Android transparency, remaining #116 slices**: COI analyzer, scorer + risk
  indicators, funding/trial (network), JATS statement extraction, Room
  persistence + `DocumentCard` UI.
- **#125 — "no longer openly available" still over-matches FULL_OPEN**: residual
  of #117, found reviewing PR #124. The negator alternation is
  `(?:not|never|cannot)`; **`no` is absent**, so "data are no longer openly
  available", "by no means openly available" and "neither … nor … openly
  available" all still report FULL_OPEN — the same dangerous
  over-stating-openness direction #117 closed for detached negators. Not fixed
  there because adding `no` needs its own false-positive round ("no restrictions
  apply and data are openly available"), and `neither … nor` is a two-token
  negator the single-token alternation cannot express at all.
- **#126 — redundant "Data not openly available" label** (cosmetic): emitted
  alongside a more specific label for the same clause ("Data cannot be shared",
  "Requires IRB approval"). Tiers are correct; presentation noise only.
- **#109 — LLM-assisted disambiguation of repo + soft-restriction**: a repo
  mention + a *soft* on-request restriction is kept FULL_OPEN today; add an
  optional config-gated deterministic-fallback LLM layer at the orchestration
  layer, leaving the pure classifier + parity tests unchanged.
- **#105 — automated Swift↔Python↔Android parity drift guard**: a shared
  language-neutral fixture asserted on all sides to catch silent divergence.
  #117 added a throwaway byte-identity check across the three pattern lists;
  worth generalising into the permanent guard this issue describes.
- **#111 — cache compiled regexes in Swift `RegexHelper`** (`anyMatch` recompiles
  per call). Negligible today; memoize if it ever hits a hot path.
- **Swift risk *level* heuristic** (`TransparencyScorer.calculateRiskLevel`) has
  no Python counterpart; revisit only if a canonical definition is introduced.

### Verify

- `pytest tests/` → 0 failures (Python is the reference).
- `cd Packages/BioMedLit && swift test` → 0 failures.
- Android: `cd android/MedicalFactChecker && ./gradlew test` → 0 failures.
- macOS app still builds: `xcodebuild -scheme MedicalFactChecker -destination
  'platform=macOS' build` from `ios/MedicalFactChecker/`.
- `ruff check .` / `mypy src/` carry pre-existing debt; the gate is **no new
  errors** (baseline at time of writing: 97 ruff findings on the transparency
  analyzer + tests, 677 mypy errors across `src/`).
