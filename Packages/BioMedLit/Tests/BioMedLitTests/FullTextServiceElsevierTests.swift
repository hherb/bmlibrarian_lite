// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2026 Dr Horst Herb
// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest
@testable import BioMedLit

private struct ExtractingStub: PDFTextExtracting {
    func extract(from fileURL: URL) -> PDFExtractionResult {
        PDFExtractionResult(
            text: "The article.", success: true, pageCount: 1, convertedPages: 1, warnings: []
        )
    }
}

/// A scan: the file opens, and no page yields text.
private struct ScanStub: PDFTextExtracting {
    func extract(from fileURL: URL) -> PDFExtractionResult {
        PDFExtractionResult(
            text: "", success: true, pageCount: 2, convertedPages: 0,
            warnings: ["page 1 yielded no text", "page 2 yielded no text"]
        )
    }
}

fileprivate extension RetryConfiguration {
    /// One attempt, no wait: a 503 that outlasts it arrives as `serverError`.
    static let noRetry = RetryConfiguration(
        maxAttempts: 1, initialDelay: 0, maxDelay: 0, backoffMultiplier: 1, jitterFactor: 0
    )

    /// Two attempts, no backoff wait: enough to show a retry is paced.
    static let oneRetry = RetryConfiguration(
        maxAttempts: 2, initialDelay: 0, maxDelay: 0, backoffMultiplier: 1, jitterFactor: 0
    )
}

/// Elsevier's Article API in the full-text chain (#480, stage C2): asked after
/// Europe PMC's render and before Unpaywall, only for an Elsevier DOI and only
/// with the user's key; a first page is never served; refusals are scoped to the
/// credentials refused; the article URL, which needs the key, is never a link.
final class FullTextServiceElsevierTests: RecordingLoggerTestCase {
    private let doi = "10.1016/j.cell.2020.01.001"
    private let elsevierHost = "api.elsevier.com"
    private let coreHost = "api.core.ac.uk"
    private let key = "test-elsevier-key"
    private let token = "test-elsevier-token"
    private let repo = "https://repo.example.org/b.pdf"
    private let pdfBody = Data("%PDF-1.7\n".utf8) + Data(repeating: 0x30, count: 64)
    private let bodylessJATS = """
        <article><front><article-meta><title-group><article-title>T</article-title>\
        </title-group><abstract><p>Abstract only.</p></abstract></article-meta></front></article>
        """
    private let authenticationError = Data(
        "<service-error><status><statusCode>AUTHENTICATION_ERROR</statusCode></status></service-error>".utf8
    )

    /// The article's cache key: no PMID, so the DOI names it.
    private var cacheKey: ArticleCacheKey {
        ArticleCacheKey(pmid: "", pmcId: nil, doi: doi)!
    }

    /// The article URL Elsevier is asked by.
    private var articleURL: URL {
        Elsevier.articleURL(doi: doi)!
    }

    /// Where a served Elsevier PDF is cached: the document's key, the article URL.
    private var cachedPath: String {
        FullTextService.pdfCacheDirectory
            .appendingPathComponent(FullTextService.cacheFilename(key: cacheKey, url: articleURL)).path
    }

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        FullTextService.deleteCachedPDF(for: cacheKey)
        // Europe PMC knows no record, so the open-access tiers decide the outcome
        StubURLProtocol.routes["search"] = (200, Data(#"{"resultList": {"result": []}}"#.utf8))
        // Unpaywall knows no copy (OpenAlex's fallback route answers 404 too)
        StubURLProtocol.routes["unpaywall"] = (404, Data())
    }

    override func tearDown() {
        StubURLProtocol.reset()
        FullTextService.deleteCachedPDF(for: cacheKey)
        super.tearDown()
    }

    private func makeService(
        extractor: PDFTextExtracting = ExtractingStub(),
        extractPDFText: Bool = true,
        email: String = "test@example.org",
        coreAPIKey: String? = nil,
        elsevierAPIKey: String? = "test-elsevier-key",
        elsevierInstToken: String? = nil,
        elsevierRetry: RetryConfiguration = .noRetry,
        elsevierSession: ElsevierSession = ElsevierSession(),
        writeCachedPDF: @escaping @Sendable (Data, URL) throws -> Void = FullTextService.writeAtomically
    ) -> FullTextService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        return FullTextService(
            email: email,
            session: session,
            europePMCService: EuropePMCService(session: session),
            extractor: extractor,
            extractPDFText: extractPDFText,
            europePMCRetry: .noRetry,
            pmcOpenDataRetry: .noRetry,
            openAlexRetry: .noRetry,
            coreAPIKey: coreAPIKey,
            coreRetry: .noRetry,
            coreThrottle: CoreThrottle(),
            elsevierAPIKey: elsevierAPIKey,
            elsevierInstToken: elsevierInstToken,
            elsevierRetry: elsevierRetry,
            elsevierSession: elsevierSession,
            writeCachedPDF: writeCachedPDF
        )
    }

