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

/// The References section is where a fabricated identifier does the most damage.
///
/// It used to take a non-optional `pmid: String` and print `PMID: \(pmid)` with
/// no test applied, filled from an identifier slot that also holds preprint, PMC
/// and Europe PMC thesis accessions (#212). Worse than the on-screen surfaces:
/// this output is concatenated into `EvidenceReport.fullReport` and **saved**,
/// so a wrong label is written down once and read back by every later view and
/// export, including ones that did not exist when it was written.
final class ReportReferenceIdentityTests: XCTestCase {
    private func reference(identifier: String?) -> String {
        ReportFormatter.formatReferences([
            ReportFormatter.ReferenceData(
                authors: "Smith J, Jones A",
                year: 2016,
                title: "An article",
                journal: "The Journal",
                identifier: identifier
            )
        ])
    }

    /// The caller establishes the namespace; the formatter prints what it is given.
    func testAnEstablishedIdentifierIsPrintedAsGiven() {
        XCTAssertTrue(reference(identifier: "PMID: 12662058").contains("PMID: 12662058"))
    }

    /// A namespace other than PubMed survives intact. The old signature could
    /// not express this at all: every identifier came out labelled `PMID`.
    func testANonPubMedNamespaceIsNotRelabelled() {
        let output = reference(identifier: "Europe PMC: 889149")

        XCTAssertTrue(output.contains("Europe PMC: 889149"), output)
        XCTAssertFalse(output.contains("PMID"), output)
    }

    /// Where nothing can name the identifier, the reference carries no locator
    /// rather than an unlabelled or mislabelled one.
    ///
    /// A reference with no locator is honest and the reader can still search the
    /// title. One that resolves to the wrong paper is not, and nothing in the
    /// exported report tells them so.
    func testAnUnnameableIdentifierLeavesNoLocator() {
        let output = reference(identifier: nil)

        XCTAssertFalse(output.contains("PMID"), output)
        XCTAssertFalse(output.contains(":"), output)
        XCTAssertTrue(output.contains("An article"), output)
    }

    /// The trailing separator belongs to the identifier, not to the journal, so
    /// dropping the identifier must not leave a dangling `.` mid-line.
    func testTheLineIsWellFormedWithoutAnIdentifier() {
        XCTAssertEqual(
            reference(identifier: nil),
            "**1.** **Smith J, Jones A (2016).** An article. *The Journal*"
        )
    }
}
