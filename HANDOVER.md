# HANDOVER

Working notes for picking up in-flight work. Each section is one self-contained
slice: what's known, where to start, and how to verify. Remove a section once
its slice has landed; add a new section when handing off new work.

---

## Recently landed (context)

- **Android PubMed/LLM unit-test failures fixed** (2026-07-18, closes #119):
  the 7 pre-existing Android failures that #116's compile fix unmasked
  (`PubMedServiceTest` ×6, `LLMServiceTest` ×1). Root causes were **not** stale
  tests:
  - `PubMedService.parseArticleXml` built its parser via Android's
    `org.xmlpull.v1.XmlPullParserFactory`, which under plain JUnit comes from the
    stub `android.jar` and throws `RuntimeException("… not mocked")`. The broad
    `catch (e) { printStackTrace() }` swallowed it → every parse returned an empty
    list. **Rewrote `parseArticleXml` to a JAXP SAX parser** (`SAXParserFactory` +
    new inner `PubMedXmlHandler : DefaultHandler`) — pure-JVM, so it runs in unit
    tests *and* on-device — extracting the same fields. The handler snapshots its
    character buffer only at the boundaries of the extracted (`TEXT_ELEMENTS`)
    tags, so inline markup inside a title/abstract (`<i>`, `<sup>` — species
    names, exponents) is preserved rather than dropped; a markup-terminated title
    is no longer lost (which under a naive per-`startElement` reset would return a
    null title and silently drop the whole article). Hardened against XXE /
    external-DTD network fetches (`SAFE_SAX_FEATURES` — including
    `FEATURE_SECURE_PROCESSING`, which caps internal entity expansion because
    Android's Expat parser gives no default "billion laughs" limit — plus a no-op
    `resolveEntity`). Every flag goes through `setFeature` inside a per-flag
    `try/catch`, so an implementation that does not recognise one skips it.
    **`setXIncludeAware` is deliberately not called**: JAXP's base implementation
    throws `UnsupportedOperationException` unless overridden, which the outer catch
    would swallow into an empty result on-device while JVM tests stayed green — the
    #119 failure mode exactly. New regression tests:
    `search parses XML with DOCTYPE …`, `search blocks external entity references
    …`, `search preserves text around inline markup …`, and `search returns
    articles decoded before malformed XML aborts the parse` (pins the deliberate
    partial-result contract). **The two security tests point their `systemId` at a
    closed loopback port (`http://127.0.0.1:1/…`), not at the real
    `dtd.nlm.nih.gov` URL — that is load-bearing.** An unhardened parser *fetches*
    the real NLM systemId successfully (measured: 11.2s vs 1ms), so a realistic
    systemId makes the test pass either way and guards nothing; against a closed
    port the unhardened parser fails with `ConnectException`. Both tests were
    verified red by temporarily removing the hardening.
  - The `createSampleXml` test helper emitted a leading-whitespace-before-`<?xml>`
    prolog (an artifact of interpolating a multi-line block into `trimIndent()`),
    which strict SAX correctly rejects ("processing instruction … not allowed");
    kxml2 had been lenient. Fixed the helper to emit the declaration at column 0.
  - `LLMServiceTest.convertToPubMedQuery returns query on success` tested the
    `@Deprecated convertToPubMedQuery` method, which has **no production callers**
    and now routes through `convertToStructuredQuery` + `PubMedQueryBuilder`.
    Removed the dead method and its stale test. `PubMedQueryBuilder` stays (used
    by `ResponseParser`/`QueryBuilder`/`FactCheckWorkflow`).
  - Result: full Android suite green (515 tests, 0 fail, 18 network-gated skips).
    The `ReportUiEventTest` compile fix and the 5 stale-value test updates
    referenced by #119 already landed with #116 (PR #120) — not re-touched here.
  - Deliberately **not** fixed here, lodged as **#123**: `parseArticleXml` still
    ends its catch with `printStackTrace()`, violating golden rule 8 (errors must
    be logged and reported to the user). The obvious `Log.e` fix would reintroduce
    the exact defect this slice removed — `app/build.gradle.kts` sets no
    `testOptions`, so `unitTests.isReturnDefaultValues` is `false` and
    `android.util.Log` throws "not mocked" under plain JUnit, which would make the
    error path untestable again. Needs a JVM-portable logging seam first.
- **Android data-availability classifier, Slice 1** (2026-07-18, #116/PR #120):
  pure-Kotlin port of the canonical (Python/Swift) classifier in
  `domain.transparency` (`DataDisclosureLevel`, `DataAvailabilityResult`,
  `RegexHelper`, `DataRepositoryPatterns`, `DataAvailabilityAnalyzer`),
  byte-identical patterns to the merged #113 canonical. `RegexHelper` compiles
  with `(?U)` so `\w\s\b\d` match Unicode like Python/Swift — **reused slices must
  keep this** or non-ASCII input silently diverges. 45 mirrored JUnit4 tests.
  Remaining #116 slices below.
- **Transparency parity, earlier slices** (2026-07-16/17, all merged): Swift↔Python
  data-availability parity (#101/PR #100/#103); full-open over-match + refusal
  precedence fixes (#106, #107, PR #108); GDPR/HIPAA/privacy/patient-consent
  restore (#104); Python Step-3 label dedup (#114); privacy/legal open-data
  false-positive fix + negation guards (#113/PR #118). Python
  (`study_transparency_analyzer.py`) is the canonical reference; Swift `BioMedLit`
  and Android `domain.transparency` mirror it. Details in the linked PRs and
  `docs/superpowers/{specs,plans}/2026-07-17-*`.

## Potential follow-ups

- **#123 — Android parse errors are swallowed (golden rule 8)**: `parseArticleXml`
  ends its catch with `printStackTrace()` — the only such call left in
  `app/src/main` — so a truncated EFetch batch silently under-reports articles and
  a genuine parser defect looks identical to malformed input. Blocked on a
  JVM-portable logging seam: a plain `Log.e` would reintroduce the untestable
  Android dependency #119 was about (no `testOptions` ⇒ `Log` throws "not mocked"
  under JUnit). Overlaps #121.
- **#117 — negated open-availability affirmations still over-match FULL_OPEN**:
  residual of #113. Non-adjacent / alternate-negator forms ("never openly
  shared", "could not be openly shared", "not currently openly available",
  double-spaced "not  openly") still classify FULL_OPEN instead of NOT_AVAILABLE.
  Fix mirrored across Python + Swift + Android `DataRepositoryPatterns`.
- **#121 — JATS parser untestable like PubMed was** (from #119): `util.jats.
  JATSXMLParser` also uses Android `XmlPullParser`, so its only coverage is a
  network-gated integration test (`Assume.assumeTrue(INTEGRATION_TESTS==1)`).
  Migrating it to the same JAXP SAX approach used for `PubMedService` would make
  it unit-testable offline.
- **Android transparency, remaining #116 slices**: COI analyzer, scorer + risk
  indicators, funding/trial (network), JATS statement extraction, Room
  persistence + `DocumentCard` UI.
- **#109 — LLM-assisted disambiguation of repo + soft-restriction**: a repo
  mention + a *soft* on-request restriction is kept FULL_OPEN today; add an
  optional config-gated deterministic-fallback LLM layer at the orchestration
  layer, leaving the pure classifier + parity tests unchanged.
- **#105 — automated Swift↔Python(↔Android) parity drift guard**: a shared
  language-neutral fixture asserted on all sides to catch silent divergence.
- **#111 — cache compiled regexes in Swift `RegexHelper`** (`anyMatch` recompiles
  per call). Negligible today; memoize if it ever hits a hot path.
- **Swift risk *level* heuristic** (`TransparencyScorer.calculateRiskLevel`) has
  no Python counterpart; revisit only if a canonical definition is introduced.

### Verify

- Android: `cd android/MedicalFactChecker && ./gradlew test` → 0 failures.
- `cd Packages/BioMedLit && swift test` → 0 failures.
- `pytest tests/` → 0 failures (Python is the reference).
- macOS app still builds: `xcodebuild -scheme MedicalFactChecker -destination
  'platform=macOS' build` from `ios/MedicalFactChecker/`.
