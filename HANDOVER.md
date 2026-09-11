# HANDOVER

Working notes for picking up in-flight work. Each section is one self-contained
slice: what's known, where to start, and how to verify. Remove a section once
its slice has landed; add a new section when handing off new work.

---

## In flight

Nothing. Pick a slice from **Potential follow-ups** below.

## Recently landed (context)

Compressed once a slice is merged: what remains is the rule that still binds,
not the archaeology. Git history and the `doc/cross_platform/` READMEs carry
the rest.

- **A document's identity may not claim what the article is** (#208, 2026-09-11).
  Rules that still bind:
  - **An identity is opaque and unique by construction.** `Document.id` is a
    UUID. It was `"pmid-\(pmid)"` over the primary identifier slot, which is two
    mistakes: `.unique` is gone for CloudKit so nothing rejected the duplicates
    an empty slot produced, and the string *asserted a namespace* the slot cannot
    vouch for. Pinned by a SwiftData round trip which, before the fix, returned
    the second article when asked for the first.
  - **The empty-slot half was narrower than #208 claimed — re-measure before
    quoting.** Europe PMC always sends `id`, so `pmid ?? id ?? ""` is never empty
    from a search: 0 of 100 `SRC:ETH OR SRC:CBA OR SRC:HIR` and 0 of 100
    `SRC:PPR` records lacked one, measured 2026-09-11. The collision was
    reachable only in principle. The namespace half was live for 1,236,785
    preprints and 322,044 thesis and case-report records.
  - **A renderer that cannot see the documents may not name an identifier.**
    `PDFExporter` and both `PrintableReportView`s turned `doc:pmid-889149` into
    `(PMID: 889149)` in the exported body — #212 exactly, on the three surfaces
    #218 missed, in a document that outlives the app. `ReportFormatter` now owns
    this: `flattenedReferenceLinks(in:)` for a renderer that parses emphasis
    itself, `plainText(fromReportMarkdown:)` for one that does not.
  - **"Three identical private copies" was wrong, and the review caught it.**
    They were not identical: both `PrintableReportView` copies also stripped
    `**` and `__`, while `PDFExporter` needed `**` to survive so
    `drawFormattedText` could set a bold font. Consolidating onto one function
    dropped the emphasis stripping into a plain `Text(_:)`, which renders
    markers literally. Hence two functions. **Before deduplicating, diff the
    copies — do not trust the claim that they match, including your own.**
  - **The reader-facing surface is `plainTextReport`, not the print views.**
    Both `PrintableReportView`s are instantiated nowhere (#221) and macOS PDF
    export is a stub, so the three surfaces #226 first fixed reach a reader on
    iOS only. `EvidenceReport.plainTextReport` feeds the clipboard and share
    sheet on iOS and the clipboard and *Export as Text* on macOS, and it
    interpolated `fullReport` raw. **When fixing a rendering defect, find the
    surface a user actually reaches before enumerating the ones that look
    alike.**
  - **No migration, and none needed.** Stored rows keep the identity they were
    given, so a report saved before this resolves by exact match. Nothing may
    reconstruct an identity from an article's fields.
  - **The report prompt's example is a UUID now.** Shown `doc:pmid-12345678`, a
    model told to copy IDs verbatim is also being invited to write "PMID
    12345678" into the prose, where no later renderer can tell it was never one.
  - **A gate must ask exactly what the thing it gates asks.**
    `canAnalyzeTransparency` read the raw slot while the analyser is passed
    `Document.pubmedID`, so a thesis with no DOI — 60 of 100 such records — was
    offered a button that threw `noIdentifiers`. Now `pubmedID != nil ||
    usableDOI != nil`; `pmcId` is deliberately not a third rung, because the
    analyser has no route that starts from one. `usableDOI` trims, because a
    provider's JSON can send `""` and `doi != nil` reads that as present.
  - **A shared gate is only shared if every caller reads it.** The docstring
    said the report views and the workflow agree on eligibility; the workflow
    filtered on score and staleness only, called `analyze`, and swallowed the
    guaranteed `noIdentifiers` into a warning. It now reads the gate, separates
    cancellation from failure, logs the identity rather than the empty slot, and
    reports failures to the user. **A claim in a docstring is not a call site.**
  - **Six document lists identified rows by `\.pmid`**, the same mistake one
    layer up; they use `\.id`.
  - Lodged rather than fixed: **#224** (an unresolvable report reference is a
    silent no-op on both platforms, golden rule 8 — wants the lookup lifted out
    of the view, where it can be tested), **#225** (two dead file-path constants,
    one of them spelling `"pmid-"`).

