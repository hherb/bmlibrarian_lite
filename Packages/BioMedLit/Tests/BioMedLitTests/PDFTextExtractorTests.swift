// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2025 Dr Horst Herb
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

/// The extractor is what makes a downloaded PDF contribute anything at all, and
/// every way it can come up empty has to be distinguishable: a scan that yields
/// nothing, a file that needs a password, and a partial extraction are three
/// different things to tell an operator.
final class PDFTextExtractorTests: XCTestCase {
    /// Fixtures sit beside this file, so no walk is needed. Located from
    /// `#filePath` rather than bundled as SwiftPM resources, matching
    /// `JATSRealCorpusTests` — and here it also keeps the generator script's
    /// output path and the test's input path the same string.
    private static func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/PDF/\(name)")
    }

    private let extractor = PDFKitTextExtractor()

    func testAnOrdinaryPDFYieldsItsProse() {
        let result = extractor.extract(from: Self.fixture("ordinary.pdf"))
        XCTAssertTrue(result.success)
        XCTAssertTrue(result.text.contains("Randomised trial"))
        XCTAssertTrue(result.text.contains("120 patients"))
        XCTAssertEqual(result.pageCount, 1)
        XCTAssertEqual(result.convertedPages, 1)
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.charCount, result.text.count)
    }

    /// The point of the whole result type: a page that gave nothing is counted,
    /// so a caller can tell half an article from a whole one.
    func testAPageWithNoTextIsCountedAsUnconverted() {
        let result = extractor.extract(from: Self.fixture("mixed.pdf"))
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.pageCount, 2)
        XCTAssertEqual(result.convertedPages, 1)
        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(result.completionRatio, 0.5, accuracy: 0.001)
        XCTAssertTrue(
            result.warnings.contains(where: { $0.contains("2") }),
            "the warning should name the page that gave nothing, got \(result.warnings)"
        )
    }

    /// A scan. Successful — nothing went wrong — but with no text, which is a
    /// state the caller must not mistake for prose.
    func testAnImageOnlyPDFSucceedsWithNoText() {
        let result = extractor.extract(from: Self.fixture("imageonly.pdf"))
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.charCount, 0)
        XCTAssertEqual(result.convertedPages, 0)
        XCTAssertFalse(result.isComplete)
    }

    /// bmlib is explicit that a password is a failure rather than an empty
    /// success, so that a locked file is never reported as a scan.
    func testAnEncryptedPDFIsAFailureNotAnEmptySuccess() {
        let result = extractor.extract(from: Self.fixture("encrypted.pdf"))
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.charCount, 0)
        XCTAssertNotNil(result.errorMessage)
    }

    /// The negative control the guard needs to not be a check that cannot fail.
    ///
    /// An *owner* password restricts permissions without blocking reads, so the
    /// file is encrypted and converts perfectly. PDFKit reports
    /// `isLocked == false, isEncrypted == true` for this fixture — verified when
    /// it was generated — so a guard widened to `isEncrypted` rejects a readable
    /// article. bmlib rejects on `needs_pass` alone and names widening it as the
    /// wrong rule (`DECISIONS.md`, "fulltext — the PDF converter"); `isLocked` is
    /// PDFKit's `needs_pass`.
    func testAnOwnerPasswordAloneDoesNotBlockExtraction() {
        let result = extractor.extract(from: Self.fixture("ownerpassword.pdf"))
        XCTAssertTrue(result.success, "an owner password restricts permissions, not reading")
        XCTAssertNil(result.errorMessage)
        XCTAssertTrue(result.text.contains("120 patients"))
        XCTAssertEqual(result.convertedPages, result.pageCount)
        XCTAssertTrue(result.isComplete)
    }

    func testAMissingFileIsAFailure() {
        let result = extractor.extract(from: Self.fixture("does-not-exist.pdf"))
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.pageCount, 0)
        XCTAssertNotNil(result.errorMessage)
    }

    /// `isComplete` is derived, and every clause of it matters: an empty
    /// successful extraction is not complete.
    func testCompletenessRequiresSuccessEveryPageAndSomeText() {
        let empty = PDFExtractionResult(
            text: "", success: true, pageCount: 0, convertedPages: 0, warnings: []
        )
        XCTAssertFalse(empty.isComplete)
        XCTAssertEqual(empty.completionRatio, 0)
    }
}
