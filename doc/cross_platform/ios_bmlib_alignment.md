# iOS ↔ bmlib alignment: what has not caught up

Assessment date: 2026-08-20. bmlib at **0.10.0** (released 2026-08-15) plus the
unreleased `#105`/`#96`/`#73` work on `main`. iOS/macOS app and `Packages/BioMedLit`
at the tip of `master` (0.4.1, apps 1.5.1).

## How the two relate

`~/src/bmlib` is a standalone Python library. **Nothing in this repository imports
it** — not the desktop Python app, not the Swift package. `BioMedLit` is an
independent Swift re-implementation of the same algorithms, and it was forked from
the *older* `bmlibrarian_lite` Python lineage (`src/bmlibrarian_lite/study_transparency_analyzer/`),
which is what the parity contract in `doc/cross_platform/transparency_parity/`
still names as canonical.

bmlib has since gone through seven releases (0.4.0 → 0.10.0) whose subject matter
is, to a striking degree, *exactly the code paths BioMedLit mirrors*: Europe PMC
full-text retrieval, the JATS parser, transparency analysis, PDF handling, JSON
extraction from LLM responses. Most of those fixes were driven by measurement
against real corpora and pinned by mutation testing. None of them have reached Swift.

This document is a gap list, ordered by what it costs to leave each one alone.

