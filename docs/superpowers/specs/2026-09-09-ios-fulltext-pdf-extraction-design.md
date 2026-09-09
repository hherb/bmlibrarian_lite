# A downloaded PDF contributes its text

Design date: 2026-09-09. Swift package `Packages/BioMedLit` and the iOS/macOS app
at the tip of `master`.

This is the first of three slices bringing iOS and macOS up to bmlib's current
state. The other two, transparency analysis and a two-way JATS diff, get their
own specs. The gap list all three draw on is
[`doc/cross_platform/ios_bmlib_alignment.md`](../../../doc/cross_platform/ios_bmlib_alignment.md);
its §7 names this slice as the highest-value remaining item, and everything in
its §1 has already landed.

## The problem

`FullTextService` retrieves a PDF, and none of its text reaches anything that
reads text.

- **The PDF tiers return a URL and stop.** `FullTextContent.europePMCPDF` and
  `.unpaywall` carry a `URL` and nothing else. `Document.applyFullTextResult`
  sets `fullTextContent = nil` for that case.
- **`document.fullTextContent` is the only feed into analysis.**
  `FactCheckWorkflow.swift:1942`, `ReportView.swift` and `MacReportView.swift`
  each pass it to `TransparencyAnalysisService.analyze` — all three call sites
  are transparency analysis; nothing passes it to report generation, which works
  from the citations. So a PDF-sourced article is analysed as though it had no
  full text at all.

  > **Correction (final review).** An earlier draft of this bullet, and of the
  > §3 correction below, said `ReportView`/`MacReportView` passed it to *report
  > generation*. They do not, and no code path does: `fullTextContent` reaches
  > exactly three consumers, all three of them `analyze`, plus macOS's "Copy
  > Text" menu item. Named here because the payoff this slice is justified by
  > has to be stated accurately.
- **iOS never downloads the PDF.** `FullTextService.downloadAndCachePDF` has one
  call site, `MacScoredDocumentsView.swift:669`. On iOS the remote URL string is
  written into `fullTextPDFPath`, a field `MacFullTextViewer` reads as a file
  path.

Two things make this the binding constraint rather than one gap among several.
The alignment doc's §1.1 fix widened the Europe PMC availability allow-list, so
the PDF tier now offers roughly 95% more free PDFs than it used to. And a
body-less Europe PMC deposit currently parses successfully, so it is returned,
cached and analysed as an article body.

### Two corrections to the gap list

Both were verified against the current code while designing this, and §3 of the
alignment doc is wrong about them.

**Cache writes are already atomic.** §3 says `cachePDF` "writes straight to the
target path" and repeats bmlib's issue #70 failure, a disk that fills mid-write
leaving a truncated file served as complete forever.
`FullTextService.cachePDF` calls `data.write(to:options: .atomic)`, which writes
an auxiliary file and renames. A full disk fails the write and throws. The
truncated-file failure is not reachable through this path. What is reachable is
the read side, which validates nothing: `cachedPDFPath(for:)` checks only
`FileManager.fileExists`.

**Scoring and citation extraction do not read full text.** §3 says the missing
PDF text costs "scoring, citation extraction and transparency analysis". Neither
`ParallelScoringService` nor `ParallelCitationService` reads `fullTextContent`;
they work from abstracts. The cost is real but lands on transparency analysis
alone — not on report generation either, as this spec first said. Stating it
accurately matters because it is the payoff this slice is justified by.

### A gap the list does not name

An abstract-only Europe PMC deposit is indistinguishable from a real article.
`JATSXMLParser.parseToHTML` throws `.noContent` only when the whole rendering is
empty. A deposit carrying `<front>` and `<back>` but no `<body>` renders its
abstract, returns successfully, and becomes `FullTextContent.europePMC` like any
other article. bmlib distinguishes this as `content_kind="abstract"`, holds it
back as a last resort, and never caches it as full text. iOS caches it, shows it,
and hands it to the transparency analyzer as an article body.

## What is built

### 1. `FullTextContentKind`

A new enum in `Models/FullTextModels.swift`, carrying bmlib's four raw values
verbatim so the two remain comparable: `fulltext`, `abstract`, `extracted`,
`none`.

Raw values are written as explicit literals and pinned against literals in tests,
never round-tripped through `init(rawValue:)`. This is the rule
`FullTextDegradation` already records: a compiler-derived case name is a detail a
rename changes silently, and a test that round-trips agrees with the rename and
pins nothing.

### 2. Three fields beside `content`, not inside it

`FullTextResult` gains `contentKind`, `extractedText` and `localPDFPath`.

