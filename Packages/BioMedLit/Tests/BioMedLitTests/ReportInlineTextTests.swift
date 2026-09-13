// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2026 Dr Horst Herb
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

import XCTest
@testable import BioMedLit

/// Splitting a line of report markdown into what a renderer draws.
///
/// The report used to be read by two parsers with different ideas of what a
/// reference is: ``ReportFormatter/flattenedReferenceLinks(in:)`` for export,
/// and a private copy in each on-screen view. #230 widened the first and left
/// the second, so the screen printed `(doc:pmid-889149)` where the export had
/// stopped doing so (#233). One recognition, answered here, is what keeps the
/// two from drifting again.
///
/// Every expectation is a literal written by hand.
final class ReportInlineTextTests: XCTestCase {

    private let identity = "8A1D4C22-0000-4000-8000-000000000001"

    // MARK: - Document references

    /// A well-formed reference is one segment naming its document.
    func testAWellFormedDocumentReferenceNamesItsDocument() {
        let parsed = ReportInlineText(
            parsing: "Evidence is mixed [Smith et al., 2016](doc:\(identity))."
        )

        XCTAssertEqual(parsed.segments, [
            .prose("Evidence is mixed "),
            .documentReference(displayText: "Smith et al., 2016", documentIdentity: identity),
            .prose("."),
        ])
        XCTAssertEqual(parsed.removedReferences, [])
    }

    /// A reference whose display text is not "Author, Year" still names its
    /// document.
    ///
    /// The on-screen parser required that shape, so `[the WHO guideline](doc:…)`
    /// fell through to SwiftUI's own markdown parser, which made it a link to
    /// `doc:<identity>` — a scheme the app hands to the system, which opens
    /// nothing. The target is what makes this a reference, not its wording.
    func testADocumentReferenceNeedNotReadAsAuthorAndYear() {
        let parsed = ReportInlineText(parsing: "As [the WHO guideline](doc:\(identity)) says.")

        XCTAssertEqual(parsed.segments, [
            .prose("As "),
            .documentReference(displayText: "the WHO guideline", documentIdentity: identity),
            .prose(" says."),
        ])
    }

    /// A space between the display text and its target does not strand the
    /// target in the prose.
    ///
    /// On screen this printed `(doc:pmid-889149)` after a tappable citation.
    /// `889149` pasted into PubMed is a real 1977 paper on mouse courtship.
    func testASpaceBeforeTheTargetStillNamesTheDocument() {
        let parsed = ReportInlineText(parsing: "A [Smith, 2016] (doc:pmid-889149) study.")

        XCTAssertEqual(parsed.segments, [
            .prose("A "),
            .documentReference(displayText: "Smith, 2016", documentIdentity: "pmid-889149"),
            .prose(" study."),
        ])
    }

    /// Whitespace around the identity is not part of it.
    ///
    /// The link pattern tolerates a space after the scheme. Kept, it became the
    /// lookup value ` pmid-889149`, which matches no row, so the tap did nothing.
    func testWhitespaceAroundTheIdentityIsNotPartOfIt() {
        let parsed = ReportInlineText(parsing: "[Smith, 2016](doc: pmid-889149 )")

        XCTAssertEqual(parsed.segments, [
            .documentReference(displayText: "Smith, 2016", documentIdentity: "pmid-889149"),
        ])
    }

    // MARK: - Targets that cannot be parsed

    /// An unterminated target is removed, and the citation it belonged to is
    /// left to be resolved by its text.
    func testAnUnterminatedTargetLeavesACitationResolvedByItsText() {
        let parsed = ReportInlineText(parsing: "A [Smith, 2016](doc:pmid-889149 study.")

        XCTAssertEqual(parsed.segments, [
            .prose("A "),
            .untargetedCitation(displayText: "Smith, 2016"),
            .prose(" study."),
        ])
        XCTAssertEqual(parsed.removedReferences, ["(doc:pmid-889149"])
    }

    /// A target with no display text is removed entirely, and named.
    func testABareTargetIsRemovedAndNamed() {
        let parsed = ReportInlineText(parsing: "A (doc:\(identity)) bare target.")

        XCTAssertEqual(parsed.segments, [.prose("A bare target.")])
        XCTAssertEqual(parsed.removedReferences, ["(doc:\(identity))"])
    }

