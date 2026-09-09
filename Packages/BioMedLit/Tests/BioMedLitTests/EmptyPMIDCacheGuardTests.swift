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

/// `cachedPDFPath(for: "")` resolves to `<cache>/.pdf` — the same path for every
/// article with no PMID, and an empty PMID is real and reachable:
/// `EuropePMCService.swift` builds one as `result.pmid ?? result.id ?? ""`, and
/// `MacScoredDocumentsView.swift` documents an empty `pmid` alongside a real
/// `pmcId` as an ordinary Europe PMC condition, not a bug. Before
/// `downloadAndCachePDF` consulted the cache, every call re-downloaded, so
/// extraction always read back the bytes it had just written and the shared
/// filename never mattered — the collision self-healed. Once a cache hit could
/// short-circuit the download that stopped being true, and a second empty-PMID
/// article would deterministically read back the first one's cached text.
final class EmptyPMIDCacheGuardTests: XCTestCase {
    /// A source URL shared by both articles below, so the only thing that could
    /// separate their cache entries is the identifier — which neither has.
    private let sharedSourceURL = URL(string: "https://example.org/first-article.pdf")!

    /// The one path every empty-PMID article resolves to.
    private var sharedEmptyPMIDFile: URL {
        FullTextService.pdfCacheDirectory
            .appendingPathComponent(
                FullTextService.cacheFilename(pmid: "", url: sharedSourceURL)
            )
    }

    private var quarantinedSharedFile: URL {
        sharedEmptyPMIDFile.appendingPathExtension(
            BioMedLitConstants.quarantinedPDFExtension
        )
    }

    private func clearCache() {
        try? FileManager.default.removeItem(at: sharedEmptyPMIDFile)
        try? FileManager.default.removeItem(at: quarantinedSharedFile)
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

    /// The direct case: whatever else happens, `cachedPDFPath` must never point
    /// at the shared entry for an empty PMID, even when one exists on disk (left
    /// behind by another empty-PMID article, or by an old build that lacked the
    /// guard below).
    func testCachedPDFPathIsNilForAnEmptyPMIDEvenWhenTheSharedFileExists() throws {
        try Data(BioMedLitConstants.pdfMagicBytes).write(to: sharedEmptyPMIDFile)

        XCTAssertNil(FullTextService.cachedPDFPath(for: "", from: sharedSourceURL))
    }

    /// The scenario the bug report measured: two unrelated articles, neither
    /// with a PMID, must not be able to read each other's PDF bytes back
    /// through the cache.
    ///
    /// Before the guard, this reproduced the collision directly: the first
    /// call downloaded and cached its bytes at the shared path; the second
    /// call's `cachedPDFPath(for: "")` found that entry, judged it valid, and
    /// returned the *first* article's bytes without a network request —
    /// exactly the corruption `downloadAndCachePDF`'s cache-first change made
    /// deterministic instead of self-healing.
    func testASecondEmptyPMIDArticleCannotReadTheFirstOnesCachedBytes() async throws {
        let firstArticleBytes = Data(BioMedLitConstants.pdfMagicBytes) + Data("first article".utf8)
        let secondArticleBytes = Data(BioMedLitConstants.pdfMagicBytes) + Data("second article".utf8)
        StubURLProtocol.routes = [
            "first-article.pdf": (200, firstArticleBytes),
            "second-article.pdf": (200, secondArticleBytes),
        ]

        let service = makeService()

        // Article A, with no PMID, fetches its own PDF.
        var firstPath: String?
        var firstError: Error?
        do {
            firstPath = try await service.downloadAndCachePDF(
                from: URL(string: "https://example.org/first-article.pdf")!, for: ""
            )
        } catch {
            firstError = error
        }

        // Whatever article A's own fetch produced, it must be its own bytes.
        if let firstPath, FileManager.default.fileExists(atPath: firstPath) {
            let firstContent = try Data(contentsOf: URL(fileURLWithPath: firstPath))
            XCTAssertEqual(
                firstContent, firstArticleBytes,
                "the first article's own fetch must return its own bytes"
            )
        }

        // Article B — an unrelated paper that also has no PMID — fetches next.
        var secondPath: String?
        var secondError: Error?
        do {
            secondPath = try await service.downloadAndCachePDF(
                from: URL(string: "https://example.org/second-article.pdf")!, for: ""
            )
        } catch {
            secondError = error
        }

        // The defect this guards against: B's result must never be A's bytes.
        if let secondPath, FileManager.default.fileExists(atPath: secondPath) {
            let secondContent = try Data(contentsOf: URL(fileURLWithPath: secondPath))
            XCTAssertNotEqual(
                secondContent, firstArticleBytes,
                "the second article's PDF must not be the first article's cached bytes"
            )
        }

        // And the mechanism that would let it happen again must not exist:
        // nothing may ever be written to the one path every empty-PMID article
        // resolves to.
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: sharedEmptyPMIDFile.path),
            "an empty PMID must not produce a cache entry other articles can collide on"
        )

        // This guard's chosen behaviour: an empty PMID is refused outright
        // rather than downloaded without caching (see `downloadAndCachePDF`'s
        // doc comment for why). Both fetches above must have failed instead of
        // quietly succeeding.
        XCTAssertNotNil(firstError, "an empty PMID must be refused, not downloaded and cached")
        XCTAssertNotNil(secondError, "an empty PMID must be refused, not downloaded and cached")
    }
}
