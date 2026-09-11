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

import BioMedLit
import XCTest
@testable import MedicalFactChecker

/// What a reader actually receives when they copy, share or export a report.
///
/// ``EvidenceReport/plainTextReport`` is the only report surface that reaches a
/// reader on both platforms today: the clipboard and share sheet on iOS, the
/// clipboard and *Export as Text* on macOS. The two printable views are not
/// instantiated anywhere, and macOS PDF export is a stub.
///
/// It interpolated ``EvidenceReport/fullReport`` verbatim, so every reference
/// arrived as `[Smith et al., 2016](doc:<identity>)` — markdown link syntax
/// wrapped around a value that names a row in this app's store and resolves
/// nowhere else. #226 made that value a UUID, which lengthened what leaked
/// without changing that it leaked.
final class SharedReportTextTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StringArrayTransformer.register()
    }

    private func makeReport(fullReport: String) -> EvidenceReport {
        EvidenceReport(
            verdict: .supported,
            summary: "A summary",
            fullReport: fullReport,
            citationCount: 1,
            uniqueSourceCount: 1,
            documentsReviewed: 1
        )
    }

    /// No link syntax and no identity reach the reader.
    func testASharedReportCarriesNoDocumentIdentity() {
        let identity = "8A1D4C22-0000-4000-8000-000000000001"
        let report = makeReport(
            fullReport: "Evidence is mixed [Smith et al., 2016](doc:\(identity))."
        )

        let shared = report.plainTextReport

        XCTAssertTrue(shared.contains("Evidence is mixed Smith et al., 2016."), shared)
        XCTAssertFalse(shared.contains(identity), shared)
        XCTAssertFalse(shared.contains("doc:"), shared)
        XCTAssertFalse(shared.contains("]("), shared)
    }

    /// A report saved before #208 leaks a locator, not merely an identity.
    ///
    /// Its targets are `pmid-<primary slot>`, and that slot also held Europe PMC
    /// thesis accessions: bare decimals. Pasted into PubMed, `889149` is a real
    /// 1977 paper on mouse courtship, not this article (#212). That is the whole
    /// reason the identity may not travel with the prose.
    func testALegacyTargetDoesNotTravelWithTheProse() {
        let report = makeReport(
            fullReport: "A thesis reported this [Nyby, 1977](doc:pmid-889149)."
        )

        let shared = report.plainTextReport

        XCTAssertTrue(shared.contains("A thesis reported this Nyby, 1977."), shared)
        XCTAssertFalse(shared.contains("889149"), shared)
        XCTAssertFalse(shared.contains("pmid-"), shared)
    }

    /// Emphasis markers are removed: nothing downstream renders markdown.
    ///
    /// The clipboard, the share sheet and a `.txt` file all show what they are
    /// given. `formatReferences` opens every entry with `**1.**`.
    func testASharedReportCarriesNoMarkdownEmphasis() {
        let report = makeReport(
            fullReport: "**1.** **Nyby, J (1977).** Mouse courtship. Europe PMC: 889149"
        )

        let shared = report.plainTextReport

        XCTAssertTrue(
            shared.contains("1. Nyby, J (1977). Mouse courtship. Europe PMC: 889149"),
            shared
        )
        XCTAssertFalse(shared.contains("**"), shared)
    }

    /// The namespace-labelled identifier a reader *can* use is left alone.
    ///
    /// Flattening removes what resolves nowhere. It must not remove the
    /// reference list's identifier, which is the only way a reader looks the
    /// study up once the link is gone.
    func testTheReferenceListIdentifierSurvives() {
        let report = makeReport(
            fullReport: "1. Nyby, J (1977). Mouse courtship. Europe PMC: 889149"
        )

        XCTAssertTrue(report.plainTextReport.contains("Europe PMC: 889149"))
    }
}