    /// Every removed reference is named, not only the first.
    func testEveryRemovedReferenceIsNamed() {
        let parsed = ReportInlineText(parsing: "A [Smith, 2016](doc:abc and [Jones, 2019](doc:def agree.")

        XCTAssertEqual(parsed.removedReferences, ["(doc:abc", "(doc:def"])
    }

    /// A target sitting inside a link's display text is removed too.
    ///
    /// The export path swept the flattened text, display text included, so a
    /// renderer that sweeps only the prose between links would print what the
    /// export removes.
    func testATargetInsideDisplayTextIsRemoved() {
        let parsed = ReportInlineText(parsing: "[Smith (doc:abc), 2016](doc:def)")

        XCTAssertEqual(parsed.segments, [
            .documentReference(displayText: "Smith, 2016", documentIdentity: "def"),
        ])
        XCTAssertEqual(parsed.removedReferences, ["(doc:abc)"])
    }

    /// A scheme that lost its opening parenthesis is not removed (#236), and
    /// the parse says it is still there rather than claiming a clean result.
    func testASchemeTheSweepCannotReachIsReportedAsRetained() {
        let parsed = ReportInlineText(parsing: "A [Smith, 2016]doc:pmid-889149 study.")

        XCTAssertTrue(parsed.retainsDocumentReferenceScheme)
        XCTAssertEqual(parsed.removedReferences, [])
    }

    /// Text carrying only well-formed references retains no scheme.
    func testWellFormedReferencesRetainNoScheme() {
        let parsed = ReportInlineText(parsing: "Both [Smith, 2016](doc:abc) and [Jones, 2019](doc:def).")

        XCTAssertFalse(parsed.retainsDocumentReferenceScheme)
    }

    // MARK: - A target may not take the sentence with it

    /// An unterminated target does not run on to a later parenthetical.
    ///
    /// The target run accepted anything up to a closing parenthesis, so an
    /// unterminated `(doc:abc` found the `)` that closed the confidence interval
    /// and everything between became the "identity" — deleted from the page,
    /// reported nowhere, because from the pattern's point of view that parsed.
    /// An identity is a UUID or `pmid-<digits>`, so a run of prose is not one.
    func testAnUnterminatedTargetDoesNotSwallowALaterParenthetical() {
        let parsed = ReportInlineText(
            parsing: "Benefit in adults (as [Smith, 2016](doc:abc showed in 120 patients (95% CI 1.2-3.4))."
        )

        XCTAssertEqual(
            parsed.flattened,
            "Benefit in adults (as [Smith, 2016] showed in 120 patients (95% CI 1.2-3.4))."
        )
        XCTAssertEqual(parsed.removedReferences, ["(doc:abc"])
    }

    /// An unterminated target does not swallow the citation after it.
    func testACitationAfterAnUnterminatedTargetSurvives() {
        let parsed = ReportInlineText(
            parsing: "Benefit ([Smith, 2016](doc:abc; [Jones, 2019](doc:def)) in adults."
        )

        XCTAssertEqual(parsed.segments, [
            .prose("Benefit ("),
            .untargetedCitation(displayText: "Smith, 2016"),
            .prose("; "),
            .documentReference(displayText: "Jones, 2019", documentIdentity: "def"),
            .prose(") in adults."),
        ])
        XCTAssertEqual(parsed.removedReferences, ["(doc:abc"])
    }

    /// A closed target carrying words is removed, not taken for an identity.
    ///
    /// It used to become a reference to the identity `pmid 889149`, which no
    /// row carries, so the tap did nothing and nobody was told. Removed, it is
    /// reported, and the citation can still be found by author and year.
    func testAClosedTargetThatIsNotIdentityShapedIsRemoved() {
        let parsed = ReportInlineText(parsing: "[Smith, 2016](doc:pmid 889149)")

        XCTAssertEqual(parsed.segments, [.untargetedCitation(displayText: "Smith, 2016")])
        XCTAssertEqual(parsed.removedReferences, ["(doc:pmid 889149)"])
    }