They sit beside `content` rather than becoming associated values on the enum
cases. That is the argument the type already makes for `warnings` and
`degradation`: the facts describe the retrieval, not the content type, and
burying them makes every `case .europePMCPDF(let url)` in a caller change
whenever a new fact is learned about a fetch. It is also bmlib's own shape, where
`FullTextResult` carries `html`, `pdf_url`, `file_path` and `content_kind` side by
side, so a PDF result offers the link and the text together.

`localPDFPath` is separate from the URL the content enum carries because they are
different things. The enum's URL is where the PDF came from; `localPDFPath` is
where it now is.

The initializer already asserts three combinations the chain never emits. Four
join them:

| Invariant | Why it is asserted rather than trusted |
| --- | --- |
| `extractedText != nil` iff `contentKind == .extracted` | The two are one fact stored twice; a caller branching on the kind must not find the text absent. |
| `.fulltext`/`.abstract` only with `.europePMC` content | Those two kinds name what a *parse* found. No other source is parsed. |
| `.europePMC` content never carries `extractedText` | Extraction is a PDF operation. Text on a parsed source would mean two texts with no rule for which wins. |
| `localPDFPath != nil` only for a PDF-bearing source | A path on a publisher link would give the viewer a file that does not exist. |

The app-side `AppFullTextResult` in `Models/FullTextSource.swift` gains the same
three fields, and like its existing `degradation` field it carries no asserts: it
is built from persisted values as well as live ones, so a value written by a
newer build must decode rather than crash a debug build.

### 3. `PDFTextExtracting` and a PDFKit backend

New in `Packages/BioMedLit/Sources/BioMedLit/Services/`. A protocol plus one
implementation, mirroring bmlib's `PDFConverter` abstract base and its
`PyMuPDFConverter`. The protocol is what lets `FullTextService` be tested without
a real PDF; it is the same seam `URLSession` and `EuropePMCService` already
occupy in that initializer.

PDFKit is a system framework on both platforms the package targets, iOS 17 and
macOS 14, so `Package.swift` gains no dependency. That the `import` links cleanly
from inside a package target is verified by building before anything is written
on top of it.

`PDFExtractionResult` mirrors bmlib's `ConversionResult`: `success`, `pageCount`,
`convertedPages`, `charCount`, `warnings`, the extracted `text`, and a derived
`isComplete` requiring success, every page converted, and a non-zero character
count. Three rules port with it.

- **A PDF that needs a password is a failed result, not an empty successful one.**
  bmlib states this explicitly. The distinction is what stops a locked file being
  logged as a scan. PDFKit reports it as `isLocked` — and *only* `isLocked`, as
  the final review had to correct: bmlib names rejecting on `is_encrypted` as the
  wrong rule, because an owner password restricts permissions without blocking
  reads, so an encrypted-but-readable article would be thrown away. The suite
  carries an owner-password negative control for exactly that.
- **A page yielding no text counts as unconverted** and records a warning naming
  the page, so `convertedPages < pageCount` is what a partial extraction looks
  like.
- **Every empty or partial outcome is logged at warning level.** A scanned PDF
  that yields nothing is invisible otherwise, and a partial extraction must not
  be mistaken for a whole article. This is bmlib's stated reason and it carries
  over unchanged.

Extraction never overwrites text an earlier tier produced, which the
`extractedText`/`.europePMC` invariant above makes unrepresentable rather than
merely avoided.

### 4. The tier chain

Three changes in `FullTextService.fetchFullText`.

**A body-less parse is reported as such.** `JATSXMLParser` already tracks
`producedContent`. It gains `producedBody` beside it, exposed the way
`parseWarnings` is, as a property read after the parse rather than a new return
value, so neither `parseToHTML` nor `parseToMarkdown` changes signature.
`fetchEuropePMCXML` returns the kind alongside the two renderings, and a parse
that produced content but no body yields `.abstract`.

`producedBody` is read from the parser that produced the HTML, matching the
existing rule that the HTML parser's warnings are the ones taken because that is
the rendering the reader is shown. The two parsers read the same bytes, so the
choice is about which instance is authoritative, not about which answer is right.

**An abstract-only result is held back.** Instead of returning immediately,
`fetchFullText` keeps it in a local and runs the PDF tiers. A PDF that yields
text wins. If nothing better arrives, the abstract is returned rather than a bare
link. This mirrors bmlib's `_with_abstract_fallback`, including its rule that a
PDF tier counts as a success as soon as it has a URL, so a download that failed
must not discard an abstract already in hand.

One deviation, and it removes work rather than adding it. bmlib hangs the
publisher link onto the returned abstract, because its `FullTextResult` carries
`html` and `web_url` in the same object. Swift's `FullTextContent` is an enum, so
a case cannot hold both, and it does not need to: `Document.fullTextLinkDestination`
already resolves the DOI page or the PubMed record for every document, and its
documentation records that it deliberately mirrors the chain's own last two
fallbacks for exactly this reason. Carrying a second copy on the result would
give the views two sources for one link and a reason for them to disagree.

