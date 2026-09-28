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

/// The accession rules `fullTextXML` is asked by (#434), mirroring Python's
/// `fulltext_accession`.
final class FullTextAccessionTests: XCTestCase {
    func testAPMCIDIsNormalisedWhateverItsPrefixCase() {
        for identifier in ["PMC123", "pmc123", "Pmc123", "123", "  PMC123\n"] {
            XCTAssertEqual(FullTextAccession.normalized(identifier), "PMC123", identifier)
        }
    }

    /// A preprint has no PMC ID; refusing its record ID left every preprint's
    /// full text unfetched.
    func testAPreprintRecordIDIsKept() {
        for identifier in ["PPR1316954", "ppr1316954", " PPR1316954 "] {
            XCTAssertEqual(FullTextAccession.normalized(identifier), "PPR1316954", identifier)
        }
    }

    /// Each of these goes into a URL path, so none may pass. `PMC١٢٣` is the
    /// one `isNumber` alone would admit.
    func testAnythingElseIsRefused() {
        for identifier in [
            "", "   ", "PMC", "PPR", "PMCabc", "12a", "PMC12 3", "../PMC1", "PMC-1",
            "PMC١٢٣", "١٢٣", "10.1234/example", "MED123", "PMCPPR1", "PPRPMC1",
        ] {
            XCTAssertNil(FullTextAccession.normalized(identifier), identifier)
        }
    }

    /// A slot that can hold a PubMed ID must not have `123` read as `PMC123`.
    func testPrefixedDemandsThePrefix() {
        XCTAssertNil(FullTextAccession.prefixed("123", as: "PPR"))
        XCTAssertNil(FullTextAccession.prefixed("123", as: "PMC"))
        XCTAssertNil(FullTextAccession.prefixed("PMC123", as: "PPR"))
        XCTAssertEqual(FullTextAccession.prefixed(" ppr7 ", as: "PPR"), "PPR7")
        XCTAssertEqual(FullTextAccession.prefixed("pmc7", as: "PMC"), "PMC7")
    }
}

