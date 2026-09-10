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

/// What is left of the empty-PMID guard once the PMID stopped being the key.
///
/// The cache used to key on the PMID alone and refuse an empty one, because
/// `cachedPDFPath(for: "", from:)` resolved to `<cache>/-<fingerprint>.pdf` —
/// the same path for every article with no PMID that was offered the same
/// source URL — and a second such article would have read back the first one's
/// bytes. `ArticleCacheKey` removes the shared path rather than
/// guarding it: an article is named by the first identifier it actually has, so
/// two articles can only collide if they share one, and an article with no
/// identifier at all cannot name an entry to collide on (#202).
///
/// That leaves one property still worth pinning. It is now structural rather
/// than defensive, and structural guarantees are the easiest kind to lose in a
/// refactor that "simplifies" a type.
final class UnidentifiedArticleCacheTests: XCTestCase {
    /// A source URL that would have been shared by two identifier-less
    /// articles, which is how the original collision was measured.
    private let sharedSourceURL = URL(string: "https://example.org/shared-article.pdf")!

    /// No key can be built for a document carrying nothing, so there is no
    /// filename for such a document, so no two of them can share one. This is
    /// the guarantee that replaced the runtime refusal: it is enforced by the
    /// failable initialiser rather than by a check any caller could forget.
    func testAnArticleWithNoIdentifierCannotNameACacheEntry() {
        XCTAssertNil(ArticleCacheKey(pmid: "", pmcId: nil, doi: nil))
        XCTAssertNil(ArticleCacheKey(pmid: "", pmcId: "", doi: ""))
        XCTAssertNil(ArticleCacheKey(pmid: "  ", pmcId: "  ", doi: "  "))
    }

    /// The original defect's shape, expressed against the type that now
    /// prevents it: two articles with no PMID must not resolve to one path.
    ///
    /// Before `ArticleCacheKey` both produced `<cache>/-<fingerprint>.pdf` from
    /// an empty identifier and the same URL. Now each is named by the
    /// identifier it does have, so the same URL yields two entries.
    func testTwoArticlesWithoutPMIDsResolveToDifferentPathsForOneURL() throws {
        let first = try XCTUnwrap(ArticleCacheKey(pmid: "", pmcId: "PMC5000001", doi: nil))
        let second = try XCTUnwrap(ArticleCacheKey(pmid: "", pmcId: "PMC5000002", doi: nil))

        XCTAssertNotEqual(
            FullTextService.cacheFilename(key: first, url: sharedSourceURL),
            FullTextService.cacheFilename(key: second, url: sharedSourceURL),
            "two articles sharing a source URL must not share a cache entry"
        )
    }

    /// Two articles that carry different *kinds* of identifier must not collide
    /// either, which is why the kind is part of the filename and not only the
    /// value. This is the case an untagged key would have merged: one article's
    /// PMC accession is `5000001` and the other's PubMed ID is the same digits.
    func testArticlesIdentifiedByDifferentKindsResolveToDifferentPaths() throws {
        let viaPMC = try XCTUnwrap(ArticleCacheKey(pmid: "", pmcId: "5000001", doi: nil))
        let viaPubMed = try XCTUnwrap(ArticleCacheKey(pmid: "5000001", pmcId: nil, doi: nil))

        XCTAssertNotEqual(
            FullTextService.cacheFilename(key: viaPMC, url: sharedSourceURL),
            FullTextService.cacheFilename(key: viaPubMed, url: sharedSourceURL)
        )
    }

    /// One article, one entry. A PMC-only Europe PMC record carries its
    /// accession in the primary slot *and* in `pmcId`, and while the tag named
    /// the rung rather than the kind, the two rungs named two entries — so the
    /// record class #202 was opened for downloaded and stored its PDF twice
    /// (#209).
    func testOnePMCAccessionResolvesToOnePathThroughEitherRung() throws {
        let viaPMC = try XCTUnwrap(ArticleCacheKey(pmid: "", pmcId: "PMC5000001", doi: nil))
        let viaPrimarySlot = try XCTUnwrap(
            ArticleCacheKey(pmid: "PMC5000001", pmcId: nil, doi: nil)
        )

        XCTAssertEqual(
            FullTextService.cacheFilename(key: viaPMC, url: sharedSourceURL),
            FullTextService.cacheFilename(key: viaPrimarySlot, url: sharedSourceURL)
        )
    }
}