This is a visible behaviour change. An article that shows an abstract today may
show a PDF instead.

**Download and extraction happen inside the service.** The PDF tiers download,
cache, and extract before returning. This is what fixes iOS, which today does not
download at all, and it follows the rule the handover records from #186: all four
fetch surfaces run the same retrieval and drift when fixed one at a time.
`downloadAndCachePDF` stays public for a manual re-download.

A service-level flag mirrors bmlib's `convert_pdfs`, defaulting on, so the
download and extraction can be turned off. bmlib's flag also documents that it
applies only when there is a cache to extract from; the Swift cache directory is
created on demand and its failure is already logged, so the flag is the only
control.

### 5. Cache reads are validated

`cachedPDFPath(for:)` gains validation on non-empty content and the `%PDF` magic
bytes, which `downloadAndCachePDF` already checks on the way in and the read path
does not check on the way out. A failing entry is renamed to a `.corrupt` name
and the method returns nil.

Renamed, not deleted, so an operator can inspect it, and returning nil is what
lets the next fetch re-download. This is bmlib's issue #71 reasoning: leaving a
bad entry in place hides a freshly cached PDF behind it and the article
re-downloads on every run forever. A rename that itself fails is logged and the
method still returns nil, because best-effort quarantine must not turn a
recoverable miss into a thrown error.

**One deliberate deviation from bmlib, recorded here as the parity rule
requires.** bmlib writes through a temp file with `fsync` before `os.replace`.
Swift's `.atomic` gives temp-and-rename without the sync. The residual exposure
is a power loss that loses the file rather than one that truncates it. Losing it
is the benign failure, and the read validation above catches it. Hand-rolling an
`fsync` write to close a gap that yields the safe outcome is not worth the
divergence from a well-tested platform primitive.

### 6. Persistence

`Document` gains one optional raw string for the content kind.

Optional because `nil` has to keep meaning "written before this change", which is
not the same as `.none`. That is the pattern `fullTextDegradedReasonRaw` set, and
the reason it was chosen there holds here: a required field strands every earlier
record behind a decode failure that reads as absence. Adding an optional property
is a SwiftData lightweight migration.

`applyFullTextResult`'s `pdfURL` branch changes: the cached local path goes to
`fullTextPDFPath` and the extracted text to `fullTextContent`. That also closes
the standing bug where iOS writes a remote URL into a field the viewer reads as a
file path.

`BioMedLitAdapters.toAppFullTextResult` and `Document.cachedFullTextResult` carry
the three new fields, so a cache hit and a live retrieval stay indistinguishable
to the views. Drift between those two is what #186 had to fix across four
surfaces.

**The reader still gets the PDF.** `cachedFullTextResult` currently picks its
content by asking which stored field is populated, and it tests `fullTextContent`
before `fullTextPDFPath`. Left alone, that is a regression rather than a
no-op: extracted prose would land in `fullTextContent` and every PDF-sourced
article would reopen as text, losing the figures, tables and layout that are the
reason the PDF was kept. The rule is that extraction serves *analysis*, and
display still prefers the document.

So the reconstruction branches on the stored content kind rather than on field
population. A kind of `.extracted` yields `.pdfURL` content, with the extracted
text carried in the result's own `extractedText` field where the analyzer reads
it. `nil` kind keeps today's field-population order, which is what every record
written before this change needs.

That also exposes a second thing the same branch gets away with today.
`URL(string: path)` works there only because the stored value is a remote URL
string; a real filesystem path produces a schemeless URL. Storing the cached path
means that branch needs `URL(fileURLWithPath:)`.

> **Correction (Task 8).** This paragraph originally ended "`MacFullTextViewer`
> is unaffected, since its documentation records that it selects its view from
> the stored fields directly and hands `MacPDFView` a path rather than a URL."
> That reasoning was wrong. Reading a *path* rather than a URL is why it needs
> no `URL` change, and says nothing about its branch **order**, which had the
> identical defect: it re-implemented the same field-population chain, so an
> extracted PDF would have opened as plain prose and never reached
> `MacPDFView`. The fix gave both surfaces one shared decision,
> `Document.displayedFullText`, rather than two parallel chains — the shape
> #186 had already had to correct across four surfaces.

### 7. Stored transparency scores

Handing the analyzer text where it previously saw `nil` moves stored scores. The
mechanism exists: `TransparencyConstants.analyzerVersion` goes from 2 to 3, and
`TransparencyResult.isStale` marks earlier results in `TransparencyDetailView`,
`MacTransparencyDetailView`, `ReportView` and `MacReportView`, keeping the score
visible with a re-analyze button.