    /// A closed target that is not one identity is removed whole, whatever
    /// separates its parts.
    ///
    /// Confining a document target to one identity run sent these to the
    /// removal, which took only the first identity and printed the rest —
    /// `, doc:9B2E…)` or `, pmid-123456)` — where the export had removed the
    /// whole target. A model citing two documents in one link writes exactly
    /// this, and `pmid-123456` reads as a PubMed ID.
    func testAClosedTargetNamingSeveralDocumentsIsRemovedWhole() {
        let cases: [(markdown: String, flattened: String, removed: String)] = [
            (
                "[Smith, 2016; Jones, 2019](doc:\(identity), doc:9B2E5D33-0000-4000-8000-000000000002).",
                "[Smith, 2016; Jones, 2019].",
                "(doc:\(identity), doc:9B2E5D33-0000-4000-8000-000000000002)"
            ),
            (
                "A [Smith, 2016](doc:pmid-889149; doc:pmid-123456) b",
                "A [Smith, 2016] b",
                "(doc:pmid-889149; doc:pmid-123456)"
            ),
            (
                "A [Smith, 2016](doc:pmid-889149, pmid-123456) b",
                "A [Smith, 2016] b",
                "(doc:pmid-889149, pmid-123456)"
            ),
            (
                "A [Smith, 2016](doc:pmid:889149) b",
                "A [Smith, 2016] b",
                "(doc:pmid:889149)"
            ),
            (
                "A [Smith, 2016](doc:pmid-889149,\ndoc:pmid-123456) b",
                "A [Smith, 2016] b",
                "(doc:pmid-889149,\ndoc:pmid-123456)"
            ),
        ]

        for (markdown, flattened, removed) in cases {
            let parsed = ReportInlineText(parsing: markdown)
            XCTAssertEqual(parsed.flattened, flattened, markdown)
            XCTAssertEqual(parsed.removedReferences, [removed], markdown)
        }
    }

    /// A space inside the parenthesis before the scheme does not make the
    /// reference an ordinary link.
    ///
    /// It did: the target became `" doc:abc"`, a link to a scheme the app does
    /// not intercept, which opens nothing.
    func testASpaceBeforeTheSchemeStillNamesTheDocument() {
        let parsed = ReportInlineText(parsing: "[Smith, 2016]( doc:abc)")

        XCTAssertEqual(parsed.segments, [
            .documentReference(displayText: "Smith, 2016", documentIdentity: "abc"),
        ])
    }

    /// A removal that leaves another reference behind removes that one too.
    ///
    /// One pass over `((doc:x)doc:pmid-889149)` removed the inner target and
    /// assembled `(doc:pmid-889149)` from what was left.
    func testARemovalThatAssemblesAnotherTargetRemovesItToo() {
        let parsed = ReportInlineText(parsing: "A ((doc:x)doc:pmid-889149) b")

        XCTAssertEqual(parsed.flattened, "A b")
        XCTAssertEqual(parsed.removedReferences, ["(doc:x)", "(doc:pmid-889149)"])
        XCTAssertFalse(parsed.retainsDocumentReferenceScheme)
    }

    /// A closed parenthetical holding prose after the identity keeps the prose.
    ///
    /// The removal took everything up to the `)`, so this sentence lost the
    /// finding it reported and read "No benefit was seen overall." — the
    /// opposite of what the model wrote, with the reader told only that a link
    /// had gone. Golden rule 6: the report's own words are not machine syntax,
    /// and the stray `)` left behind costs a reader far less than the clause.
    func testAClosedTargetCarryingProseKeepsTheProse() {
        let parsed = ReportInlineText(
            parsing: "No benefit was seen (doc:pmid-889149 in 400 children, contrary to earlier claims) overall."
        )

        XCTAssertEqual(
            parsed.flattened,
            "No benefit was seen in 400 children, contrary to earlier claims) overall."
        )
        XCTAssertEqual(parsed.removedReferences, ["(doc:pmid-889149"])
    }

    /// A reference whose target was never closed keeps the sentences after it,
    /// up to a later closing parenthesis.
    func testAReferenceWhoseTargetRunsIntoProseKeepsTheProse() {
        let cases: [(markdown: String, flattened: String)] = [
            (
                "Mortality fell (as reported by [Smith, 2016](doc:abc. The effect reversed in the elderly) overall.",
                "Mortality fell (as reported by [Smith, 2016]. The effect reversed in the elderly) overall."
            ),
            (
                "Mortality fell [Smith, 2016](doc:abc, and rose) later.",
                "Mortality fell [Smith, 2016], and rose) later."
            ),
            (
                "Benefit (see [Smith, 2016](doc:\(identity), which enrolled 120 patients) was modest.",
                "Benefit (see [Smith, 2016], which enrolled 120 patients) was modest."
            ),
        ]

        for (markdown, flattened) in cases {
            let parsed = ReportInlineText(parsing: markdown)
            XCTAssertEqual(parsed.flattened, flattened, markdown)
            XCTAssertEqual(parsed.removedReferences.count, 1, markdown)
        }
    }

