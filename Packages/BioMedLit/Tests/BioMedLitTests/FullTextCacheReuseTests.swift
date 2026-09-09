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

/// `downloadAndCachePDF` never consulted `cachedPDFPath`, so every re-fetch
/// downloaded bytes already on disk and the validation and quarantine that
/// method carries had no production caller — a corrupt entry was moved aside by
/// nothing but a test. `doc/cross_platform/fulltext_retrieval.md` has shown the
/// cache check as step one of the download since this branch published it.
final class FullTextCacheReuseTests: XCTestCase {
    private let pmid = "cache-reuse-99998"

    private static let validPDF = Data([0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x34, 0x0A])
    private static let freshPDF = Data([0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x37, 0x0A])

    private var cachedFile: URL {
        FullTextService.pdfCacheDirectory
            .appendingPathComponent("\(pmid).\(BioMedLitConstants.pdfExtension)")
    }

    private var quarantinedFile: URL {
        cachedFile.appendingPathExtension("corrupt")
    }

    private func clearCache() {
        try? FileManager.default.removeItem(at: cachedFile)
        try? FileManager.default.removeItem(at: quarantinedFile)
    }

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        clearCache()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        clearCache()
        super.tearDown()
    }

    private func makeService() -> FullTextService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return FullTextService(email: "test@example.org", session: URLSession(configuration: config))
    }

    /// A valid entry is served without a request going out. The remote is stubbed
    /// to fail, so a download would be unmistakable.
    func testAValidCachedPDFIsServedWithoutDownloading() async throws {
        try Self.validPDF.write(to: cachedFile)
        StubURLProtocol.stubbed = (404, Data())

        let path = try await makeService().downloadAndCachePDF(
            from: URL(string: "https://example.org/a.pdf")!, for: pmid
        )

        XCTAssertEqual(path, cachedFile.path)
        XCTAssertEqual(try Data(contentsOf: cachedFile), Self.validPDF, "it was not re-fetched")
    }

    /// The reason quarantine and re-download belong on the same path: a bad entry
    /// reads as a miss, so the download runs and replaces it. Leaving it in place
    /// would hide every future download behind it.
    func testACorruptCachedEntryIsQuarantinedAndTheDownloadProceeds() async throws {
        try Data("<html>404 not found</html>".utf8).write(to: cachedFile)
        StubURLProtocol.stubbed = (200, Self.freshPDF)

        let path = try await makeService().downloadAndCachePDF(
            from: URL(string: "https://example.org/a.pdf")!, for: pmid
        )

        XCTAssertEqual(path, cachedFile.path)
        XCTAssertEqual(try Data(contentsOf: cachedFile), Self.freshPDF)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: quarantinedFile.path),
            "the bad entry is moved aside rather than deleted"
        )
    }

    /// The ordinary miss still downloads.
    func testAnAbsentEntryIsDownloaded() async throws {
        StubURLProtocol.stubbed = (200, Self.freshPDF)

        let path = try await makeService().downloadAndCachePDF(
            from: URL(string: "https://example.org/a.pdf")!, for: pmid
        )

        XCTAssertEqual(path, cachedFile.path)
        XCTAssertEqual(try Data(contentsOf: cachedFile), Self.freshPDF)
    }
}