- **A PubMed URL may only be built from a stated PubMed ID** (#212 + #213 in PR
  #218, 2026-09-11). The full contract is in
  `doc/cross_platform/fulltext_retrieval.md`. Rules that still bind:
  - **The shape of a number never states a PubMed ID.** Europe PMC's theses
    (`ETH`), case reports (`CBA`) and `HIR` records carry bare decimal
    accessions and no PMID — 322,044 with abstracts, measured 2026-09-11.
    Pasted after the PubMed base URL such an accession returns a **real but
    unrelated article**: thesis `889149` is also the PMID of a 1977
    mouse-courtship paper. A dead link tells the reader something is wrong; a
    live link to the wrong paper does not.
  - **Three sources of knowledge, strongest first** — the record's stated token,
    the identifier's shape where a prefix settles it, then the provider.
    `SearchProvider.pubmed` vouches for a bare decimal, which keeps every legacy
    row on the default provider linking. **`.both` vouches for nothing**: the app
    records the *search mode* on every document a merged search produces,
    including the ones only Europe PMC returned, so the provider must reach the
    resolver unflattened. An adapter that collapsed `both` to `.pubmed` existed
    and was deleted.
  - **One predicate authorises every PubMed URL and every `PMID:` line** —
    `ArticleIdentifierKind.pubmedID(in:declared:)`, reached from the app through
    `Document.pubmedURL` / `Document.citationIdentifier`. Stated as an invariant,
    not a count of today's callers: the review found three surfaces the first
    pass had missed, including the transparency analyser, which searched PubMed
    with the raw slot and filed an unrelated article's funding under this
    document.
  - **A citation names the namespace it can prove**: `PMID:`, `PMCID:`,
    `Europe PMC:`, and nothing where neither the record nor the provider names
    one. Carried as `CitationIdentifier` — namespace and value kept apart,
    because a printed citation wants `PMID: 12662058` and a clipboard wants
    `12662058`.
  - **A stated-but-unmodelled source tags `src_`, not `id_`**, or a stated `ETH`
    accession and an unclassified identifier with the same digits share a cache
    filename. `inferred(from:)` is prefix-only, and the retag orphaned any PDF
    already cached for such a record.
  - **The defect is Swift-only by construction.** Only Swift's `SearchArticle`
    collapses the identifiers into one slot. Kotlin is safe by nullability;
    Python by *package boundary* — its one URL builder takes a non-optional
    `pmid: str` on `PubMedArticle`, only ever constructed inside the PubMed-only
    package. Any port that introduces a collapsed slot inherits all of this.
  - **A refusal is not a fact about the article.**
    `FullTextError.identifierKindUnresolved` exists because sharing
    `noFullTextAvailable` made an internal refusal a permanent claim that the
    paper has no full text anywhere. Callers must keep matching
    `noFullTextAvailable` alone.
  - **Known cost, accepted:** a document stored before the kind field existed,
    from a Europe PMC or `both` search, loses its PubMed link and its citation
    identifier. Where the link is gone the card says so and offers the accession
    to search with, rather than leaving the empty space that was #187.
  - Still open from that round: **#217** (the error queue labels every entry's
    identifier `PMID`), **#219** (make the invariant structural), **#220**
    (Android has the same ungated URL builder), **#221** (`PrintableReportView`
    exists twice and is instantiated nowhere), **#222** (a legacy card can show
    a PubMed badge beside no PubMed link), **#223** (a malformed source token
    warns once per SwiftUI redraw).

- **Europe PMC's own word for what an identifier is** (#209 in PR #211,
  2026-09-10). Rules that still bind:
  - **The kind is stated, not guessed** — built from the record's `source` at the
    decode site, carried on `SearchArticle`, stored on `Document` as the token
    itself, passed back into `fetchFullText`. **A stored `nil` means "nobody
    stated one"**, for four reasons one column cannot tell apart; do not read it
    as "pre-dates the field" when planning a backfill.
  - **The cache tag names the kind, not the rung.** A PMC-only record carries its
    accession in the primary slot *and* in `pmcId`, so tagging the rung filed one
    article under two names and downloaded its PDF twice.
  - **One seam for the five fetch surfaces** and **one writer for document
    creation** (`applySearchMetadata`). The workflow builds documents in **three**
    places; the third was found still hand-copying, in review, having shipped
    documents with no kind and no preprint flag. Nothing tests those paths:
    **#216**.
  - **A lookup by identifier must not filter preprints.** `EuropePMCService.search`
    appends ` NOT SRC:PPR` unless the query already contains that literal, so the
    DOI rung — a preprint's documented recovery path — could not match one.
    Pinned on the emitted URL, because an outcome assertion passes either way.
  - **The source token is refused outside `[a-z0-9]`, and the refusal is
    logged**: it reaches a query as `src:<token>` and a filename as a tag.
    **`isNumber` is not "all digits"** — true for `½` and every non-Latin
    numeral, so `١٢٣` classified as a PubMed ID. **`NBK` is not a Europe PMC
    source token** (`SRC:NBK` → 0 hits); the real unmodelled sources are `PAT`,
    `AGR`, `ETH`, `CBA`, `HIR`, `CTX`.
  - **Only Swift conforms**: **#205** (Android) and **#207** (Python) carry the
    ports, and Python's row is `no (#207)`, not "n/a" — `pdf_utils.py` does keep
    an untagged PDF cache.

