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

/// Returns a fixed extraction, so the end-to-end test below exercises the
/// retrieval chain rather than PDFKit.
private struct StubExtractor: PDFTextExtracting {
    let result: PDFExtractionResult
    func extract(from fileURL: URL) -> PDFExtractionResult { result }
}

/// #202: an article with no PMID used to get no PDF extraction at all.
///
/// The refusal was correct as far as it went — every article with no PMID would
/// otherwise share one cache entry — but it threw away the article's other
/// identifiers, and a Europe PMC record can carry a PMC ID with no PMID. Those
/// are exactly the open-access articles most likely to have a usable free PDF.
/// The tier reported a download failure, the chain moved on, and nothing
/// distinguished this from a PDF that genuinely could not be fetched.
final class NoPMIDPDFExtractionTests: XCTestCase {
    /// Built in `setUpWithError` rather than as force-unwrapped static stored
    /// properties. A `!` in a static initialiser runs during type metadata
    /// setup, so a broken `ArticleCacheKey` would trap and take the whole test
    /// process down — every other suite in the run with it — instead of failing
    /// this one suite. `XCTUnwrap` keeps a breakage to one red test.
    private var pmcOnly: ArticleCacheKey!
    private var otherPMCOnly: ArticleCacheKey!
    private var doiOnly: ArticleCacheKey!

    private static let firstURL = URL(string: "https://example.org/pmc-article.pdf")!
    private static let secondURL = URL(string: "https://example.org/other-article.pdf")!

    private static let firstBytes =
        Data(BioMedLitConstants.pdfMagicBytes) + Data("the pmc article".utf8)
    private static let secondBytes =
        Data(BioMedLitConstants.pdfMagicBytes) + Data("a different article".utf8)

    private func clearCache() {
        for key in [pmcOnly, otherPMCOnly, doiOnly].compactMap({ $0 }) {
            FullTextService.deleteCachedPDF(for: key)
        }
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        pmcOnly = try XCTUnwrap(ArticleCacheKey(pmid: "", pmcId: "PMC202test", doi: nil))
        otherPMCOnly = try XCTUnwrap(ArticleCacheKey(pmid: "", pmcId: "PMC202other", doi: nil))
        doiOnly = try XCTUnwrap(ArticleCacheKey(pmid: "", pmcId: nil, doi: "10.202/test"))
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
        return FullTextService(
            email: "test@example.org", session: URLSession(configuration: config)
        )
    }

