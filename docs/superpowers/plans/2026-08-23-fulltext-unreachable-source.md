# An unreachable source is not an absent one — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the full-text fallback chain say "we could not reach Europe PMC" as a state distinct from "Europe PMC had nothing", and give the iOS link-only record a surface that says it.

**Architecture:** `FullTextDegradation` grows from one case to three, with explicit raw values. `FullTextService` sets the new reason at the two Europe PMC sites, which requires the PMC-ID resolution helpers to stop collapsing "no match" into "the search failed". The banner's message value takes the reason as a payload and switches for its sentence; macOS picks both new sentences up for free because it already reads `Document.cachedRetrievalNotice`. On iOS, two view sites key off a new tested `Document.isLinkOnly` predicate.

**Tech Stack:** Swift 5.9+, SwiftUI, SwiftData, XCTest. `Packages/BioMedLit` (SPM package) and `ios/MedicalFactChecker` (multiplatform app target).

**Spec:** `docs/superpowers/specs/2026-08-23-fulltext-unreachable-source-design.md`

## Global Constraints

- **Raw values are explicit and are the persisted contract.** `jatsParseFailed = "jatsParseFailed"`, `europePMCUnreachable = "europePMCUnreachable"`, `unspecified = "unspecified"`. `jatsParseFailed`'s string must not change — records written since PR #185 carry it.
- **The three clinician-facing sentences, verbatim:**
  - `jatsParseFailed` → `This article's machine-readable copy could not be read, so a substitute is shown here.` *(already shipped; do not reword)*
  - `europePMCUnreachable` → `Europe PMC could not be reached, so a substitute is shown here. Trying again later may retrieve the full article.`
  - `unspecified` → `A better copy of this article could not be used, so a substitute is shown here.`