    private func unpaywall(_ pdfs: [String]) -> Data {
        let locations = pdfs.map { ["url_for_pdf": $0, "url": $0] }
        let body: [String: Any] = ["best_oa_location": locations.first as Any, "oa_locations": locations]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    private var longText: String { String(repeating: "x", count: BioMedLitConstants.coreMinFullTextCharacters) }

    private func coreHit(_ text: String) -> Data {
        let object: [String: Any] = ["results": [["doi": doi, "fullText": text]]]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    /// How many requests went to Elsevier.
    private var elsevierRequests: Int {
        StubURLProtocol.requestedURLs.filter { URL(string: $0)?.host == elsevierHost }.count
    }

    /// The index of the first request to Elsevier, and of the first to Unpaywall.
    private func elsevierThenUnpaywall() throws -> (elsevier: Int, unpaywall: Int) {
        let elsevier = try XCTUnwrap(
            StubURLProtocol.requestedURLs.firstIndex { URL(string: $0)?.host == elsevierHost })
        let unpaywall = try XCTUnwrap(
            StubURLProtocol.requestedURLs.firstIndex { $0.contains("unpaywall") }, "Unpaywall was not asked")
        return (elsevier, unpaywall)
    }

    /// Nothing of a result names Elsevier's article URL: not its PDF URL, its
    /// link, its not-saved address, nor anything else it carries.
    private func assertNoElsevierURL(_ result: FullTextResult, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(String(describing: result).contains(elsevierHost), "\(result)", file: file, line: line)
        XCTAssertNotEqual(result.pdfURL?.host, elsevierHost, file: file, line: line)
        XCTAssertNotEqual(result.webURL?.host, elsevierHost, file: file, line: line)
        XCTAssertFalse(result.pdfNotSavedFrom?.contains(elsevierHost) ?? false, file: file, line: line)
    }

    // MARK: - Served

    func testAServedPDFIsTheFullTextAndUnpaywallIsNeverAsked() async throws {
        StubURLProtocol.routes[elsevierHost] = (200, pdfBody)
        let result = try await makeService().fetchFullText(pmcId: nil, doi: doi, pmid: "")
        XCTAssertEqual(result.content, .elsevier(localPath: cachedPath))
        XCTAssertEqual(result.source, .elsevier)
        XCTAssertEqual(result.source.displayName, BioMedLitConstants.elsevierSourceLabel)
        XCTAssertEqual(result.contentKind, .extracted)
        XCTAssertEqual(result.extractedText, "The article.")
        XCTAssertEqual(result.localPDFPath, cachedPath)
        XCTAssertNotNil(result.extractionCoverage)
        XCTAssertNil(result.openAccessShortfall)
        XCTAssertNil(result.pdfNotSavedFrom)
        // Held only as a local file: its PDF URL is the file's
        XCTAssertEqual(result.pdfURL, URL(fileURLWithPath: cachedPath))
        XCTAssertTrue(result.pdfURL?.isFileURL ?? false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cachedPath))
        assertNoElsevierURL(result)
        XCTAssertEqual(elsevierRequests, 1)
        XCTAssertFalse(StubURLProtocol.requested("unpaywall"))
        XCTAssertEqual(StubURLProtocol.requestedURLs.last, articleURL.absoluteString)
    }

    func testTheSourceIsTheContracts() throws {
        let contract = try ElsevierContract.load()
        XCTAssertEqual(contract["source"] as? String, FullTextSource.elsevier.rawValue)
        XCTAssertEqual(contract["source_label"] as? String, FullTextSource.elsevier.displayName)
    }

    func testAPDFHeldOverAHeldAbstractWins() async throws {
        StubURLProtocol.routes["fullTextXML"] = (200, Data(bodylessJATS.utf8))
        StubURLProtocol.routes[elsevierHost] = (200, pdfBody)
        let result = try await makeService().fetchFullText(pmcId: "PMC1", doi: doi, pmid: "")
        XCTAssertEqual(result.source, .elsevier)
        XCTAssertEqual(result.contentKind, .extracted)
        // The control that the abstract was held: Europe PMC served it
        XCTAssertTrue(StubURLProtocol.requested("fullTextXML"))
        let pmcKey = try XCTUnwrap(ArticleCacheKey(pmid: "", pmcId: "PMC1", doi: doi))
        FullTextService.deleteCachedPDF(for: pmcKey)
    }

    /// Only when nothing earlier obtained the article: an article body from
    /// Europe PMC asks nothing of Elsevier.
    func testAJATSBodyAsksNothingOfElsevier() async throws {
        StubURLProtocol.routes["fullTextXML"] = (200, Data("""
            <article><front><article-meta><title-group><article-title>T</article-title>\
            </title-group></article-meta></front><body><sec><p>Body.</p></sec></body></article>
            """.utf8))
        StubURLProtocol.routes[elsevierHost] = (200, pdfBody)
        let result = try await makeService().fetchFullText(pmcId: "PMC1", doi: doi, pmid: "")
        XCTAssertEqual(result.source, .europePMC)
        XCTAssertEqual(elsevierRequests, 0)
    }

    /// After Europe PMC's render, which failed, and before Unpaywall.
    func testElsevierIsAskedAfterTheRenderAndBeforeUnpaywall() async throws {
        let render = "https://europepmc.org/articles/PMC1/pdf"
        StubURLProtocol.routes["search"] = (200, Data(#"""
            {"resultList": {"result": [{
              "id": "1", "pmcid": "PMC1", "inPMC": "Y", "doi": "10.1016/j.cell.2020.01.001",
              "fullTextUrlList": {"fullTextUrl": [
                {"documentStyle": "pdf", "site": "Europe_PMC", "url": "\#(render)",
                 "availability": "Open access", "availabilityCode": "OA"}
              ]}
            }]}}
            """#.utf8))
        StubURLProtocol.routes["fullTextXML"] = (404, Data())
        StubURLProtocol.routes["pmc-oa-opendata"] = (404, Data())
        StubURLProtocol.routes["articles/PMC1/pdf"] = (404, Data())
        StubURLProtocol.routes[elsevierHost] = (404, Data())
        _ = try await makeService().fetchFullText(pmcId: nil, doi: doi, pmid: "")
        let renderIndex = try XCTUnwrap(StubURLProtocol.requestedURLs.firstIndex { $0.contains("articles/PMC1/pdf") })
        let (elsevier, unpaywall) = try elsevierThenUnpaywall()
        XCTAssertLessThan(renderIndex, elsevier)
        XCTAssertLessThan(elsevier, unpaywall)
    }

    // MARK: - Absent

    /// A first page is never served: Unpaywall is asked next, and nothing is told.
    func testAFirstPageIsAnAbsenceAndUnpaywallIsAskedNext() async throws {
        StubURLProtocol.routes[elsevierHost] = (200, pdfBody)
        StubURLProtocol.headers[elsevierHost] = [
            "X-ELS-Status": "WARNING - Response limited to first page because requestor not entitled to resource",
        ]
        let result = try await makeService().fetchFullText(pmcId: nil, doi: doi, pmid: "")
        XCTAssertNotEqual(result.source, .elsevier)
        XCTAssertNil(result.localPDFPath)
        XCTAssertNil(result.openAccessShortfall)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cachedPath), "a first page is never kept")
        let (elsevier, unpaywall) = try elsevierThenUnpaywall()
        XCTAssertLessThan(elsevier, unpaywall)
        XCTAssertTrue(logger.recorded.contains { $0.hasPrefix("INFO: ") && $0.contains("first page") })
        // The absence is settled: the chain ends on no unsettled source
        XCTAssertEqual(result.content, .doi(webURL: URL(string: "\(BioMedLitConstants.doiBaseURL)/\(doi)")!))
    }

    func testA404IsAnAbsenceAndUnpaywallIsAskedNext() async throws {
        StubURLProtocol.routes[elsevierHost] = (404, Data())
        let result = try await makeService().fetchFullText(pmcId: nil, doi: doi, pmid: "")
        XCTAssertNil(result.openAccessShortfall)
        let (elsevier, unpaywall) = try elsevierThenUnpaywall()
        XCTAssertLessThan(elsevier, unpaywall)
    }

    // MARK: - Unreachable

    func testA503IsAnUnsettledLookupToldFirst() async throws {
        StubURLProtocol.routes[elsevierHost] = (503, Data())
        // Unpaywall unconfigured: a second entry, told after Elsevier's
        let result = try await makeService(email: "").fetchFullText(pmcId: nil, doi: doi, pmid: "")
        let shortfall = try XCTUnwrap(result.openAccessShortfall)
        XCTAssertEqual(
            shortfall,
            OpenAccessShortfall(source: .elsevier, failure: .httpStatus(503)).appending(.unpaywallNotConfigured)
        )
        XCTAssertTrue(
            shortfall.notice.hasPrefix("Elsevier's API (HTTP 503 Service Unavailable) and Unpaywall"),
            shortfall.notice
        )
        let error = FullTextService.exhaustedChainError(
            primarySlot: "", primaryKind: nil, europePMCShortfall: nil, pmcOpenDataShortfall: nil,
            openAccessShortfall: shortfall, articleName: "the article"
        )
        guard case .openAccessNotEstablished = error else {
            return XCTFail("an unreachable Elsevier never ends in no full text: \(error)")
        }
    }

    func testAnUnreachableElsevierAloneIsTold() async throws {
        StubURLProtocol.routes[elsevierHost] = (503, Data())
        let result = try await makeService().fetchFullText(pmcId: nil, doi: doi, pmid: "")
        XCTAssertEqual(result.openAccessShortfall, OpenAccessShortfall(source: .elsevier, failure: .httpStatus(503)))
        XCTAssertEqual(
            result.openAccessShortfall?.notice,
            "Elsevier's API (HTTP 503 Service Unavailable) could not be asked, so a freely available copy "
                + "may exist. Whether this document is open access was not established."
        )
    }

    /// A 403 without the token is an ordinary answer, and refuses nothing.
    func testA403WithoutTheTokenIsUnreachableAndRefusesNothing() async throws {
        let session = ElsevierSession()
        StubURLProtocol.routes[elsevierHost] = (403, Data("<error>AUTHORIZATION_ERROR</error>".utf8))
        let result = try await makeService(elsevierSession: session).fetchFullText(pmcId: nil, doi: doi, pmid: "")
        XCTAssertEqual(result.openAccessShortfall, OpenAccessShortfall(source: .elsevier, failure: .httpStatus(403)))
        XCTAssertFalse(session.refusesNetwork(credentialsDigest: KeyDigest.credentials(key: key, token: nil)))
        _ = try await makeService(elsevierSession: session).fetchFullText(pmcId: nil, doi: doi, pmid: "")
        XCTAssertEqual(elsevierRequests, 2)
    }

    func testATimeoutIsUnreachable() async throws {
        StubURLProtocol.failures[elsevierHost] = URLError(.timedOut)
        let fetch = try await makeService().fetchElsevierPDF(doi: doi, cacheKey: cacheKey)
        XCTAssertEqual(fetch, .unreachable(.timeout))
    }

    func testA200ThatIsNoPDFIsMalformed() async throws {
        StubURLProtocol.routes[elsevierHost] = (200, Data("<html>login</html>".utf8))
        let fetch = try await makeService().fetchElsevierPDF(doi: doi, cacheKey: cacheKey)
        XCTAssertEqual(fetch, .unreachable(.malformedResponse))
    }

    // MARK: - Refusals, scoped and shared

    /// A 401 refuses the key across services sharing the session, whatever the
    /// token; another key is asked.
    func testA401RefusesTheKeyAcrossServices() async throws {
        let session = ElsevierSession()
        StubURLProtocol.routes[elsevierHost] = (401, Data())
        let first = try await makeService(elsevierSession: session).fetchFullText(pmcId: nil, doi: doi, pmid: "")
        XCTAssertEqual(elsevierRequests, 1)
        let second = try await makeService(elsevierInstToken: token, elsevierSession: session)
            .fetchFullText(pmcId: nil, doi: doi, pmid: "")
        XCTAssertEqual(elsevierRequests, 1, "a refused key sends nothing, whatever the token")
        for result in [first, second] {
            XCTAssertEqual(result.openAccessShortfall, .elsevierKeyRefused)
            XCTAssertTrue(
                result.openAccessShortfall?.notice
                    .hasPrefix("Elsevier's API (the key in the settings was refused) could not be asked") ?? false
            )
        }
        // Scoped: another key is asked
        StubURLProtocol.routes[elsevierHost] = (200, pdfBody)
        let corrected = try await makeService(elsevierAPIKey: "\(key)-corrected", elsevierSession: session)
            .fetchFullText(pmcId: nil, doi: doi, pmid: "")
        XCTAssertEqual(corrected.source, .elsevier)
        XCTAssertEqual(elsevierRequests, 2)
    }

    /// A 403 `AUTHENTICATION_ERROR` refuses those credentials across services;
    /// the same key with a token added is asked again.
    func testANetworkRefusalRefusesThoseCredentialsAcrossServices() async throws {
        let session = ElsevierSession()
        StubURLProtocol.routes[elsevierHost] = (403, authenticationError)
        let first = try await makeService(elsevierSession: session).fetchFullText(pmcId: nil, doi: doi, pmid: "")
        let second = try await makeService(elsevierSession: session).fetchFullText(pmcId: nil, doi: doi, pmid: "")
        XCTAssertEqual(elsevierRequests, 1, "refused credentials send nothing")
        for result in [first, second] {
            XCTAssertEqual(result.openAccessShortfall, .elsevierNetworkRefused)
            XCTAssertEqual(
                result.openAccessShortfall?.notice,
                "Elsevier's API (not available from this network) could not be asked, so a freely available "
                    + "copy may exist. Whether this document is open access was not established."
            )
        }
        XCTAssertFalse(session.refuses(keyDigest: KeyDigest.key(key)), "a network refusal is no refused key")
        // Scoped: a token added in the settings makes other credentials, asked again
        StubURLProtocol.routes[elsevierHost] = (200, pdfBody)
        let withToken = try await makeService(elsevierInstToken: token, elsevierSession: session)
            .fetchFullText(pmcId: nil, doi: doi, pmid: "")
        XCTAssertEqual(withToken.source, .elsevier)
        XCTAssertEqual(elsevierRequests, 2)
    }

    /// Refused from this network, then paused: the refusal is told, as the
    /// contract orders the checks (network before pause).
    func testANetworkRefusalIsToldBeforeAPause() async throws {
        let session = ElsevierSession()
        session.recordNetworkRefused(credentialsDigest: KeyDigest.credentials(key: key, token: nil))
        session.record(endedOn: 429, keyDigest: KeyDigest.key(key))
        session.record(endedOn: 429, keyDigest: KeyDigest.key(key))
        XCTAssertTrue(session.isPaused)
        StubURLProtocol.routes[elsevierHost] = (200, pdfBody)
        let fetch = try await makeService(elsevierSession: session).fetchElsevierPDF(doi: doi, cacheKey: cacheKey)
        XCTAssertEqual(fetch, .networkRefused)
        XCTAssertEqual(elsevierRequests, 0)
    }

    func testTwo429sPauseElsevierAcrossServices() async throws {
        let session = ElsevierSession()
        StubURLProtocol.routes[elsevierHost] = (429, Data())
        _ = try await makeService(elsevierSession: session).fetchFullText(pmcId: nil, doi: doi, pmid: "")
        _ = try await makeService(elsevierSession: session).fetchFullText(pmcId: nil, doi: doi, pmid: "")
        XCTAssertEqual(elsevierRequests, 2)
        let third = try await makeService(elsevierSession: session).fetchFullText(pmcId: nil, doi: doi, pmid: "")
        XCTAssertEqual(elsevierRequests, 2, "a paused Elsevier sends nothing")
        XCTAssertEqual(third.openAccessShortfall, OpenAccessShortfall(source: .elsevier, failure: .httpStatus(429)))
        // The pause is warned of once, naming the service, never the key
        let pauses = logger.problems.filter { $0.contains("Elsevier's API answered HTTP 429") }
        XCTAssertEqual(pauses.count, 1, "\(logger.problems)")
        XCTAssertTrue(pauses.first?.contains("2 times in a row") ?? false, "\(pauses)")
        XCTAssertFalse(logger.recorded.contains { $0.contains(key) || $0.contains(KeyDigest.key(key)) })
    }

    /// The session is Elsevier's own: a CORE pause never pauses Elsevier.
    func testACOREPauseNeverPausesElsevier() async throws {
        let session = ElsevierSession()
        let core = CoreThrottle()
        core.record(endedOn: 429, keyDigest: KeyDigest.key("core"))
        core.record(endedOn: 429, keyDigest: KeyDigest.key("core"))
        XCTAssertTrue(core.isPaused)
        StubURLProtocol.routes[elsevierHost] = (200, pdfBody)
        let fetch = try await makeService(elsevierSession: session).fetchElsevierPDF(doi: doi, cacheKey: cacheKey)
        XCTAssertEqual(fetch, .served(localPath: cachedPath))
    }

    // MARK: - The key and the token

    func testTheKeyAndTokenTravelInTheirHeadersAlone() async throws {
        StubURLProtocol.routes[elsevierHost] = (401, Data())
        _ = try await makeService(elsevierAPIKey: " \(key) ", elsevierInstToken: " \(token)\n")
            .fetchFullText(pmcId: nil, doi: doi, pmid: "")
        let index = try XCTUnwrap(
            StubURLProtocol.requestedURLs.firstIndex { URL(string: $0)?.host == elsevierHost })
        let headers = StubURLProtocol.requestedHeaders[index]
        XCTAssertEqual(headers["X-ELS-APIKey"], key, "trimmed")
        XCTAssertEqual(headers["X-ELS-Insttoken"], token, "trimmed")
        XCTAssertEqual(headers["Accept"], "application/pdf")
        XCTAssertEqual(StubURLProtocol.requestedURLs[index], articleURL.absoluteString)
        for url in StubURLProtocol.requestedURLs {
            XCTAssertFalse(url.contains(key) || url.contains(token), url)
        }
        // Never logged, nor their digests
        let digests = [KeyDigest.key(key), KeyDigest.credentials(key: key, token: token)]
        XCTAssertFalse(logger.recorded.contains { line in
            line.contains(key) || line.contains(token) || digests.contains { line.contains($0) }
        }, "\(logger.recorded)")
        // No other host was handed either
        for (offset, headers) in StubURLProtocol.requestedHeaders.enumerated() where offset != index {
            XCTAssertNil(headers["X-ELS-APIKey"])
            XCTAssertNil(headers["X-ELS-Insttoken"])
        }
    }

    func testNoTokenSendsNoTokenHeader() async throws {
        StubURLProtocol.routes[elsevierHost] = (404, Data())
        _ = try await makeService(elsevierInstToken: "   ").fetchFullText(pmcId: nil, doi: doi, pmid: "")
        let index = try XCTUnwrap(
            StubURLProtocol.requestedURLs.firstIndex { URL(string: $0)?.host == elsevierHost })
        XCTAssertEqual(StubURLProtocol.requestedHeaders[index]["X-ELS-APIKey"], key)
        XCTAssertNil(StubURLProtocol.requestedHeaders[index]["X-ELS-Insttoken"])
    }

    /// A redirect would carry the key wherever it points, so it is never
    /// followed: the 3xx is unreachable `http_status`, never a refused redirect.
    func testARedirectIsRefused() async throws {
        StubURLProtocol.redirects[elsevierHost] = "https://elsewhere.example.org/article.pdf"
        StubURLProtocol.routes["elsewhere.example.org"] = (200, pdfBody)
        let result = try await makeService().fetchFullText(pmcId: nil, doi: doi, pmid: "")
        XCTAssertFalse(StubURLProtocol.requested("elsewhere.example.org"), "the redirect was followed")
        XCTAssertEqual(result.openAccessShortfall, OpenAccessShortfall(source: .elsevier, failure: .httpStatus(302)))
        XCTAssertNotEqual(result.source, .elsevier)
        assertNoElsevierURL(result)
    }

    // MARK: - Not asked

    func testAnotherPublishersDOIIsNeverAsked() async throws {
        let other = "10.1159/000513404"
        StubURLProtocol.routes[elsevierHost] = (200, pdfBody)
        let result = try await makeService().fetchFullText(pmcId: nil, doi: other, pmid: "")
        XCTAssertEqual(elsevierRequests, 0)
        XCTAssertNil(result.openAccessShortfall, "nothing recorded: the absence is settled as before")
        FullTextService.deleteCachedPDF(for: ArticleCacheKey(pmid: "", pmcId: nil, doi: other)!)
    }

    func testWithoutAKeyElsevierIsNeverAsked() async throws {
        StubURLProtocol.routes[elsevierHost] = (200, pdfBody)
        let result = try await makeService(elsevierAPIKey: nil, elsevierInstToken: token)
            .fetchFullText(pmcId: nil, doi: doi, pmid: "")
        XCTAssertEqual(elsevierRequests, 0)
        XCTAssertNil(result.openAccessShortfall)
        XCTAssertFalse(makeService(elsevierAPIKey: nil).asksElsevier)
        XCTAssertFalse(makeService(elsevierAPIKey: "  \n").asksElsevier)
        // The control: a key, trimmed, is one
        XCTAssertTrue(makeService(elsevierAPIKey: " \(key) ").asksElsevier)
        // And the absence is settled: no shortfall, a DOI link
        XCTAssertEqual(result.content, .doi(webURL: URL(string: "\(BioMedLitConstants.doiBaseURL)/\(doi)")!))
    }

    /// The control for both: with a key and an Elsevier DOI, it is asked, by
    /// the DOI's resolver form too.
    func testAResolverDOIIsAskedBare() async throws {
        // `www.doi.org` too, which CORE's normalised form alone does not remove:
        // the chain asks by the DOI cleaned as Python's `_clean_doi` cleans it
        for resolver in ["https://doi.org/", "https://www.doi.org/", "doi: "] {
            StubURLProtocol.reset()
            StubURLProtocol.routes["search"] = (200, Data(#"{"resultList": {"result": []}}"#.utf8))
            StubURLProtocol.routes["unpaywall"] = (404, Data())
            StubURLProtocol.routes[elsevierHost] = (404, Data())
            _ = try await makeService().fetchFullText(pmcId: nil, doi: "\(resolver)\(doi)", pmid: "")
            let asked = StubURLProtocol.requestedURLs.filter { URL(string: $0)?.host == elsevierHost }
            XCTAssertEqual(asked, [articleURL.absoluteString], resolver)
            let resolverKey = try XCTUnwrap(ArticleCacheKey(pmid: "", pmcId: nil, doi: "\(resolver)\(doi)"))
            FullTextService.deleteCachedPDF(for: resolverKey)
        }
    }

    // MARK: - Credentials that cannot be sent

    /// A zero-width space or a curly quote pasted with the key is never sent:
    /// Elsevier is unsettled as a failed request, told without the key, and the
    /// walk goes on to Unpaywall, whose copy settles it.
    func testCredentialsThatCannotBeSentAreNeverSent() async throws {
        let cases: [(key: String, token: String?)] = [
            ("zero\u{200B}width-\(key)", nil), ("curly\u{2019}\(key)", nil), (key, "zero\u{200B}width-\(token)"),
        ]
        for (badKey, badToken) in cases {
            StubURLProtocol.reset()
            FullTextService.deleteCachedPDF(for: cacheKey)
            logger.reset()
            StubURLProtocol.routes["search"] = (200, Data(#"{"resultList": {"result": []}}"#.utf8))
            StubURLProtocol.routes["unpaywall"] = (404, Data())
            StubURLProtocol.routes[elsevierHost] = (200, pdfBody)
            let session = ElsevierSession()
            let result = try await makeService(
                elsevierAPIKey: badKey, elsevierInstToken: badToken, elsevierSession: session
            ).fetchFullText(pmcId: nil, doi: doi, pmid: "")
            XCTAssertEqual(elsevierRequests, 0, "never sent")
            XCTAssertTrue(StubURLProtocol.requested("unpaywall"), "the walk goes on")
            XCTAssertEqual(result.openAccessShortfall, OpenAccessShortfall(source: .elsevier, failure: .requestFailed))
            XCTAssertTrue(
                logger.recorded.contains { $0.contains("cannot be sent") }, "\(logger.recorded)"
            )
            XCTAssertFalse(
                logger.recorded.contains { $0.contains(key) || $0.contains(token) }, "\(logger.recorded)"
            )
            XCTAssertFalse(session.isPaused)
        }
    }

    // MARK: - The walk goes on

    /// An unreachable or refused Elsevier is told, and Unpaywall is still asked:
    /// a copy it serves settles the question, so nothing is left unsettled.
    func testTheWalkGoesOnAfterEveryUnsettledElsevier() async throws {
        let answers: [(status: Int, body: Data)] = [(503, Data()), (401, Data()), (403, authenticationError)]
        for answer in answers {
            StubURLProtocol.reset()
            FullTextService.deleteCachedPDF(for: cacheKey)
            StubURLProtocol.routes["search"] = (200, Data(#"{"resultList": {"result": []}}"#.utf8))
            StubURLProtocol.routes[elsevierHost] = (answer.status, answer.body)
            StubURLProtocol.routes["unpaywall"] = (200, unpaywall([repo]))
            StubURLProtocol.routes["repo.example.org"] = (200, pdfBody)
            let result = try await makeService(elsevierSession: ElsevierSession())
                .fetchFullText(pmcId: nil, doi: doi, pmid: "")
            XCTAssertEqual(elsevierRequests, 1, "HTTP \(answer.status)")
            XCTAssertEqual(result.content, .unpaywall(pdfURL: URL(string: repo)!), "HTTP \(answer.status)")
            XCTAssertNil(result.openAccessShortfall, "HTTP \(answer.status)")
            assertNoElsevierURL(result)
        }
    }

    // MARK: - The process's session

    /// The app builds a service per document; their default session is the
    /// process's, so a key refused by one is not sent by the next.
    func testTheDefaultSessionIsTheProcesss() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let urlSession = URLSession(configuration: config)
        // A key no other test uses: the shared session keeps one refused key
        let refused = "test-elsevier-key-\(UUID().uuidString)"
        func service() -> FullTextService {
            FullTextService(
                email: "test@example.org", session: urlSession,
                europePMCService: EuropePMCService(session: urlSession), extractor: ExtractingStub(),
                europePMCRetry: .noRetry, pmcOpenDataRetry: .noRetry, openAlexRetry: .noRetry,
                coreThrottle: CoreThrottle(), elsevierAPIKey: refused, elsevierRetry: .noRetry
            )
        }
        StubURLProtocol.routes[elsevierHost] = (401, Data())
        let first = try await service().fetchElsevierPDF(doi: doi, cacheKey: cacheKey)
        let second = try await service().fetchElsevierPDF(doi: doi, cacheKey: cacheKey)
        XCTAssertEqual(first, .keyRefused)
        XCTAssertEqual(second, .keyRefused)
        XCTAssertEqual(elsevierRequests, 1, "the second service knew the key was refused")
        XCTAssertTrue(ElsevierSession.shared.refuses(keyDigest: KeyDigest.key(refused)))
    }

    /// One fetch whose 429s outlast its retries counts once toward the pause,
    /// however many attempts it made.
    func testA429OutlastingItsRetriesCountsOnce() async throws {
        let session = ElsevierSession()
        StubURLProtocol.routes[elsevierHost] = (429, Data())
        let service = makeService(elsevierRetry: .oneRetry, elsevierSession: session)
        let first = try await service.fetchElsevierPDF(doi: doi, cacheKey: cacheKey)
        XCTAssertEqual(first, .unreachable(.httpStatus(429)))
        XCTAssertEqual(elsevierRequests, 2, "retried once")
        XCTAssertFalse(session.isPaused, "two attempts are one fetch")
        // The control: a second fetch ending in 429 pauses
        _ = try await service.fetchElsevierPDF(doi: doi, cacheKey: cacheKey)
        XCTAssertTrue(session.isPaused)
    }

    // MARK: - Served but not saved (the apps' deviation)

    func testAPDFNotSavedLetsTheWalkGoOnAndIsUnsettledWhenNothingServes() async throws {
        StubURLProtocol.routes[elsevierHost] = (200, pdfBody)
        let result = try await makeService(writeCachedPDF: { _, _ in
            throw CocoaError(.fileWriteOutOfSpace)
        }).fetchFullText(pmcId: nil, doi: doi, pmid: "")
        XCTAssertTrue(StubURLProtocol.requested("unpaywall"), "the walk goes on to Unpaywall")
        XCTAssertEqual(result.openAccessShortfall, OpenAccessShortfall(source: .elsevier, failure: .requestFailed))
        XCTAssertNil(result.pdfNotSavedFrom, "the not-saved note carries a link, so it is not used")
        XCTAssertNil(result.localPDFPath)
        assertNoElsevierURL(result)
        // One failure, one ERROR: Elsevier's, naming the consequence and its cause
        XCTAssertEqual(logger.errors.count, 1, "\(logger.errors)")
        XCTAssertTrue(
            logger.errors.contains { $0.contains("Elsevier's API") && $0.contains("could not be saved") },
            "\(logger.errors)"
        )
    }

    /// The control: a copy Unpaywall serves after it settles the question.
    func testAPDFNotSavedThenAnUnpaywallCopySettlesIt() async throws {
        StubURLProtocol.routes[elsevierHost] = (200, pdfBody)
        StubURLProtocol.routes["unpaywall"] = (200, unpaywall([repo]))
        StubURLProtocol.routes["repo.example.org"] = (200, pdfBody)
        let elsevierFile = FullTextService.cacheFilename(key: cacheKey, url: articleURL)
        let result = try await makeService(writeCachedPDF: { data, url in
            if url.lastPathComponent == elsevierFile { throw CocoaError(.fileWriteOutOfSpace) }
            try FullTextService.writeAtomically(data, to: url)
        }).fetchFullText(pmcId: nil, doi: doi, pmid: "")
        XCTAssertEqual(result.content, .unpaywall(pdfURL: URL(string: repo)!))
        XCTAssertNil(result.openAccessShortfall)
        assertNoElsevierURL(result)
    }

    /// A failure never falls back to a link: an unreachable, refused or absent
    /// Elsevier leaves no Elsevier URL on whatever the chain returns.
    func testNoOutcomeLeavesTheArticleURL() async throws {
        let answers: [(Int, Data)] = [(404, Data()), (503, Data()), (401, Data()), (403, authenticationError), (302, Data())]
        for (status, body) in answers {
            StubURLProtocol.reset()
            StubURLProtocol.routes["search"] = (200, Data(#"{"resultList": {"result": []}}"#.utf8))
            StubURLProtocol.routes["unpaywall"] = (404, Data())
            StubURLProtocol.routes[elsevierHost] = (status, body)
            let result = try await makeService().fetchFullText(pmcId: nil, doi: doi, pmid: "")
            assertNoElsevierURL(result)
        }
    }

    // MARK: - A PDF without text

    func testATextlessPDFAsksCOREAndItsTextWins() async throws {
        StubURLProtocol.routes[elsevierHost] = (200, pdfBody)
        StubURLProtocol.routes[coreHost] = (200, coreHit(longText))
        let result = try await makeService(extractor: ScanStub(), coreAPIKey: "test-core-key")
            .fetchFullText(pmcId: nil, doi: doi, pmid: "")
        XCTAssertEqual(result.content, .core(text: longText))
        XCTAssertFalse(StubURLProtocol.requested("unpaywall"), "the Elsevier copy's return site asked CORE")
        XCTAssertEqual(elsevierRequests, 1)
    }

    func testATextlessPDFWithCOREUnreachableCarriesCOREsEntry() async throws {
        StubURLProtocol.routes[elsevierHost] = (200, pdfBody)
        StubURLProtocol.routes[coreHost] = (503, Data())
        let result = try await makeService(extractor: ScanStub(), coreAPIKey: "test-core-key")
            .fetchFullText(pmcId: nil, doi: doi, pmid: "")
        XCTAssertEqual(result.content, .elsevier(localPath: cachedPath))
        XCTAssertEqual(result.contentKind, FullTextContentKind.none)
        XCTAssertEqual(result.localPDFPath, cachedPath)
        XCTAssertNotNil(result.extractionCoverage)
        XCTAssertEqual(result.openAccessShortfall, OpenAccessShortfall(source: .core, failure: .httpStatus(503)))
    }

    /// The control: without CORE's key the scan is returned as it is.
    func testATextlessPDFWithoutCOREIsReturned() async throws {
        StubURLProtocol.routes[elsevierHost] = (200, pdfBody)
        let result = try await makeService(extractor: ScanStub()).fetchFullText(pmcId: nil, doi: doi, pmid: "")
        XCTAssertEqual(result.content, .elsevier(localPath: cachedPath))
        XCTAssertNil(result.openAccessShortfall)
    }

    // MARK: - The cache first

    /// Plant this article's Elsevier PDF in the cache, as an earlier fetch left it.
    private func plantCachedPDF(_ data: Data? = nil) throws {
        try (data ?? pdfBody).write(to: URL(fileURLWithPath: cachedPath))
    }

    func testACachedPDFIsServedWithoutARequest() async throws {
        try plantCachedPDF()
        StubURLProtocol.routes[elsevierHost] = (503, Data())
        let result = try await makeService().fetchFullText(pmcId: nil, doi: doi, pmid: "")
        XCTAssertEqual(result.content, .elsevier(localPath: cachedPath))
        XCTAssertEqual(result.contentKind, .extracted)
        XCTAssertNil(result.openAccessShortfall)
        XCTAssertEqual(elsevierRequests, 0)
        XCTAssertFalse(StubURLProtocol.requested("unpaywall"))
    }

    /// A PDF saved on the institution's network is still served off it.
    func testACachedPDFIsServedWhileTheseCredentialsAreRefusedFromThisNetwork() async throws {
        try plantCachedPDF()
        let session = ElsevierSession()
        session.recordNetworkRefused(credentialsDigest: KeyDigest.credentials(key: key, token: nil))
        let fetch = try await makeService(elsevierSession: session).fetchElsevierPDF(doi: doi, cacheKey: cacheKey)
        XCTAssertEqual(fetch, .served(localPath: cachedPath))
        XCTAssertEqual(elsevierRequests, 0)
    }

    func testACachedPDFIsServedWhileElsevierIsPaused() async throws {
        try plantCachedPDF()
        let session = ElsevierSession()
        session.record(endedOn: 429, keyDigest: KeyDigest.key(key))
        session.record(endedOn: 429, keyDigest: KeyDigest.key(key))
        XCTAssertTrue(session.isPaused)
        let fetch = try await makeService(elsevierSession: session).fetchElsevierPDF(doi: doi, cacheKey: cacheKey)
        XCTAssertEqual(fetch, .served(localPath: cachedPath))
        XCTAssertEqual(elsevierRequests, 0)
    }

    /// The control: a corrupt entry is quarantined, and Elsevier is asked.
    func testACorruptCachedEntryIsQuarantinedAndElsevierIsAsked() async throws {
        try plantCachedPDF(Data("<html>not a pdf</html>".utf8))
        StubURLProtocol.routes[elsevierHost] = (200, pdfBody)
        let fetch = try await makeService().fetchElsevierPDF(doi: doi, cacheKey: cacheKey)
        XCTAssertEqual(fetch, .served(localPath: cachedPath))
        XCTAssertEqual(elsevierRequests, 1)
        let aside = URL(fileURLWithPath: cachedPath)
            .appendingPathExtension(BioMedLitConstants.quarantinedPDFExtension).path
        XCTAssertTrue(FileManager.default.fileExists(atPath: aside), "the corrupt entry was set aside")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: cachedPath)), pdfBody)
    }

    // MARK: - Extraction off

    /// An accepted limit: with extraction off every PDF tier hands over a URL,
    /// and Elsevier's never can be, so it is not asked and nothing is recorded.
    func testWithExtractionOffElsevierIsNotAsked() async throws {
        StubURLProtocol.routes[elsevierHost] = (200, pdfBody)
        let result = try await makeService(extractPDFText: false).fetchFullText(pmcId: nil, doi: doi, pmid: "")
        XCTAssertEqual(elsevierRequests, 0)
        XCTAssertNil(result.openAccessShortfall)
        assertNoElsevierURL(result)
    }

    // MARK: - Pacing

    /// Requests to api.elsevier.com are paced at ``BioMedLitConstants/elsevierMinimumInterval``,
    /// a retry included. A lower bound only, so a slow machine cannot fail it.
    func testRequestsArePaced() async throws {
        StubURLProtocol.sequences[elsevierHost] = [(503, Data()), (200, pdfBody)]
        let service = makeService(elsevierRetry: .oneRetry)
        let start = Date()
        let fetch = try await service.fetchElsevierPDF(doi: doi, cacheKey: cacheKey)
        XCTAssertEqual(fetch, .served(localPath: cachedPath))
        XCTAssertEqual(elsevierRequests, 2)
        XCTAssertGreaterThanOrEqual(
            Date().timeIntervalSince(start), BioMedLitConstants.elsevierMinimumInterval * 0.9
        )
    }
}
