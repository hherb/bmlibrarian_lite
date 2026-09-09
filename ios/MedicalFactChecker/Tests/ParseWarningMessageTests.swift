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
import BioMedLit
@testable import MedicalFactChecker

/// Which of the three things the banner says, for a given retrieval.
///
/// The choice lives in a value rather than in the view precisely so it can be
/// tested: it is where the judgement is, and a banner that says the wrong thing
/// is worse than one that says nothing — in a medical-literature tool, telling a
/// reader that a complete PDF may be missing content is what teaches them to
/// ignore the banner on the article where text really was discarded.
final class ParseWarningMessageTests: XCTestCase {

    private func message(
        warnings: JATSParseWarnings = JATSParseWarnings(),
        degradation: FullTextDegradation? = nil,
        extractionCoverage: PDFExtractionCoverage? = nil
    ) -> ParseWarningMessage? {
        ParseWarningMessage(
            warnings: warnings,
            degradation: degradation,
            extractionCoverage: extractionCoverage
        )
    }

    /// Nothing lost and the best source used: the banner must not appear at all.
    func testACleanResultFromTheBestSourceSaysNothing() {
        XCTAssertNil(message())
    }

    func testLostContentIsReportedAsIncomplete() {
        XCTAssertEqual(
            message(warnings: JATSParseWarnings(losses: [.openTables(2)])), .incomplete
        )
    }

    /// A parse that produced nothing is not "some of this article".
    ///
    /// It is a rendering stripped to the article's own accession number, and
    /// saying "some" of it is missing understates it to the point of being
    /// misleading. Telling the two apart needs the losses to be values — the
    /// string payload could only have been substring-matched (#184).
    func testAnEmptyRenderingIsReportedSeparately() {
        XCTAssertEqual(message(warnings: JATSParseWarnings(losses: [.noContent])), .noContent)
    }

    /// `.noContent` alongside other losses still reports the stronger of the two.
    func testNoContentOutranksTheOtherLosses() {
        XCTAssertEqual(
            message(warnings: JATSParseWarnings(losses: [.openTables(2), .noContent])),
            .noContent
        )
    }

    /// An unreadable stored record says *something* was lost, which is a
    /// truncation as far as the reader is concerned.
    func testAnUnspecifiedLossIsReportedAsIncomplete() {
        XCTAssertEqual(
            message(warnings: JATSParseWarnings(losses: [.unspecified])), .incomplete
        )
    }

    // MARK: - The fallback's note (#183)

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

    /// Lost content in the rendering the reader is looking at outranks a note
    /// about where that rendering came from.
    func testWarningsOutrankADegradation() {
        XCTAssertEqual(
            message(
                warnings: JATSParseWarnings(losses: [.openFigures(1)]),
                degradation: .jatsParseFailed
            ),
            .incomplete
        )
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

    // MARK: - Partial extraction

    /// The silence this case was added to end. A PDF whose last four pages gave
    /// no text renders as a complete-looking document, and the transparency
    /// verdict beside it was computed from prose that stopped early.
    func testAPartialExtractionIsReported() {
        XCTAssertEqual(
            message(extractionCoverage: PDFExtractionCoverage(convertedPages: 10, pageCount: 14)),
            .partialExtraction(PDFExtractionCoverage(convertedPages: 10, pageCount: 14))
        )
    }

    /// A whole extraction says nothing. The banner is rationed to the cases
    /// where something is actually missing — a note over content that is fine is
    /// what trains a reader to dismiss it.
    func testACompleteExtractionSaysNothing() {
        XCTAssertNil(
            message(extractionCoverage: PDFExtractionCoverage(convertedPages: 6, pageCount: 6))
        )
    }

    /// It alarms, unlike a degradation. The shortfall is invisible on screen.
    func testAPartialExtractionIsAWarning() {
        let message = try? XCTUnwrap(
            message(extractionCoverage: PDFExtractionCoverage(convertedPages: 1, pageCount: 9))
        )
        XCTAssertEqual(message?.isWarning, true)
    }

    /// A PDF reached by fallback whose text stops short has two things wrong
    /// with it. The missing text is the one that changes what the reader should
    /// conclude, so it outranks the note about where the copy came from.
    func testAPartialExtractionOutranksADegradation() {
        XCTAssertEqual(
            message(
                degradation: .jatsParseFailed,
                extractionCoverage: PDFExtractionCoverage(convertedPages: 2, pageCount: 8)
            ),
            .partialExtraction(PDFExtractionCoverage(convertedPages: 2, pageCount: 8))
        )
    }

    /// And a complete extraction lets the degradation through, rather than
    /// swallowing it.
    func testACompleteExtractionStillReportsADegradation() {
        XCTAssertEqual(
            message(
                degradation: .jatsParseFailed,
                extractionCoverage: PDFExtractionCoverage(convertedPages: 8, pageCount: 8)
            ),
            .degraded(.jatsParseFailed)
        )
    }

    /// Parse losses still win over everything: they describe the rendering the
    /// reader is actually looking at.
    func testParseLossesOutrankAPartialExtraction() {
        XCTAssertEqual(
            message(
                warnings: JATSParseWarnings(losses: [.noContent]),
                extractionCoverage: PDFExtractionCoverage(convertedPages: 2, pageCount: 8)
            ),
            .noContent
        )
    }

    /// A scan gets its own sentence. "0 of 12 pages" understates it: this is not
    /// a shortfall in the analysis but its complete absence, on a document that
    /// looks entirely ordinary on screen.
    func testAScanIsReportedAsHavingYieldedNoTextAtAll() {
        let message = message(
            extractionCoverage: PDFExtractionCoverage(convertedPages: 0, pageCount: 12)
        )
        XCTAssertEqual(
            message, .partialExtraction(PDFExtractionCoverage(convertedPages: 0, pageCount: 12))
        )
        XCTAssertEqual(message?.isWarning, true)
    }
}
