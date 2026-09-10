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
/// cache check as step one of the download since this branch changed it to a
/// *validated* one — an unvalidated existence check was already in that
/// document beforehand.
final class FullTextCacheReuseTests: XCTestCase {
    private let pmid = "cache-reuse-99998"

    /// The name this article's cached PDFs are filed under.
    private lazy var cacheKey = ArticleCacheKey(pmid: pmid, pmcId: nil, doi: nil)!

    private static let validPDF = Data([0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x34, 0x0A])
    private static let freshPDF = Data([0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x37, 0x0A])

    /// The one source URL every test here fetches from. Named once because it
    /// is part of the cache key: an entry is keyed on the article *and* the URL
    /// its bytes came from, so a test that planted a file under one URL and
    /// downloaded from another would simply miss.
    private let sourceURL = URL(string: "https://example.org/a.pdf")!

    private var cachedFile: URL {
        FullTextService.pdfCacheDirectory
            .appendingPathComponent(FullTextService.cacheFilename(key: cacheKey, url: sourceURL))
    }

    private var quarantinedFile: URL {
        cachedFile.appendingPathExtension(BioMedLitConstants.quarantinedPDFExtension)
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
            from: sourceURL, for: cacheKey
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
            from: sourceURL, for: cacheKey
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
            from: sourceURL, for: cacheKey
        )

        XCTAssertEqual(path, cachedFile.path)
        XCTAssertEqual(try Data(contentsOf: cachedFile), Self.freshPDF)
    }
}
