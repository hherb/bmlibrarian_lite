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

/// The report names the papers a run left out as retracted, carries the
/// methods line, and cautions under a cited paper that stands under a concern.
final class ReportFormatterRetractionTests: XCTestCase {
    private let when = Date(timeIntervalSince1970: 1_792_315_800) // 2026-10-18 09:30 UTC
    private let notice = StoredRetractionEvidence(
        source: "retraction_watch_export", kind: "retraction", date: "2026-03-09",
        noticeDOI: "10.9/n", recordID: nil, rawKind: nil)

    private func check(_ status: String, deciding: StoredRetractionEvidence? = nil) -> PaperRetractionCheck {
        PaperRetractionCheck(
            status: status, deciding: deciding, unanswered: status == "unchecked" ? ["crossref"] : [],
            checkedAt: when, exportDataAsOf: nil, crossrefFailure: nil)
    }

    private func section(_ papers: [(title: String, check: PaperRetractionCheck)]) -> RetractionReportSection {
        RetractionReportSection(papers: papers)
    }

    private func report(_ retraction: RetractionReportSection?) -> String {
        ReportFormatter.fullReport(
            analysis: "The analysis.", references: "**1.** Ref", shortfalls: [], retraction: retraction)
    }

    func testLeftOutSectionNamesEachPaperAndNotice() {
        let text = report(section([("Bad trial", check("retracted", deciding: notice)), ("Good trial", check("clear"))]))
        XCTAssertTrue(text.contains(
            "## Left out as retracted\n\n- Bad trial. Retracted 2026-03-09; notice 10.9/n"))
        XCTAssertFalse(text.contains("Good trial"))
        let leftOut = text.range(of: "## Left out as retracted")!.lowerBound
        XCTAssertLessThan(leftOut, text.range(of: "## References")!.lowerBound)
    }

    func testConcernCaveatUnderItsReference() {
        let ref = ReportFormatter.ReferenceData(
            authors: "A", year: 2020, title: "T", journal: nil, identifier: nil,
            caveat: RetractionText.concernCaveat(check("concern", deciding: notice)))
        XCTAssertEqual(
            ReportFormatter.formatReferences([ref]),
            "**1.** **A (2020).** T\n    ⚠️ Expression of concern (2026-03-09, notice 10.9/n)")
    }

    func testNoExclusionsAddsOnlyTheMethodsLine() {
        let text = report(section([("Fine", check("clear"))]))
        XCTAssertFalse(text.contains("## Left out as retracted"))
        XCTAssertTrue(text.contains(
            "The analysis.\n\n## Methodology\n\n- **Retraction Check:** Retraction status checked 2026-10-18\n\n## References"),
            "a complete search's report heads the line itself")
        XCTAssertEqual(report(nil), "The analysis.\n\n## References\n\n**1.** Ref")
    }

    /// An incomplete search's Methodology holds both lines under one heading.
    func testRetractionLineJoinsTheSearchMethodology() {
        let text = ReportFormatter.fullReport(
            analysis: "The analysis.", references: "**1.** Ref",
            shortfalls: [RetrievalShortfall(source: .pubmed, failure: .forHTTPStatus(429))],
            retraction: section([("Fine", check("clear"))]))
        XCTAssertEqual(text.components(separatedBy: "## Methodology").count, 2, "one heading")
        let completeness = text.range(of: "- **Search Completeness:**")!.lowerBound
        let retraction = text.range(of: "- **Retraction Check:**")!.lowerBound
        XCTAssertLessThan(text.range(of: "## Methodology")!.lowerBound, completeness)
        XCTAssertLessThan(completeness, retraction)
        XCTAssertLessThan(retraction, text.range(of: "## References")!.lowerBound)
    }

    func testStandInReportCarriesTheSection() {
        let text = ReportFormatter.standInReport(
            "No evidence.", shortfalls: [],
            retraction: section([("Bad trial", check("retracted", deciding: notice))]))
        XCTAssertTrue(text.hasPrefix(
            "No evidence.\n\n## Methodology\n\n- **Retraction Check:** Retraction status checked 2026-10-18"))
        XCTAssertTrue(text.contains("## Left out as retracted\n\n- Bad trial. Retracted 2026-03-09; notice 10.9/n"))
    }

    func testUncheckedCountInTheMethodsLine() {
        let mixed = section([("A", check("clear")), ("B", check("unchecked")), ("C", check("unchecked"))])
        XCTAssertEqual(mixed.methodsLine, "Retraction status checked 2026-10-18; 2 papers could not be checked")
        let none = section([("B", check("unchecked"))])
        XCTAssertEqual(none.methodsLine, "Retraction status could not be checked")
    }
}
