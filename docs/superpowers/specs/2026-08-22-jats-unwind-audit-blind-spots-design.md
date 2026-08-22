# JATS unwind audit: closing its two blind spots (#180, #181)

**Date:** 2026-08-22
**Issues:** [#180](https://github.com/hherb/bmlibrarian_lite/issues/180), [#181](https://github.com/hherb/bmlibrarian_lite/issues/181)
**Platform:** Swift — `Packages/BioMedLit` and the `ios/MedicalFactChecker` app target
**Status:** approved, pending implementation

## Problem

PR #179 (#175) moved the end-of-parse unwind audit onto the code path production
actually uses. It now runs everywhere it should, and it is still unable to do the
two things a safety net exists for.

**#180 — it cannot see an over-decrement.** `exhibitFootnoteDepth` and
`subArticleDepth` are decremented as `max(0, n - 1)` at three sites, and
`unwindDiagnostics` only tests `> 0`. The clamp guarantees the counter can never
*be* negative, so the evidence is destroyed before the audit could read it. Worse
than blind: if the depth is 2 and three decrements arrive, the third clamps to 0
and the counter reads "balanced" for the rest of the document while a real
`<table-wrap-foot>` is still open — the audit then **certifies a defective parse
as clean**, which is the opposite of what a net is for.

Not live today. The current code is symmetric at every site. The exposure is to a
future edit, which is precisely what the comment at `case "fn"` says the
element-stack test exists to defend against; the clamp defeats that defence.

**#181 — nothing a caller can act on.** `JATSParseUnwindState` and
`unwindState` are `internal`, `reportParseCompletion` is `private`, and the
diagnostics go to `BioMedLitLib.logger` and nowhere else.
`FullTextService.fetchEuropePMCXML` returns `(html, markdown)` with no channel to
say "this article came back truncated". The UI renders a gutted article exactly as
it renders a complete one, so a reader cannot tell a parser defect from a thin
deposit. This is the residual form of #175: the diagnostic exists, it is on the
right code path, and it changes nothing anyone can act on.

## Correction to #181 as filed

The issue states the broad `catch` in `fetchEuropePMCXML` relabels "anything —
including a `CancellationError` from a torn-down task" as an XML parse error.
**That is not reachable today.** The `do` block wraps only two synchronous calls,
`parseToHTML()` and `parseToMarkdown()`, and the only error they throw is
`JATSParseError`, which the *first* catch already takes. `session.data(for:)` sits
outside the block, so a cancelled fetch propagates untouched.

The flattening of the typed error is real and is fixed here. The broad catch is
dead defensive code and a trap for a future edit that makes the block async; it is
made honest rather than presented as a live bug fix.

## Scope

In:

- #180 in full, including the type hardening the issue suggests.
- #181 in full, parser through to a banner the reader sees, on iOS and macOS.
- The adjacent typed-error fix in `fetchEuropePMCXML`.
- The `doc/cross_platform/jats_parsing.md` port contract.

Out, and already lodged:

- bmlib has no audit at all (hherb/bmlib#134); Kotlin has none either (#165).
  Both get a note pointing at the seventh counter; neither is ported here.
- #176 (`FullTextTab` swallows full-text errors with no message and no log) is
  the same defect class one layer up, in Python. Not this slice.

## Design

### 1. Count the underflow; keep the clamp (#180)

The clamp is **correct for routing** and must stay. A negative
`exhibitFootnoteDepth` would let the next legitimate `<table-wrap-foot>` bring the
counter back to 0, switching footnote routing off while a real footnote is open —
a live content-loss bug strictly worse than the clamp. So the clamp stays and the
evidence is kept beside it:

```swift
/// End tags that arrived with nothing to close.
private var depthUnderflows = 0
```

incremented at each of the three decrement sites when the counter is already zero:

```swift
if exhibitFootnoteDepth == 0 { depthUnderflows += 1 }
exhibitFootnoteDepth = max(0, exhibitFootnoteDepth - 1)
```

`depthUnderflows` becomes a seventh field of `JATSParseUnwindState` and a seventh
line in `unwindDiagnostics`. It cannot false-positive: a well-formed document
never delivers an unmatched end tag, and `XMLParser` refuses one that does.

### 2. Make an invalid unwind state unconstructible (#180, second half)

`JATSParseUnwindState` has same-typed `Int` fields and a defaulted memberwise
init, so a negative value is constructible and
`JATSParseGuardTests.testANegativeCountIsNotReportedAsAnImbalance` currently
codifies that *tolerance*.

Replace it with an explicit clamping `init`, making all seven fields `let`, and
add:

```swift
var isBalanced: Bool { self == JATSParseUnwindState() }
```

`isBalanced` must agree with `unwindDiagnostics` by construction. That agreement
is pinned by test, not by comment: a field added to one and not the other is
exactly the drift this is meant to stop.

The existing negative-tolerance test is rewritten to assert the value is
**clamped at construction** — strictly stronger than asserting no diagnostic is
emitted for it.

### 3. A warnings channel, parser to reader (#181)

`JATSParseWarnings` carries **facts, not copy**:

```swift
public struct JATSParseWarnings: Sendable, Equatable {
    public let diagnostics: [String]
    public var isClean: Bool { diagnostics.isEmpty }
}

public private(set) var parseWarnings = JATSParseWarnings(diagnostics: [])
```

populated in `reportParseCompletion` from two of its three complaint kinds:

| Complaint | Reaches the reader | Why |
| --- | --- | --- |
| Unwind imbalance | yes | Content the parser held was provably discarded. |
| No title, abstract or body extracted | yes | The reader sees an accession number and nothing else. |
| Zero authors | **no**, log only | A metadata gap, not a truncation. Editorials and corrections legitimately have none, so firing on it would train readers to dismiss the banner. |

The reader-facing **sentence lives in the app target**, not in BioMedLit. The
package has no clinician-facing copy today beyond `LocalizedError`, and wording
placed in a parser package cannot be localized with the rest of the UI. The
package emits diagnostics; the app composes the sentence and offers the
diagnostics as expandable detail.

The channel, hop by hop:

1. `JATSXMLParser.parseWarnings` — public, populated in `reportParseCompletion`.
2. `FullTextService.fetchEuropePMCXML` returns warnings alongside the text.
   Two parsers run over the same document (`XMLParser` is consumed by its first
   parse). Both produce the same warnings; the **HTML parser's are taken**, since
   that is the parse the reader is shown. Commented at the site.
3. `FullTextResult.europePMC(html:markdown:warnings:)`.
4. `AppFullTextResult.warnings` — **not** inside
   `AppFullTextContentType.html`. Warnings describe the retrieval, not the
   content type, and putting them in the enum case would force every
   `case .html(let a, let b)` pattern match across five views to change for no
   benefit.
5. `Document.fullTextParseWarningsJSON: String?` — see below.
6. A banner in `FullTextViewer` (iOS) and `MacFullTextViewer` (macOS).

### 4. Persistence, or the banner is nearly invisible

Full text is cached on the `Document` and re-rendered from it:

- `MacFullTextViewer` renders from `document.fullTextHTML` and **never sees the
  in-flight result at all**, so without persistence macOS would never show the
  banner.
- `FullTextTab` rebuilds an `AppFullTextResult` from the `Document` on reopen, so
  iOS would show the banner once and lose it.

`Document` therefore gains `fullTextParseWarningsJSON: String?`, mirroring the
existing `transparencyResultJSON` pattern — an added optional property, which
SwiftData migrates lightweight, so **no new `SchemaVersion` is required**. Written
by `applyFullTextResult`, cleared by `markFullTextUnavailable` and
`clearFullTextCache` alongside the content they belong to, and read back by the
cached-result constructors in `FullTextTab`.

A stale-warning bug is the risk here: warnings cleared out of step with the
content they describe would label the wrong article. Every site that assigns or
nils `fullTextHTML`/`fullTextContent` must handle the warnings field in the same
statement, pinned by a round-trip test.

### 5. Preserve the typed parse error

`FullTextError` gains `case jatsParseFailure(JATSParseError)` so `.noContent`,
`.alreadyParsed` and `.parsingFailed` stay distinguishable to callers instead of
collapsing into one string. `isRetryable` must be **false** for it: a parse
failure is deterministic, so retrying burns the network budget to reach the same
result. `errorDescription` delegates to the wrapped error.

`xmlParseError(String)` is **kept, not replaced** — the broad second catch has no
`JATSParseError` to wrap. That catch is unreachable today (see *Correction*
above) and exists only against a future async edit; it is left in place and
commented as such rather than deleted.

Adding a case is safe here: nothing outside the enum switches over
`FullTextError` exhaustively — the five app call sites all use
`if case FullTextError.noFullTextAvailable`. Only `errorDescription` and
`isRetryable` inside the enum need the new case.

### 6. A test seam on `FullTextService`

`FullTextService.init(email:)` builds its `URLSession` internally, so
`fetchEuropePMCXML` **cannot be exercised offline at all** and both the warnings
channel and the typed error would ship untested. Add `init(email:session:)`, with the
existing session construction moved to a static factory used as the default
argument so production behaviour is unchanged, and drive the tests through a
stubbed `URLProtocol`. No test stub exists in `Packages/BioMedLit/Tests` yet; this slice
adds the first.

### 7. Dead code removed

`BioMedLitAdapters.toFullTextContent` and the `FullTextContent` enum below it
have no callers anywhere in the repo. They are a parallel representation of
exactly the thing being changed, so keeping them means making the warnings change
twice in a copy nothing runs. Both are deleted; the compiler and the macOS app
build are the verification.

## Testing

Every claim below is a test that fails before the change.

**`JATSParseGuardTests` (pure function):**

- Each of the seven fields produces its own diagnostic, naming what it cost.
- `depthUnderflows` produces a diagnostic; zero produces none.
- `isBalanced` agrees with `unwindDiagnostics(_:).isEmpty` across the seven
  single-field states and the all-fields state.
- A negative argument is clamped at construction.

**`JATSParseGuardTests` (parser-driven):** an end tag delivered with no matching
start, via the `XMLParserDelegate` callbacks directly — the one thing well-formed
XML cannot do, and the same trick the existing counter-to-field tests use.
Increments `depthUnderflows` at each of the three sites.

**Parser warnings:** a clean corpus parse leaves `parseWarnings.isClean`; a parse
that produced nothing reports it; zero authors does **not** appear in
`parseWarnings` while still reaching the log.

**Service:** over a stubbed `URLProtocol` — warnings propagate to
`FullTextResult`; a malformed document surfaces the typed `JATSParseError` rather
than a flattened string; the typed error is not retried.

**App target:** the adapter carries warnings onto `AppFullTextResult`;
`Document.applyFullTextResult` round-trips them through JSON; `clearFullTextCache`
and `markFullTextUnavailable` clear them; the cached reconstruction in
`FullTextTab` preserves them.

**Mutation testing** on the new guards, per repo convention — with a `cp` backup,
never `git checkout`, since the restore step wipes uncommitted work in the file.

**Full gates:** `swift test` in both `Packages/BioMedLit` and
`ios/MedicalFactChecker`, plus `xcodebuild -scheme MedicalFactChecker
-destination 'platform=macOS' build` because app sources change.

## Cross-platform

`doc/cross_platform/jats_parsing.md` is the port contract; a change that leaves it
stale re-introduces the defect downstream. It gains the seventh counter and the
clamp-plus-count rule.

bmlib (hherb/bmlib#134) and Kotlin (#165) have no audit at all and are not ported
here; both issues get a comment naming the underflow counter so a future port
carries it.

## Landing

One PR onto `master` closing both issues, with #180 as its own commit and #181
built on top. Not stacked: a stacked PR merged into a base branch that has since
moved leaves the linked issues open, which has already happened once in this repo.