    /// The defect, directly: this download used to be refused.
    func testAnArticleWithOnlyAPMCIdentifierGetsItsPDFCached() async throws {
        StubURLProtocol.routes = ["pmc-article.pdf": (200, Self.firstBytes)]

        let path = try await makeService().downloadAndCachePDF(
            from: Self.firstURL, for: pmcOnly
        )

        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Self.firstBytes)
    }

    /// An article whose only identifier is a DOI gets an entry too.
    func testAnArticleWithOnlyADOIGetsItsPDFCached() async throws {
        StubURLProtocol.routes = ["pmc-article.pdf": (200, Self.firstBytes)]

        let path = try await makeService().downloadAndCachePDF(
            from: Self.firstURL, for: doiOnly
        )

        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Self.firstBytes)
    }

    /// The property the old refusal was protecting, which must survive the fix:
    /// two articles that both lack a PMID must not read each other's bytes.
    func testTwoArticlesWithoutPMIDsDoNotShareCachedBytes() async throws {
        StubURLProtocol.routes = [
            "pmc-article.pdf": (200, Self.firstBytes),
            "other-article.pdf": (200, Self.secondBytes),
        ]
        let service = makeService()

        let firstPath = try await service.downloadAndCachePDF(
            from: Self.firstURL, for: pmcOnly
        )
        let secondPath = try await service.downloadAndCachePDF(
            from: Self.secondURL, for: otherPMCOnly
        )

        XCTAssertNotEqual(firstPath, secondPath)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: secondPath)), Self.secondBytes)
    }

    /// A cached entry is served back to the article that owns it, and only to
    /// that article. The second lookup asks for the same URL under a different
    /// article and must miss.
    func testACachedEntryIsNotServedToADifferentArticle() async throws {
        StubURLProtocol.routes = ["pmc-article.pdf": (200, Self.firstBytes)]
        _ = try await makeService().downloadAndCachePDF(from: Self.firstURL, for: pmcOnly)

        XCTAssertNotNil(FullTextService.cachedPDFPath(for: pmcOnly, from: Self.firstURL))
        XCTAssertNil(FullTextService.cachedPDFPath(for: otherPMCOnly, from: Self.firstURL))
    }

    // MARK: - End to end

    /// The whole point of #202, through the public entry point.
    ///
    /// A Europe PMC article with a PMC ID and neither a PMID nor a DOI used to
    /// get nothing: the cache refused to name an entry for it, *and* nothing
    /// asked Europe PMC for its PMC ID, so no render URL was ever resolved and
    /// no PDF tier fired. Both halves have to work for this to pass — keying
    /// the cache correctly is not enough on its own.
    ///
    /// The XML deposit here is body-less, so the XML tier holds it back and the
    /// PDF tier gets its turn, which is the only route to a render URL.
    func testAnArticleWithOnlyAPMCIdentifierReachesItsPDFThroughFetchFullText() async throws {
        let pmcId = "PMC202e2e"
        let key = try XCTUnwrap(ArticleCacheKey(pmid: "", pmcId: pmcId, doi: nil))
        FullTextService.deleteCachedPDF(for: key)
        defer { FullTextService.deleteCachedPDF(for: key) }

        let searchResponse = #"""
        {"resultList": {"result": [{
          "id": "1", "pmcid": "PMC202e2e", "inPMC": "Y",
          "fullTextUrlList": {"fullTextUrl": [
            {"documentStyle": "pdf", "site": "Europe_PMC",
             "url": "https://europepmc.org/articles/PMC202e2e/pdf",
             "availability": "Open access", "availabilityCode": "OA"}
          ]}
        }]}}
        """#
        let bodyless = Data("""
        <article><front><article-meta>
          <title-group><article-title>A trial</article-title></title-group>
          <abstract><p>Abstract only.</p></abstract>
        </article-meta></front></article>
        """.utf8)

        StubURLProtocol.routes = [
            "search": (200, Data(searchResponse.utf8)),
            "fullTextXML": (200, bodyless),
            "articles/PMC202e2e/pdf": (200, Self.firstBytes),
        ]

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        let service = FullTextService(
            email: "test@example.org",
            session: session,
            europePMCService: EuropePMCService(session: session),
            extractor: StubExtractor(
                result: PDFExtractionResult(
                    text: "The recovered article body.",
                    success: true,
                    pageCount: 1,
                    convertedPages: 1,
                    warnings: [],
                    errorMessage: nil
                )
            ),
            extractPDFText: true
        )

        let result = try await service.fetchFullText(pmcId: pmcId, doi: nil, pmid: "")

        XCTAssertEqual(
            result.contentKind, .extracted,
            "the PDF's text must reach the caller, not the held-back abstract"
        )
        XCTAssertEqual(result.extractedText, "The recovered article body.")

        // The stub answers any URL containing `search`, so the assertions above
        // hold whether the chain asked the right question or the wrong one.
        // This is what pins the question itself: `PMCID:` is the only field that
        // matches a PMC accession, and the pre-fix `ext_id:… src:med` would
        // match nothing against the live API.
        XCTAssertTrue(
            StubURLProtocol.requested("PMCID:PMC202e2e")
                || StubURLProtocol.requested("PMCID%3APMC202e2e"),
            "the PMC ID must be asked for by its own field: \(StubURLProtocol.requestedURLs)"
        )
    }

    /// A preprint is the other article class the routing fix exists for, and
    /// the one with the least to fall back on.
    ///
    /// A `SRC:PPR` record carries no PMID and no PMC ID, so its accession is the
    /// only identifier it has besides a DOI — and with no DOI it has nothing
    /// else at all. Asked for as `ext_id:… src:med` it matched nothing, so no
    /// render URL resolved and no PDF tier fired, despite Europe PMC holding an
    /// open-access PDF. The unit test pins the query string; this pins the
    /// wiring that carries it to a retrieved PDF.
    func testAPreprintReachesItsPDFThroughFetchFullText() async throws {
        let accession = "PPR202e2e"
        let key = try XCTUnwrap(ArticleCacheKey(pmid: accession, pmcId: nil, doi: nil))
        FullTextService.deleteCachedPDF(for: key)
        defer { FullTextService.deleteCachedPDF(for: key) }

        // No `pmcid`, as a preprint record has none, so the XML tier never runs
        // and the render URL is the article's only route to its text.
        let searchResponse = #"""
        {"resultList": {"result": [{
          "id": "PPR202e2e", "source": "PPR",
          "fullTextUrlList": {"fullTextUrl": [
            {"documentStyle": "pdf", "site": "Europe_PMC",
             "url": "https://europepmc.org/articles/PPR202e2e/pdf",
             "availability": "Open access", "availabilityCode": "OA"}
          ]}
        }]}}
        """#

        StubURLProtocol.routes = [
            "search": (200, Data(searchResponse.utf8)),
            "articles/PPR202e2e/pdf": (200, Self.firstBytes),
        ]

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        let service = FullTextService(
            email: "test@example.org",
            session: session,
            europePMCService: EuropePMCService(session: session),
            extractor: StubExtractor(
                result: PDFExtractionResult(
                    text: "The preprint body.",
                    success: true,
                    pageCount: 1,
                    convertedPages: 1,
                    warnings: [],
                    errorMessage: nil
                )
            ),
            extractPDFText: true
        )

        let result = try await service.fetchFullText(pmcId: nil, doi: nil, pmid: accession)

        XCTAssertEqual(result.contentKind, .extracted)
        XCTAssertEqual(result.extractedText, "The preprint body.")
        XCTAssertTrue(
            StubURLProtocol.requested("src:ppr") || StubURLProtocol.requested("src%3Appr"),
            "a preprint must be asked for under its own source: \(StubURLProtocol.requestedURLs)"
        )
    }

    // MARK: - The final fallback

    /// Builds a service whose every network call answers "nothing here", so the
    /// chain runs out of tiers and reaches its last resort.
    private func makeExhaustedService() -> FullTextService {
        StubURLProtocol.routes = [
            "search": (200, Data(#"{"resultList": {"result": []}}"#.utf8)),
        ]
        StubURLProtocol.stubbed = (404, Data())
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        return FullTextService(
            email: "test@example.org",
            session: session,
            europePMCService: EuropePMCService(session: session)
        )
    }

    /// The last resort pastes the primary slot after the PubMed base URL, and
    /// the slot does not always hold a PubMed ID.
    ///
    /// A preprint gave `…/PPR1287966/`, which 404s, returned to the reader as
    /// this article's full text and rendered as an ordinary publisher link. A
    /// local routing fault reaching the reader as a real destination is #202's
    /// own failure shape, on the very articles the ladder exists to serve.
    /// An article with nowhere to point must say so.
    func testAPreprintWithNothingElseDoesNotGetAFabricatedPubMedLink() async throws {
        do {
            let result = try await makeExhaustedService().fetchFullText(
                pmcId: nil, doi: nil, pmid: "PPR1287966"
            )
            XCTFail("expected no full text, got \(result.content)")
        } catch FullTextError.noFullTextAvailable {
            // The honest answer: nothing left to point at.
        }
    }

    /// The degenerate case: an empty slot built `https://pubmed.ncbi.nlm.nih.gov//`
    /// — PubMed's front page — and offered it as the article's full text.
    /// `URL(string:)` accepts that happily, so nothing downstream caught it.
    func testAnArticleWithNoIdentifierDoesNotGetALinkToPubMedsFrontPage() async throws {
        do {
            let result = try await makeExhaustedService().fetchFullText(
                pmcId: nil, doi: nil, pmid: ""
            )
            XCTFail("expected no full text, got \(result.content)")
        } catch FullTextError.noFullTextAvailable {
            // The honest answer: nothing left to point at.
        }
    }

    /// The fallback that was always correct, pinned so narrowing it did not
    /// cost a real PubMed article its last-resort link.
    ///
    /// The kind is stated because from #212 the digits alone no longer state
    /// it: a Europe PMC thesis accession has the same shape and names a
    /// different article on PubMed.
    func testAStatedPubMedIdentifierStillGetsItsPubMedLink() async throws {
        let result = try await makeExhaustedService().fetchFullText(
            pmcId: nil, doi: nil, pmid: "12662058", primaryKind: .pubmed
        )

        guard case .doi(let webURL) = result.content else {
            return XCTFail("expected a link, got \(result.content)")
        }
        XCTAssertEqual(webURL.absoluteString, "https://pubmed.ncbi.nlm.nih.gov/12662058/")
    }

    /// The same digits with nobody vouching for them. Europe PMC's theses, case
    /// reports and `HIR` records carry bare numeric accessions and no PubMed ID,
    /// so this shape reaches the last resort on stored data and used to resolve
    /// to a real, unrelated article (#212).
    func testABareNumberNobodyVouchedForDoesNotGetAPubMedLink() async throws {
        do {
            let result = try await makeExhaustedService().fetchFullText(
                pmcId: nil, doi: nil, pmid: "889149"
            )
            XCTFail("expected no full text, got \(result.content)")
        } catch FullTextError.identifierKindUnresolved(let identifier) {
            // Changed claim: this used to expect `noFullTextAvailable`, and that
            // was the app telling the reader an article has no full text
            // anywhere in order to explain a decision of its own. The refusal is
            // ours — nobody named this accession — so the error says that, and
            // carries the accession the reader can search with. The caller does
            // not mark the document permanently unavailable on it.
            XCTAssertEqual(identifier, "889149")
        }
    }

    /// The other half of the distinction, so neither error can absorb the other.
    ///
    /// A stated preprint is fully classified: we know what the identifier is, it
    /// has no PubMed record by definition, and every other rung was tried. That
    /// really is "nothing left", and it must keep saying so — otherwise the
    /// honest answer disappears into the refusal and the fetch button never
    /// stops being offered for articles that genuinely have nothing.
    func testAKnownKindWithNothingLeftStillSaysNoFullText() async throws {
        do {
            let result = try await makeExhaustedService().fetchFullText(
                pmcId: nil, doi: nil, pmid: "PPR1287966", primaryKind: .preprint
            )
            XCTFail("expected no full text, got \(result.content)")
        } catch FullTextError.noFullTextAvailable {
            // The honest answer: nothing left that is known to name this article.
        }
    }

    // MARK: - Cache stability

    /// The key must name the article the same way whether or not a network
    /// lookup succeeded.
    ///
    /// `fetchFullText` builds it from the identifiers the *document* carries,
    /// before any search runs. Were it rebuilt from the resolved PMC ID instead
    /// — a plausible "the resolved one is more specific" refactor — a DOI-only
    /// article would file under `doi_…` when Europe PMC answered nothing and
    /// under `pmc_…` when it answered, giving one article two entries and
    /// meaning an offline run never reuses an online run's cache.
    func testTheCacheKeyDoesNotDependOnWhetherTheLookupSucceeded() async throws {
        let doi = "10.202/stability"
        let key = try XCTUnwrap(ArticleCacheKey(pmid: "", pmcId: nil, doi: doi))
        let pdfPath = "articles/PMC202stab/pdf"
        FullTextService.deleteCachedPDF(for: key)
        defer { FullTextService.deleteCachedPDF(for: key) }

        // Both runs offer the same render URL. They differ only in whether the
        // record carries a `pmcid` — that is, in what a lookup *resolves*, which
        // is exactly what must not reach the key.
        func searchResponse(withPMCID: Bool) -> Data {
            let pmcid = withPMCID ? #""pmcid": "PMC202stab","# : ""
            return Data("""
            {"resultList": {"result": [{
              "id": "1", \(pmcid)
              "fullTextUrlList": {"fullTextUrl": [
                {"documentStyle": "pdf", "site": "Europe_PMC",
                 "url": "https://europepmc.org/\(pdfPath)",
                 "availability": "Open access", "availabilityCode": "OA"}
              ]}
            }]}}
            """.utf8)
        }
        // Body-less, so the XML tier holds back and the PDF tier gets its turn
        // on the run where a PMC ID does resolve.
        let bodyless = Data("""
        <article><front><article-meta>
          <title-group><article-title>A trial</article-title></title-group>
          <abstract><p>Abstract only.</p></abstract>
        </article-meta></front></article>
        """.utf8)

        func fetch(resolvingPMCID: Bool) async throws {
            StubURLProtocol.routes = [
                "search": (200, searchResponse(withPMCID: resolvingPMCID)),
                "fullTextXML": (200, bodyless),
                pdfPath: (200, Self.firstBytes),
            ]
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [StubURLProtocol.self]
            let session = URLSession(configuration: config)
            let service = FullTextService(
                email: "test@example.org",
                session: session,
                europePMCService: EuropePMCService(session: session),
                extractor: StubExtractor(
                    result: PDFExtractionResult(
                        text: "Body.",
                        success: true,
                        pageCount: 1,
                        convertedPages: 1,
                        warnings: [],
                        errorMessage: nil
                    )
                ),
                extractPDFText: true
            )
            _ = try await service.fetchFullText(pmcId: nil, doi: doi, pmid: "")
        }

        try await fetch(resolvingPMCID: false)
        try await fetch(resolvingPMCID: true)

        // One download, not two. A key rebuilt from the resolved PMC ID would
        // file the second run under `pmc_…`, miss the entry the first run wrote
        // under `doi_…`, and fetch the identical bytes again.
        let downloads = StubURLProtocol.requestedURLs.filter { $0.contains(pdfPath) }
        XCTAssertEqual(
            downloads.count, 1,
            "the second run must hit the cache the first run wrote: \(downloads)"
        )
    }
}