/// What asking `fullTextXML` produced: served, absent (404) or unreachable of
/// its real kind (#434, the port of Python's #429).
final class EuropePMCFullTextFetchTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    /// Two attempts, a moment apart, so a throttle that outlasts its retries
    /// can be pinned without the production policy's seventy-five seconds.
    private static let fastRetry = RetryConfiguration(
        maxAttempts: 2, initialDelay: 0.01, maxDelay: 0.01, backoffMultiplier: 1, jitterFactor: 0
    )

    private func service() -> FullTextService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        return FullTextService(
            email: "test@example.com",
            session: session,
            europePMCService: EuropePMCService(session: session),
            extractPDFText: false,
            europePMCRetry: Self.fastRetry
        )
    }

    private static let article = Data("<article><body><p>Prose.</p></body></article>".utf8)

    private func fullTextRequests() -> [String] {
        StubURLProtocol.requestedURLs.filter { $0.contains("fullTextXML") }
    }

    func testServedXMLIsReturned() async throws {
        StubURLProtocol.routes = ["fullTextXML": (200, Self.article)]
        let fetch = try await service().fetchEuropePMCXML(accession: "PMC123")
        XCTAssertEqual(fetch, ServedXML(Self.article).map { .served($0) })
    }

    /// Python's `test_blank_xml_cannot_be_served`: a blank answer is not a
    /// served full text, so it cannot be built as one.
    func testBlankXMLCannotBeServed() {
        XCTAssertNil(ServedXML(Data()))
        XCTAssertNil(ServedXML(Data(" \n\t".utf8)))
        XCTAssertNotNil(ServedXML(Self.article))
    }

    func testA404IsAbsent() async throws {
        StubURLProtocol.routes = ["fullTextXML": (404, Data())]
        let fetch = try await service().fetchEuropePMCXML(accession: "PMC123")
        XCTAssertEqual(fetch, .absent)
    }

    /// A blank answer told us nothing about the article. It used to be parsed,
    /// and reached the reader as a parse failure.
    func testABlankBodyIsAnIncompleteResponse() async throws {
        for body in ["", "  \n\t "] {
            StubURLProtocol.routes = ["fullTextXML": (200, Data(body.utf8))]
            let fetch = try await service().fetchEuropePMCXML(accession: "PMC123")
            XCTAssertEqual(fetch, .unreachable(.incompleteResponse), "body \(body.debugDescription)")
        }
    }

    /// The case #429 named: a throttle that outlasts its retries stays a 429,
    /// and is retried first.
    func testAThrottleOutlastingItsRetriesStaysA429() async throws {
        StubURLProtocol.routes = ["fullTextXML": (429, Data())]
        let fetch = try await service().fetchEuropePMCXML(accession: "PMC123")
        XCTAssertEqual(fetch, .unreachable(.httpStatus(429)))
        XCTAssertEqual(fullTextRequests().count, Self.fastRetry.maxAttempts)
    }

    /// What Europe PMC answered for non-open-access PMC IDs on 2026-09-28 (#432).
    func testAServerErrorIsUnreachableNotAbsent() async throws {
        StubURLProtocol.routes = ["fullTextXML": (500, Data())]
        let fetch = try await service().fetchEuropePMCXML(accession: "PMC123")
        XCTAssertEqual(fetch, .unreachable(.httpStatus(500)))
        XCTAssertEqual(fullTextRequests().count, Self.fastRetry.maxAttempts)
    }

    func testAStatusWeDoNotModelIsUnreachableAndNotRetried() async throws {
        StubURLProtocol.routes = ["fullTextXML": (403, Data())]
        let fetch = try await service().fetchEuropePMCXML(accession: "PMC123")
        XCTAssertEqual(fetch, .unreachable(.httpStatus(403)))
        XCTAssertEqual(fullTextRequests().count, 1)
    }

    func testATimeoutKeepsItsKind() async throws {
        StubURLProtocol.failures = ["fullTextXML": URLError(.timedOut)]
        let fetch = try await service().fetchEuropePMCXML(accession: "PMC123")
        XCTAssertEqual(fetch, .unreachable(.timeout))
    }

    func testAConnectionFailureKeepsItsKind() async throws {
        StubURLProtocol.failures = ["fullTextXML": URLError(.cannotConnectToHost)]
        let fetch = try await service().fetchEuropePMCXML(accession: "PMC123")
        XCTAssertEqual(fetch, .unreachable(.connection))
    }

    /// A cancelled fetch is not a dead source.
    func testACancelledFetchThrows() async {
        StubURLProtocol.failures = ["fullTextXML": URLError(.cancelled)]
        do {
            _ = try await service().fetchEuropePMCXML(accession: "PMC123")
            XCTFail("a cancelled fetch must not produce an outcome")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    /// Not an accession: recorded as a request never made, and never sent.
    func testANonAccessionIsNeverSent() async throws {
        StubURLProtocol.routes = ["fullTextXML": (404, Data())]
        let fetch = try await service().fetchEuropePMCXML(accession: "10.1234/example")
        XCTAssertEqual(fetch, .unreachable(.requestFailed))
        XCTAssertTrue(StubURLProtocol.requestedURLs.isEmpty, "\(StubURLProtocol.requestedURLs)")
    }

    /// `pmc123` used to become `PMCpmc123`, which Europe PMC answers 404.
    func testALowerCasePMCIDIsAskedForNormalised() async throws {
        StubURLProtocol.routes = ["fullTextXML": (200, Self.article)]
        _ = try await service().fetchEuropePMCXML(accession: "pmc123")
        XCTAssertEqual(fullTextRequests().count, 1)
        XCTAssertTrue(StubURLProtocol.requested("/PMC123/fullTextXML"), "\(fullTextRequests())")
    }

    /// Live, `GET /PPR1316954/fullTextXML` answers 200.
    func testAPreprintIsAskedForByItsRecordID() async throws {
        StubURLProtocol.routes = ["fullTextXML": (200, Self.article)]
        _ = try await service().fetchEuropePMCXML(accession: "ppr1316954")
        XCTAssertTrue(StubURLProtocol.requested("/PPR1316954/fullTextXML"), "\(fullTextRequests())")
    }
}

/// The chain around the fetch: the preprint route, and what a chain that found
/// nothing may say about the article (#434).
final class FullTextChainEuropePMCTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func service() -> FullTextService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        return FullTextService(
            email: "test@example.com",
            session: session,
            europePMCService: EuropePMCService(session: session),
            extractPDFText: false,
            europePMCRetry: RetryConfiguration(
                maxAttempts: 1, initialDelay: 0, maxDelay: 0, backoffMultiplier: 1, jitterFactor: 0
            )
        )
    }

    private static let article = Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <article>
      <front><article-meta>
        <title-group><article-title>A preprint in full</article-title></title-group>
        <contrib-group><contrib contrib-type="author">
          <name><surname>Doe</surname><given-names>J</given-names></name>
        </contrib></contrib-group>
      </article-meta></front>
      <body><sec><title>Methods</title><p>Real prose.</p></sec></body>
    </article>
    """.utf8)

    /// A Europe PMC search answer holding one record.
    private static func searchAnswer(_ record: String) -> Data {
        Data(#"{"resultList": {"result": [\#(record)]}}"#.utf8)
    }

    private static let preprintRecord =
        #"{"id": "PPR1316954", "source": "PPR", "doi": "10.1101/example"}"#

    // MARK: The preprint route

    /// A preprint's search returns its record, and the XML is fetched by that
    /// record's `PPR` ID.
    func testAPreprintIsFetchedByItsRecordID() async throws {
        StubURLProtocol.routes = [
            "search": (200, Self.searchAnswer(Self.preprintRecord)),
            "fullTextXML": (200, Self.article),
        ]
        let result = try await service().fetchFullText(
            pmcId: nil, doi: nil, pmid: "PPR1316954", primaryKind: .preprint
        )
        guard case .europePMC(let html, _) = result.content else {
            return XCTFail("expected the preprint's full text, got \(result.content)")
        }
        XCTAssertTrue(html.contains("A preprint in full"))
        XCTAssertTrue(StubURLProtocol.requested("/PPR1316954/fullTextXML"))
    }

    /// A DOI-only document whose search finds a preprint record.
    func testADOISearchThatFindsAPreprintFetchesItsFullText() async throws {
        StubURLProtocol.routes = [
            "search": (200, Self.searchAnswer(Self.preprintRecord)),
            "fullTextXML": (200, Self.article),
        ]
        let result = try await service().fetchFullText(
            pmcId: nil, doi: "10.1101/example", pmid: ""
        )
        guard case .europePMC = result.content else {
            return XCTFail("expected the preprint's full text, got \(result.content)")
        }
        XCTAssertTrue(StubURLProtocol.requested("/PPR1316954/fullTextXML"))
    }

    /// A search that fails does not cost a preprint document its XML: the
    /// document's own slot names it.
    func testAPreprintIsFetchedEvenWhenItsSearchFails() async throws {
        StubURLProtocol.routes = [
            "search": (400, Data()),
            "fullTextXML": (200, Self.article),
        ]
        let result = try await service().fetchFullText(
            pmcId: nil, doi: nil, pmid: "PPR1316954", primaryKind: .preprint
        )
        guard case .europePMC = result.content else {
            return XCTFail("expected the preprint's full text, got \(result.content)")
        }
        XCTAssertNil(result.degradation)
    }

    /// A preprint record that also carries a PubMed ID fills the slot with it.
    /// The preprint is still fetched by its record ID, as Python and Android
    /// do, and the PubMed ID is not read as `PMC555`.
    func testAPreprintRecordsPubMedIDIsNotFetchedAsAPMCID() async throws {
        StubURLProtocol.routes = [
            "search": (200, Self.searchAnswer(
                #"{"id": "PPR1", "pmid": "555", "source": "PPR", "doi": "10.1101/x"}"#
            )),
            "fullTextXML": (200, Self.article),
            "unpaywall": (404, Data()),
        ]
        _ = try await service().fetchFullText(pmcId: nil, doi: "10.1101/x", pmid: "")
        XCTAssertFalse(StubURLProtocol.requested("PMC555"), "\(StubURLProtocol.requestedURLs)")
        XCTAssertTrue(StubURLProtocol.requested("/PPR1/fullTextXML"), "\(StubURLProtocol.requestedURLs)")
    }

    /// A search that answered "no such record" is not second-guessed by
    /// fetching the slot anyway: that only adds a 404 about an article Europe
    /// PMC does not hold.
    func testASearchThatFoundNoRecordIsNotSecondGuessed() async throws {
        StubURLProtocol.routes = [
            "search": (200, Data(#"{"resultList": {"result": []}}"#.utf8)),
            "fullTextXML": (200, Self.article),
        ]
        do {
            _ = try await service().fetchFullText(
                pmcId: nil, doi: nil, pmid: "PPR1316954", primaryKind: .preprint
            )
            XCTFail("Europe PMC holds no record, so nothing was fetched")
        } catch FullTextError.noFullTextAvailable {
            XCTAssertFalse(StubURLProtocol.requested("fullTextXML"))
        }
    }

    /// A lost search reads the slot, but a bare number there may be a PubMed
    /// ID, and asking for `PMC12345` would fetch a different article and serve
    /// it as this one's full text. `fullTextXML` answers with an article here,
    /// so a wrong request would change the outcome and not only the log.
    func testALostSearchNeverFetchesABareSlotAsAPMCID() async throws {
        let kinds: [ArticleIdentifierKind?] = [nil, .pubmed, .preprint, .unknown]
        for kind in kinds {
            StubURLProtocol.reset()
            StubURLProtocol.routes = [
                "search": (400, Data()),
                "fullTextXML": (200, Self.article),
            ]
            let result = try? await service().fetchFullText(
                pmcId: nil, doi: nil, pmid: "12345", primaryKind: kind
            )
            XCTAssertFalse(
                StubURLProtocol.requested("fullTextXML"),
                "kind \(String(describing: kind)): \(StubURLProtocol.requestedURLs)"
            )
            if let result, case .europePMC = result.content {
                XCTFail("kind \(String(describing: kind)): served another article's text")
            }
        }
    }

    /// The routing on its own, as a table: the slot is read only after a lost
    /// search, and only in its prefixed form.
    func testFullTextAccessionRouting() {
        typealias Row = (
            pmcId: String?, preprint: String?, slot: String?,
            kind: ArticleIdentifierKind?, lost: Bool, expected: String?
        )
        let rows: [Row] = [
            ("PMC1", "PPR2", "PPR3", .preprint, true, "PMC1"),
            (nil, "PPR2", "PPR3", .preprint, true, "PPR2"),
            (nil, nil, "PPR3", .preprint, true, "PPR3"),
            (nil, nil, "ppr3", nil, true, "PPR3"),
            (nil, nil, "PMC4", .pmc, true, "PMC4"),
            (nil, nil, "PPR3", .preprint, false, nil),
            (nil, nil, "12345", nil, true, nil),
            (nil, nil, "12345", .pubmed, true, nil),
            (nil, nil, "12345", .preprint, true, nil),
            (nil, nil, "12345", .pmc, true, nil),
            (nil, nil, "ETH12345", .europePMCSource("eth"), true, nil),
            (nil, nil, "  ", nil, true, nil),
        ]
        for row in rows {
            XCTAssertEqual(
                FullTextService.fullTextAccession(
                    pmcId: row.pmcId,
                    resolvedPreprintAccession: row.preprint,
                    pmid: row.slot,
                    primaryKind: row.kind,
                    searchLostTheSource: row.lost
                ),
                row.expected,
                "\(row)"
            )
        }
    }

    // MARK: What a chain that found nothing may say

    /// Europe PMC's 404 for an article it holds is not the article's absence
    /// (#432), so the chain must not throw `noFullTextAvailable`, which callers
    /// record on the document for good.
    func testA404DoesNotEstablishTheArticleHasNoFullText() async throws {
        StubURLProtocol.routes = [
            "search": (200, Self.searchAnswer(Self.preprintRecord)),
            "fullTextXML": (404, Data()),
        ]
        do {
            _ = try await service().fetchFullText(
                pmcId: nil, doi: nil, pmid: "PPR1316954", primaryKind: .preprint
            )
            XCTFail("nothing was served")
        } catch FullTextError.absenceNotEstablished(let failure) {
            XCTAssertEqual(failure, .httpStatus(404))
        }
    }

    func testAnUnreachableEuropePMCDoesNotEstablishIt() async throws {
        StubURLProtocol.routes = ["search": (200, Self.searchAnswer(Self.preprintRecord))]
        StubURLProtocol.failures = ["fullTextXML": URLError(.badServerResponse)]
        do {
            _ = try await service().fetchFullText(
                pmcId: nil, doi: nil, pmid: "PPR1316954", primaryKind: .preprint
            )
            XCTFail("nothing was served")
        } catch FullTextError.absenceNotEstablished(let failure) {
            XCTAssertEqual(failure, .requestFailed)
        }
    }

    /// A lost identifier search, with nothing else to ask by.
    func testALostSearchDoesNotEstablishIt() async throws {
        StubURLProtocol.routes = ["search": (400, Data())]
        do {
            _ = try await service().fetchFullText(
                pmcId: nil, doi: nil, pmid: "889149", primaryKind: .europePMCSource("eth")
            )
            XCTFail("nothing was served")
        } catch FullTextError.absenceNotEstablished(let failure) {
            XCTAssertEqual(failure, .httpStatus(400))
        }
    }

    /// The control: every source that could be asked answered, and none had it.
    /// Without it the tests above pass against a chain that never says
    /// `noFullTextAvailable` at all.
    func testAnAnsweredChainStillSaysNoFullTextAvailable() async throws {
        StubURLProtocol.routes = [
            "search": (200, Self.searchAnswer(#"{"id": "889149", "source": "ETH"}"#)),
        ]
        do {
            _ = try await service().fetchFullText(
                pmcId: nil, doi: nil, pmid: "889149", primaryKind: .europePMCSource("eth")
            )
            XCTFail("nothing was served")
        } catch FullTextError.noFullTextAvailable {
            // expected
        }
    }

    /// The reader's sentence follows #435's decision: an HTTP answer "did not
    /// serve it", a transport failure "could not be asked".
    func testTheSentenceNamesWhatEuropePMCDid() {
        let answered = FullTextError.absenceNotEstablished(.httpStatus(404)).errorDescription ?? ""
        XCTAssertTrue(answered.contains("Europe PMC (HTTP 404 Not Found) did not serve it"), answered)
        XCTAssertFalse(answered.contains("could not be asked"), answered)

        let unasked = FullTextError.absenceNotEstablished(.timeout).errorDescription ?? ""
        XCTAssertTrue(
            unasked.contains("Europe PMC could not be asked (the request timed out)"), unasked
        )
        XCTAssertFalse(FullTextError.absenceNotEstablished(.timeout).isRetryable)
    }

    // MARK: Degradation

    /// A blank 200 is our failure to get an answer, not a parse failure.
    func testABlankBodyIsReportedAsUnreachableNotAsAParseFailure() async throws {
        StubURLProtocol.routes = [
            "fullTextXML": (200, Data()),
            "unpaywall": (404, Data()),
        ]
        let result = try await service().fetchFullText(
            pmcId: "PMC12759138", doi: "10.1234/example", pmid: "1"
        )
        XCTAssertEqual(result.degradation, .europePMCUnreachable)
    }

    /// And the 404 stays no degradation: Europe PMC answered.
    func testA404IsNoDegradation() async throws {
        StubURLProtocol.routes = [
            "fullTextXML": (404, Data()),
            "unpaywall": (404, Data()),
        ]
        let result = try await service().fetchFullText(
            pmcId: "PMC12759138", doi: "10.1234/example", pmid: "1"
        )
        XCTAssertNil(result.degradation)
    }
}
