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

/// The COI and data-availability extractors end a section at a blank line or at
/// the end of the text. PDFKit's `PDFPage.string` separates lines with a single
/// `\n` and never emits a blank one, so a statement found mid-page used to match
/// from its header to the end of the page — and on the last page, to the end of
/// the document. `COIAnalyzer` then counted industry keywords across the whole
/// blob, and an article that declared none could be stored as having industry
/// ties because a sentence naming a drug's manufacturer sat further down the
/// same page.
final class SectionCaptureCapTests: XCTestCase {
    private let service = TransparencyAnalysisService(email: "test@example.org")

    /// A COI statement with no industry keywords in it and no "no conflicts"
    /// phrasing either, so that the verdict below turns on what was captured
    /// rather than on the explicit-declaration shortcut.
    private static let coiStatement =
        "Conflict of interest: This study was investigator-initiated and the "
        + "authors received nothing for their participation."

    /// Ordinary body prose, of the kind that follows a disclosure on the same
    /// PDF page, ending in a sentence full of industry keywords.
    private static func unsegmentedTail(padding: Int) -> String {
        let filler = Array(
            repeating: "Patients were followed for twelve months after randomisation.",
            count: padding
        ).joined(separator: "\n")
        return filler
            + "\nStudy drug was supplied by Acme Pharmaceuticals Inc., and the "
            + "manufacturer reviewed the protocol."
    }

    /// The whole point: a blob whose industry keywords sit outside the section
    /// must not produce a verdict the section alone would not produce.
    func testAnUnsegmentedBlobDoesNotManufactureIndustryTies() {
        let fromSectionAlone = COIAnalyzer.analyze(
            statement: service.extractCOISection(from: Self.coiStatement)
        )
        XCTAssertFalse(
            fromSectionAlone.hasIndustryTies,
            "the statement itself declares no industry relationship"
        )

        let blob = Self.coiStatement + "\n" + Self.unsegmentedTail(padding: 40)
        let fromBlob = COIAnalyzer.analyze(statement: service.extractCOISection(from: blob))

        XCTAssertFalse(
            fromBlob.hasIndustryTies,
            "prose from elsewhere on the page must not become part of the disclosure"
        )
    }

    /// And the mechanism that achieves it, asserted directly.
    func testTheCOICaptureIsCappedForUnsegmentedProse() throws {
        let blob = Self.coiStatement + "\n" + Self.unsegmentedTail(padding: 40)

        let captured = try XCTUnwrap(service.extractCOISection(from: blob))

        XCTAssertLessThanOrEqual(captured.count, TransparencyConstants.maxSectionCaptureLength)
        XCTAssertFalse(
            captured.contains("Acme Pharmaceuticals"),
            "the tail of the page is not part of the disclosure"
        )
        XCTAssertTrue(captured.contains("investigator-initiated"))
    }

    /// The same runaway applies to the data-availability extractor, which shares
    /// the terminator.
    func testTheDataAvailabilityCaptureIsCappedForUnsegmentedProse() throws {
        let blob = "Data availability: The dataset is held by the sponsor.\n"
            + Self.unsegmentedTail(padding: 40)

        let captured = try XCTUnwrap(service.extractDataAvailabilitySection(from: blob))

        XCTAssertLessThanOrEqual(captured.count, TransparencyConstants.maxSectionCaptureLength)
        XCTAssertTrue(captured.contains("held by the sponsor"))
    }

    /// The negative control: a properly segmented rendering — JATS markdown,
    /// with blank lines between paragraphs — is unaffected, and a statement
    /// shorter than the cap comes back whole.
    func testASegmentedRenderingIsUnaffected() throws {
        let markdown = Self.coiStatement + "\n\n"
            + "Study drug was supplied by Acme Pharmaceuticals Inc."

        let captured = try XCTUnwrap(service.extractCOISection(from: markdown))

        // `RegexHelper.extractFirst` returns the lowercased text it matched
        // against, which is pre-existing behaviour and not what this test is
        // about.
        XCTAssertEqual(
            captured,
            "this study was investigator-initiated and the authors received "
                + "nothing for their participation."
        )
        XCTAssertLessThan(captured.count, TransparencyConstants.maxSectionCaptureLength)
    }

    /// A disclosure that really does name industry partners still reads as one:
    /// the cap bounds what is captured, it does not blunt the analysis.
    func testARealIndustryDisclosureIsStillDetected() {
        let statement = "Conflict of interest: Dr A is a consultant for Acme "
            + "Pharmaceuticals Inc. and has received honoraria from Beta Corp."

        let result = COIAnalyzer.analyze(statement: service.extractCOISection(from: statement))

        XCTAssertTrue(result.hasIndustryTies)
    }
}
