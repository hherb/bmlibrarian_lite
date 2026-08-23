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
        degradation: FullTextDegradation? = nil
    ) -> ParseWarningMessage? {
        ParseWarningMessage(warnings: warnings, degradation: degradation)
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
        XCTAssertEqual(message(degradation: .jatsParseFailed), .degraded)
    }

    /// The whole point of the third state: it is information, not a warning.
    ///
    /// The reader is looking at a complete PDF. What is true is that we could not
    /// read the better copy, which is worth saying and is not worth alarming them
    /// about — and styling it as a warning is what would make the real warning
    /// worthless.
    func testADegradationIsNotStyledAsAWarning() {
        XCTAssertFalse(ParseWarningMessage.degraded.isWarning)
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

    /// Each state says something different. Three headlines that collapsed to one
    /// would pass every test above while telling the reader nothing new.
    func testTheThreeStatesReadDifferently() {
        let headlines = [
            ParseWarningMessage.incomplete,
            .noContent,
            .degraded,
        ].map { String(describing: $0.headline) }

        XCTAssertEqual(Set(headlines).count, 3, "\(headlines)")
    }
}
