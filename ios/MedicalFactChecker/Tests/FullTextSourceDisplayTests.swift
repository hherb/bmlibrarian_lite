// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2026 Dr Horst Herb
//
// Licensed under the GNU Affero General Public License, version 3 or later.

import XCTest
@testable import MedicalFactChecker

/// The reader-facing label of a stored full-text source.
final class FullTextSourceDisplayTests: XCTestCase {

    private func label(_ source: String?) -> String? {
        let document = Document(pmid: "1", title: "T", abstract: "")
        document.fullTextSource = source
        return document.fullTextSourceDisplay
    }

    func testPMCOpenDataHasItsOwnLabel() {
        XCTAssertEqual(label("pmc_open_data"), "PMC Open-Access Collection")
    }

    func testExistingLabelsAreUnchanged() {
        XCTAssertEqual(label("europepmc"), "Europe PMC")
        XCTAssertEqual(label("unpaywall"), "Unpaywall")
        XCTAssertEqual(label("doi"), "Publisher")
        XCTAssertEqual(label("cached"), "Cached")
    }

    func testUnknownSourceFallsBackToCapitalised() {
        XCTAssertEqual(label("mystery"), "Mystery")
        XCTAssertNil(label(nil))
    }
}
