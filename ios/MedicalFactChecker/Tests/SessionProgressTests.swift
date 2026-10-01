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
@testable import MedicalFactChecker

/// The progress bar's value before any document has been found.
///
/// The claim is analysed and the search runs before a single document exists,
/// and the first of those waits on the model. A bar held at 0% through them
/// read as a hung app.
final class SessionProgressTests: XCTestCase {

    func testAnalysingTheClaimShowsItsShareBeforeAnyDocumentIsFound() {
        let session = FactCheckSession(claim: "Green tea lowers blood pressure")
        session.currentStep = .convertingQuery

        XCTAssertEqual(session.progressPercent, 5)
    }

    func testSearchingShowsItsShareBeforeAnyDocumentIsFound() {
        let session = FactCheckSession(claim: "Green tea lowers blood pressure")
        session.currentStep = .searchingPubMed

        XCTAssertEqual(session.progressPercent, 10)
    }

    /// Control: a session that has not started is still at nothing.
    func testAnIdleSessionIsAtZero() {
        let session = FactCheckSession(claim: "Green tea lowers blood pressure")

        XCTAssertEqual(session.progressPercent, 0)
    }

    /// Scoring divides by the documents found; with none it must not divide by zero.
    func testScoringWithNoDocumentsFoundStaysAtTheStartOfItsShare() {
        let session = FactCheckSession(claim: "Green tea lowers blood pressure")
        session.currentStep = .scoringDocuments

        XCTAssertEqual(session.progressPercent, 10)
    }
}