- **An article without a PMID can reach its PDF** (#202 in PR #206, 2026-09-10).
  **An article is named by a *ladder*, not by its PMID** — the primary slot, the
  PMC ID, the DOI, each tagged with its kind, and **no two identifiers may share
  a name**, which is stronger than keeping the kinds apart: `sanitize` is not
  injective, so the DOI rung is digested outright and the other two carry a
  digest whenever sanitising changes the value. **The key comes from the
  document, never from `resolvedPmcId`** — a key that depended on whether a
  lookup succeeded would file one article under two names across runs; tagging
  orphans earlier entries rather than replacing them, and only `clearPDFCache()`
  reclaims them. **Europe PMC answers only in the identifier's own terms**,
  measured live, so fixing the cache key alone does *not* fix #202. **A query
  that matches nothing is logged.** **`doc/cross_platform/fulltext_retrieval.md`
  is the port contract**, and it specified a ladder Swift never implemented —
  the real root of #202.

- **A downloaded PDF now contributes its text** (PR #198, 2026-09-09). Spec:
  `docs/superpowers/specs/2026-09-09-ios-fulltext-pdf-extraction-design.md`.
  **Extraction serves analysis; display prefers the document** —
  `Document.displayedFullText` is the single seam deciding what the reader sees.
  **An abstract-only deposit is held back, not returned**: returned on the spot
  it beat every remaining tier, so an open-access PDF became unreachable and the
  abstract was analysed as the article. When no PDF tier answers the abstract
  *is* returned, so the consumer must check the kind —
  `Document.analyzableFullText`; **a `nil` stored content kind means "predates
  the field", not `.none`**. **Extraction coverage travels with the text, and is
  persisted**, or a ten-of-fourteen-page extraction reaches the analyser exactly
  as a whole article does. **A PDF tier's outcome has four states, not two** —
  the first two shared `(nil, nil)`, so a render URL that 404s ended the chain.
  **`fullTextPDFPath` holds a path or a URL string, and only the writer knows
  which**: ask `Document.localPDFFilePath`, write through `applyFullTextResult`.
  **The PDF fixtures are not byte-reproducible.**

- **Older rounds, compressed to the rules that still bind.** Git history and the
  `doc/cross_platform/` READMEs carry the rest; each rule below cost a defect.
  - **A redaction placeholder is only as good as the load path** (PR #195):
    `--json` printed `<redacted>`, a *truthy string* that saved back would go to
    NCBI as a credential. **A guard must name its own cause.** **Prefix-anchor a
    publisher branch, and check its neighbours** — PeerJ's `doi.split(".")[-1]`
    dropped the series, so every `peerj-cs` DOI resolved to an unrelated article.
  - **An unreachable source is not an absent one** (#186/#187). A source that
    answered "nothing" and a source we could not reach are opposite answers, and
    only the first is the evidence base's fault. **Raw values stay explicit**,
    never round-tripped through `init(rawValue:)`, which agrees with a rename and
    pins nothing. **Accumulate as a fold, never per branch.**
  - **A reader-facing payload must not be rendered English** (#184/#183):
    `JATSParseWarnings` carries typed losses and `diagnostics` is *derived*. **A
    tagged union's persisted form needs named keys and a `schemaVersion`** —
    synthesised `Codable` emits `{"_0":2}` (#163). **A 404 is not a
    degradation**: a warning over content that is fine trains a reader to dismiss
    the banner on the article that really lost text. **A view's private computed
    state cannot be tested**, so the banner's choice is a pure value.
  - **The clamp erased the evidence** (#180/#181): counters decremented as
    `max(0, n - 1)` and the audit only tested `> 0`, so a counter that clamped to
    0 read "balanced" and the audit **certified a defective parse as clean**. **A
    stack hides an over-pop just as the clamp did.** **Logging is not
    reporting** — warnings travel parser → service → document → banner, persisted
    because macOS renders only from the cache. **`isBalanced` is pinned against
    the losses via a `Mirror`**; a hand-written field list passes when a field is
    added to neither. **A refactor onto a shared writer is only safe where every
    caller wanted everything that writer does.** **A pbxproj UUID collision
    silently drops a file from the build.**
  - **Route markup on the owning element, not on ambient parser state**
    (#170/#173/#175, #156/#157/#161, #167/#169) — eight defects, one mistake.
    **Read `elementStack`**; every exhibit flag derives from one shared
    `ExhibitCollector` and is never stored, because a stored flag is what an
    inner exhibit's close tag clears while the outer one is still open, and a
    parser-wide counter has the same flaw. **Fix every site the predicate is
    asked at.** **A safety net installed where production never runs is not
    installed.** **`<graphic>` deposits are ranked, not positional** (`archival`
    < `thumbnail` < `full`, from `content-type` **or** `specific-use`, never the
    extension); **one parse per `JATSXMLParser` instance**. **bmlib is ahead of
    Swift — port from it**; Kotlin has none (#165).
  - **Measure prevalence from the XML, never through the parser** (#164):
    `scripts/jats_survey.py`. Asking the parser would agree with its own bugs,
    which is how #161/#162 survived a green suite.
  - **Real PMC JATS corpus** (#146): seven open-access articles under
    `doc/cross_platform/jats_corpus/`, each with a stored structural digest,
    parsed offline on every PR. **Read that directory's `README.md` before
    touching it.** Two traps it omits: **the fixture walk stops at the checkout
    root** in both `JATSRealCorpusTests` and `TransparencyParityTests` and they
    must not drift — worktrees live *inside* the checkout, so a climb to `/`
    validates a branch against the main checkout's fixtures and passes; and **a
    test only hears what the logger records** — the recorder ignored `debug`,
    where discarded captions are announced, so the corpus dropped 21 of 62
    captions under a green test of that name.
  - **Funder classification and sponsor tiers, Python↔Swift** (#143/#147/#152).
    Both platforms score precision 0.909 / recall 0.333. `sponsor_patterns.json`
    (schema_version 3) is the contract, asserted from both sides, and
    `confidence_probes` are checked *behaviourally* — a typo transcribed
    faithfully into every copy agrees with itself. **Never merge the funder lists
    into `INDUSTRY_KEYWORDS`**, which is COI *prose*, where corporate suffixes
    match far too freely. **A stem and a whole word are different kinds of
    thing**, and the failure is *silent*. **`NONPROFIT` means "not recognised"**,
    the modal outcome at 325/417 corpus names, raising a caveat keyed off the
    *funder*, not the tier — deliberate, pinned by `TestKnownPatternCollisions`,
    revisit on both platforms or neither. Deferred: #159, #160.
  - **CI on all three platforms** (#129). **No job may gain a `paths:` filter** —
    the parity fixtures live outside `src/` and `tests/`, so any plausible filter
    skips the run for a contract-only edit. **A Qt preflight constructs a
    `QApplication` before pytest**, since the widget suites open with
    `importorskip("PySide6")` and a broken Qt install would skip ~100 tests
    green. **`lint_delta.py` compares against the merge base** in a throwaway
    worktree outside the repo; identity is `(tool, path, code, message)`, no
    line/column. **Ruff config must stay in `[tool.ruff.lint]`** — under the
    deprecated top-level spelling, head and base would one day shrink together
    and the gate stay green over no rules.
  - **Model fetch failures are errors, not fallbacks** (PR #135):
    `ModelFetchService.fetchModels` *throws* on Swift and Kotlin rather than
    returning the hardcoded catalogue — a caller that cannot tell a live line-up
    from a hardcoded one cannot tell a retired model ID from a current one, which
    is how the DeepSeek V3 retirement went unnoticed. **Do not reintroduce a
    fallback inside the service**: the healing logic must only ever see a
    provider-supplied list, or it rewrites a valid stored selection whenever the
    network is down.
  - **Cross-platform parity drift guard** (#105) and the data-availability
    classifier's July slices (#101–#125). Python
    `study_transparency_analyzer.py` is canonical; Swift and Android mirror it
    byte-for-byte — for this classifier and, since #143, the funder-name one, but
    *not* `INDUSTRY_KEYWORDS` (#148). **The contract is
    `doc/cross_platform/transparency_parity/`, and its `README.md` carries the
    rationale, structural traps, mutation evidence and the two fixtures' division
    of labour — read it before touching a pattern.** Three things it does *not*
    carry: **do not remove the `inputs.dir` declaration in
    `app/build.gradle.kts`**, without which Gradle reports `UP-TO-DATE` for a
    contract-only edit and skips the Android parity test; **do not reword the
    pattern test fixtures**, because negated openness is matched forward — Python
    forbids a variable-length lookbehind — so the pins only work at specific
    sentence shapes; and **Kotlin's `negatedOpennessPatterns` must stay declared
    *before* `restrictedPatterns`**, since object properties initialise in
    declaration order and a forward reference silently appends nothing.
    `RegexHelper` compiles with `(?U)`.

## Potential follow-ups

### The #206 round: identifier identity, on the other two platforms

The Swift fix is one platform's half of a contract change. All of these are
independent of each other.

- **#214 — what the retrieval chain learns never reaches the reader or the error
  queue**, and **#215 — cache read and write failures are misreported as download
  failures**. Both are in `FullTextService`, and both are honesty-of-reporting
  work of the shape #183/#186/#187 established.
- **#216 — nothing tests `FactCheckWorkflow`'s three document-creation paths.**
  How the third hand-copying site survived the whole of #209.
- **#210 — macOS shows a preprint as plain "Europe PMC".** `MacScoredDocumentsView`
  draws `MacProviderBadge`, which takes no preprint flag, while the macOS badge
  that does is referenced only by its own preview. Dead until #209 made
  `isPreprint` real; live now, and the two platforms disagree about what they
  tell the reader.
- **#224 — an unresolvable report reference is a silent no-op**, on both
  platforms. `findDocumentById` answers `nil`, `selectedDocument` becomes `nil`,
  and nothing presents: golden rule 8, and untestable where it sits. The fix is
  to lift the resolution out of the view and fall back to the display-text
  lookup that already exists for references carrying no identity.
- **#205 — Android asks `src:med` for every identifier** (`FullTextService.kt:308`)
  and never asks for a PMC ID at all. A verbatim port of the Swift repair, plus
  the revised "Cache Keys" section **and the stated kind** (#209): route on the
  record's `source`, persist the token, tag the cache on the kind.
- **#207 — Python has no preprint routing, runs only the first matching rung,
  and puts the PMC rung first** (`europepmc.py`, `get_article_info`). Less
  severe than the Swift defect was, because Python keeps the identifiers in
  separate parameters and so never asks for a PMC accession under `src:med`.
  Also wants the stated kind (#209); it has no PDF cache, so the tag half of the
  contract does not apply.
- **#204 — unsectioned `<back>` routing sweeps `<ref-list>` apparatus into
  `bodySections`.** Found from bmlib's side. `case "p"` ends on the ambient
  `inBack`, so a `<ref-list>`'s own `<p>` and a `<ref>`'s `<note><p>` become
  article prose — "Faculty Opinions Recommendation", highlight keys, a bare DOI.
  Measured at 191 paragraphs in 39 of 8,117 served articles (0.47%) and 1,354 in
  307 of 97,909 (0.25%). Small, but a corruption rather than a blank, where
  everything else that widening recovers is content that was missing. **bmlib
  refuses `<ref-list>` and nothing else, decided by an ancestor test on the
  element stack** — a bare `inRefList` flag is re-admitted by a nested list's
  close tag. Port it, or record the divergence knowingly; bmlib has it in its
  own `docs/DECISIONS.md`.

### Extracted PDF text misrepresents an article to the transparency analyser

Three ways, all opened by PR #198 and all needing a decision that covers Python,
Swift and Kotlin rather than a Swift-side patch.

- **#199 — the extractors over-capture on PDF prose.** `PDFPage.string` emits no
  blank runs within a page, so page joins are the only `\n\n`, and all eight
  patterns in `TransparencyAnalysisService` terminate on `(?=\n\n|\z)` — a
  header found mid-page captures the rest of that page, and on the last page the
  rest of the document. An article can then be recorded as having industry ties
  it never declared. **The obvious fix is already disproved**: a bounded cap
  (0c2c268, reverted in a2b5cd8) pushed "…all other authors declare no competing
  interests" past the cap on a long, *well-formed* JATS disclosure, storing a
  conflict the article had explicitly declared away — a worse failure, on the
  common path. The repair is section segmentation, scoped in
  `doc/cross_platform/ios_bmlib_alignment.md`.
- **#203 — a negative finding from partial text is recorded as absence.** The
  analysers pass `nil` when the regex finds nothing and the detail view prints
  "No COI statement found", while the pages that fail to extract are
  disproportionately the last ones — exactly where funding, competing-interest
  and data-availability statements live. Coverage is on the document (#198) but
  does not reach analysis; the contract needs an "unknown because the source was
  partial" state, which changes what a stored verdict means on all three
  platforms.
- **#200 — `isComplete` is satisfied by one character per page.** A scanned
  article with a per-page download stamp, watermark or DOI reports a whole
  extraction, warns about nothing, and delivers a list of download stamps to the
  analyser. Wants a per-page minimum and a total minimum, named constants, agreed
  once for both. **The two already diverge deliberately** (#198): Python counts a
  text-free page as converted, Swift does not. Resolve that in the same pass.

### The rest of the #198 round

- **#196 — the NCBI key still reaches a user file in clear text.** The route PR
  #195 did not close: `study_transparency_analyzer.py:929` puts the key in a GET
  query, `requests.HTTPError.__str__` embeds the whole URL,
  `batch_analyzer.py:194` stores it in `result.errors`, and `export_to_json`
  writes it into a **user-chosen file with default permissions** while the
  config file is 0600. `pubmed/search_client.py:_make_request` models the fix:
  log `status_code`, never the URL.
- **#190 — CI never builds either app target.** `swift test` compiles the
  iOS-only sources to nothing on a macOS host and the SPM target excludes
  `Sources/macOS`. Partly addressed: #218 added a macOS `xcodebuild` job. Still
  wants an iOS Simulator job and — cheaper, and the exact defect that occurred —
  a guard that fails when a `.swift` file under
  `ios/MedicalFactChecker/Sources/` is referenced by no target.
- **Reporting honestly about full-text retrieval**, all one family. **#189** — a
  failed Unpaywall lookup reads as an article with no OA PDF; it cannot reuse
  `europePMCUnreachable`, so it wants its own reason and sentence. **#192** — a
  403/410, and a malformed PMC ID of ours, land in the catch-all `else` and get
  the one sentence that *invites a retry*; wants a fourth reason, so a
  `jats_parsing.md` change and a three-port change. **#194** — make `unspecified`
  unwritable by construction: one debug `assert` on the wrong type holds a rule
  the persisted contract depends on, and reading a newer build's reason
  *downgrades* it; wants the write-side enum split from a lossless read-side one.
  **#193** — the same file's PDF cache swallows its failures (golden rule 8).
  **#201** — concurrent fetches for one PDF both download.
- **#197 / #188 — `doc/cross_platform/jats_parsing.md` still specifies defects.**
  The normative spec invents a figure number the publisher did not deposit
  (#174's shape), and specifies contributor state as single slots while omitting
  `<string-name>` (#154's neighbourhood). A faithful Kotlin port would rebuild
  both from the spec. #175's lesson: the port contract is a place a fixed defect
  survives.
- **#148 — `INDUSTRY_KEYWORDS` has already drifted Python↔Swift**: Python's first
  entry is `\bpharma(?:ceutical)?s?\b`, Swift's is `\bpharma(?:ceutical)?\b`, and
  `\b` lands before the "s", so a COI statement using the plural raises the
  industry-ties indicator on desktop and not on iOS/macOS. All 17 other entries
  are byte-identical and nothing compares the two lists. One-character fix, but
  wants a shared fixture or it recurs — #147 added `sponsor_patterns.json` for
  the government/academic lists, the guard `INDUSTRY_KEYWORDS` still has none of.
- **#172, #174, #177 — what is left of the #171 review round.** **#172 and #174
  go together** — both are a table or figure the renderer cannot honestly
  describe: #172 drops a table deposited as a `<graphic>` entirely (all 8 in
  `PMC12759138`), #174 gives an unlabelled exhibit a fabricated `"Figure N"` from
  its array position, `alt` text included, which here is a number a citation may
  carry. bmlib already models a table's `graphic_url`, so #172 is a port. #177
  wants publisher spread first.
- **#154, #155, #162 — the JATS parser defects the corpus found that are still
  open.** Fixing any of them moves the corpus digests and needs the sibling
  parsers checked — see **Verify**.
  - **#154 — author affiliations are never captured.** `currentAffiliations` is
    written once and read nowhere, and `<xref ref-type="aff">` is unhandled.
    98.7% of real articles link affiliations that way; only 4.4% inline `<aff>`
    inside `<contrib>`, which is the shape every synthetic test uses.
  - **#155 — `<mixed-citation>` yields no structured reference metadata.** 80.9%
    of articles, **74.6% of all real references**. The citation string survives,
    so it degrades quietly.
  - **#162 — `rowspan` is never read.** A spanning cell contributes to its first
    row only, every later row is a cell short, and `padRow` pads the gap so the
    columns after it shift. `markdownRowCount` could never see it — which is why
    the digest now stores a `markdownDigest` hash of the rendering.
- **#150 — spelled-out NIH institute names match no government pattern**, on
  either platform: the lists carry the acronyms but no "National Institute of X"
  form, while CrossRef returns it routinely, so a US federal agency tiers
  NONPROFIT. Only `sponsor_type` is affected. Pinned as the behaviour we *want*,
  `xfail(strict=True)`, so fixing it XPASSes and the marker must come off.
  Widening to `\bnational institutes? of\b` also reaches non-US bodies, so
  measure on both platforms before widening.
- **#144 — captions on `<supplementary-material>`/`<media>`/`<boxed-text>` are
  dropped**: no longer corrupting the enclosing section, but there is no model to
  capture them into. 417 occurrences across 386 articles. **#145** — stale
  transparency results still feed report aggregates and the exported PDF:
  `TransparencySummarySection` and `PrintableReportView` average v1 and v2 scores
  into one unlabelled figure.
- **#123 — Android parse errors are swallowed (golden rule 8)**: `parseArticleXml`
  ends its catch with `printStackTrace()` — the only such call left in
  `app/src/main` — so a truncated EFetch batch silently under-reports articles.
  Blocked on a JVM-portable logging seam: a plain `Log.e` reintroduces the
  untestable Android dependency `PubMedService` (#119) escaped by parsing on a
  pure-JVM JAXP SAX parser (`setXIncludeAware` deliberately left uncalled — JAXP's
  base implementation throws it into the same swallowed path on-device while JVM
  tests stay green). Overlaps **#121 — the JATS parser is untestable the same
  way**; migrating it to JAXP SAX fixes both.
- **Android transparency, remaining #116 slices**: COI analyzer, scorer + risk
  indicators, funding/trial (network), JATS statement extraction, Room
  persistence + `DocumentCard` UI. **#109 — LLM-assisted disambiguation of repo +
  soft-restriction**: kept FULL_OPEN today; wants an optional config-gated LLM
  layer at the orchestration layer, classifier and parity tests unchanged.
- **#136/#137 — pricing is hardcoded in six places per platform and has already
  drifted**: GPT-5.2 is advertised at $2.00/$8.00 but billed at $1.75/$14.00, and
  `mistral-large-latest` matches no pricing key so it bills at the
  `defaultPricing` placeholder. #136 needs a decision on which figures are
  current; #137 is the duplication that caused it. **#138 — the model-list fetch
  has no retry/backoff** (golden rule 7). **#139 — four providers still filter
  models by whitelist** (OpenAI, Groq, Mistral, Anthropic), the pattern that broke
  DeepSeek — riskier now that the healing logic rewrites a valid selection when a
  whitelist drops a model.
- **Small and cosmetic.** **#140** — `ThinkingConfig.type` is a raw `String` for
  a two-valued toggle. **#126** — redundant "Data not openly available" label
  (tiers are correct). **#111** — cache compiled regexes in Swift `RegexHelper`,
  negligible until it hits a hot path. **#225** — two dead file-path constants in
  `FullTextConstants`, one spelling `"pmid-"`. **Swift's risk *level* heuristic**
  (`TransparencyScorer.calculateRiskLevel`) has no Python counterpart; revisit
  only if a canonical definition appears.

### Verify

- **Closing an issue is a claim; check the commit made it true.** #183, #192,
  #217 and #219 have each been closed by a commit whose own message listed them
  as deferred. The mechanism is GitHub's keyword parser: "Lodged rather than
  fixed: #217" contains `fixed: #217`. Only the *first* number after the keyword
  closes, which is why #220–#223 in the same sentence stayed open — so the
  failure is easy to miss twice. Write a deferral with no closing keyword before
  an issue number.
- Touching any data-availability pattern? Run all three parity suites; a change
  that does not update `doc/cross_platform/transparency_parity/` **and** all
  three platforms is meant to fail.
- Touching a *funder* pattern is a different workflow — edit the lists on both
  platforms, then re-run the **measurement**, not a string comparison:
  `pytest tests/test_funder_classification.py` and
  `cd Packages/BioMedLit && swift test --filter 'Funder|IndustryPattern'`.
- Touching the JATS parser? The corpus digests are *expected* to move. Run
  `cd Packages/BioMedLit && swift test --filter JATSRealCorpusTests`, read what it
  names, then regenerate with `UPDATE_JATS_DIGESTS=1` and read
  `git diff doc/cross_platform/jats_corpus/` line by line — that diff is the
  evidence a fix worked, and regenerating unread is how a regression becomes a
  committed expectation, the one failure the corpus cannot survive. The
  regeneration run fails on purpose; re-run without the variable to verify. Then
  check the sibling parsers: bmlib's is Python and can be **run** over the same
  corpus files, which beats reading it; Android's needs a source read until #121.
- Mutation-testing a source file? **Back it up with `cp`, not `git checkout`** —
  the restore step wipes every uncommitted change in the file, and the runs after
  the first then silently measure a tree with the feature missing. Cost an
  implementation once already.
  - **Key the harness on `swift test`'s exit code, not on its output.** Scraping
    the last `with N failures` line reports killed mutants as survivors: the run
    prints several summaries and the last one is not the overall verdict. Cost a
    round of false "survivors" in #180/#181.
  - **A survivor is a claim about the test, and sometimes about the code.** In
    #186 the test meant to pin a predicate ended on a path that *discards* the
    value it asserted on, so it could not have failed however the predicate was
    mutated — and chasing that turned up a real defect behind it. Ask what the
    asserted value's provenance is on that exact path before assuming the test
    merely needs strengthening.
- **`swift test` compiles neither app target's platform-guarded sources.** On a
  macOS host every `#if os(iOS)` file becomes nothing, and the SPM target excludes
  `Sources/macOS` — so a break behind either guard is invisible to it *and* to
  the other platform's `xcodebuild`. Touching iOS-only view code means
  `xcodebuild -scheme MedicalFactChecker -destination 'platform=iOS
  Simulator,name=<device>' build`; CI runs neither (**#190**).
- Adding a Swift file either app needs? It must be in `project.pbxproj` — a file
  on disk and absent from the project compiles nowhere, which is how the iOS
  target sat unbuildable, and a **duplicate pbxproj UUID silently drops the file
  from the build** with "cannot find X in scope" in an unrelated file as the only
  symptom. `xcode_project_guards.py` checks duplicate IDs and out-of-repo
  references, not absent files, so check the new IDs are unused before building.
- `pytest tests/` → 0 failures (Python is the reference).
- `cd Packages/BioMedLit && swift test` → 0 failures.
- `cd ios/MedicalFactChecker && swift test` → 0 failures.
- Android: `cd android/MedicalFactChecker && ./gradlew test` → 0 failures.
- macOS app still builds: `xcodebuild -scheme MedicalFactChecker -destination
  'platform=macOS' build` from `ios/MedicalFactChecker/`.
- `ruff check .` / `mypy src/` carry pre-existing debt, so a clean run is
  unreachable and the gate is **no new findings vs. the merge base**. CI enforces
  this on PRs; reproduce it locally with
  `python .github/scripts/lint_delta.py --base-ref origin/master`.
  - **Don't record an absolute baseline count — the mypy total is
    platform-dependent**, differing between macOS and the Linux runner from the
    platform-specific branches it analyses, and drifting with every commit. No
    number is written here for that reason. The gate is immune because it
    compares two measurements from the same machine in the same run; a committed
    baseline number would be wrong by ~a dozen the moment it changed hosts.

### Xcode Cloud contract (macOS ships from the multiplatform project)

Since the standalone macOS app was retired in `c32d707`, Xcode Cloud archives
`ios/MedicalFactChecker/MedicalFactChecker.xcodeproj`, scheme
`MedicalFactChecker`. Two things silently break that build, and neither shows up
locally — verify against a **fresh clone**, which is all Xcode Cloud gets:

- **No Swift package reference may point outside this repository.** A stray
  `XCLocalSwiftPackageReference` to a sibling checkout
  (`../../../locumtracker/…`) failed package resolution before any compilation.
  It resolves fine on a dev machine where the sibling exists, so local builds
  stay green while every cloud build dies.
- **`MedicalFactChecker.xcscheme` must stay shared**
  (`…xcodeproj/xcshareddata/xcschemes/`). Xcode Cloud can only select shared
  schemes; the autocreated per-user scheme is invisible to it.

Both invariants are enforced on every PR by
`.github/workflows/xcode-project-guards.yml`. Reproduce a cloud build with:

```bash
git clone <repo> /tmp/x && cd /tmp/x/ios/MedicalFactChecker && xcodebuild \
  -scheme MedicalFactChecker -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO archive
```