    /// A removal does not cross a bracket, so the citation after it survives.
    func testARemovalDoesNotCrossABracket() {
        let parsed = ReportInlineText(parsing: "Benefit ([Smith, 2016](doc:abc; [Jones, 2019]) in adults.")

        XCTAssertEqual(parsed.segments, [
            .prose("Benefit ("),
            .untargetedCitation(displayText: "Smith, 2016"),
            .prose("; "),
            .untargetedCitation(displayText: "Jones, 2019"),
            .prose(") in adults."),
        ])
        XCTAssertEqual(parsed.removedReferences, ["(doc:abc"])
    }

    /// A removal does not cross a paragraph to reach a later `)`.
    func testARemovalDoesNotCrossAParagraph() {
        let parsed = ReportInlineText(
            parsing: "Mortality fell [Smith, 2016](doc:abc overall.\n\nDeaths fell in the next cohort) too."
        )

        XCTAssertEqual(
            parsed.flattened,
            "Mortality fell [Smith, 2016] overall.\n\nDeaths fell in the next cohort) too."
        )
        XCTAssertEqual(parsed.removedReferences, ["(doc:abc"])
    }

    /// An empty target is removed, and the citation found by its text.
    func testAnEmptyTargetIsRemoved() {
        let parsed = ReportInlineText(parsing: "[Smith, 2016](doc:)")

        XCTAssertEqual(parsed.segments, [.untargetedCitation(displayText: "Smith, 2016")])
        XCTAssertEqual(parsed.removedReferences, ["(doc:)"])
    }

    // MARK: - Line breaks and other spaces beside the scheme

    /// A line break after the scheme does not strand the identity.
    ///
    /// A model wraps `(doc: pmid-889149)` at its space. The reference was
    /// neither a link nor wholly removed: `(doc:` went, `pmid-889149)` was
    /// printed, and the diagnostic said the target had been removed.
    func testALineBreakAfterTheSchemeStillNamesTheDocument() {
        let parsed = ReportInlineText(parsing: "A [Smith, 2016](doc:\npmid-889149) study.")

        XCTAssertEqual(parsed.segments, [
            .prose("A "),
            .documentReference(displayText: "Smith, 2016", documentIdentity: "pmid-889149"),
            .prose(" study."),
        ])
        XCTAssertEqual(parsed.removedReferences, [])
    }

    /// A line break between the parenthesis and the scheme is tolerated too.
    func testALineBreakBeforeTheSchemeStillNamesTheDocument() {
        let parsed = ReportInlineText(parsing: "[Smith, 2016](\ndoc:pmid-889149)")

        XCTAssertEqual(parsed.segments, [
            .documentReference(displayText: "Smith, 2016", documentIdentity: "pmid-889149"),
        ])
    }

    /// An unterminated target broken after its scheme gives up the identity.
    func testAnUnterminatedTargetBrokenAfterTheSchemeGivesUpTheIdentity() {
        let parsed = ReportInlineText(parsing: "A [Smith, 2016](doc:\npmid-889149 study.")

        XCTAssertEqual(parsed.flattened, "A [Smith, 2016] study.")
        XCTAssertEqual(parsed.removedReferences, ["(doc:\npmid-889149"])
    }

    /// A bare target broken before its scheme is removed whole.
    ///
    /// Joined for the screen, it became `( doc:pmid-889149)` in prose: the
    /// identity shown, and the reader told nothing.
    func testABareTargetBrokenBeforeTheSchemeIsRemoved() {
        let parsed = ReportInlineText(parsing: "Benefit (\ndoc:pmid-889149) in adults.")

        XCTAssertEqual(parsed.joiningWrappedLines().flattened, "Benefit in adults.")
        XCTAssertEqual(parsed.removedReferences, ["(\ndoc:pmid-889149)"])
        XCTAssertFalse(parsed.joiningWrappedLines().retainsDocumentReferenceScheme)
    }

