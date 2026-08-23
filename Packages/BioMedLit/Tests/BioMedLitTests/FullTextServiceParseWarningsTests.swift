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

/// Serves a canned Europe PMC response, so the parse-to-caller channel can be
/// exercised without a network.
///
/// `FullTextService` built its own `URLSession` in `init(email:)`, which is why
/// `fetchEuropePMCXML` had no offline coverage at all — and why both the warnings
/// channel and the typed parse error would otherwise have shipped untested.
final class StubURLProtocol: URLProtocol {
    /// The body every intercepted request receives, with its status code.
    static var stubbed: (status: Int, body: Data) = (200, Data())

    /// Bodies served only to requests whose URL contains the key.
    ///
    /// The chain #183 is about calls more than one host — Europe PMC for the
    /// XML, Unpaywall for a PDF — so a single canned body cannot exercise a
    /// fallback: the second call would be served the first call's response.
    /// Longest key wins, so a specific route beats a general one.
    static var routes: [String: (status: Int, body: Data)] = [:]

    /// Errors to fail matching requests with, instead of answering them.
    ///
    /// Needed because cancellation cannot be expressed as a status code: the
    /// chain has to distinguish "this source gave nothing" from "the caller
    /// stopped us", and only the second must propagate.
    ///
    /// Keyed by URL substring like ``routes``, and for a sharper reason: the
    /// chain guards cancellation at three separate `catch` sites, so failing
    /// *every* request cancels at whichever site is reached first and proves
    /// nothing about the others. One route at a time isolates one guard.
    static var failures: [String: Error] = [:]