Cached full text is **not** retroactively invalidated. An article cached before
this change keeps whatever tier answered at the time, and extraction applies to
the next retrieval. That is the precedent set when §1 landed, and re-running
transparency analysis still does not re-fetch full text.

## Testing

Test-driven throughout. Each regression test reproduces the defect before
asserting the fix, which is how §1's fixes were landed and what makes the test
evidence that the fix was needed.

**Fixtures.** Four PDFs from a committed generator script rather than opaque
binaries, so they are reproducible and reviewable: an ordinary text PDF, an
encrypted one, an image-only one, and a multi-page one with a text-free page. A
body-less JATS fixture joins the existing corpus for the abstract case.

**Extractor.** Text recovered from the ordinary PDF; the encrypted one a failure
rather than an empty success; the image-only one a success with zero characters
and a warning; the mixed one `convertedPages < pageCount` with `isComplete` false.

**Service.** Through the injected `URLSession`, which the initializer documents
as the seam without which the PDF branch has no offline coverage at all. Covered:
an abstract-only parse is held back rather than returned; a PDF that yields text
beats the held abstract; a PDF that yields nothing falls back to the held abstract
with the link attached; and the extraction flag off returns the link alone.

The four new initializer assertions are **not** each given a test, and this spec
should not have promised it: a Swift `assert` traps the process, and XCTest
cannot observe a trap without a crash harness this repo does not have. What is
verified instead is that every combination the chain actually emits *satisfies*
them — each service test above asserts the emitted `contentKind`,
`extractedText` and `localPDFPath` together, so a tier that violated an
invariant would trap the debug test run rather than pass quietly. The asserts
document and enforce the invariants at their write sites; the tests pin what is
written.

**Cache.** A corrupt entry is renamed and the read returns nil; a valid file is
returned untouched; a rename that fails is logged and still returns nil.

**Reconstruction**, in the app's own suite alongside the existing
`FullTextParseWarningsTests`. An `.extracted` record rebuilds as `.pdfURL` and not
as text, which is the regression the display rule exists to stop; the extracted
text is still reachable on the result; a record with a `nil` kind keeps today's
field-population order; and a stored filesystem path survives the round trip,
which is what the `URL(fileURLWithPath:)` change is for.

**Raw values.** The four `FullTextContentKind` strings pinned against literals in
both directions, matching `FullTextServiceParseWarningsTests`'s treatment of
`FullTextDegradation`.

## Files

New:

- `Packages/BioMedLit/Sources/BioMedLit/Services/PDFTextExtractor.swift`
- `Packages/BioMedLit/Tests/BioMedLitTests/PDFTextExtractorTests.swift`
- `Packages/BioMedLit/Tests/BioMedLitTests/FullTextServiceExtractionTests.swift`
- `Packages/BioMedLit/Tests/BioMedLitTests/Fixtures/` and its generator script

Changed:

- `Packages/BioMedLit/Sources/BioMedLit/Models/FullTextModels.swift`
- `Packages/BioMedLit/Sources/BioMedLit/Services/FullTextService.swift`
- `Packages/BioMedLit/Sources/BioMedLit/JATS/JATSXMLParser.swift`
- `Packages/BioMedLit/Sources/BioMedLit/Transparency/Models/TransparencyConstants.swift`
- `ios/MedicalFactChecker/Sources/Models/Document.swift`
- `ios/MedicalFactChecker/Sources/Models/FullTextSource.swift`
- `ios/MedicalFactChecker/Sources/Utilities/BioMedLitAdapters.swift`
- `ios/MedicalFactChecker/Sources/macOS/Views/FactCheck/MacScoredDocumentsView.swift`
- `ios/MedicalFactChecker/Tests/FullTextParseWarningsTests.swift`
- `ios/MedicalFactChecker/MedicalFactChecker.xcodeproj/project.pbxproj`, since a
  new source file that is not added to the target does not build, which is the
  failure `85f37d6` had to fix for `Logger.swift`

Docs, at the end:

- `doc/cross_platform/ios_bmlib_alignment.md`: the §3 table, and the two
  corrections above
- `doc/cross_platform/fulltext_retrieval.md`
- `HANDOVER.md`

## Out of scope

Named so the next spec does not have to rediscover them.

- **The NCBI efetch JATS tier and the ID Converter resolver**, bmlib's tiers 1c
  and 1b′. These are discovery, and they get the next spec.
- **Section segmentation of extracted text**, bmlib's `segmenter.py`. Extraction
  produces prose; giving it structure is separate work with its own contract.
- **Everything in §2**, transparency, and the two-way JATS diff. Separate slices,
  in that order.