    /// A space other than a space or tab before the scheme still names the
    /// document.
    ///
    /// The ordinary-link branch refused only spaces and tabs before `doc:`, so
    /// a no-break space let the target through as an ordinary link to
    /// `doc:pmid-889149`: a tinted citation that opens nothing, and nothing
    /// logged.
    func testAnyHorizontalSpaceBeforeTheSchemeStillNamesTheDocument() {
        for space in ["\u{00A0}", "\u{202F}", "\u{2009}", "\u{3000}"] {
            let parsed = ReportInlineText(parsing: "[Smith, 2016](\(space)doc:pmid-889149\(space))")

            XCTAssertEqual(parsed.segments, [
                .documentReference(displayText: "Smith, 2016", documentIdentity: "pmid-889149"),
            ], space.unicodeScalars.first.map { String($0.value, radix: 16) } ?? "")
        }
    }

    /// A space before the scheme of an unterminated target is removed with it.
    func testASpaceBeforeTheSchemeOfAnUnterminatedTargetIsRemovedWithIt() {
        let parsed = ReportInlineText(parsing: "A [Smith, 2016]( doc:pmid-889149 study.")

        XCTAssertEqual(parsed.segments, [
            .prose("A "),
            .untargetedCitation(displayText: "Smith, 2016"),
            .prose(" study."),
        ])
        XCTAssertEqual(parsed.removedReferences, ["( doc:pmid-889149"])
    }

    /// A space before the scheme does not let a closed target that is not one
    /// identity become an ordinary link.
    func testASpaceBeforeTheSchemeOfAClosedTargetDoesNotMakeALink() {
        let parsed = ReportInlineText(parsing: "[Smith, 2016]( doc:pmid 889149)")

        XCTAssertEqual(parsed.segments, [.untargetedCitation(displayText: "Smith, 2016")])
        XCTAssertEqual(parsed.removedReferences, ["( doc:pmid 889149)"])
    }

    // MARK: - Where a reference may start

    /// A reference written against the word before it still names its document.
    ///
    /// The lookbehind meant for an image's `!` applied to the `[` as well, so
    /// the reference lost its identity: the reader was told a malformed link
    /// had been removed, and a tap searched by author and year instead.
    func testAReferenceAgainstAWordStillNamesItsDocument() {
        let parsed = ReportInlineText(parsing: "reduction[Smith, 2016](doc:8A1D4C22).")

        XCTAssertEqual(parsed.segments, [
            .prose("reduction"),
            .documentReference(displayText: "Smith, 2016", documentIdentity: "8A1D4C22"),
            .prose("."),
        ])
        XCTAssertEqual(parsed.removedReferences, [])
    }

    /// Long runs of whitespace and repeated fragments parse in linear time.
    ///
    /// `[ \t]*\n?[ \t]*` divided a run of spaces between its halves in every
    /// possible way before failing: 30,000 spaces took over five seconds. The
    /// bound here is generous, so a slow machine does not fail it, and still
    /// far below what a quadratic pattern needs at this length.
    func testLongRunsParseInLinearTime() {
        let run = String(repeating: " ", count: 100_000)
        let fragments = String(repeating: " doc:abc,", count: 20_000)
        let inputs = [
            "[Smith, 2016]" + run + "x",
            "[Smith, 2016]" + run + "\n" + run + "x",
            "[Smith, 2016](doc:" + run + "x",
            "[Smith, 2016](" + run,
            "[Smith," + run + "x]",
            "A (doc:abc" + fragments,
            "A (doc:pmid" + run + "x",
        ]
        let clock = ContinuousClock()

        for input in inputs {
            let elapsed = clock.measure { _ = ReportInlineText(parsing: input) }
            XCTAssertLessThan(elapsed, .seconds(5), String(input.prefix(20)))
        }
    }

    // MARK: - Wrapped lines

    /// A paragraph parsed with its line breaks is shown with spaces for them.
    ///
    /// Why the order matters — joining first lets an ordinary link's target
    /// cross the break — is pinned where paragraphs are built, in
    /// `ReportMarkdownBlocksTests`.
    func testJoiningWrappedLinesReplacesLineBreaksWithSpaces() {
        let parsed = ReportInlineText(
            parsing: "Mortality fell [Smith et al.,\n2016](doc:abc)\nin adults."
        ).joiningWrappedLines()

        XCTAssertEqual(parsed.segments, [
            .prose("Mortality fell "),
            .documentReference(displayText: "Smith et al., 2016", documentIdentity: "abc"),
            .prose(" in adults."),
        ])
    }