- **Two things must never set a degradation:** a 404 from Europe PMC (the source was absent, not lost) and a cancellation (which throws instead of falling through). Both are pinned by existing tests that must stay green.
- **`.unspecified` is never produced by this build.** It exists only for `Document.storedDegradation` decoding a value a newer build wrote.
- **All three degradations are information, not warnings** — `ParseWarningMessage.isWarning` stays `false` for every one.
- **Never use a retryable failure in a test of the XML branch.** `fetchEuropePMCWithRetry` uses `RetryConfiguration.serverError` — 5 attempts, 5 s initial delay, exponential — so a 503 or a timeout costs ~75 s of real time. Use HTTP 400 (`.invalidResponse`, non-retryable) or `URLError(.badServerResponse)` (not in `RetryHelper`'s transient set).
- **Google-style doc comments on every new declaration; no magic numbers; no inline stylesheets** (`doc/llm/general_golden_rules.md`).
- **New app-target Swift files need an `xcodebuild` check**, not just `swift test` — the SPM target excludes `Sources/macOS`. This plan adds no new app file, but any file it *does* add must have its pbxproj UUIDs verified absent before building.

---

### Task 1: Three reasons, with the raw values pinned

**Files:**
- Modify: `Packages/BioMedLit/Sources/BioMedLit/Models/FullTextModels.swift:66-71` (the enum) and `:110-135` (the `FullTextResult.init` asserts)
- Test: `Packages/BioMedLit/Tests/BioMedLitTests/FullTextServiceParseWarningsTests.swift` (append a new `MARK` section)

**Interfaces:**
- Consumes: nothing.
- Produces: `FullTextDegradation.europePMCUnreachable` and `.unspecified`, both `String`-raw-valued, used by every later task.

- [ ] **Step 1: Write the failing test**

Append to `FullTextServiceParseWarningsTests.swift`, immediately before the file's final closing brace:

```swift
    // MARK: - The persisted contract (#186)

    /// The raw values are the persisted contract, pinned as literals.
    ///
    /// Compared against strings rather than round-tripped through
    /// `init(rawValue:)`, which would agree with a rename and pin nothing —
    /// the hole #185's mutation round found in the warnings tests. A stored
    /// record outlives the case name, so the case name must not be what decides
    /// the string.
    func testTheDegradationRawValuesArePinned() {
        XCTAssertEqual(FullTextDegradation.jatsParseFailed.rawValue, "jatsParseFailed")
        XCTAssertEqual(
            FullTextDegradation.europePMCUnreachable.rawValue, "europePMCUnreachable"
        )
        XCTAssertEqual(FullTextDegradation.unspecified.rawValue, "unspecified")
    }

    /// And decode back, which is the direction `Document.storedDegradation` reads.
    func testTheDegradationRawValuesDecode() {
        XCTAssertEqual(
            FullTextDegradation(rawValue: "europePMCUnreachable"), .europePMCUnreachable
        )
        XCTAssertEqual(FullTextDegradation(rawValue: "unspecified"), .unspecified)
        XCTAssertNil(FullTextDegradation(rawValue: "somethingANewerBuildKnowsAbout"))
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd Packages/BioMedLit && swift test --filter FullTextServiceParseWarningsTests`
Expected: FAIL — `type 'FullTextDegradation' has no member 'europePMCUnreachable'`.

- [ ] **Step 3: Write the implementation**

Replace the enum declaration in `FullTextModels.swift` (keeping the existing doc comment above it, but replacing its final paragraph — the one beginning "One case, no payload, on purpose." — with the text below):

```swift
/// The raw values are explicit because they are a *persisted* contract: a
/// compiler-derived name is a detail a rename silently changes, which is the
/// mistake ``JATSParseWarnings`` was rebuilt to avoid (#184, #163).
/// `jatsParseFailed` keeps the string it has shipped with since PR #185.
///
/// No payload on any case. The parser's typed ``JATSParseError`` is already
/// logged at error level with its own message, which is where a bug report gets
/// its detail; persisting that error's `String` payloads would repeat the
/// mistake this enum's sibling exists to correct.
public enum FullTextDegradation: String, Sendable, Codable, Equatable {
    /// Europe PMC served machine-readable XML and this parser could not read it.
    case jatsParseFailed = "jatsParseFailed"

    /// Europe PMC could not be reached, so we never learned whether it had
    /// machine-readable text for this article.
    ///
    /// Distinct from no degradation at all, which means the source answered and
    /// had nothing. A 503 through every retry, a transport failure, or a search
    /// that threw are all *losses*: the machine-readable copy may have been
    /// there, and the reader is looking at a substitute because of us rather
    /// than because of the evidence base (#186).
    ///
    /// It deliberately does not claim the copy exists. `fullTextXML` answers 404
    /// for abstract-only deposits, so an unreachable endpoint tells us a PMC
    /// record exists and nothing about whether it has full text.
    case europePMCUnreachable = "europePMCUnreachable"

    /// A better source was lost and this build cannot say why.
    ///
    /// Never produced here — no code path emits it. It exists so a reader of a
    /// record written by a *newer* build has an honest answer: the field is only
    /// ever written when something was lost, so an unrecognised value still
    /// means a loss, and naming a specific reason we do not have would be the
    /// overclaim this whole channel exists to prevent.
    case unspecified = "unspecified"
}
```

Then add a third assert inside `FullTextResult.init`, immediately after the existing `degradation == nil || content.source != .europePMC` assert:

```swift
        // The one case with no producer. Asserted rather than trusted, because
        // the type system cannot say "readable but not writable" and a future
        // caller reaching for a vague-sounding case would silently tell every
        // reader we do not know why their article is a substitute.
        assert(
            degradation != .unspecified,
            "no producer emits .unspecified; it names a value read back from a newer build"
        )
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd Packages/BioMedLit && swift test --filter FullTextServiceParseWarningsTests`
Expected: PASS — all tests in the class, including the pre-existing ones.

- [ ] **Step 5: Commit**

```bash
git add Packages/BioMedLit/Sources/BioMedLit/Models/FullTextModels.swift \
        Packages/BioMedLit/Tests/BioMedLitTests/FullTextServiceParseWarningsTests.swift
git commit -m "feat(fulltext): model the unreachable and unspecified degradations (#186)"
```

---

### Task 2: Set the reason when the XML fetch fails

**Files:**
- Modify: `Packages/BioMedLit/Sources/BioMedLit/Services/FullTextService.swift:160-172` (the `else` branch of the Europe PMC catch)
- Test: `Packages/BioMedLit/Tests/BioMedLitTests/FullTextServiceParseWarningsTests.swift`

**Interfaces:**
- Consumes: `FullTextDegradation.europePMCUnreachable` from Task 1.
- Produces: nothing new; `fetchFullText` keeps its signature.

- [ ] **Step 1: Write the failing tests**

Append to the `// MARK: - The persisted contract (#186)` section added in Task 1:

```swift
    /// An endpoint that answered with a status we cannot use is not an absent
    /// source.
    ///
    /// HTTP 400 rather than the 503 the issue names, deliberately: a 503 is
    /// retryable, and `fetchEuropePMCWithRetry` runs `RetryConfiguration.serverError`
    /// — five attempts from a five-second delay — so the honest version of that
    /// test costs about seventy-five seconds of real time. Both statuses reach
    /// the same `else` branch.
    func testAnUnusableEuropePMCStatusIsReportedAsUnreachable() async throws {
        StubURLProtocol.routes = [
            "fullTextXML": (400, Data()),
            "unpaywall": (404, Data()),
        ]

        let result = try await stubbedService()
            .fetchFullText(pmcId: "PMC12759138", doi: "10.1234/example", pmid: "1")

        XCTAssertEqual(result.degradation, .europePMCUnreachable)
    }

    /// The transport failing outright, which reaches the same branch by a
    /// different route — no `HTTPURLResponse` is ever produced, so the status
    /// switch is never entered.
    ///
    /// `URLError.badServerResponse` because it is absent from `RetryHelper`'s
    /// transient set, so it fails once rather than five times over 75 seconds.
    func testAnEuropePMCTransportFailureIsReportedAsUnreachable() async throws {
        StubURLProtocol.failures = ["fullTextXML": URLError(.badServerResponse)]
        StubURLProtocol.routes = ["unpaywall": (404, Data())]

        let result = try await stubbedService()
            .fetchFullText(pmcId: "PMC12759138", doi: "10.1234/example", pmid: "1")

        XCTAssertEqual(result.degradation, .europePMCUnreachable)
    }

    /// The distinction the whole case exists for, asserted as one statement
    /// rather than as two tests that could drift: the same chain, the same
    /// fallback, two different notes.
    func testAnAbsentSourceAndAnUnreachableOneReportDifferently() async throws {
        StubURLProtocol.routes = [
            "fullTextXML": (404, Data()),
            "unpaywall": (404, Data()),
        ]
        let absent = try await stubbedService()
            .fetchFullText(pmcId: "PMC12759138", doi: "10.1234/example", pmid: "1")

        StubURLProtocol.reset()
        StubURLProtocol.routes = [
            "fullTextXML": (400, Data()),
            "unpaywall": (404, Data()),
        ]
        let unreachable = try await stubbedService()
            .fetchFullText(pmcId: "PMC12759138", doi: "10.1234/example", pmid: "1")

        XCTAssertNil(absent.degradation)
        XCTAssertEqual(unreachable.degradation, .europePMCUnreachable)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Packages/BioMedLit && swift test --filter FullTextServiceParseWarningsTests`
Expected: FAIL — the first two assert `.europePMCUnreachable` and get `nil`.

- [ ] **Step 3: Write the implementation**

In `FullTextService.fetchFullText`, replace the `else` clause of the `if case FullTextError.jatsParseFailure` block (the one that currently only logs a warning) with:

```swift
                } else if case FullTextError.noFullTextAvailable = error {
                    // The source answered and had nothing. Never a degradation:
                    // a note that fires on every article never deposited as
                    // full text is worthless on the ones where it is true.
                    BioMedLitLib.logger?.warning(
                        "Europe PMC has no machine-readable text for \(pmcId)",
                        category: .fullText
                    )
                } else {
                    // Everything else — a server error that outlasted its
                    // retries, a transport failure, a status we do not model —
                    // means we could not reach the source, not that it was
                    // empty. Those are opposite answers, and collapsing them
                    // tells the reader the evidence base is thin when the
                    // shortfall is ours (#186).
                    degradation = .europePMCUnreachable
                    BioMedLitLib.logger?.warning(
                        "Europe PMC XML could not be retrieved for \(pmcId): "
                            + "\(error.localizedDescription); falling back to a PDF or publisher link",
                        category: .fullText
                    )
                }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd Packages/BioMedLit && swift test --filter FullTextServiceParseWarningsTests`
Expected: PASS, including the pre-existing `testAnAbsentSourceIsNotADegradation` and the three cancellation tests.

- [ ] **Step 5: Commit**

```bash
git add Packages/BioMedLit/Sources/BioMedLit/Services/FullTextService.swift \
        Packages/BioMedLit/Tests/BioMedLitTests/FullTextServiceParseWarningsTests.swift
git commit -m "fix(fulltext): an unreachable Europe PMC is not an absent one (#186)"
```

---

### Task 3: Teach the resolution helpers that a failed search is not "no match"

**Files:**
- Modify: `Packages/BioMedLit/Sources/BioMedLit/Services/FullTextService.swift:118-132` (the call site in `fetchFullText`), `:345-382` (`resolvePMCIdAndPDFUrl`), `:384-419` (`searchForPMCIdAndPDFUrl`)
- Test: `Packages/BioMedLit/Tests/BioMedLitTests/FullTextServiceParseWarningsTests.swift`

**Interfaces:**
- Consumes: `FullTextDegradation.europePMCUnreachable` from Task 1.
- Produces: a `private struct PMCResolution { let pmcId: String?; let pdfRenderURL: String?; let searchFailed: Bool }` used only inside `FullTextService`.

- [ ] **Step 1: Write the failing tests**

Append to the same `MARK` section:

```swift
    /// A search that *failed* is not a search that found nothing.
    ///
    /// The sharper half of #186: this collapse skips the machine-readable
    /// branch entirely, so the article reports as having no full text because
    /// we could not ask. HTTP 400 makes `EuropePMCService` throw
    /// `httpError`, which is not retryable and so fails on the first attempt.
    func testAFailedIdentifierResolutionIsReportedAsUnreachable() async throws {
        StubURLProtocol.routes = [
            "search": (400, Data()),
            "unpaywall": (404, Data()),
        ]

        let result = try await stubbedService()
            .fetchFullText(pmcId: nil, doi: "10.1234/example", pmid: "1")

        XCTAssertEqual(result.degradation, .europePMCUnreachable)
    }

    /// The negative control it needs. Europe PMC answering "no record" is an
    /// absent source, and marking it degraded would fire the note on every
    /// article that has no PMC record at all — most of PubMed.
    func testAResolutionThatFoundNothingIsNotADegradation() async throws {
        StubURLProtocol.routes = [
            "search": (200, Data(#"{"resultList": {"result": []}}"#.utf8)),
            "unpaywall": (404, Data()),
        ]

        let result = try await stubbedService()
            .fetchFullText(pmcId: nil, doi: "10.1234/example", pmid: "1")

        XCTAssertNil(result.degradation)
    }

    /// A failed first search that the second recovers from costs the reader
    /// nothing.
    ///
    /// The mutation-sensitive one: weakening `searchFailed && pmcId == nil` to
    /// `searchFailed` marks a wholly successful retrieval as degraded, and no
    /// other test in this file would notice. Routed by query substring — the
    /// PMID attempt's URL carries `ext_id`, the DOI attempt's carries `DOI`.
    func testAFailedPMIDSearchTheDOISearchRecoversFromIsNotADegradation() async throws {
        let searchResponse = #"""
        {"resultList": {"result": [{
          "id": "1", "pmid": "1", "pmcid": "PMC12759138", "inPMC": "Y"
        }]}}
        """#
        StubURLProtocol.routes = [
            "ext_id": (400, Data()),
            "DOI": (200, Data(searchResponse.utf8)),
            "fullTextXML": (200, Data(Self.completeArticle.utf8)),
        ]

        let result = try await stubbedService()
            .fetchFullText(pmcId: nil, doi: "10.1234/example", pmid: "1")

        guard case .europePMC = result.content else {
            return XCTFail("expected the Europe PMC parse to succeed, got \(result.content)")
        }
        XCTAssertNil(result.degradation)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Packages/BioMedLit && swift test --filter FullTextServiceParseWarningsTests`
Expected: FAIL — `testAFailedIdentifierResolutionIsReportedAsUnreachable` gets `nil`. The other two should already pass; they are the controls that must stay passing.

- [ ] **Step 3: Write the implementation**

Add the value type just above `resolvePMCIdAndPDFUrl` in `FullTextService`:

```swift
    /// What an identifier resolution learned, including whether it failed.
    ///
    /// A bare `(pmcId:pdfRenderURL:)` tuple could not tell "Europe PMC has no
    /// record for this article" from "we could not ask Europe PMC" — opposite
    /// answers, the second of which skips the machine-readable source entirely
    /// (#186). It is the same collapse #183 corrected one layer up.
    private struct PMCResolution {
        /// The PMC ID, when one was found.
        let pmcId: String?

        /// The free PDF render URL from the search result, when one was offered.
        let pdfRenderURL: String?

        /// Whether any attempted search threw rather than answering.
        ///
        /// OR-ed across the PMID and DOI attempts: either one failing leaves us
        /// unable to say the article has no PMC record.
        let searchFailed: Bool

        /// The answer when a search completed and matched nothing.
        static let noMatch = PMCResolution(pmcId: nil, pdfRenderURL: nil, searchFailed: false)
    }
```

Rewrite the two helpers to return it:

```swift
    private func resolvePMCIdAndPDFUrl(
        pmid: String?,
        doi: String?
    ) async throws -> PMCResolution {
        var searchFailed = false

        // Try resolving by PMID first
        if let pmid = pmid, !pmid.isEmpty {
            let resolved = try await searchForPMCIdAndPDFUrl(query: "ext_id:\(pmid) src:med")
            searchFailed = resolved.searchFailed
            if let pmcId = resolved.pmcId {
                BioMedLitLib.logger?.info("Resolved PMID \(pmid) to \(pmcId)", category: .fullText)
                return resolved
            }
        }

        // Try resolving by DOI
        if let doi = doi, !doi.isEmpty {
            let resolved = try await searchForPMCIdAndPDFUrl(query: "DOI:\"\(doi)\"")
            searchFailed = searchFailed || resolved.searchFailed
            if let pmcId = resolved.pmcId {
                BioMedLitLib.logger?.info("Resolved DOI \(doi) to \(pmcId)", category: .fullText)
                return resolved
            }
        }

        return PMCResolution(pmcId: nil, pdfRenderURL: nil, searchFailed: searchFailed)
    }
```

```swift
    private func searchForPMCIdAndPDFUrl(query: String) async throws -> PMCResolution {
        do {
            let result = try await europePMCService.search(
                query: query,
                pageSize: 1,
                requireAbstract: false
            )
            if let firstArticle = result.articles.first {
                let pmcId = firstArticle.pmcId?.isEmpty == false ? firstArticle.pmcId : nil
                return PMCResolution(
                    pmcId: pmcId,
                    pdfRenderURL: firstArticle.pdfRenderURL,
                    searchFailed: false
                )
            }
        } catch where error.isCancellation {
            // As above: cancelling the search must not be read as "this article
            // has no PMC record", which would skip the Europe PMC branch whole.
            throw CancellationError()
        } catch {
            // Warning rather than debug: "Europe PMC has nothing for this
            // article" and "we could not ask Europe PMC" are opposite answers,
            // and this one skips the machine-readable source entirely. The flag
            // is what carries that distinction to the reader; the log line only
            // ever carried it to us.
            BioMedLitLib.logger?.warning(
                "PMC ID resolution failed for query '\(query)': \(error.localizedDescription)",
                category: .fullText
            )
            return PMCResolution(pmcId: nil, pdfRenderURL: nil, searchFailed: true)
        }
        return .noMatch
    }
```

Update the call site at the top of `fetchFullText`. Note that `degradation` must now be declared *before* the resolution, not after it:

```swift
        // Set when a better source existed and was lost, and attached to
        // whichever fallback the chain returns instead (#183, #186).
        var degradation: FullTextDegradation?

        // Resolve PMC ID and PDF render URL from PMID or DOI if not already available
        var resolvedPmcId = pmcId
        var pdfRenderURL: String?
        if resolvedPmcId == nil || resolvedPmcId?.isEmpty == true {
            let resolved = try await resolvePMCIdAndPDFUrl(pmid: pmid, doi: doi)
            resolvedPmcId = resolved.pmcId
            pdfRenderURL = resolved.pdfRenderURL
            // Only when the failure actually cost us the source. A failed PMID
            // search that the DOI search then recovered from cost the reader
            // nothing, and the XML branch's own outcome decides from here.
            if resolved.searchFailed && resolved.pmcId == nil {
                degradation = .europePMCUnreachable
            }
        }
```

Delete the now-duplicated `var degradation: FullTextDegradation?` declaration that sat below this block.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd Packages/BioMedLit && swift test`
Expected: PASS — the whole package, including `testACancelledIdentifierResolutionDoesNotFallThrough`, which exercises the rewritten `catch where error.isCancellation`.

- [ ] **Step 5: Commit**

```bash
git add Packages/BioMedLit/Sources/BioMedLit/Services/FullTextService.swift \
        Packages/BioMedLit/Tests/BioMedLitTests/FullTextServiceParseWarningsTests.swift
git commit -m "fix(fulltext): a failed PMC search is not an article without a PMC record (#186)"
```

---

### Task 4: The banner says which reason

**Files:**
- Modify: `ios/MedicalFactChecker/Sources/Views/Components/ParseWarningBanner.swift:42-101` (the `ParseWarningMessage` enum) and `:196-205` (the `#Preview`)
- Test: `ios/MedicalFactChecker/Tests/ParseWarningMessageTests.swift:76-113`

**Interfaces:**
- Consumes: all three `FullTextDegradation` cases from Task 1.
- Produces: `ParseWarningMessage.degraded(FullTextDegradation)` — an associated value where the case previously had none. Callers matching `.degraded` must become `.degraded(let reason)` or `case .degraded`.

- [ ] **Step 1: Write the failing tests**

In `ParseWarningMessageTests.swift`, replace `testAFallbackAfterAFailedParseIsReportedAsDegraded`, `testADegradationIsNotStyledAsAWarning` and `testTheThreeStatesReadDifferently` with:

```swift
    func testAFallbackAfterAFailedParseIsReportedAsDegraded() {
        XCTAssertEqual(message(degradation: .jatsParseFailed), .degraded(.jatsParseFailed))
    }

    /// A source we could not reach reports as itself, not as a failed parse.
    ///
    /// The two sound similar and are opposite in whose fault they are: one says
    /// our parser choked on text we held, the other says we never got the text.
    /// Only the second is worth retrying, which is why only its sentence says so.
    func testAnUnreachableSourceIsReportedAsItsOwnReason() {
        XCTAssertEqual(
            message(degradation: .europePMCUnreachable), .degraded(.europePMCUnreachable)
        )
    }

    /// A reason this build does not know still reaches the reader as a note.
    func testAnUnspecifiedDegradationStillSpeaks() {
        XCTAssertEqual(message(degradation: .unspecified), .degraded(.unspecified))
    }

    /// The whole point of the third state: it is information, not a warning —
    /// and that must hold for every reason, not just the one it shipped with.
    ///
    /// The reader is looking at a complete PDF. What is true is that we could not
    /// get the better copy, which is worth saying and is not worth alarming them
    /// about — and styling it as a warning is what would make the real warning
    /// worthless.
    func testNoDegradationIsStyledAsAWarning() {
        for reason in [
            FullTextDegradation.jatsParseFailed, .europePMCUnreachable, .unspecified,
        ] {
            XCTAssertFalse(
                ParseWarningMessage.degraded(reason).isWarning, "\(reason) styled as a warning"
            )
        }
        XCTAssertTrue(ParseWarningMessage.incomplete.isWarning)
        XCTAssertTrue(ParseWarningMessage.noContent.isWarning)
    }

    /// Each state says something different. Headlines that collapsed onto one
    /// another would pass every test above while telling the reader nothing new
    /// — and the two degradations are the pair most at risk of it, since they
    /// differ only in whose shortfall produced the substitute.
    func testTheFiveStatesReadDifferently() {
        let headlines = [
            ParseWarningMessage.incomplete,
            .noContent,
            .degraded(.jatsParseFailed),
            .degraded(.europePMCUnreachable),
            .degraded(.unspecified),
        ].map { String(describing: $0.headline) }

        XCTAssertEqual(Set(headlines).count, 5, "\(headlines)")
    }

    /// Only one of the three invites a retry, because only one is worth
    /// retrying: a deterministic parse failure will fail again.
    func testOnlyTheUnreachableSentenceInvitesARetry() {
        let unreachable = String(
            describing: ParseWarningMessage.degraded(.europePMCUnreachable).headline
        )
        XCTAssertTrue(unreachable.contains("again"), unreachable)

        for reason in [FullTextDegradation.jatsParseFailed, .unspecified] {
            let other = String(describing: ParseWarningMessage.degraded(reason).headline)
            XCTAssertFalse(other.contains("again"), other)
        }
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd ios/MedicalFactChecker && swift test --filter ParseWarningMessageTests`
Expected: FAIL — `enum case 'degraded' has no associated values`.

- [ ] **Step 3: Write the implementation**

In `ParseWarningBanner.swift`, change the `degraded` case, the initialiser, `isWarning` and `headline`:

```swift
    /// A better source existed and could not be used (#183), and why (#186).
    ///
    /// Carries the reason rather than splitting into a case per reason: they
    /// differ only in their sentence, and every other property — the icon, the
    /// tint, `isWarning` — answers the same for all of them. A case each would
    /// invite those answers to drift apart.
    case degraded(FullTextDegradation)
```

```swift
    init?(warnings: JATSParseWarnings, degradation: FullTextDegradation?) {
        if !warnings.isClean {
            self = warnings.losses.contains(.noContent) ? .noContent : .incomplete
        } else if let degradation {
            self = .degraded(degradation)
        } else {
            return nil
        }
    }
```

```swift
    var isWarning: Bool {
        if case .degraded = self { return false }
        return true
    }
```

```swift
    var headline: LocalizedStringKey {
        switch self {
        case .incomplete:
            return "Some of this article could not be displayed. Parts of the text may be missing."
        case .noContent:
            return "None of this article's text could be displayed. Only its reference details are shown."
        case .degraded(.jatsParseFailed):
            return "This article's machine-readable copy could not be read, so a substitute is shown here."
        case .degraded(.europePMCUnreachable):
            return """
                Europe PMC could not be reached, so a substitute is shown here. \
                Trying again later may retrieve the full article.
                """
        case .degraded(.unspecified):
            return "A better copy of this article could not be used, so a substitute is shown here."
        }
    }
```

Add the two new reasons to the `#Preview` so all five renderings are visible:

```swift
        ParseWarningBanner(warnings: JATSParseWarnings(), degradation: .europePMCUnreachable)
        ParseWarningBanner(warnings: JATSParseWarnings(), degradation: .unspecified)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd ios/MedicalFactChecker && swift test --filter ParseWarningMessageTests`
Expected: PASS — all eleven tests in the class.

- [ ] **Step 5: Commit**

```bash
git add ios/MedicalFactChecker/Sources/Views/Components/ParseWarningBanner.swift \
        ios/MedicalFactChecker/Tests/ParseWarningMessageTests.swift
git commit -m "feat(fulltext): the banner says which source was lost, and how (#186)"
```

---

### Task 5: An unrecognised stored reason reports as unspecified

**Files:**
- Modify: `ios/MedicalFactChecker/Sources/Models/Document.swift:624-638` (`storedDegradation`)
- Test: `ios/MedicalFactChecker/Tests/FullTextParseWarningsTests.swift:288-302`

**Interfaces:**
- Consumes: `FullTextDegradation.unspecified` from Task 1.
- Produces: nothing new.

- [ ] **Step 1: Write the failing test**

Replace `testAnUnknownStoredDegradationIsNotReportedAsNone` in `FullTextParseWarningsTests.swift` with:

```swift
    /// Same reasoning as an undecodable warnings payload: the field is only ever
    /// written when something *was* lost, so reporting "no degradation" would
    /// tell the reader the publisher had no machine-readable text when we know
    /// otherwise.
    ///
    /// It reports `.unspecified` rather than guessing a reason. Before there
    /// were three reasons, answering `.jatsParseFailed` was a one-in-one guess;
    /// it is now a one-in-three guess that names our own parser as the culprit,
    /// which is exactly the misattribution this channel exists to prevent.
    func testAnUnknownStoredDegradationIsReportedAsUnspecified() {
        let document = makeDocument()
        document.fullTextPDFPath = "https://example.org/a.pdf"
        document.fullTextSource = AppFullTextSource.unpaywall.rawValue
        document.fullTextDegradedReasonRaw = "somethingANewerBuildKnowsAbout"

        XCTAssertEqual(document.cachedFullTextResult?.degradation, .unspecified)
        XCTAssertEqual(document.cachedRetrievalNotice.degradation, .unspecified)
    }

    /// A reason this build *does* know is not flattened into the unknown one.
    func testAKnownStoredDegradationSurvives() {
        let document = makeDocument()
        document.fullTextPDFPath = "https://example.org/a.pdf"
        document.fullTextSource = AppFullTextSource.unpaywall.rawValue
        document.fullTextDegradedReasonRaw = FullTextDegradation.europePMCUnreachable.rawValue

        XCTAssertEqual(document.cachedRetrievalNotice.degradation, .europePMCUnreachable)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd ios/MedicalFactChecker && swift test --filter FullTextParseWarningsTests`
Expected: FAIL — the first asserts `.unspecified` and gets `.jatsParseFailed`.

- [ ] **Step 3: Write the implementation**

In `Document.swift`, replace the body of `storedDegradation` after the `guard`, and its final doc-comment paragraph:

```swift
    /// Why the cached source is not the best one that existed, or `nil`.
    ///
    /// An unrecognised value is *not* "no degradation". The field is only ever
    /// written when a better source was lost, so a raw value this build does not
    /// know — one written by a newer build — still means something was lost, and
    /// reporting none would tell the reader the publisher had no machine-readable
    /// text when we know otherwise.
    ///
    /// It reports ``FullTextDegradation/unspecified``, which says exactly that
    /// and no more. Naming a specific reason would be a guess, and the reason it
    /// used to guess — a failed parse — blames our own parser for something we
    /// cannot attribute (#186).
    private var storedDegradation: FullTextDegradation? {
        guard let raw = fullTextDegradedReasonRaw else { return nil }
        if let known = FullTextDegradation(rawValue: raw) { return known }
        documentLog.error(
            """
            Unrecognised full-text degradation \(raw, privacy: .public) stored for PMID \
            \(self.pmid, privacy: .public); reporting an unspecified one rather than none.
            """
        )
        return .unspecified
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd ios/MedicalFactChecker && swift test --filter FullTextParseWarningsTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/MedicalFactChecker/Sources/Models/Document.swift \
        ios/MedicalFactChecker/Tests/FullTextParseWarningsTests.swift
git commit -m "fix(fulltext): an unknown stored degradation no longer blames the parser (#186)"
```

---

### Task 6: `Document.isLinkOnly`, the predicate both iOS surfaces need

**Files:**
- Modify: `ios/MedicalFactChecker/Sources/Models/Document.swift:400-408` (beside `hasFullText` and `fullTextAttempted`)
- Test: `ios/MedicalFactChecker/Tests/FullTextParseWarningsTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `Document.isLinkOnly: Bool`, read by Task 7's two views.

- [ ] **Step 1: Write the failing test**

Append to `FullTextParseWarningsTests.swift`, before the final closing brace:

```swift
    // MARK: - The link-only record (#187)

    /// The four states that reach the predicate, in one test so that a change
    /// widening it has to face the three it must stay false for.
    ///
    /// It lives on the model rather than inside a view because it is the whole
    /// judgement behind two surfaces, and a private computed property in a
    /// `View` cannot be tested at all (#185).
    func testALinkOnlyRecordIsTheOneThatWasFetchedAndCachedNothing() {
        let neverAttempted = makeDocument()
        XCTAssertFalse(neverAttempted.isLinkOnly)

        let cachedContent = makeDocument()
        cachedContent.applyFullTextResult(
            AppFullTextResult(
                content: .pdfURL(URL(string: "https://example.org/a.pdf")!), source: .unpaywall
            )
        )
        XCTAssertFalse(cachedContent.isLinkOnly)

        let unavailable = makeDocument()
        unavailable.fullTextUnavailable = true
        XCTAssertFalse(unavailable.isLinkOnly)

        let linkOnly = makeDocument()
        linkOnly.applyFullTextResult(
            AppFullTextResult(
                content: .webURL(URL(string: "https://doi.org/10.1234/example")!), source: .doi
            )
        )
        XCTAssertTrue(linkOnly.isLinkOnly)
        XCTAssertFalse(linkOnly.hasFullText, "a web URL is opened, not cached as text")
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd ios/MedicalFactChecker && swift test --filter FullTextParseWarningsTests`
Expected: FAIL — `value of type 'Document' has no member 'isLinkOnly'`.

- [ ] **Step 3: Write the implementation**

Add to `Document.swift`, immediately after `fullTextAttempted`:

```swift
    /// Whether this document was fetched and nothing displayable came back.
    ///
    /// What a publisher-link fallback stores: a web URL is opened in a browser
    /// rather than held as text, so `hasFullText` is false even though the whole
    /// chain ran. Without this the iOS list shows such a record a download
    /// button and it reads as never-fetched (#187), which is also the state in
    /// which a retrieval note has the most to say and the least chance of being
    /// seen.
    ///
    /// Distinct from ``fullTextUnavailable``, which is the chain reporting that
    /// no source had anything at all.
    var isLinkOnly: Bool {
        fullTextAttempted && !hasFullText && !fullTextUnavailable
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd ios/MedicalFactChecker && swift test --filter FullTextParseWarningsTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/MedicalFactChecker/Sources/Models/Document.swift \
        ios/MedicalFactChecker/Tests/FullTextParseWarningsTests.swift
git commit -m "feat(fulltext): name the link-only record on the model (#187)"
```

---

### Task 7: The two iOS surfaces

**Files:**
- Modify: `ios/MedicalFactChecker/Sources/Views/FactCheck/ScoredDocumentsView.swift:437-461` (`fullTextSection`) and `:655-662` (the `.webURL` branch of `fetchFullText`)
- Modify: `ios/MedicalFactChecker/Sources/Views/FactCheck/FullTextTab.swift:405-420` (the row's trailing slot) and its constants enum at `:24-34`

**Interfaces:**
- Consumes: `Document.isLinkOnly` from Task 6; `ParseWarningBanner` unchanged in signature.
- Produces: no new public API.

- [ ] **Step 1: Add the notice to the card**

In `ScoredDocumentsView.swift`, replace the `else` branch of `fullTextSection` with a stack that puts the notice above the fetch button:

```swift
        } else {
            // Not yet attempted, or attempted and left with only a link.
            VStack(alignment: .leading, spacing: ScoredDocumentsConstants.sectionSpacing) {
                linkOnlyNotice
                fullTextFetchView
            }
        }
```

Add `linkOnlyNotice` beside `fullTextFetchView`:

```swift
    /// What a link-only record has to say, and the way to reach the substitute.
    ///
    /// Rendered here rather than in ``FullTextViewer`` because this record has
    /// no content to open that viewer with — which is exactly the outcome the
    /// degradation channel was added for, and the one place iOS could not speak
    /// (#187). A record that *did* cache content is left alone: it opens in the
    /// viewer, which banners it already, and a second copy behind it is the
    /// duplication that makes a notice ignorable.
    ///
    /// The "Get Full Text" button below is the retry the unreachable sentence
    /// invites, so no second retry control is added.
    @ViewBuilder
    private var linkOnlyNotice: some View {
        if document.isLinkOnly {
            VStack(alignment: .leading, spacing: ScoredDocumentsConstants.sectionSpacing) {
                ParseWarningBanner(
                    warnings: document.cachedRetrievalNotice.warnings,
                    degradation: document.cachedRetrievalNotice.degradation
                )

                if let doi = document.doi, let url = PlatformHelper.doiURL(for: doi) {
                    Link(destination: url) {
                        Label("Open Publisher", systemImage: "safari")
                            .font(.caption)
                    }
                }
            }
        }
    }
```

`ScoredDocumentsConstants` has only `inlineProgressScale` and `sortPreferenceKey`, so add the spacing there rather than repeating the literal the file's stacks already use inline:

```swift
    /// Vertical gap between the rows of the full-text section.
    static let sectionSpacing: CGFloat = 8
```

- [ ] **Step 2: Stop the silent jump to Safari**

In the same file's `fetchFullText`, replace the `.webURL` branch:

```swift
                    // A web URL is opened rather than shown — but only when
                    // there is nothing to explain first. Handing the reader to
                    // Safari before they have read why this is a substitute is
                    // the silent fallback #183 objects to, one surface along;
                    // the note and an Open Publisher link are in the card.
                    if case .webURL(let url) = result.content {
                        if result.degradation == nil {
                            openURL(url)
                        }
                    } else {
                        showFullTextViewer = true
                    }
```

- [ ] **Step 3: Make the list row stop reading as unfetched**

In `FullTextTab.swift`, in `FullTextDocumentRow`'s trailing slot, insert an `isLinkOnly` branch *before* the download button:

```swift
                if isLoadingFullText {
                    ProgressView()
                        .scaleEffect(0.8)
                } else if document.hasFullText {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if document.isLinkOnly {
                    // Fetched, and all we got was a link. A download button here
                    // says "not fetched yet", which is wrong and invites a tap
                    // that re-runs the whole chain (#187).
                    linkOnlyBadge
                } else if !document.fullTextUnavailable {
                    Button(action: onFetchFullText) {
                        Image(systemName: "arrow.down.circle")
                            .font(.title3)
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                }
```

Add the badge beside `unavailableBadge`, matching its shape exactly so the two read as the same kind of label:

```swift
    /// Badge shown when the fetch returned only a publisher link.
    ///
    /// Tinted with the accent colour rather than orange: a link is a working
    /// outcome, not a failure, and the reason it is only a link — if there is
    /// one — is said in full on the document's card.
    private var linkOnlyBadge: some View {
        Text("Link only")
            .font(.caption2)
            .foregroundColor(.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.15))
            .cornerRadius(4)
    }
```

- [ ] **Step 4: Verify both targets build and every test still passes**

Run:
```bash
cd ios/MedicalFactChecker && swift test
xcodebuild -scheme MedicalFactChecker -destination 'platform=macOS' build
```
Expected: tests PASS; build SUCCEEDED. The `xcodebuild` run is not optional — `swift test` excludes `Sources/macOS`, so it cannot see a macOS-only compile break.

- [ ] **Step 5: Commit**

```bash
git add ios/MedicalFactChecker/Sources/Views/FactCheck/ScoredDocumentsView.swift \
        ios/MedicalFactChecker/Sources/Views/FactCheck/FullTextTab.swift
git commit -m "fix(fulltext): give the iOS link-only record somewhere to speak (#187)"
```

---

### Task 8: The port contract, and the gap this PR does not close

**Files:**
- Modify: `doc/cross_platform/jats_parsing.md:1251-1276` (the "The fallback has to admit what it cost" section)

**Interfaces:**
- Consumes: the finished model from Tasks 1–3.
- Produces: the specification Kotlin (#165) and bmlib (hherb/bmlib#134) port from.

- [ ] **Step 1: Rewrite the contract section**

Replace the paragraphs from "Give the result a way to say a better source existed" through "…and a cancelled fetch is not a dead source at all." with:

```markdown
Give the result a way to say a better source existed and was lost, alongside the
warnings rather than inside the case that carries the content: both facts
describe the *retrieval*, not the content type, and burying them in the cases
means every consumer's pattern match changes each time a new fact is learned
about a fetch. The reason needs no payload — the parser's typed error belongs in
the log, where a bug report reads it; persisting its message would be the same
mistake as persisting the diagnostics.

There are **three** honest states, and modelling two of them is what leaves the
reader misinformed (#186):

1. **the source was absent** — it answered, and had no machine-readable text.
   No degradation. A note that fires on every article never deposited as full
   text is worthless on the ones where it is true.
2. **we had it and could not read it** — our parser failed on text we held.
3. **we could not reach it** — a server error that outlasted its retries, a
   transport failure, a status we do not model, or an identifier *search* that
   threw. Distinct from (1): the source may well have had the text, and the
   reader is looking at a substitute because of us.

State (3) has a trap one layer down. An identifier resolution that returns
"nothing" for both "no record exists" and "the search failed" collapses (1) into
(3) before the fetch is even attempted, and the second answer skips the
machine-readable source entirely. Return the failure alongside the result, OR-ed
across every attempted query, and raise the degradation only when a search
failed **and** no identifier was found: a failed first query that a later one
recovers from cost the reader nothing.

Its sentence must not claim the machine-readable copy exists — a full-text
endpoint answers "not found" for abstract-only deposits, so an unreachable one
tells you a record exists and nothing about whether it has full text. Say that
the source could not be reached, and invite a retry, which is the one thing that
distinguishes it from the other two: a parse failure is deterministic and will
fail again.

**Persist the reason as an explicit string, never a compiler-derived case name.**
A reader that meets a value it does not know must not report "no degradation" —
the field is only ever written when something *was* lost — and must not guess a
known reason either, which names a culprit the record does not identify. Model
an explicit "unspecified" reason for exactly this, produced by no writer and
asserted against, so it can only ever arrive by being read.

Two things must **not** set it. A source that answered "not found" was absent,
not lost. And a cancelled fetch is not a dead source at all.
```

- [ ] **Step 2: Verify the section is internally consistent**

Run: `sed -n '/### The fallback has to admit what it cost/,/^### /p' doc/cross_platform/jats_parsing.md`
Expected: the three states, the resolution trap, the raw-value rule and the two exclusions all present, with no leftover sentence claiming there is one reason.

- [ ] **Step 3: Lodge the gap this PR leaves open**

The spec puts a failed Unpaywall lookup out of scope: it is not a Europe PMC failure, so `europePMCUnreachable` would misstate it, and it wants its own reason and sentence.

```bash
gh issue create \
  --title "Full text: a failed Unpaywall lookup is reported as an article with no open-access PDF" \
  --body "$(cat <<'BODY'
Split out of #186, which deliberately left it.

`FullTextService.fetchFullText` catches every Unpaywall failure and falls
through to a publisher link with no degradation set. So "Unpaywall has no open
access location for this DOI" and "we could not reach Unpaywall" — a 403, a
timeout, a decode failure — reach the reader identically. That is the same
collapse #183 fixed for Europe PMC's XML and #186 fixed for its search.

#186 could not simply reuse `europePMCUnreachable`: Unpaywall is a different
source, and labelling its failure as Europe PMC being unreachable states
something untrue. It needs its own reason and its own sentence — something that
says an open-access PDF may have existed and was not checked for, without
claiming one did.

Smaller in consequence than #186, because the fallback below Unpaywall is a
publisher link either way and no machine-readable text is at stake. Still a
reader being told the evidence base is thinner than we know it to be.
BODY
)"
```

- [ ] **Step 4: Commit**

```bash
git add doc/cross_platform/jats_parsing.md
git commit -m "docs(jats): specify the three states a fallback can be in (#186)"
```

---

### Task 9: Full verification

**Files:** none modified.

- [ ] **Step 1: Run every suite the change touches**

```bash
cd Packages/BioMedLit && swift test
cd ios/MedicalFactChecker && swift test
xcodebuild -scheme MedicalFactChecker -destination 'platform=macOS' build
```
Expected: 0 failures from both packages; BUILD SUCCEEDED.

- [ ] **Step 2: Run the untouched platforms as a regression check**

```bash
pytest tests/
cd android/MedicalFactChecker && ./gradlew test
python .github/scripts/lint_delta.py --base-ref origin/master
```
Expected: 0 failures; `lint_delta` reports no new findings. Neither Python nor Android is touched by this change; they run because HANDOVER's Verify section makes them the gate, and because the contract document they port from did change.

- [ ] **Step 3: Mutation-test the two new predicates**

Back the file up with `cp` — **not** `git checkout`, whose restore wipes every uncommitted change in the file — and key the harness on `swift test`'s **exit code**, never on scraping its output, which prints several summaries of which the last is not the verdict.

Mutants that must be killed:
1. `FullTextService.swift`: `resolved.searchFailed && resolved.pmcId == nil` → `resolved.searchFailed`. Killed by `testAFailedPMIDSearchTheDOISearchRecoversFromIsNotADegradation`.
2. `FullTextService.swift`: delete `degradation = .europePMCUnreachable` from the XML `else` branch. Killed by `testAnUnusableEuropePMCStatusIsReportedAsUnreachable`.
3. `FullTextService.swift`: move `degradation = .europePMCUnreachable` into the `noFullTextAvailable` branch. Killed by `testAnAbsentSourceAndAnUnreachableOneReportDifferently`.
4. `Document.swift`: `isLinkOnly` → drop the `!fullTextUnavailable` conjunct. Killed by `testALinkOnlyRecordIsTheOneThatWasFetchedAndCachedNothing`.
5. `Document.swift`: `storedDegradation` unknown-value return → `.jatsParseFailed`. Killed by `testAnUnknownStoredDegradationIsReportedAsUnspecified`.
6. `ParseWarningBanner.swift`: `.degraded(.europePMCUnreachable)` headline → the `.jatsParseFailed` sentence. Killed by `testTheFiveStatesReadDifferently`.

Any survivor is a missing assertion, not an acceptable result — write the test that kills it before moving on.

- [ ] **Step 4: Update HANDOVER and open the PR**

Move the slice into "Recently landed", compress it to the rules that still bind, drop #186 and #187 from "Potential follow-ups", add the new Unpaywall issue, and keep the file under 500 lines. Then commit, push and open a PR to `master` linking both issues.
