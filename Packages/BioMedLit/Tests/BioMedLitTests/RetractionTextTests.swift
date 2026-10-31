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

/// The reader-facing retraction sentences, asserted whole: they are the
/// desktop's `retraction_text.py` wording (the export cause aside).
final class RetractionTextTests: XCTestCase {
    private let when = Date(timeIntervalSince1970: 1_792_315_800) // 2026-10-18 09:30 UTC
    private let both = ["retraction_watch_export", "crossref"]
    private let rwCause = "the Retraction Watch data could not be used (no up-to-date copy is on this device)"

    private func evidence(
        source: String = "retraction_watch_export", kind: String = "retraction",
        notice: String? = "10.9/n", day: String? = "2026-03-09"
    ) -> StoredRetractionEvidence {
        StoredRetractionEvidence(source: source, kind: kind, date: day, noticeDOI: notice, recordID: nil, rawKind: nil)
    }

    private func check(
        _ status: String, _ deciding: StoredRetractionEvidence? = nil, unanswered: [String] = [],
        failure: String? = nil, asOf: String? = "2026-10-01"
    ) -> PaperRetractionCheck {
        PaperRetractionCheck(
            status: status, deciding: deciding, unanswered: unanswered, checkedAt: when,
            exportDataAsOf: asOf, crossrefFailure: failure)
    }

    private func paper(_ doi: String? = "10.1/x", pmid: String? = nil) -> RetractionPaper {
        RetractionPaper(doi: doi, pmid: pmid, publicationTypes: [])
    }

    func testCheckedOnLine() {
        XCTAssertEqual(RetractionText.checkedOnLine(when), "Retraction status checked 2026-10-18")
        XCTAssertEqual(RetractionText.checkedOnLine(nil), "Retraction status never checked")
        // late in the UTC day: still the UTC date
        let late = Date(timeIntervalSince1970: 1_792_367_940) // 2026-10-18 23:59 UTC
        XCTAssertEqual(RetractionText.checkedOnLine(late), "Retraction status checked 2026-10-18")
    }

    func testStatusLines() {
        let asOf = "; Retraction Watch data as of 2026-10-01"
        XCTAssertEqual(
            RetractionText.paperStatusLine(check("retracted", evidence())),
            "Retracted on 2026-03-09 (notice 10.9/n)" + asOf)
        let label = evidence(source: "pubmed_label", notice: nil, day: nil)
        XCTAssertEqual(
            RetractionText.paperStatusLine(check("retracted", label, asOf: nil)), "Retracted (PubMed's label)")
        let concern = evidence(kind: "expression_of_concern", day: "2026-03")
        XCTAssertEqual(
            RetractionText.paperStatusLine(check("concern", concern)),
            "Expression of concern, 2026-03 (notice 10.9/n)" + asOf)
        XCTAssertEqual(
            RetractionText.paperStatusLine(check("concern", evidence(kind: "expression_of_concern", day: nil), asOf: nil)),
            "Expression of concern (notice 10.9/n)")
        XCTAssertEqual(
            RetractionText.paperStatusLine(check("concern", evidence(source: "pubmed_label", kind: "expression_of_concern", notice: nil, day: nil), asOf: nil)),
            "Expression of concern (PubMed's label)")
        XCTAssertEqual(RetractionText.paperStatusLine(check("retracted", evidence(), asOf: nil)),
                       "Retracted on 2026-03-09 (notice 10.9/n)")
        XCTAssertEqual(RetractionText.paperStatusLine(check("retracted", evidence(notice: nil), asOf: nil)),
                       "Retracted on 2026-03-09")
        XCTAssertEqual(RetractionText.paperStatusLine(check("retracted", evidence(source: "crossref_publisher", notice: nil, day: nil), asOf: nil)),
                       "Retracted")
        XCTAssertEqual(RetractionText.paperStatusLine(check("clear")),
                       "No retraction found; Retraction Watch data as of 2026-10-01")
    }

