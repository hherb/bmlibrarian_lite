# An unreachable source is not an absent one (#186, #187)

**Date:** 2026-08-23
**Issues:** [#186](https://github.com/hherb/bmlibrarian_lite/issues/186), [#187](https://github.com/hherb/bmlibrarian_lite/issues/187)
**Platform:** Swift — `Packages/BioMedLit` and the `ios/MedicalFactChecker` app target
**Status:** designed

## Problem

PR #185 gave the fallback chain a way to say a better source existed and was
lost, and gave macOS somewhere to show it. Both issues here were split out of
that PR's review: the first is that the new channel models two of three honest
states, and the second is that one iOS surface still cannot render any of them.

**#186 — an unreachable source reports as an absent one.** `FullTextService`
sets `degradation = .jatsParseFailed` only when Europe PMC served XML this
parser could not read. Every other Europe PMC failure takes the `else` branch
and sets nothing: the XML endpoint 503s through all retries, the request times
out, the response is an HTTP status we do not handle. In each case the chain
hands back a PDF or a publisher link with `degradation == nil`, the banner
renders nothing, and the record is cached that way.

By the contract this channel was built on — a fallback must say whether the
machine-readable text was *lost* or *never existed* — a 503 is lost. There are
three honest states, and `FullTextDegradation` models two:

1. never existed (Europe PMC answered 404) — correctly no degradation today
2. we had it and could not read it — `.jatsParseFailed`
3. we could not reach it — **currently indistinguishable from (1)**

`searchForPMCIdAndPDFUrl` has the same defect one layer down, and it is the
sharper one. It returns `(nil, nil)` both when Europe PMC has no record for this
article and when the search itself failed. Those are opposite answers, and the
second skips the machine-readable branch entirely — the article then reports as
having no full text because we could not ask. PR #185 raised its log line from
`.debug` to `.warning`, which makes the failure visible to us; it still says
nothing to the reader.

**#187 — a link-only record has nowhere to speak on iOS.** When the chain falls
through to a publisher link, `applyFullTextResult` caches no content: a web URL
is opened in a browser, not held as text. So `hasFullText` is `false`, and:

- `FullTextTab`'s row shows a download button, so a document we *did* fetch
  reads as unfetched, and a re-tap re-runs the whole chain;
- `ScoredDocumentsView` calls `openURL` directly on a `.webURL` result,
  bypassing `FullTextViewer` and the banner inside it.

The gap is narrower than "iOS has no surface". `FullTextViewer` already renders
the banner, so a *degraded record that cached a PDF* is covered on iOS today.
What has nowhere to go is the link-only record, which is exactly the outcome
`.jatsParseFailed` was added for.

## Scope

In:

- a third and fourth case on `FullTextDegradation`, with explicit raw values;
- setting the new reason at both Europe PMC sites, which means teaching the
  resolution helpers to distinguish "no match" from "the search failed";
- clinician-facing copy for the two new cases;
- the iOS surfaces for a link-only record;
- `doc/cross_platform/jats_parsing.md`, which Kotlin (#165) and bmlib
  (hherb/bmlib#134) port from.

Out, deliberately:

- **A failed Unpaywall lookup.** #186's bullet list includes "Unpaywall answers
  403", but Unpaywall is not Europe PMC, and marking that failure
  `europePMCUnreachable` would state something untrue. It is a real gap — an
  open-access PDF may have existed and gone unchecked — and it wants its own
  reason with its own sentence. Lodged as a follow-up issue instead.
- **A retry affordance for a degraded record that *did* cache content.** Such a
  record has `hasFullText == true`, so no surface offers a re-fetch. Out of
  scope here; the copy invites a retry on the case that can act on it.
- Android and Python, which have no equivalent of this channel yet.

## Design

### 1. Three reasons, and one that is only ever read

`FullTextDegradation` gains two cases:

```swift
public enum FullTextDegradation: String, Sendable, Codable, Equatable {
    case jatsParseFailed = "jatsParseFailed"
    case europePMCUnreachable = "europePMCUnreachable"
    case unspecified = "unspecified"
}
```

The raw values become **explicit**, and a test pins the three literal strings.
This is #163's complaint and #184's lesson answered before this enum accrues
stored history: a persisted string must not be a compiler-derived detail that a
rename silently changes. `jatsParseFailed` keeps the exact string it has shipped
with since PR #185, so no record written since then changes meaning.

`.unspecified` is never written by this build. It exists so
`Document.storedDegradation` has an honest answer when it decodes a raw value a
newer build wrote. The field is only ever populated when a better source *was*
lost, so an unrecognised value still means a loss — but today's code answers
`.jatsParseFailed`, which asserts a specific reason we do not have, and which
after this change is one of three rather than one of one. This mirrors
`JATSParseWarnings.Loss.unspecified` exactly, and for the same reason.

That it is never produced is asserted rather than left to good conduct, beside
the two asserts `FullTextResult.init` already carries:

```swift
assert(
    degradation != .unspecified,
    "no producer emits .unspecified; it names a value read back from a newer build"
)
```

### 2. What sets `europePMCUnreachable`

Two sites, one rule: **everything that is not a 404 and not a cancellation.**

At the XML fetch, the `else` branch of the existing catch — which today only
logs — sets it. That covers `.serverError` surviving all retries, `.networkError`,
and `.invalidResponse` for a status we do not model. `.noFullTextAvailable` (the
404) continues to set nothing, and cancellation continues to throw rather than
fall through. Both exclusions are already pinned by test and stay pinned: a note
that fires on every article never deposited as full text is worthless on the
ones where it is true, and a cancelled fetch is not a dead source at all.

At the resolution helpers, `searchForPMCIdAndPDFUrl` and
`resolvePMCIdAndPDFUrl` stop returning a bare tuple and return a value that also
carries whether a search failed:

```swift
private struct PMCResolution {
    let pmcId: String?
    let pdfRenderURL: String?
    /// A search threw rather than answering. OR-ed across the PMID and DOI
    /// attempts: either one failing leaves us unable to say the article has no
    /// PMC record.
    let searchFailed: Bool
}
```

The degradation is set only when `searchFailed && pmcId == nil`. A failed PMID
search followed by a DOI search that *did* resolve costs the reader nothing —
the XML branch runs, and its own outcome decides. This is the difference between
reporting what we could not do and reporting what it cost.

`FullTextResult.init`'s existing assert — a degradation cannot travel with
`.europePMC` content — still holds under both new sites. If resolution failed we
have no PMC ID, so the XML branch is skipped; and resolution only runs when the
caller supplied no PMC ID.

### 3. Copy: three sentences that read as one family

`ParseWarningMessage.degraded` takes the reason as a payload —
`case degraded(FullTextDegradation)` — and switches for its headline:

| case | sentence |
|---|---|
| `jatsParseFailed` | This article's machine-readable copy could not be read, so a substitute is shown here. *(unchanged)* |
| `europePMCUnreachable` | Europe PMC could not be reached, so a substitute is shown here. Trying again later may retrieve the full article. |
| `unspecified` | A better copy of this article could not be used, so a substitute is shown here. |

They share a shape, so they are recognisable as the same kind of note. The
unreachable sentence claims only that we could not reach Europe PMC — never that
a machine-readable copy exists. It does not: `fullTextXML` 404s for abstract-only
deposits, so a 503 tells us a PMC *record* exists and nothing about whether it
has full text. Asserting otherwise would be the same overclaim in the opposite
direction.

`isWarning` stays `false` for all three. A complete substitute is information; a
warning triangle over content that is fine is the false alarm that trains a
reader to dismiss the banner on the article where text really was discarded.

### 4. macOS is already wired

`MacFullTextTab.noFullTextView` and `MacFullTextViewer` both read
`document.cachedRetrievalNotice`, which reads the stored fields directly. Both
new sentences appear there with no change to either file. That is the payoff of
#185's rule — read a retrieval note from the stored fields, never through a
rebuild of the content — and it is worth stating in the spec so a reviewer does
not read the absence of macOS changes as an omission.

### 5. iOS: the link-only record

Two surfaces, both keyed on predicates that live on `Document` as tested
properties rather than as private computed state inside a view. #185's lesson:
the only real judgement in a view file is the part a test cannot reach.

```swift
/// Fetched, and nothing displayable came back — what a publisher-link fallback
/// stores, since a web URL is opened in a browser rather than held as text.
var isLinkOnly: Bool { fullTextAttempted && !hasFullText && !fullTextUnavailable }
```

**`ScoredDocumentsView`.** The banner renders in `fullTextSection`, for an
`isLinkOnly` record whose notice has something to say, above the existing "Get
Full Text" button — which already *is* the retry the copy invites. Not for a
record that cached content: that one opens in `FullTextViewer`, which banners it
already, and a second copy in the card behind it is the duplication that makes a
notice ignorable.
An **Open Publisher** link joins it, because of the second change: the automatic
`openURL` on a `.webURL` result now fires only when `degradation == nil`.
Without that link the substitute the sentence mentions would be unreachable from
the card.

Suppressing the jump costs one extra tap, on degraded articles only. It buys the
thing the note exists for: an app that hands the reader to Safari before they
have read why is the silent fallback #183 objects to, one surface along. An
ordinary link-only article — no PMC record, nothing lost — keeps today's
behaviour exactly.

**`FullTextTab`.** The row gains a **Link only** badge where it currently shows a
download arrow, so a record we already fetched stops reading as unfetched. The
badge is styled as the existing `unavailableBadge` is, and sits in the same slot.

### 6. The port contract

`doc/cross_platform/jats_parsing.md`'s "The fallback has to admit what it cost"
section currently specifies one reason and the two things that must not set it.
It is rewritten to specify three states, the unknown-value rule, and the
explicit-raw-value requirement. A routing or modelling change that leaves this
document stale re-introduces the defect downstream — a faithful Kotlin port
(#165) or bmlib port (hherb/bmlib#134) would rebuild the two-state version from
the spec while the Swift fix sat next to it.

## Testing

`Packages/BioMedLit`:

- The three raw values, pinned as literals — the encoder's output compared
  against a literal string, not against `Self(rawValue:)`, which would agree with
  a rename. #185's mutation round found exactly this hole in the warnings tests.
- Stubbed-session paths through `fetchFullText`, using the `session` and
  `europePMCService` seams that #185 added: a 503 through all retries sets
  `.europePMCUnreachable`; a 404 sets nothing; a parse failure still sets
  `.jatsParseFailed`; a cancellation still throws.
- Resolution paths through the injected `EuropePMCService`: a throwing search
  with no other route to a PMC ID sets the degradation; a search that answers
  cleanly with no match sets nothing; a failed PMID search followed by a DOI
  search that resolves sets nothing.
- The last of those is the mutation-sensitive one — it is what fails if
  `searchFailed && pmcId == nil` is weakened to `searchFailed`.

`ios/MedicalFactChecker`:

- `ParseWarningMessageTests`: a message for each reason, the three headlines
  distinct, `isWarning == false` for all three, and warnings still outranking a
  degradation on a result carrying both.
- `Document.storedDegradation`: an unrecognised raw value reads back as
  `.unspecified`; a known one round-trips; `nil` stays `nil`.
- `Document.isLinkOnly` across the four states that reach it: never attempted;
  attempted with content cached; attempted, nothing cached, marked unavailable;
  and attempted, nothing cached, not unavailable — the one it is `true` for.

Verification, per HANDOVER's Verify section: both Swift packages green,
`xcodebuild -scheme MedicalFactChecker -destination 'platform=macOS' build`
because app sources change, and the Python and Android suites as regression.
Mutation-test the new predicates with a `cp` backup, keyed on `swift test`'s
exit code.

## Cross-platform

Swift only. Android's full-text chain has no degradation channel at all, and
Python's desktop app does not use this service. The contract document carries
the three-state model forward for both ports; #165 and hherb/bmlib#134 are where
that lands.