    /// Joining lines keeps what the parse removed.
    func testJoiningWrappedLinesKeepsTheRemovals() {
        let parsed = ReportInlineText(parsing: "A (doc:abc)\nb").joiningWrappedLines()

        XCTAssertEqual(parsed.segments, [.prose("A b")])
        XCTAssertEqual(parsed.removedReferences, ["(doc:abc)"])
    }

    // MARK: - Ordinary links

    /// An ordinary link keeps its destination, which a screen can follow.
    func testAnOrdinaryLinkKeepsItsDestination() {
        let parsed = ReportInlineText(
            parsing: "See [the guideline](https://example.org/guideline) for detail."
        )

        XCTAssertEqual(parsed.segments, [
            .prose("See "),
            .link(displayText: "the guideline", target: "https://example.org/guideline"),
            .prose(" for detail."),
        ])
    }

    /// An ordinary link's target may not cross a line break.
    ///
    /// Its target has no character set to confine it, so the line break is
    /// all that stops an unclosed one reaching a `)` in a later paragraph and
    /// deleting everything between — silently, since it is not a document
    /// reference and nothing reports it.
    func testAnOrdinaryLinkMayNotCrossALineBreak() {
        let prose = "See [the guideline](https://example.org/a\n\n1) dose"
        let parsed = ReportInlineText(parsing: prose)

        XCTAssertEqual(parsed.flattened, prose)
        XCTAssertEqual(parsed.removedReferences, [])
    }

    /// A parenthesis inside a destination does not end it — Wiley's DOIs carry one.
    func testAParenthesisInsideADestinationDoesNotEndIt() {
        let parsed = ReportInlineText(parsing: "[DOI](https://doi.org/10.1002/(SICI)1097-0258)")

        XCTAssertEqual(parsed.segments, [
            .link(displayText: "DOI", target: "https://doi.org/10.1002/(SICI)1097-0258"),
        ])
    }

    // MARK: - Citations with no target

    /// A citation written before reports carried identities is recognised by
    /// its shape.
    func testAnAuthorYearCitationWithNoTargetIsRecognised() {
        let parsed = ReportInlineText(parsing: "Survival improved [Smith et al., 2016a].")

        XCTAssertEqual(parsed.segments, [
            .prose("Survival improved "),
            .untargetedCitation(displayText: "Smith et al., 2016a"),
            .prose("."),
        ])
    }

    /// Bracketed prose is not a citation, and its parenthetical is not a link.
    func testBracketedProseIsNotACitation() {
        let prose = "The trial reported a 12% [sic] (95% CI 4-19) reduction."

        XCTAssertEqual(ReportInlineText(parsing: prose).segments, [.prose(prose)])
    }

    /// A stray opening bracket does not become part of the citation after it.
    ///
    /// The on-screen pattern allowed `[` inside the display text, so the whole
    /// of `[also [Smith, 2016]` became one citation looked up by `also [Smith`.
    func testAStrayOpeningBracketDoesNotJoinTheCitationAfterIt() {
        let parsed = ReportInlineText(parsing: "see [also [Smith, 2016]")

        XCTAssertEqual(parsed.segments, [
            .prose("see [also "),
            .untargetedCitation(displayText: "Smith, 2016"),
        ])
    }

    /// Empty text has nothing to draw.
    func testEmptyTextHasNoSegments() {
        XCTAssertEqual(ReportInlineText(parsing: "").segments, [])
    }

    /// Every pattern the parser relies on compiles.
    ///
    /// Each is a literal, and a failure to compile degrades quietly: with no
    /// link pattern every well-formed reference is reported as malformed, and
    /// with no removal pattern an identity reaches the page.
    func testEveryPatternCompiles() {
        XCTAssertNotNil(ReportInlineText.markdownLinkRegex)
        XCTAssertNotNil(ReportInlineText.residualDocumentReferenceRegex)
        XCTAssertNotNil(ReportInlineText.untargetedCitationRegex)
    }

    // MARK: - Flattening

    /// A verbatim renderer is shown each link's display text, and a citation
    /// with no target exactly as it was written.
    func testFlattenedTextIsWhatAVerbatimRendererShows() {
        let parsed = ReportInlineText(
            parsing: "A [Smith, 2016](doc:abc), [Jones, 2019] and [x](https://y) (doc:zzz)."
        )

        XCTAssertEqual(parsed.flattened, "A Smith, 2016, [Jones, 2019] and x.")
    }
}