    func testUncheckedStatusLines() {
        XCTAssertEqual(
            RetractionText.paperStatusLine(check("unchecked", unanswered: ["crossref"], failure: "Crossref answered HTTP 503")),
            "Retraction status not checked: Crossref (Crossref answered HTTP 503); Retraction Watch data as of 2026-10-01")
        XCTAssertEqual(
            RetractionText.paperStatusLine(check("unchecked", unanswered: ["retraction_watch_export"], asOf: nil)),
            "Retraction status not checked: Retraction Watch")
        XCTAssertEqual(
            RetractionText.paperStatusLine(check("unchecked", unanswered: both, asOf: nil)),
            "Retraction status not checked: Retraction Watch, Crossref")
        XCTAssertEqual(
            RetractionText.paperStatusLine(check("unchecked", asOf: nil)), "Retraction status not checked")
    }

    func testSummaryClauseCountsAndSingulars() {
        XCTAssertNil(RetractionText.runSummaryClause(excluded: 0, unchecked: 0, causes: []))
        XCTAssertEqual(RetractionText.runSummaryClause(excluded: 1, unchecked: 0, causes: []),
                       "1 retracted paper left out")
        XCTAssertEqual(RetractionText.runSummaryClause(excluded: 2, unchecked: 3, causes: []),
                       "2 retracted papers left out; 3 papers' retraction status could not be checked")
        XCTAssertEqual(RetractionText.runSummaryClause(excluded: 0, unchecked: 1, causes: ["no DOI or PMID"]),
                       "1 paper's retraction status could not be checked: no DOI or PMID")
        XCTAssertEqual(RetractionText.runSummaryClause(excluded: 1234, unchecked: 1234, causes: ["a", "b"]),
                       "1,234 retracted papers left out; 1,234 papers' retraction status could not be checked: a; b")
    }

    func testEveryUncheckedPaperHasANamedCause() {
        let cases: [(String, RetractionPaper, PaperRetractionCheck?, Set<RetractionPaper>)] = [
            ("no DOI, which Crossref needs", paper(nil, pmid: "12345678"),
             check("unchecked", unanswered: ["crossref"], asOf: "2026-10-01"), []),
            ("Crossref had no usable answer for the DOI", paper(),
             check("unchecked", unanswered: ["crossref"]), []),
            ("a Retraction Watch notice could not be read", paper(),
             check("unchecked", unanswered: ["retraction_watch_export"]), []),
            (rwCause, paper(),
             check("unchecked", unanswered: ["retraction_watch_export"], asOf: nil), []),
            ("no DOI or PMID", paper(nil), check("unchecked", unanswered: both, asOf: nil), []),
            ("the check was cancelled before reaching them", paper(), nil, []),
            ("the check failed", paper(), PaperRetractionCheck.failed(at: when), [paper()]),
            ("the check failed", paper(), nil, [paper()]),
        ]
        for (cause, p, c, failed) in cases {
            XCTAssertEqual(RetractionText.uncheckedCauses([(p, c)], failed: failed), [cause], cause)
        }
        // decided papers give no cause, even when listed as failed
        XCTAssertEqual(RetractionText.uncheckedCauses([(paper(), check("clear"))], failed: []), [])
        XCTAssertEqual(RetractionText.uncheckedCauses([(paper(), check("clear"))], failed: [paper()]), [])
    }

