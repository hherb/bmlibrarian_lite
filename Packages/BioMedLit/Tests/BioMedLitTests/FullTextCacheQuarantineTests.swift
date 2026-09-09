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

/// `cachedPDFPath` asked only whether a file existed. A zero-length or corrupt
/// entry was therefore served as this article's full text forever, and — worse —
/// stood in front of any fresh download, so the article re-fetched on every run
/// and never got better. bmlib's issue #71 is the same finding.
final class FullTextCacheQuarantineTests: XCTestCase {
    private let pmid = "quarantine-test-99999"

    private var cachedFile: URL {
        FullTextService.pdfCacheDirectory
            .appendingPathComponent("\(pmid).\(BioMedLitConstants.pdfExtension)")
    }

    private var quarantinedFile: URL {
        cachedFile.appendingPathExtension("corrupt")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: cachedFile)
        try? FileManager.default.removeItem(at: quarantinedFile)
        super.tearDown()
    }

    func testAValidPDFIsReturnedUntouched() throws {
        try Data([0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x34]).write(to: cachedFile)
        XCTAssertEqual(FullTextService.cachedPDFPath(for: pmid), cachedFile.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cachedFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantinedFile.path))
    }

    func testAnEmptyEntryIsQuarantinedAndReadsAsAbsent() throws {
        try Data().write(to: cachedFile)
        XCTAssertNil(FullTextService.cachedPDFPath(for: pmid))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: cachedFile.path),
            "it must not stand in front of the next download"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: quarantinedFile.path),
            "moved aside rather than deleted, so an operator can look at it"
        )
    }

    func testAnEntryThatIsNotAPDFIsQuarantined() throws {
        try Data("<html>404 not found</html>".utf8).write(to: cachedFile)
        XCTAssertNil(FullTextService.cachedPDFPath(for: pmid))
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantinedFile.path))
    }

    func testAnAbsentEntryIsSimplyAbsent() {
        XCTAssertNil(FullTextService.cachedPDFPath(for: pmid))
        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantinedFile.path))
    }

    /// A second corrupt entry replaces the first rather than failing the read:
    /// `replaceItemAt` overwrites, and a quarantine that threw would turn a
    /// recoverable miss into an error.
    func testASecondQuarantineOverwritesTheFirst() throws {
        try Data("first".utf8).write(to: quarantinedFile)
        try Data("second".utf8).write(to: cachedFile)
        XCTAssertNil(FullTextService.cachedPDFPath(for: pmid))
        XCTAssertEqual(try Data(contentsOf: quarantinedFile), Data("second".utf8))
    }
}
