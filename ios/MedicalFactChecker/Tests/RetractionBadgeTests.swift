// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2026 Dr Horst Herb
// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest
import BioMedLit
@testable import MedicalFactChecker

/// The retraction badge's pure content: which status shows what, where.
final class RetractionBadgeTests: XCTestCase {
    private func check(_ status: String, unanswered: [String] = []) -> PaperRetractionCheck {
        PaperRetractionCheck(
            status: status, deciding: nil, unanswered: unanswered,
            checkedAt: Date(timeIntervalSince1970: 0), exportDataAsOf: nil, crossrefFailure: nil
        )
    }

    func testBadgeContentPerStatus() {
        XCTAssertEqual(RetractionBadge.Content(check: check("retracted"))?.text, "RETRACTED")
        XCTAssertEqual(RetractionBadge.Content(check: check("concern"))?.text, "CONCERN")
        XCTAssertEqual(RetractionBadge.Content(check: check("unchecked", unanswered: ["crossref"]))?.text, "NOT CHECKED")
        // clear shows nothing, in the list and in the detail view
        XCTAssertNil(RetractionBadge.Content(check: check("clear")))
        XCTAssertNil(RetractionBadge.Content(check: check("clear"), inDetail: true))
        // never checked: NOT CHECKED only in the detail view
        XCTAssertNil(RetractionBadge.Content(check: nil))
        let never = RetractionBadge.Content(check: nil, inDetail: true)
        XCTAssertEqual(never?.text, "NOT CHECKED")
        XCTAssertEqual(never?.tooltip, "Retraction status never checked")
    }

    func testTooltipIsThePaperStatusLine() {
        let retracted = check("retracted")
        XCTAssertEqual(RetractionBadge.Content(check: retracted)?.tooltip, RetractionText.paperStatusLine(retracted))
    }
}
