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

/// One article can be offered more than one PDF, and they are different files.
///
/// Keyed on the PMID alone, the first tier to download won the entry and every
/// later tier was served *its* bytes. The chain then returned a Europe PMC
/// download as the Unpaywall result — recording `fullTextSource = "unpaywall"`
/// over the wrong provenance — and never fetched the copy that might have
/// extracted cleanly.
final class PDFCacheKeyTests: XCTestCase {
    private static let pmid = "cache-key-test-99301"

    /// The name this article's cached PDFs are filed under.
    private static let cacheKey = ArticleCacheKey(pmid: pmid, pmcId: nil, doi: nil)!
    private static let europePMCURL = URL(string: "https://europepmc.org/articles/PMC9/pdf")!
    private static let unpaywallURL = URL(string: "https://example.org/oa.pdf")!

    private static let europePMCBytes =
        Data([0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x34]) + Data("europe pmc copy".utf8)
    private static let unpaywallBytes =
        Data([0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x34]) + Data("unpaywall copy".utf8)

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        FullTextService.deleteCachedPDF(for: Self.cacheKey)
    }

    override func tearDown() {
        StubURLProtocol.reset()
        FullTextService.deleteCachedPDF(for: Self.cacheKey)
        super.tearDown()
    }

    private func makeService() -> FullTextService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return FullTextService(
            email: "test@example.org", session: URLSession(configuration: config)
        )
    }

    /// The defect, directly: two sources for one article must not share bytes.
    func testTwoSourcesForOneArticleGetSeparateCacheEntries() async throws {
        StubURLProtocol.routes = [
            "articles/PMC9/pdf": (200, Self.europePMCBytes),
            "oa.pdf": (200, Self.unpaywallBytes),
        ]
        let service = makeService()

        let firstPath = try await service.downloadAndCachePDF(
            from: Self.europePMCURL, for: Self.cacheKey
        )
        let secondPath = try await service.downloadAndCachePDF(
            from: Self.unpaywallURL, for: Self.cacheKey
        )

        XCTAssertNotEqual(firstPath, secondPath)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: firstPath)), Self.europePMCBytes)
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: secondPath)), Self.unpaywallBytes,
            "the second source must not be served the first source's bytes"
        )
    }

    /// The same article and the same URL still hit, which is the whole point of
    /// having a cache.
    func testTheSameSourceIsServedFromTheCache() async throws {
        StubURLProtocol.routes = ["oa.pdf": (200, Self.unpaywallBytes)]
        let service = makeService()

        let firstPath = try await service.downloadAndCachePDF(
            from: Self.unpaywallURL, for: Self.cacheKey
        )
        StubURLProtocol.routes = ["oa.pdf": (404, Data())]
        let secondPath = try await service.downloadAndCachePDF(
            from: Self.unpaywallURL, for: Self.cacheKey
        )

        XCTAssertEqual(firstPath, secondPath, "a second fetch of the same URL must not re-download")
    }

    /// The key is stable across processes. `Hasher` is seeded per launch, so
    /// building the fingerprint from it would miss every entry written by a
    /// previous run — a cache that never hits, and never says so.
    func testTheKeyIsStableForTheSameInputs() {
        let first = FullTextService.cacheFilename(key: Self.cacheKey, url: Self.unpaywallURL)
        let second = FullTextService.cacheFilename(key: Self.cacheKey, url: Self.unpaywallURL)
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.hasSuffix(".\(BioMedLitConstants.pdfExtension)"))
    }

    /// An identifier is not trusted with the filename. Europe PMC supplies it,
    /// and `appendingPathComponent` on a value holding `/` or `..` would place
    /// the written file outside the cache directory entirely.
    func testAnIdentifierCannotWalkOutOfTheCacheDirectory() {
        let hostileKey = ArticleCacheKey(pmid: "../../etc/passwd", pmcId: nil, doi: nil)!
        let hostile = FullTextService.cacheFilename(key: hostileKey, url: Self.unpaywallURL)
        XCTAssertFalse(hostile.contains("/"))
        XCTAssertFalse(hostile.contains(".."))

        let planted = FullTextService.pdfCacheDirectory.appendingPathComponent(hostile)
        XCTAssertEqual(
            planted.deletingLastPathComponent().standardizedFileURL,
            FullTextService.pdfCacheDirectory.standardizedFileURL
        )
    }

    /// Quarantined entries are cache too. Filtering the clear on the `pdf`
    /// extension alone left every `.corrupt` file behind, so bytes set aside for
    /// inspection accumulated in a directory the user had asked to empty.
    ///
    /// Tested through the predicate rather than by calling `clearPDFCache()`,
    /// which empties the real user cache directory — running this suite would
    /// otherwise delete the cached PDFs of whoever ran it.
    func testTheCacheClearCoversQuarantinedEntriesAsWellAsPDFs() {
        let cached = FullTextService.pdfCacheDirectory
            .appendingPathComponent(
                FullTextService.cacheFilename(key: Self.cacheKey, url: Self.unpaywallURL)
            )
        let quarantined = cached
            .appendingPathExtension(BioMedLitConstants.quarantinedPDFExtension)

        XCTAssertTrue(FullTextService.isClearableCacheEntry(cached))
        XCTAssertTrue(FullTextService.isClearableCacheEntry(quarantined))
        XCTAssertFalse(
            FullTextService.isClearableCacheEntry(
                FullTextService.pdfCacheDirectory.appendingPathComponent("notes.txt")
            ),
            "the clear must stay scoped to what this cache wrote"
        )
    }

    /// Deleting one article's cache removes every entry it holds, not just the
    /// one that happens to match a rebuilt filename.
    func testDeletingAnArticleRemovesEveryEntryItHolds() async throws {
        StubURLProtocol.routes = [
            "articles/PMC9/pdf": (200, Self.europePMCBytes),
            "oa.pdf": (200, Self.unpaywallBytes),
        ]
        let service = makeService()
        let first = try await service.downloadAndCachePDF(from: Self.europePMCURL, for: Self.cacheKey)
        let second = try await service.downloadAndCachePDF(from: Self.unpaywallURL, for: Self.cacheKey)

        FullTextService.deleteCachedPDF(for: Self.cacheKey)

        XCTAssertFalse(FileManager.default.fileExists(atPath: first))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second))
    }
}