    func testAMixedRunNamesEveryCauseOnceInOrder() {
        let a = paper("10.1/a"), b = paper("10.1/b"), n = paper(nil), c = paper("10.1/c"), d = paper("10.1/d")
        let rows: [(paper: RetractionPaper, check: PaperRetractionCheck?)] = [
            (c, nil),
            (n, check("unchecked", unanswered: both, asOf: nil)),
            (a, check("unchecked", unanswered: both, failure: "Crossref answered HTTP 429", asOf: nil)),
            (b, check("unchecked", unanswered: both, failure: "Crossref answered HTTP 429", asOf: nil)),
            (d, check("unchecked", unanswered: ["crossref"], failure: "Crossref timed out")),
        ]
        XCTAssertEqual(RetractionText.uncheckedCauses(rows, failed: []), [
            rwCause,
            "Crossref could not be used (Crossref answered HTTP 429, Crossref timed out)",
            "no DOI or PMID",
            "the check was cancelled before reaching them",
        ])
        // the failure cause leads, and the silent / no-DOI causes follow Crossref's
        let more: [(paper: RetractionPaper, check: PaperRetractionCheck?)] = [
            (paper(nil, pmid: "5"), check("unchecked", unanswered: ["crossref"])),
            (paper("10.1/s"), check("unchecked", unanswered: ["crossref"])),
            (paper("10.1/f"), PaperRetractionCheck.failed(at: when)),
        ]
        XCTAssertEqual(RetractionText.uncheckedCauses(more, failed: [paper("10.1/f")]), [
            "the check failed", "no DOI, which Crossref needs", "Crossref had no usable answer for the DOI",
        ])
    }

    func testMethodsLine() {
        XCTAssertEqual(RetractionText.methodsLine(checkedAt: when, notChecked: 0, heldPapers: true),
                       "Retraction status checked 2026-10-18")
        XCTAssertEqual(RetractionText.methodsLine(checkedAt: when, notChecked: 1, heldPapers: true),
                       "Retraction status checked 2026-10-18; 1 paper could not be checked")
        XCTAssertEqual(RetractionText.methodsLine(checkedAt: when, notChecked: 2, heldPapers: true),
                       "Retraction status checked 2026-10-18; 2 papers could not be checked")
        XCTAssertEqual(RetractionText.methodsLine(checkedAt: when, notChecked: 1234, heldPapers: true),
                       "Retraction status checked 2026-10-18; 1,234 papers could not be checked")
        XCTAssertEqual(RetractionText.methodsLine(checkedAt: nil, notChecked: 3, heldPapers: true),
                       "Retraction status could not be checked")
        XCTAssertEqual(RetractionText.methodsLine(checkedAt: nil, notChecked: 0, heldPapers: false),
                       "Retraction status never checked")
    }

    func testLeftOutEntries() {
        XCTAssertEqual(RetractionText.leftOutHeading, "## Left out as retracted")
        XCTAssertEqual(RetractionText.leftOutEntry(title: "Title rw", check: check("retracted", evidence(notice: nil))),
                       "- Title rw. Retracted 2026-03-09")
        XCTAssertEqual(RetractionText.leftOutEntry(title: "Title rw", check: check("retracted", evidence())),
                       "- Title rw. Retracted 2026-03-09; notice 10.9/n")
        XCTAssertEqual(
            RetractionText.leftOutEntry(title: "Title label", check: check("retracted", evidence(source: "pubmed_label", notice: nil, day: nil))),
            "- Title label. Retracted (PubMed's label)")
        XCTAssertEqual(RetractionText.leftOutEntry(title: "No evidence", check: check("retracted")),
                       "- No evidence. Retracted (PubMed's label)")
        XCTAssertEqual(
            RetractionText.leftOutEntry(title: "A  *bold*\n[x]_y_ <b> `c` \\", check: check("retracted", evidence())),
            "- A \\*bold\\* \\[x\\]\\_y\\_ \\<b\\> \\`c\\` \\\\. Retracted 2026-03-09; notice 10.9/n")
    }

    func testConcernCaveat() {
        XCTAssertEqual(
            RetractionText.concernCaveat(check("concern", evidence(kind: "expression_of_concern", day: "2026-03"))),
            "    ⚠️ Expression of concern (2026-03, notice 10.9/n)")
        XCTAssertEqual(
            RetractionText.concernCaveat(check("concern", evidence(kind: "expression_of_concern", notice: nil, day: nil))),
            "    ⚠️ Expression of concern")
        XCTAssertEqual(RetractionText.concernCaveat(check("concern")), "    ⚠️ Expression of concern")
    }
    // MARK: - Saved work

