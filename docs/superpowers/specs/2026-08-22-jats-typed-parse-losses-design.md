# Typed parse losses, and a fallback that admits what it cost (#184, #183)

**Date:** 2026-08-22
**Issues:** [#184](https://github.com/hherb/bmlibrarian_lite/issues/184), [#183](https://github.com/hherb/bmlibrarian_lite/issues/183)
**Platform:** Swift — `Packages/BioMedLit` and the `ios/MedicalFactChecker` app target
**Status:** implemented

## Problem

PR #182 built the channel #181 asked for: the parser's unwind audit reaches the
reader as a banner instead of dying in the log. Both issues here are about the
shape of what travels down that channel, and both were split out of that PR's
review rather than found later.

**#184 — the payload is rendered English.** `JATSParseWarnings.diagnostics` is
`[String]`, and those strings are log lines: `"JATS parse ended with 2 open
<fig> — those figures and their content were discarded"`. They are shown to the
reader in the banner's disclosure, persisted verbatim into SwiftData, and
compared by `Equatable`. So the disclosure is permanently English in an app that
localises the sentence directly above it; the banner cannot say "2 tables and 1
figure" because it can only replay sentences; rewording a diagnostic changes
value equality and invalidates every stored record; and tests can only
substring-match, which is why they assert on `"<fig>"` and `"3"` rather than on a
value.

The type also is not homogeneous. `reportParseCompletion` appends its own
no-content line to the unwind diagnostics, and nothing in the type distinguishes
that from a stack that failed to unwind.

**#183 — the fallback cannot say what it cost.** `fetchFullText` tries Europe PMC
XML first and, on failure, falls through to the Europe PMC PDF render, Unpaywall,
and finally a `doi.org` link. That chain is right: a reader who can be handed the
publisher's PDF should get it rather than an error. What is wrong is that two
very different outcomes present identically —

- Europe PMC had no machine-readable text for this article, or
- Europe PMC had it, and our parser choked on it.

Only `FullTextResult.europePMC` carries `warnings`; the other four cases have no
channel at all. So the reader concludes the article is not machine-readable when
in fact the app held the full text and lost it, and in a medical-literature tool
that is a reader mis-attributing our defect to the evidence base.

PR #182 fixed the log half exactly as #183 describes it: the typed
`FullTextError.jatsParseFailure(JATSParseError)` survives to the catch and is
logged at `error` level, distinct from the `warning` used for a genuinely absent
source. Nothing reaches the reader.

### Bookkeeping correction

#183 was closed as completed by commit `464c0b7`, whose own message lists it as
deferred. The code confirms the message: `FullTextResult` still declares
`warnings` on `.europePMC` alone. Reopened before this work started.

## Scope

In:

- #184 in full: typed losses, an explicit versioned persisted form, and the
  banner copy that typing makes possible.
- #183 in full: parser failure through to a note the reader sees, on iOS and
  macOS.
- Hoisting `warnings` out of the `.europePMC` enum case, which #183 forces a
  decision on either way.
- The `doc/cross_platform/jats_parsing.md` port contract.

Out, and lodged rather than ported:

- bmlib and the Kotlin parser have no warnings channel at all — neither the
  audit nor any way to report it. Recorded against the existing porting issues.

## Design

### 1. Losses, not sentences

```swift
public struct JATSParseWarnings: Sendable, Equatable, Codable {
    public enum Loss: Sendable, Equatable {
        case subArticleDepth(Int)
        case openFigures(Int)
        case openTables(Int)
        case exhibitFootnoteDepth(Int)
        case openCaptions(Int)
        case openSections(Int)
        case depthUnderflows(Int)
        case noContent
        case unspecified
    }

    public let losses: [Loss]
    public var isClean: Bool { losses.isEmpty }
    public var diagnostics: [String] { losses.map(\.logLine) }
}
```

`unwindDiagnostics(_:) -> [String]` becomes `unwindLosses(_:) -> [Loss]`, and
every sentence it used to build moves into `Loss.logLine`.

**The wording moves byte-for-byte.** This is not tidiness. `logLine` is what the
parser writes to `BioMedLitLib.logger`, and `JATSRealCorpusTests`'
`testParsingReportsNoContentLoss` reads that log's text. Reproducing each
sentence exactly keeps the log, the corpus digests and that test still, so the
diff is the type and nothing else — and a wording change later is then visibly a
wording change, not smuggled inside a refactor.

`diagnostics` staying available as a computed property is what keeps the banner,
the log loop and the persistence path compiling unchanged; the issue's own
suggested shape, kept.

Two cases earn their place beyond the seven counters:

- **`.noContent`** is the line `reportParseCompletion` appends itself. It was
  already in the payload and already not an unwind imbalance; the type now says
  so, which lets the banner treat it as the different severity it is.
- **`.unspecified`** is "something was lost and we cannot say what", the answer
  `Document.storedParseWarnings` already gives for a record it cannot decode. It
  lives in the package because `losses` is `[Loss]` and the app therefore cannot
  add a case of its own.

The `Mirror`-driven test that pins `isBalanced` against the diagnostics re-points
at `unwindLosses`. It keeps its whole value: a field added to neither the
predicate nor the losses is still a silent disagreement about what "clean" means,
and a hand-written field list would still pass.

### 2. The persisted form is explicit and versioned

`Codable` is hand-written, not synthesised. Swift's synthesis for an enum with
associated values emits `{"openFigures":{"_0":2}}`, and `_0` is a compiler
implementation detail — not something to write into a user's database. The stored
shape is named:

```json
{"schemaVersion": 1, "losses": [{"kind": "openFigures", "count": 2}]}
```

This is #163's complaint answered before it accrues history. That issue exists
because the corpus digest format shipped without a version or explicit
`CodingKeys`; the same mistake is avoidable here for the cost of one `enum
CodingKeys`.

### 3. Legacy records need a test, not a migration

`fullTextParseWarningsJSON` currently holds a bare `[String]` of English.
Decoding rejects it — no `schemaVersion` key — and
`Document.storedParseWarnings` already turns a decode failure into
`.unspecified` rather than a clean parse, because *the field is only ever written
when something was lost*, so "we cannot read it" and "nothing was lost" are
opposite answers.

That behaviour is exactly what is wanted, so this needs no migration code, only a
test that feeds the real legacy payload and asserts the result is **not** clean.

The alternative — mapping old sentences back to losses — was rejected. It would
re-create the wording coupling #184 exists to remove, and it would do so in the
one place where wording is hardest to change, a persisted format. The record is
rewritten from the parser on the next fetch.

A record written before the field existed remains `nil` and reads as clean,
which the port contract already requires.

### 4. The result carries what it cost

`FullTextResult` becomes a struct and its cases become `FullTextContent`:

```swift
public struct FullTextResult: Sendable, Equatable {
    public let content: FullTextContent
    public let warnings: JATSParseWarnings
    public let degradation: FullTextDegradation?

    public var source: FullTextSource { content.source }
    public var html: String? { content.html }
    public var markdown: String? { content.markdown }
}

/// Why this result is not the best source that existed for the article.
public enum FullTextDegradation: String, Sendable, Codable {
    case jatsParseFailed
}
```

The argument for hoisting is already written in this repo, in
`AppFullTextResult`'s doc comment: warnings sit beside `content` "because it
describes the *retrieval*, not the content type — and because burying it in the
enum case would make every `case .html(let content, let markdown)` in the views
change for no benefit". The package's enum does the very thing that comment
forbids, and #183 would otherwise bury a second value in three more cases. The
two models now have the same shape, and `toAppFullTextResult` becomes close to a
field-for-field map.

It is cheap where it might not have been: `BioMedLit.FullTextResult` is named in
two package source files and one package test, and the app switches on it in
exactly one place, `BioMedLitAdapters.toAppFullTextResult`. The accessors are
preserved, so `source`, `html` and `markdown` callers are untouched.

**`FullTextDegradation` has one case and no payload, deliberately.** The parser's
typed `JATSParseError` is already logged at `error` level with the parser's own
message, which is where a bug report gets its detail. Persisting that error's
`String` payloads would repeat precisely the mistake #184 is fixing. An optional
enum rather than a `Bool` because the field names a *reason* from a set that is
currently one — and because `degradation: FullTextDegradation?` reads as what it
is at every call site, which `didFailToParseBetterSource: Bool` does not.

`fetchFullText` records the degradation in the parse-failure catch it already
has, and attaches it to whichever fallback it goes on to return.

Two outcomes must not set it, and both are covered by tests. A Europe PMC 404 is
an *absent* source, not a lost one — marking that degraded would fire the note on
every article never deposited as full text, which is exactly what would make it
worthless on the articles where it is true. And a cancelled fetch already
rethrows rather than falling through, so it never reaches a fallback at all.

### 5. One writer, on the app side

`AppFullTextResult` gains `degradation` beside `warnings`, defaulting to `nil`.
`Document` gains `fullTextDegradedReason: String?`, an added optional property
inside `SchemaV2` — the same lightweight addition `fullTextParseWarningsJSON`
made in `8f23fd1`, and no new schema version for the same reason.

It is written and cleared **only** through `applyFullTextResult`, and
reconstructed by `cachedFullTextResult`. This is not a style preference: the
review of PR #182 found four hand-assignment sites for the warnings field, two of
which defaulted it to clean so a truncated article reopened from the cache
rendered as complete, and a fourth — the upload path — that never cleared it, so
a reader uploading a complete copy *because* the parse was truncated was told
their own upload was missing content. A new field that travels with the cached
content goes through the same single writer, and the upload path clears it.

An unrecognised stored raw value is treated as a degradation of unknown kind and
logged, on the same reasoning as an undecodable warnings payload: the field is
only written when a better source was lost.

### 6. One banner, three states

`ParseWarningBanner` renders:

- **clean** — nothing, as today;
- **`warnings` non-empty** — today's yellow "Some of this article could not be
  displayed", with the technical detail in the disclosure;
- **`degradation` present** — a new informational note, not a warning, that the
  machine-readable copy could not be read and this is a substitute.

Informational rather than yellow because a fallback PDF is *complete*: a warning
triangle over content that is fine is the false alarm that trains a reader to
dismiss the banner on the article where text really was discarded. What is true
and worth saying is narrower — the app's own text extraction lost, which is why
the reader is looking at a PDF and why scoring and citation ran without full
text.

The two are mutually exclusive in practice and the banner does not need to
resolve a conflict: a degradation means the JATS parse *failed*, so there is no
parsed rendering to have lost anything, and `applyFullTextResult` writes both
fields from the same result. Should both ever be set, warnings win — an
incomplete rendering the reader is actually looking at outranks a note about the
source it came from.

One component owns all three so the two facts cannot drift apart in styling or
wording, and both keep the existing seam: the package emits facts, the app
composes the clinician-facing sentence.

Typing the losses also lets `.noContent` stop hiding behind the generic headline.
"None of this article could be displayed" is a different sentence from "some of
it", and the type can now tell them apart.

## Testing

Package:

- `Loss` round-trips through the versioned `Codable` form, every case.
- A legacy bare-`[String]` payload fails to decode.
- `logLine` wording is pinned per case, so the log and the corpus test cannot
  move silently.
- `unwindLosses` and `isBalanced` agree across every single-field state, driven
  by a `Mirror` of the struct as before.
- `fetchFullText` serves unparseable XML plus a PDF fallback through the
  `URLProtocol` stub added in #182, and the returned result carries
  `.jatsParseFailed`. A parse that succeeds carries `nil`.

App:

- A stored legacy payload reads back as a loss, not as clean.
- The degradation survives a cache round-trip through `applyFullTextResult` and
  `cachedFullTextResult`.
- The upload path clears both warnings and degradation.
- Banner state selection: clean, warnings, degradation, and `noContent`'s
  distinct headline.

Then mutation-check the new tests, keying the harness on `swift test`'s **exit
code** — scraping the last `with N failures` line reported killed mutants as
survivors in #180/#181 — and backing up sources with `cp`, never `git checkout`.

## Cross-platform

`doc/cross_platform/jats_parsing.md`'s "Reporting the audit to the caller"
section currently says to carry the diagnostics. It gets two corrections: carry
*typed* losses, with the rendered line as a derived property, and give the
fallback result a way to say a better source was lost. A port that follows the
current text would rebuild #184 from the spec, which is how #169 nearly reached
Kotlin.

bmlib and the Kotlin parser have neither an audit nor a channel, so there is
nothing to correct in them yet; the gap is recorded against the existing issues
rather than ported here.
