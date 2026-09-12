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

    // MARK: - Wrapped lines

    /// A paragraph parsed with its line breaks is shown with spaces for them.
    ///
    /// A renderer that joined wrapped lines with a space *before* parsing
    /// erased the line break the target run is forbidden to cross, and the
    /// screen deleted prose that the export kept. Parse first, then join.
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