**Status.** Everything in §1 is now fixed on `master` — see
[§1 status](#1-status-fixed) for what landed and what it moved. §2 onward is
still a plan; nothing there has been implemented.

---

## 1. Verified defects — reproduced against the current Swift code

> **All four are fixed.** Each subsection below is kept as the original
> reproduction — it is the evidence the fix was needed and the shape the
> regression tests assert. See [§1 status](#1-status-fixed) for what changed.

Each of the four below was confirmed by running the real BioMedLit code, not by
reading it. bmlib fixed each one and says what it cost.

### 1.1 The Europe PMC free-PDF filter takes ~4% of what it is offered

`Packages/BioMedLit/Sources/BioMedLit/Services/EuropePMCService.swift:144`

```swift
return urls.first(where: { $0.documentStyle == "pdf" && $0.availability == "Free" })?.url
```

bmlib's issue **#79** (0.9.1) measured this over 600 recent MEDLINE records
(`scripts/sample_free_pdf_urls.py`). Of 326 `documentStyle=pdf` entries:

| `availability` | `availabilityCode` | entries | share |
| --- | --- | --- | --- |
| Open access | `OA` | 312 | 95.7% |
| Free | `F` | 14 | 4.3% |
| Subscription required | `S` | 0 | — |

Both accepted labels are the identical `…?pdf=render` URL on the identical host.
So the iOS PDF tier is discarding about **95% of the free PDFs it exists to find**,
and there is no log line for "a PDF entry was seen and not taken" — the article
simply falls through to Unpaywall or to a bare DOI link.

bmlib's fix allow-lists on `availabilityCode ∈ {OA, F}`, falls back to the display
string `∈ {"Open access", "Free"}` only for an entry carrying no code, and rejects
a *present but unrecognised* code without consulting the label — an unknown future
value must under-credit rather than risk downloading a paywalled PDF.

### 1.2 A figure caption inside a section renames the section and blanks the figure

`Packages/BioMedLit/Sources/BioMedLit/JATS/JATSXMLParser.swift:1127–1155`

`didEndElement` routes `<title>` and `<p>` on the `sectionStack` / `inFigure` /
`inTableWrap` flags, and tests the section branch **first**. There is no
"am I inside a `<caption>`" state at all — `case "caption": break` defers to
"nested p elements", and those are captured by the section.

For the ordinary PMC layout (`<fig>` nested inside `<sec>`), the parser was run on:

```xml
<sec>
  <title>Methods</title>
  <p>We enrolled 120 patients.</p>
  <fig id="f1"><label>Figure 1</label>
    <caption><title>Study flow diagram</title><p>CONSORT diagram of enrolment.</p></caption>
  </fig>
  <p>Analysis was by intention to treat.</p>
</sec>
```

Actual output:

```
sectionTitle     = "Study flow diagram"        ← should be "Methods"
sectionParagraphs = ["We enrolled 120 patients.",
                     "CONSORT diagram of enrolment.",   ← caption prose, spilled
                     "Analysis was by intention to treat."]
figureCaption    = ""                          ← should be the caption
```

Three losses at once: the section is **renamed** by the figure's caption title,
caption prose contaminates the section's body text, and the figure keeps no
caption. bmlib fixed this in 0.6.0 by routing on the enclosing `<caption>` rather
than on whichever `in_*` flag happens to be set.

### 1.3 An unsectioned `<body>` loses all of its prose

Same file, `case "p"` requires `!sectionStack.isEmpty`; a section is only appended
to `bodySections` when `</sec>` closes. But `<sec>` is **optional** in JATS.

Parsed a `<body>` holding two loose `<p>` and nothing else:

```
bodySections = 0
markdown     = "# T"          ← the title, and nothing else
```

Every word of the article body is silently dropped. bmlib's issue **#30** (0.6.0)
makes loose prose a titleless `JATSBodySection`, flushed at each `<sec>` boundary
so document order is preserved, and counts it towards `has_body` — which is what
ended a permanent cache miss on those articles.

### 1.4 Industry-funder classification misses most pharma and flags two research councils

`Packages/BioMedLit/Sources/BioMedLit/Transparency/Analysis/FundingAnalyzer.swift`
+ `IndustryPatterns` in `TransparencyConstants.swift`.

The same 17 names through `FundingAnalyzer.classifyFunder` and through bmlib's
`_is_industry_funder`:

| Funder name | Swift | bmlib |
| --- | --- | --- |
| Department of Biotechnology *(Indian ministry)* | **INDUSTRY** ❌ | not-industry |
| Biotechnology and Biological Sciences Research Council *(UK)* | **INDUSTRY** ❌ | not-industry |
| Research Corporation for Science Advancement *(US non-profit)* | **INDUSTRY** ❌ | not-industry |
| Vertex Pharmaceuticals Incorporated | **not-industry** ❌ | INDUSTRY |
| Regeneron Pharmaceuticals | **not-industry** ❌ | INDUSTRY |
| Moderna Therapeutics | **not-industry** ❌ | INDUSTRY |
| Abbott Laboratories | **not-industry** ❌ | INDUSTRY |
| Tempus Labs, LLC | **not-industry** ❌ | INDUSTRY |
| Flatiron Health LLC | **not-industry** ❌ | INDUSTRY |
| Pfizer Inc / Genentech, Inc. | INDUSTRY ✅ | INDUSTRY |
| Ministry of Science and Technology | not-industry ✅ | not-industry |
| Lincoln Medical Center | not-industry ✅ | not-industry |
| University of Calgary, …, AB, Canada | not-industry ✅ | not-industry |
| Key Laboratory of Molecular Biology *(Chinese state lab)* | not-industry ✅ | not-industry |
| Novo Nordisk A/S · Bristol-Myers Squibb Company | not-industry | not-industry |

Six of the nine mismatches are the **plural**: `#"\bpharma(?:ceutical)?\b"#` cannot
match "Pharmaceuticals", because the `\b` lands before the "s". "X Pharmaceuticals"
is the standard company-name form, so the pattern that exists to catch pharma
mostly does not. `therapeutics`, `laboratories` and `llc` are absent entirely.

The three false positives are the ones bmlib measured and removed. Issue **#36**
(0.6.0) calibrated the list against 833 real CrossRef/PubMed funder names, 417 of
them hand-labelled and committed as `tests/data/funder_names.json`, moving
**precision 0.400 → 0.917 and recall 0.176 → 0.324**. It split the list into
substring *stems* (`pharmaceutic`, `therapeutics`, `laboratories`) and whole
*words* (`pharma`, `biotech`, `inc`, `incorporated`, `corp`, `ltd`, `limited`,
`gmbh`, `llc`), and the corpus explicitly disqualified `biotech` as a substring
(0 TP / 4 FP — it reached exactly the ministry and the research council above)
and `corporation` (1 TP / 1 FP — the false positive is literally "Research
Corporation for Science Advancement"). `labs` and `ab` were rejected on collision
grounds; note Swift's `governmentPatterns` still carries a bare `#"\bva\b"#`,
which is the same two-letter collision against an address's state abbreviation.

This matters more than a classifier's usual accuracy budget:
`industryFundingDetected` feeds a HIGH-risk rule, and HIGH downgrades the paper's
tier in the report.

**Two structural notes.** Swift's `industryKeywords` mixes funder-name patterns
with COI-*prose* phrases (`employee of`, `advisory board`, `honoraria`,
`grants from`, `shareholder`, `speaker's bureau`) in one list; bmlib keeps
`_INDUSTRY_STEMS`/`_INDUSTRY_WORDS` and `_INDUSTRY_COI_KEYWORDS` deliberately
separate, because the generic corporate suffixes match far too freely in running
text while the disclosure phrases never occur in a funder name. And
`funder_names.json` is directly portable as a fourth parity fixture alongside
`data_availability_*.json`.

---

## 1 status: fixed

Landed together, each with regression tests that reproduce the defect above
before asserting the fix.

| # | Fix | Where |
| --- | --- | --- |
| 1.1 | Free-PDF allow-list on `availabilityCode ∈ {OA, F}`, falling back to the display string only for an entry carrying no code; an unrecognised code is rejected without consulting the label. `availabilityCode` is now decoded, and a PDF entry that is seen and not taken is logged. | `EuropePMCService.extractFreePDFURL`, `EuropePMCFullTextUrlEntry.isFreeToDownload`, `BioMedLitConstants.europePMCFreePDFAvailability*` |
| 1.2 | `<title>` and `<p>` route on the enclosing `<caption>` — tested before every prose branch, because a `<fig>` usually sits inside a `<sec>`. Caption children join with a single space; non-caption `<p>` inside a figure or table is dropped as furniture rather than reaching the section. | `JATSXMLParser.appendCaptionText`, `inCaption` |
| 1.3 | Loose `<body>` prose accumulates into a titleless section, flushed when a real `<sec>` opens and again at `</body>` so document order is preserved. Whitespace-only paragraphs do not open one. | `JATSXMLParser.flushImplicitBodySection`, `implicitBodySection` |
| 1.4 | Funder patterns split into substring *stems* and whole *words*, calibrated against the 417-name labelled corpus. COI-prose phrases stay in `industryKeywords`, which `classifyFunder` no longer reads. | `IndustryPatterns.funderNameStems` / `funderNameWords`, `FundingAnalyzer.matchesIndustryName` |

Two further parser defects surfaced while reproducing these and were fixed with
them — see [Found while fixing](#found-while-fixing-also-fixed).

**Measured effect of 1.4.** Against the corpus, now lifted byte-identical from
bmlib into `doc/cross_platform/transparency_parity/funder_names.json` as the
fourth shared fixture:

| | precision | recall |
| --- | --- | --- |
| before | 0.455 | 0.167 |
| after | **0.909** | **0.333** |

Identical to what bmlib's `_is_industry_funder` scores on the same names.
`FunderClassificationTests` holds floors of 0.90 / 0.30 and asserts the new
matcher beats the old figures.

**One deliberate deviation from bmlib:** `plc` is kept in `funderNameWords` and
excluded in bmlib. bmlib drops it as "0 TP — no corpus evidence", but `pharma`,
`biotech`, `corp` and `gmbh` also score 0 TP / 0 FP on the same corpus and bmlib
keeps all four on the reserved-suffix argument. `plc` is a legally reserved UK
public-limited-company suffix in exactly that position, it scores 0 TP / 0 FP so
precision and recall are unchanged, and it is the form UK-listed pharma funders
report under.

### Stored values

All four fixes change which evidence reaches the scorer, so stored transparency
scores are not comparable across them. `TransparencyResult` now carries
`analyzerVersion`, stamped from `TransparencyConstants.analyzerVersion` (bumped
to `2`). The field is **optional**: the persisted column is free-form JSON, and a
required field would strand every earlier analysis behind a decode failure that
reads as "never analysed". A result decoding to `nil` predates versioning and is
therefore stale by definition.

`TransparencyResult.isStale` and `Document.transparencyAnalysisIsStale` drive a
notice in `TransparencyDetailView` / `MacTransparencyDetailView` and a
"Re-analyze" button in `ReportView` / `MacReportView`. The stale score stays
visible — it is the last thing that was actually measured — but it is marked so
it is not read beside a current one as if the two were interchangeable.

Cached full text is **not** invalidated. An article cached before 1.1 keeps
whatever tier answered at the time; the allow-list applies to the next
retrieval. Re-running transparency analysis does not re-fetch it.

### Found while fixing, also fixed

Neither was in the original gap list — both surfaced while reproducing §1, and
both are in `JATSXMLParser`.

**`<sec>` inside `<abstract>` emitted body sections.** Swift pushed a
`SectionBuilder` for every `<sec>`, including inside a structured abstract, and
appended a section to `bodySections` at each `</sec>`. Worse than it first
looked: for a two-section structured abstract the article reported **three** body
sections, and the two empty ones came *first*, so anything reading
`bodySections.first` got an empty section rather than the introduction. Both the
push and the pop are now guarded with `!inAbstract`, as bmlib guards them — and
the two guards see the same state, because `</sec>` inside an abstract fires
before `</abstract>` clears the flag. The abstract's own sections are unaffected;
they were always read by the abstract accumulator.

**`<article-id>` fallback overwrote correctly typed ids.** Ids whose
`pub-id-type` the parser did not recognise fell through to pattern matching that
could overwrite a value already read from a typed element. Two real cases, both
present in the very first integration-test article (PMC12759138):

| element | value | was taken as | is |
| --- | --- | --- | --- |
| `<article-id pub-id-type="publisher-id">` | `10.1177_20552076251406653` | the DOI | SAGE's internal id — the DOI with the slash replaced by an underscore |
| `<article-id pub-id-type="pmcid-ver">` | `PMC12759138.1` | the PMC ID | the canonical id plus a version suffix |

Both overwrote the correct value simply by appearing later in the document. The
PMC one also overrode a caller-supplied `knownPMCId`, and `pmcaid`/`pmcaiid` —
PMC's internal numeric article ids — were reachable by the numeric branch and
could be mistaken for a PMID.

Three guards now: a typed `doi`/`pmc`/`pmcid` marks its value authoritative and
the pattern fallback will not overwrite it; the DOI branch requires DOI *shape*
(a `10.` prefix **and** a slash), which is what the underscore form fails; and
`pmcid-ver`/`pmcaid`/`pmcaiid` are recognised-and-ignored so they never reach
pattern matching at all. The fallback still takes a genuinely untyped
`10.1234/x`.

> **This one is bmlib's too.** `JATSParser(data).parse()` returns
> `doi='10.1177_20552076251406653'` for the same XML — `_classify_article_id`
> takes any `10.`-prefixed string. Worth reporting upstream; Swift is now ahead
> of Python here rather than behind it.

**`<sub-article>` content was parsed as the article's own.** JATS lets a
`<sub-article>` carry a complete `<front>`/`<article-meta>` and `<body>`. PLOS
deposits its entire peer-review history that way — one sub-article per round,
each with its own DOI, title, authors and prose — and nothing excluded them, so
the *last* of each silently replaced the real article's. On PMC12774363:

| | master | after 1.3 | fixed |
| --- | --- | --- | --- |
| title | `Associated Data` | `Associated Data` | *Lack of ANKMY2 suppresses kidney cystogenesis…* |
| DOI | `…pgen.1012008.r006` | `…pgen.1012008.r006` | `…pgen.1012008` |
| body paragraphs | 48 | **230** | 28 |

The middle column is the important one: fixing 1.3 made this *worse*. Review
correspondence is loose `<p>` inside a sub-article `<body>`, which is exactly the
shape 1.3 stopped dropping — so ~180 paragraphs of reviewer and editor prose
entered `bodySections`, where scoring, citation extraction and the transparency
regexes read them as article text. A `subArticleDepth` counter (not a flag —
JATS permits nesting) now excludes the whole region, while still maintaining the
element stack and text buffers so the two stay balanced across it.

**Every PLOS author was dropped.** `<contrib>` was treated as an author only when
it carried `contrib-type="author"`. JATS also allows the role to be declared once
on the group, and PLOS uses that form — `<contrib-group content-type="author">`
with bare `<contrib>` children — so PMC12774363 parsed with **zero** authors. A
`<contrib>` with no `contrib-type` now inherits its group (an author group, or a
`<contrib-group>` with no `content-type`, which JATS treats as authors by
convention); an explicit `contrib-type` still decides on its own, so an editor
inside an author group stays out.

> **All three are bmlib's too.** On the same article `JATSParser(...).parse()`
> returns title `Associated Data`, DOI `…r006`, **0** authors and 230 body
> paragraphs — identical to what Swift produced before these fixes, since bmlib
> was the source of the port. Reported upstream.

With all of these fixed, all 19 network-gated `JATSXMLParserIntegrationTests`
pass against live PMC, including the two that fail on `master`.

---

## 2. Transparency: capabilities bmlib has and iOS does not

### 2.1 The PubMed record is read for metadata only

`TransparencyAnalysisService.fetchBasicMetadata` calls `PubMedService.search` and
takes title, journal, authors, PMC id and DOI. bmlib's issue **#18** (0.6.0) adds
one `efetch` per analysis and reads three structured signals Europe PMC cannot
give for a closed-access paper:

- `<CoiStatement>` — a COI signal for a paper whose full text you do not have
- `<GrantList>` — **the first funder signal a PMID-only analysis has ever had**
- `<DataBankList>` — data deposition (see 2.2)

`pubmedApiKey` is already plumbed through `TransparencyAnalysisService.swift:41,489`,
so today it only raises the rate limit on a metadata lookup.

### 2.2 Data deposition from `<DataBankList>` is not credited

bmlib 0.7.0 added `_DEPOSITION_DATABANK_LEVELS`, a curated split of NLM's
vocabulary mapping each repository to the level a deposit into it establishes:
BioProject, dbVar, Dryad, figshare, GenBank, GEO, PDB, SRA → `full_open`; dbGaP →
`on_request` only, because it needs Data Access Committee approval. Reference-only
names (dbSNP, OMIM, RefSeq) are excluded on purpose — they cite a record, they do
not deposit one. It is a mapping rather than a set-per-level so adding a repository
cannot silently inherit the generous default. `full_open` is worth 20 points.

iOS determines data availability by regex over full text only, so a paper that
deposited into GEO but has no data-availability statement scores nothing for it —
and a PMID-only paper scores nothing at all.

### 2.3 Europe PMC is dead code on the transparency path

`getEuropePMCService()` is defined at `TransparencyAnalysisService.swift:495` and
**called from nowhere**. bmlib's `_check_europepmc()` supplies open-access status
(15 points), citation count (5), and the `industry_coi` signal derived from the
COI statement in the full text. OpenAlex is not consulted by iOS at all.

### 2.4 An unreachable network produces a fabricated score

Every fetch in `TransparencyAnalysisService` is wrapped in a `catch` that logs a
warning and continues; `TransparencyResultBuilder.build()` then computes a score
from the base 50 regardless. With no network — PubMed, CrossRef and
ClinicalTrials.gov all failing — the app still stores a score and a risk level for
the document, and nothing downstream can tell that verdict from a real one.

bmlib's 0.4.0 unreachable-API guard returns `UNKNOWN` at score 0 in exactly this
case, "so a dead network no longer reads as a HIGH-risk paper", and issue **#21**
(0.6.0) added `TransparencyUnknownReason ∈ {DISABLED, NO_IDENTIFIER, UNREACHABLE}`
so a caller can retry an outage and skip a disabled analyzer. iOS's
`TransparencyRiskLevel.unknown` carries no reason.

### 2.5 Trial registration is read from the title only

```swift
// TransparencyAnalysisService.swift:252
if let title = builder.title {
    nctIds.append(contentsOf: TrialComplianceAnalyzer.extractNCTIds(from: title))
}
```

The full text `analyze()` was handed is never scanned. Titles rarely carry an NCT
id, so most registered trials read as unregistered — and `trialRegistrationPoints`
is 10 points plus a "Clinical trial without detected registration" risk indicator.

bmlib scans the full text with a registration-cue window (`_REGISTRATION_CUE_RE`,
±60 characters around "registered at/with", "trial registration"), capped at
`_MAX_OWN_TRIAL_IDS = 2`, so a *cited* trial is not mistaken for the paper's own
registration.

`TransparencyConstants.registryNames` (15 entries) is **dead code** — nothing
reads it, and only NCT ids are recognised anywhere. bmlib recognises 23 registry
names via `<DataBankList>`, including JMACCT, REPEC and UMIN CTR, whose absence
was itself a 0.7.0 fix, plus jRCT, CRIS and JAPICCTI.

### 2.6 COI detection is cue-phrase-only

`extractCOISection` matches header cue phrases over plain text. bmlib's issue
**#13** counts a non-blank JATS-*tagged* COI section as `coi_disclosed=True` even
without a cue phrase, using the cue-phrase scan as the fallback for untagged text.
Without it, a properly tagged `<sec sec-type="COI-statement">` with unusual wording
reads as "No conflict of interest statement found" — a HIGH-risk indicator.

### 2.7 The scoring models are not comparable

Swift starts at a base of 50 and applies component deltas. bmlib starts at 0 and
awards named components (funder info 15, COI disclosed 10, data full-open 20 /
on-request 10, open access 15, cited 5, trial registered 20, results posted 15),
capped at 100. Not a defect on either side, but the two numbers are not
interchangeable, and any convergence is a stored-value migration. Worth an explicit
decision rather than drift.

---

## 3. Full-text retrieval

iOS runs Europe PMC XML → Europe PMC PDF → Unpaywall → DOI. bmlib runs
caller-supplied sources → Europe PMC XML (1a/1b) → **NCBI PMC via efetch (1c)** →
free PDF (1d) → Unpaywall → DOI/PubMed URL.

| | bmlib | iOS |
| --- | --- | --- |
| NCBI PMC JATS tier (`efetch`) — issue #47, 0.7.0 | ✅ | ❌ |
| Second PMC-id resolver (NCBI ID Converter) — #47 | ✅ | ❌ |
| Free-PDF availability allow-list — #79 | ✅ | ❌ (see 1.1) |
| Body-less JATS detection / `content_kind` | ✅ | ❌ |
| PDF → text extraction | ✅ | ❌ (see below) |
| PDF section segmentation | ✅ (0.8.0) | ❌ |
| Judged PDF metadata title — #56, 0.9.1 | ✅ | n/a |
| Atomic cache write — #70, 0.9.0 | ✅ | ❌ |
| Corrupt-entry quarantine — #71, 0.9.0 | ✅ | ❌ |
| Exhaustion / swallowed-bug reporting — #67/#68/#72 | ✅ | ❌ |

Three of these are worth naming individually.

**A downloaded PDF contributes nothing.** `Document.applyFullTextResult` has
`case .pdfURL: fullTextContent = nil`. The PDF is fetched, cached and rendered for
the user in `FullTextViewer` (PDFKit, display only), but scoring, citation
extraction and transparency analysis all see `nil`. Combined with 1.1 — where ~95%
of Europe PMC's free PDFs are never even offered — the PDF path currently returns
no text to the pipeline at all. PDFKit's `PDFPage.string` is the native equivalent
of what bmlib does with PyMuPDF.

**No `contentKind`.** bmlib distinguishes `fulltext` / `abstract` / `extracted` /
`none`, which is what lets it detect the medRxiv preprints that serve
`<front>`+`<back>` with no prose, hold them back as a last resort, and never cache
them. iOS cannot tell an abstract-only retrieval from a real one, so it caches and
scores it as full text.

**Cache writes are not atomic and reads are not validated.** `cachePDF` writes
straight to the target path. bmlib's issue **#70** found the failure this creates:
a disk that fills mid-write leaves a truncated file that decodes fine and is served
as complete forever, with no log at any level — "worse than #67: that lost data in
a shape resembling absence, this fabricated a complete-looking article". Its fix is
temp file + `fsync` + `os.replace`; issue **#71** adds quarantining an unreadable
entry to a `.corrupt` name, because leaving it in place hides a freshly cached PDF
behind it and the article re-downloads on every run forever.

---

## 4. Modules with no Swift counterpart at all

| bmlib module | Since | iOS |
| --- | --- | --- |
| `bmlib.citations` — `[@id:N:Label]` marker parsing, Vancouver/APA/Harvard/Chicago formatters, reference builder numbering by first appearance | 0.8.0 | ❌ — `ReportFormatter` only |
| `bmlib.quality` — metadata filter → study classifier → quality agent, CEBM hierarchy, `CochraneAssessor` (9-domain risk of bias) | 0.4.0–0.8.0 | ❌ (also absent on Android; present in desktop Python) |
| `bmlib.publications.retractions` — Retraction Watch import, `lookup_retractions()`, `is_retracted()` | 0.7.0 | ❌ — only `"Retracted Publication"` as a PubMed exclude-type at query time, which cannot catch a paper retracted *after* the record you hold was indexed |
| `bmlib.context_processor` — hierarchical map-reduce for content that exceeds the context window | 0.7.0 | ❌ |
| `bmlib.llm.text_utils` — boundary-aware chunking, map-reduce and rolling-summary helpers | | ❌ |

## 5. LLM plumbing

- **JSON handling is the widest gap.** `ResponseParser.extractJSON` finds objects
  only — `extractBalancedJSON` starts at the first `{`, and the fallback is
  first-`{`-to-last-`}`; a top-level array is not located. `fixJSONString` handles
  trailing commas, and single→double quotes only when the string contains no `"` at
  all. bmlib has `json_repair.py` (single quotes, trailing *and missing* commas,
  control characters, **truncation**, unquoted keys), a six-stage span locator
  `iter_json_spans()`, the whole-span-beats-nested-fragment policy from issue **#33**
  (an unfenced array of objects was being reduced to its first element, dropping
  every sibling with no error), and `salvage_json_fields()` for recovering the
  intact fields of a long malformed response.
- **Providers**: iOS has Anthropic, OpenAI, DeepSeek, Groq, Mistral, Ollama, custom.
  bmlib has Anthropic, OpenAI, Ollama, OpenAI-compatible, DeepSeek, Mistral,
  **Gemini**. Groq is iOS-only; Gemini is bmlib-only.
- **Thinking**: iOS has a DeepSeek-specific `ThinkingConfig` opt-out. bmlib has a
  cross-provider `think` kwarg (bool / effort string / int budget) mapped to each
  provider's native parameter, with the trace on `LLMResponse.thinking`.
- **Tool calling**: bmlib only.
- **Ollama model listing**: bmlib reads `/api/tags` as raw JSON specifically because
  the SDK's model silently drops the `capabilities` array and `details.context_length`,
  and resolves missing context windows lazily behind a memoised `show()`. iOS reads
  `/api/tags` but not those fields.

---

## 6. Not gaps

- **The data-availability classifier is richer on Swift**, not poorer — negated-openness
  patterns, ordered restriction labels, the repository table. It is the one piece
  under a real parity contract (`doc/cross_platform/transparency_parity/`), pinned
  string-for-string and case-for-case across Python, Swift and Kotlin. bmlib's own
  data-availability handling is coarser and derives mostly from `<DataBankList>`.
- **Embeddings**: iOS uses `NLEmbedding` on-device; bmlib implements `embed()` for
  Ollama only. Different platforms, deliberately.
- **`bmlib.publications` (sync, fetchers, PostgreSQL storage), `bmlib.db`, `bmlib.templates`**
  are server/desktop concerns with no mobile counterpart.
- **Checkpointing, error queue, background tasks, iCloud sync, `SearchResultMerger`**
  are iOS capabilities with no bmlib counterpart.

---

## 7. Suggested order

Roughly by (impact × confidence) ÷ effort. Items 1–3 are **done** — see
[§1 status](#1-status-fixed).

1. ~~**1.1 Europe PMC availability allow-list**~~ — done.
2. ~~**1.4 funder patterns**~~ — done, corpus lifted as the fourth shared fixture.
3. ~~**1.2 + 1.3 JATS caption routing and unsectioned body**~~ — done.
4. **PDF → text via PDFKit** — now the highest-value remaining item, and more so
   than before: 1.1 means the Europe PMC PDF tier finally offers the ~95% of free
   PDFs it was discarding, but `Document.applyFullTextResult` still sets
   `fullTextContent = nil` for `case .pdfURL`, so none of them reach scoring,
   citation extraction or transparency analysis.
5. **2.5 trial ids from full text** with the cue window, and **2.4** the
   unreachable-API guard — the two places where iOS currently reports a confident
   wrong answer rather than an unknown.
6. **2.1/2.2 the PubMed `efetch` step** — one request per analysis, and the only
   route to COI and funder signals for a closed-access, PMID-only paper.
7. Everything in §3's table below the PDF work, then §4/§5 as product priorities
   dictate.

Item 4 is a behaviour change that **moves stored values**: `fullTextContent` and
cached full text are not comparable across it, and giving the scorer a paper's
full text where it previously saw `nil` moves transparency scores too. The
mechanism for that is now in place — bump
`TransparencyConstants.analyzerVersion` and stored results mark themselves stale
(see [Stored values](#stored-values)).