    func testSavedWorkLine() {
        XCTAssertEqual(RetractionText.savedWorkLine([]), "Retraction status never checked")
        XCTAssertEqual(
            RetractionText.savedWorkLine([check("unchecked", unanswered: both)]),
            "Retraction status could not be checked")
        let older = PaperRetractionCheck(
            status: "clear", deciding: nil, unanswered: [], checkedAt: when.addingTimeInterval(-86_400),
            exportDataAsOf: nil, crossrefFailure: nil)
        XCTAssertEqual(
            RetractionText.savedWorkLine([check("retracted", evidence()), older, check("unchecked", unanswered: both)]),
            "Retraction status checked 2026-10-17; 1 paper could not be checked",
            "the oldest decided check, never an unchecked one's time")
    }

    func testSavedWorkLineNamesWhyPapersStayUncheckedAfterCheckAgain() {
        let rwCause = "the Retraction Watch data could not be used (no up-to-date copy is on this device)"
        let unchecked = check("unchecked", unanswered: both)
        XCTAssertEqual(
            RetractionText.savedWorkLine([check("clear"), unchecked], causes: [rwCause]),
            "Retraction status checked 2026-10-18; 1 paper could not be checked: \(rwCause)")
        XCTAssertEqual(
            RetractionText.savedWorkLine([unchecked], causes: [rwCause]),
            "Retraction status could not be checked: \(rwCause)")
        XCTAssertEqual(
            RetractionText.savedWorkLine([check("clear")], causes: [rwCause]),
            "Retraction status checked 2026-10-18", "no paper unchecked, no causes")
    }

    func testNotCheckedAgainClause() {
        XCTAssertEqual(RetractionText.notCheckedAgainClause(0), "")
        XCTAssertEqual(RetractionText.notCheckedAgainClause(1), "; 1 paper could not be checked again")
        XCTAssertEqual(RetractionText.notCheckedAgainClause(1_200), "; 1,200 papers could not be checked again")
        XCTAssertEqual(
            RetractionText.notCheckedAgainClause(2, causes: ["a", "b"]), "; 2 papers could not be checked again: a; b")
    }

    func testSavedWorkWarning() {
        XCTAssertNil(RetractionText.savedWorkWarning([]))
        XCTAssertEqual(
            RetractionText.savedWorkWarning([(title: "A\n  trial", check: check("retracted", evidence()))]),
            "Since this report was written, 1 paper this report cites has a retraction warning:\n"
                + "• A trial: Retracted on 2026-03-09 (notice 10.9/n); Retraction Watch data as of 2026-10-01\n"
                + "The report has not been changed; re-run the question to bring it up to date.")
        let two = RetractionText.savedWorkWarning([
            (title: "A", check: check("retracted", evidence())),
            (title: "B", check: check("concern", evidence(kind: "expression_of_concern"), asOf: nil)),
        ])
        XCTAssertTrue(two?.hasPrefix("Since this report was written, 2 papers this report cites have") == true)
        XCTAssertTrue(two?.contains("• B: Expression of concern, 2026-03-09 (notice 10.9/n)\n") == true)
    }

    func testExcludedLine() {
        let run = check("retracted", evidence(notice: "10.9/notice"), asOf: nil)
        let runLine = "Excluded: retracted. Retracted on 2026-03-09 (notice 10.9/notice)"
        XCTAssertEqual(RetractionText.excludedLine(runCheck: run, current: run), runLine)
        XCTAssertEqual(
            RetractionText.excludedLine(runCheck: run, current: check("clear", asOf: nil)),
            "\(runLine). Checked again: No retraction found")
    }

    func testReportNotice() {
        XCTAssertEqual(
            RetractionText.reportNotice("1 retracted paper left out"),
            "> **Retraction check:** 1 retracted paper left out.")
    }

    func testPaperKey() {
        XCTAssertEqual(paper("https://doi.org/10.1/X").paperKey, paper("10.1/x").paperKey)
        XCTAssertEqual(paper(nil, pmid: "123").paperKey, "pmid:123")
        XCTAssertNil(paper(nil, pmid: "x").paperKey, "a PMID that is not canonical is no PMID")
        XCTAssertNil(paper(nil).paperKey)
    }
}