    /// Reset all three, so one test's setup cannot leak into the next.
    static func reset() {
        stubbed = (200, Data())
        routes = [:]
        failures = [:]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url?.absoluteString ?? ""
        if let failure = Self.failures.first(where: { url.contains($0.key) })?.value {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let match = Self.routes
            .filter { url.contains($0.key) }
            .max { $0.key.count < $1.key.count }
        let (status, body) = match?.value ?? Self.stubbed
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// The channel #181 is about: a truncated parse has to reach the caller, not just
/// the log.
final class FullTextServiceParseWarningsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    private func service(serving body: String, status: Int = 200) -> FullTextService {
        StubURLProtocol.stubbed = (status, Data(body.utf8))
        return stubbedService()
    }

    /// A service whose transport answers from ``StubURLProtocol``.
    ///
    /// The identifier resolver is stubbed too. It reaches Europe PMC over its
    /// own session, so leaving it on the default sent any test that omits a PMC
    /// ID to the live network — which is both slow and a test that passes or
    /// fails on someone else's uptime.
    private func stubbedService() -> FullTextService {
        let session = URLSession(configuration: Self.stubbedConfiguration)
        return FullTextService(
            email: "test@example.com",
            session: session,
            europePMCService: EuropePMCService(session: session)
        )
    }

    /// A session configuration whose requests are served by ``StubURLProtocol``.
    private static var stubbedConfiguration: URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return config
    }

    /// An article stripped to its own accession number. `buildHTML` emits the
    /// identifiers line first, so the render is not empty and nothing throws —
    /// which is exactly how this reached readers without a word.
    private static let contentlessArticle = """
    <?xml version="1.0" encoding="UTF-8"?>
    <article><front><article-meta></article-meta></front><body></body></article>
    """

    private static let completeArticle = """
    <?xml version="1.0" encoding="UTF-8"?>
    <article>
      <front><article-meta>
        <title-group><article-title>A whole article</article-title></title-group>
        <contrib-group><contrib contrib-type="author">
          <name><surname>Doe</surname><given-names>J</given-names></name>
        </contrib></contrib-group>
      </article-meta></front>
      <body><sec><title>Methods</title><p>Real prose.</p></sec></body>
    </article>
    """

    func testWarningsFromATruncatedParseReachTheResult() async throws {
        let result = try await service(serving: Self.contentlessArticle)
            .fetchFullText(pmcId: "PMC12759138", doi: nil, pmid: "1")

        guard case .europePMC = result.content else {
            return XCTFail("expected a Europe PMC result, got \(result)")
        }
        let warnings = result.warnings
        XCTAssertFalse(warnings.isClean, "the reader was shown an accession number and nothing else")
        XCTAssertEqual(warnings.losses, [.noContent])
    }

    /// The negative control. Without it the assertion above passes just as
    /// happily against a channel that reports every article as truncated.
    func testACompleteArticleCarriesNoWarnings() async throws {
        let result = try await service(serving: Self.completeArticle)
            .fetchFullText(pmcId: "PMC12759138", doi: nil, pmid: "1")

        guard case .europePMC(let html, _) = result.content else {
            return XCTFail("expected a Europe PMC result, got \(result)")
        }
        XCTAssertTrue(html.contains("A whole article"))
        XCTAssertTrue(result.warnings.isClean, "\(result.warnings.diagnostics)")
    }

    /// The typed error survives the boundary.
    ///
    /// It used to be flattened with `parseError.localizedDescription`, so
    /// `.noContent`, `.alreadyParsed` and `.parsingFailed` arrived at the caller
    /// as one indistinguishable string.
    func testAParseFailureSurfacesTheTypedError() async throws {
        do {
            _ = try await service(serving: "<article><body></article>")
                .fetchEuropePMCXML(pmcId: "PMC12759138")
            XCTFail("malformed XML should not parse")
        } catch let error as FullTextError {
            guard case .jatsParseFailure(let parseError) = error else {
                return XCTFail("the typed error was flattened: \(error)")
            }
            guard case .parsingFailed = parseError else {
                return XCTFail("expected .parsingFailed, got \(parseError)")
            }
        }
    }

    /// A parse failure is deterministic, so retrying it burns the network budget
    /// to reach the same result.
    func testAParseFailureIsNotRetried() {
        XCTAssertFalse(FullTextError.jatsParseFailure(.noContent).isRetryable)
    }

    // MARK: - The fallback admits what it cost (#183)

    /// Passing no DOI means this lands on the *PubMed* fallback, the chain's last
    /// return. Both it and the doi.org branch above it return `.doi(webURL:)`, so
    /// the host is asserted: without it the two are indistinguishable and one of
    /// them can lose its degradation with the suite still green.
    func testAParseFailureMarksTheFallbackAsDegraded() async throws {
        let result = try await service(serving: "<article><body></article>")
            .fetchFullText(pmcId: "PMC12759138", doi: nil, pmid: "1")

        guard case .doi(let webURL) = result.content else {
            return XCTFail("expected the publisher-link fallback, got \(result.content)")
        }
        XCTAssertEqual(webURL.host, "pubmed.ncbi.nlm.nih.gov")
        XCTAssertEqual(result.degradation, .jatsParseFailed)
    }

    /// The doi.org branch, which the test above never reaches.
    ///
    /// It is a separate `return` from the PubMed fallback, so it carries its own
    /// copy of the degradation and can lose it independently.
    func testAPublisherLinkFallbackCarriesTheDegradation() async throws {
        StubURLProtocol.routes = [
            "fullTextXML": (200, Data("<article><body></article>".utf8)),
            "unpaywall": (404, Data()),
        ]

        let result = try await stubbedService()
            .fetchFullText(pmcId: "PMC12759138", doi: "10.1234/example", pmid: "1")

        guard case .doi(let webURL) = result.content else {
            return XCTFail("expected the publisher-link fallback, got \(result.content)")
        }
        XCTAssertEqual(webURL.host, "doi.org")
        XCTAssertEqual(result.degradation, .jatsParseFailed)
    }

    /// The Europe PMC PDF render branch, the *first* fallback a real degraded
    /// fetch reaches — an article whose XML we failed to parse is by definition
    /// in PMC, and usually offers a `pdf=render` URL.
    ///
    /// It shipped with no coverage at all because it was unreachable by a test:
    /// the branch needs a `pdfRenderURL`, which only the identifier resolution
    /// produces, and that went through a `EuropePMCService` the initialiser
    /// hard-coded. Injecting the service is what makes this assertion possible.
    func testAnEuropePMCPDFFallbackAlsoCarriesTheDegradation() async throws {
        let searchResponse = #"""
        {"resultList": {"result": [{
          "id": "1", "pmid": "1", "pmcid": "PMC12759138", "inPMC": "Y",
          "fullTextUrlList": {"fullTextUrl": [
            {"documentStyle": "pdf", "site": "Europe_PMC",
             "url": "https://europepmc.org/articles/PMC12759138?pdf=render",
             "availability": "Open access", "availabilityCode": "OA"}
          ]}
        }]}}
        """#
        StubURLProtocol.routes = [
            "fullTextXML": (200, Data("<article><body></article>".utf8)),
            "search": (200, Data(searchResponse.utf8)),
        ]

        // No PMC ID, so the chain resolves one — and picks up the PDF render URL
        // on the way, which is the only route to this branch.
        let result = try await stubbedService()
            .fetchFullText(pmcId: nil, doi: nil, pmid: "1")

        guard case .europePMCPDF(let pdfURL) = result.content else {
            return XCTFail("expected the Europe PMC PDF fallback, got \(result.content)")
        }
        XCTAssertEqual(
            pdfURL.absoluteString,
            "https://europepmc.org/articles/PMC12759138?pdf=render"
        )
        XCTAssertEqual(result.degradation, .jatsParseFailed)
    }

    /// The same, one step earlier in the chain: an Unpaywall PDF carries it too.
    ///
    /// Worth its own test because the degradation is attached at each `return`
    /// rather than at one exit, so a site that forgets it is a live defect that
    /// the publisher-link test above cannot see.
    func testAnUnpaywallFallbackAlsoCarriesTheDegradation() async throws {
        StubURLProtocol.routes = [
            "europepmc": (200, Data("<article><body></article>".utf8)),
            "unpaywall": (200, Data(#"{"best_oa_location": {"url_for_pdf": "https://example.org/a.pdf"}}"#.utf8)),
        ]

        let result = try await stubbedService()
            .fetchFullText(pmcId: "PMC12759138", doi: "10.1234/example", pmid: "1")

        guard case .unpaywall(let pdfURL) = result.content else {
            return XCTFail("expected the Unpaywall fallback, got \(result.content)")
        }
        XCTAssertEqual(pdfURL.absoluteString, "https://example.org/a.pdf")
        XCTAssertEqual(result.degradation, .jatsParseFailed)
    }

    /// The negative control. Without it every assertion above passes just as
    /// happily against a service that reports every result as degraded.
    func testASuccessfulParseIsNotDegraded() async throws {
        let result = try await service(serving: Self.completeArticle)
            .fetchFullText(pmcId: "PMC12759138", doi: nil, pmid: "1")

        XCTAssertNil(result.degradation)
    }

    /// A source that was simply absent is not a degradation.
    ///
    /// Europe PMC answering 404 means there was no machine-readable text to
    /// lose. Marking that as degraded would say "we had it and choked" on every
    /// article that was never deposited — the false positive that would make the
    /// note worthless on the articles where it is true.
    func testAnAbsentSourceIsNotADegradation() async throws {
        let result = try await service(serving: "", status: 404)
            .fetchFullText(pmcId: "PMC12759138", doi: nil, pmid: "1")

        guard case .doi = result.content else {
            return XCTFail("expected the publisher-link fallback, got \(result.content)")
        }
        XCTAssertNil(result.degradation)
    }

    // MARK: - A cancelled fetch is not a dead source

    /// Cancellation must propagate, not fall through to a publisher link.
    ///
    /// Falling through would cache a doi.org link as this article's full text,
    /// as though Europe PMC had nothing — a wrong answer written to the database
    /// because the reader closed a tab.
    ///
    /// Served as `URLError.cancelled` deliberately: that is how a cancelled
    /// `URLSession` request actually surfaces. The guard originally tested only
    /// for `CancellationError`, which `Task.sleep` in the retry backoff raises —
    /// so it caught the rarer of the two shapes and missed the one a real fetch
    /// hits.
    func testACancelledFetchDoesNotFallThrough() async {
        // Only the Europe PMC XML call is cancelled. The rest of the chain
        // answers normally, so nothing downstream can throw the cancellation on
        // this guard's behalf and make the test pass for the wrong reason.
        StubURLProtocol.failures = ["fullTextXML": URLError(.cancelled)]
        StubURLProtocol.routes = ["unpaywall": (404, Data())]

        do {
            _ = try await stubbedService()
                .fetchFullText(pmcId: "PMC12759138", doi: "10.1234/example", pmid: "1")
            XCTFail("a cancelled fetch returned a fallback instead of propagating")
        } catch {
            XCTAssertTrue(
                error is CancellationError,
                "expected cancellation to propagate, got \(error)"
            )
        }
    }

    /// The same guard on the Unpaywall branch, which is a separate `catch`.
    ///
    /// Europe PMC is allowed to fail normally here, so the chain genuinely
    /// reaches Unpaywall and this guard is the only one that can propagate.
    func testACancelledUnpaywallFetchDoesNotFallThrough() async {
        StubURLProtocol.routes = ["fullTextXML": (404, Data())]
        StubURLProtocol.failures = ["unpaywall": URLError(.cancelled)]

        do {
            _ = try await stubbedService()
                .fetchFullText(pmcId: "PMC12759138", doi: "10.1234/example", pmid: "1")
            XCTFail("a cancelled Unpaywall fetch returned a fallback instead of propagating")
        } catch {
            XCTAssertTrue(
                error is CancellationError,
                "expected cancellation to propagate, got \(error)"
            )
        }
    }

    /// And on identifier resolution, the earliest of the three.
    ///
    /// Swallowing a cancellation here is the worst of the three, because it
    /// leaves no PMC ID: the Europe PMC branch is then skipped entirely and the
    /// article reports as having no machine-readable copy at all.
    func testACancelledIdentifierResolutionDoesNotFallThrough() async {
        StubURLProtocol.failures = ["search": URLError(.cancelled)]

        do {
            // No PMC ID, so the chain has to resolve one first.
            _ = try await stubbedService()
                .fetchFullText(pmcId: nil, doi: "10.1234/example", pmid: "1")
            XCTFail("a cancelled resolution returned a fallback instead of propagating")
        } catch {
            XCTAssertTrue(
                error is CancellationError,
                "expected cancellation to propagate, got \(error)"
            )
        }
    }
}
