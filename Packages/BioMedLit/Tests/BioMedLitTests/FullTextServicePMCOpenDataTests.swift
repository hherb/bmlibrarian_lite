import XCTest
@testable import BioMedLit

/// PMC's open-data bucket inside the chain (#480).
///
/// The bucket is asked after Europe PMC's `fullTextXML` gave no body, by PMC
/// ID only. Its listing 404 or an empty listing is its answer that it holds
/// nothing; anything it could not be asked for is a shortfall, named only when
/// Europe PMC left none.
final class FullTextServicePMCOpenDataTests: XCTestCase {
    private let pmcid = "PMC10358571"
    private let fullJATS = """
        <article><front><article-meta><title-group><article-title>A trial</article-title>\
        </title-group></article-meta></front><body><sec><title>Methods</title>\
        <p>We randomised 40 patients.</p></sec></body></article>
        """
    private let bodylessJATS = """
        <article><front><article-meta><title-group><article-title>T</article-title>\
        </title-group><abstract><p>Abstract only.</p></abstract></article-meta></front></article>
        """
    /// A body the JATS parser refuses outright.
    private let unparseable = "<article><front><unclosed></article>"
    private var listing: Data {
        Data("""
            <?xml version="1.0"?><ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">\
            <KeyCount>1</KeyCount><Contents><Key>metadata/PMC10358571.1.json</Key></Contents>\
            </ListBucketResult>
            """.utf8)
    }
    private var emptyListing: Data {
        Data("""
            <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><KeyCount>0</KeyCount>\
            </ListBucketResult>
            """.utf8)
    }
    private var metadata: Data {
        Data(#"{"xml_url":"s3://pmc-oa-opendata/PMC10358571.1/PMC10358571.1.xml?md5=a"}"#.utf8)
    }

    /// Route keys, matched as URL substrings (longest wins).
    private let listingRoute = "pmc-oa-opendata.s3.amazonaws.com/?list-type"
    private let metadataRoute = "metadata/PMC10358571.1.json"
    private let xmlRoute = "PMC10358571.1/PMC10358571.1.xml"

    override func setUp() { super.setUp(); StubURLProtocol.reset() }
    override func tearDown() { StubURLProtocol.reset(); super.tearDown() }

    private func service() -> FullTextService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        return FullTextService(email: "reader@example.org", session: session,
                               europePMCService: EuropePMCService(session: session),
                               europePMCRetry: RetryConfiguration(maxAttempts: 1, initialDelay: 0,
                                                                  maxDelay: 0, backoffMultiplier: 1,
                                                                  jitterFactor: 0))
    }

    private func routeBucket() {
        StubURLProtocol.routes["fullTextXML"] = (404, Data())
        StubURLProtocol.routes[listingRoute] = (200, listing)
        StubURLProtocol.routes[metadataRoute] = (200, metadata)
        StubURLProtocol.routes[xmlRoute] = (200, Data(fullJATS.utf8))
    }

    // MARK: - The chain

    func testEuropePMCAbsentThenTheBucketServes() async throws {
        routeBucket()
        let result = try await service().fetchFullText(pmcId: pmcid, doi: nil, pmid: "31829877")
        XCTAssertEqual(result.source, .pmcOpenData)
        XCTAssertEqual(result.contentKind, .fulltext)
        XCTAssertNil(result.degradation)
        XCTAssertTrue(result.content.markdown?.contains("We randomised 40 patients.") ?? false)
        XCTAssertTrue(result.content.html?.contains("We randomised 40 patients.") ?? false)
        // The listing asked for this article's metadata prefix.
        XCTAssertTrue(StubURLProtocol.requested("prefix=metadata/PMC10358571."),
                      "\(StubURLProtocol.requestedURLs)")
    }

    func testAPMCIDTheSearchResolvedAsksTheBucket() async throws {
        routeBucket()
        StubURLProtocol.routes["search"] = (200, Data(#"""
            {"resultList": {"result": [{"id": "31829877", "pmid": "31829877",
              "pmcid": "PMC10358571", "inPMC": "Y"}]}}
            """#.utf8))
        let result = try await service().fetchFullText(
            pmcId: nil, doi: nil, pmid: "31829877", primaryKind: .pubmed)
        XCTAssertEqual(result.source, .pmcOpenData)
        XCTAssertEqual(result.contentKind, .fulltext)
    }

    func testABucketAbsenceIsNotAFailure() async throws {
        StubURLProtocol.routes["fullTextXML"] = (404, Data())
        StubURLProtocol.routes[listingRoute] = (200, emptyListing)
        do {
            _ = try await service().fetchFullText(pmcId: pmcid, doi: nil, pmid: "")
            XCTFail("expected an error")
        } catch let error as FullTextError {
            // Europe PMC's 404 is its shortfall; the bucket adds none.
            guard case .absenceNotEstablished(let failure) = error else {
                return XCTFail("got \(error)")
            }
            XCTAssertEqual(failure, .httpStatus(404))
        }
        XCTAssertTrue(StubURLProtocol.requested(listingRoute))
    }

    func testAnUnreachableBucketBlocksNoFullText() async throws {
        routeBucket()
        StubURLProtocol.routes[listingRoute] = (503, Data())
        // Europe PMC's shortfall is set first, so its sentence stands.
        do {
            _ = try await service().fetchFullText(pmcId: pmcid, doi: nil, pmid: "")
            XCTFail("expected an error")
        } catch let error as FullTextError {
            guard case .absenceNotEstablished(let failure) = error else {
                return XCTFail("got \(error)")
            }
            XCTAssertEqual(failure, .httpStatus(404))
        }
    }

    func testABodylessBucketDepositIsHeldBackLikeEuropePMCs() async throws {
        routeBucket()
        StubURLProtocol.routes[xmlRoute] = (200, Data(bodylessJATS.utf8))
        let result = try await service().fetchFullText(pmcId: pmcid, doi: nil, pmid: "")
        XCTAssertEqual(result.source, .pmcOpenData)
        XCTAssertEqual(result.contentKind, .abstract)
    }

    /// Europe PMC's XML did not parse (no shortfall of its own) and neither
    /// did the bucket's: the bucket's malformed answer is what the chain
    /// names, as Python records it.
    func testAnUnparseableBucketXMLIsTheBucketsShortfall() async throws {
        routeBucket()
        StubURLProtocol.routes["fullTextXML"] = (200, Data(unparseable.utf8))
        StubURLProtocol.routes[xmlRoute] = (200, Data(unparseable.utf8))
        do {
            _ = try await service().fetchFullText(pmcId: pmcid, doi: nil, pmid: "")
            XCTFail("expected an error")
        } catch let error as FullTextError {
            guard case .pmcOpenDataNotEstablished(.malformedResponse) = error else {
                return XCTFail("got \(error)")
            }
        }
    }

    /// Europe PMC's XML did not parse (no shortfall of its own) and the
    /// bucket's listing answered 503: the bucket's shortfall is named. Pins
    /// through the chain what the brief thought only `exhaustedChainError`
    /// could show.
    func testAnUnreachableBucketIsNamedWhenEuropePMCLeftNoShortfall() async throws {
        routeBucket()
        StubURLProtocol.routes["fullTextXML"] = (200, Data(unparseable.utf8))
        StubURLProtocol.routes[listingRoute] = (503, Data())
        do {
            _ = try await service().fetchFullText(pmcId: pmcid, doi: nil, pmid: "")
            XCTFail("expected an error")
        } catch let error as FullTextError {
            guard case .pmcOpenDataNotEstablished(.httpStatus(503)) = error else {
                return XCTFail("got \(error)")
            }
        }
    }

    /// The control: the same Europe PMC parse failure with the bucket absent
    /// leaves nothing unsettled.
    func testAnAbsentBucketAfterAParseFailureIsNoFullText() async throws {
        StubURLProtocol.routes["fullTextXML"] = (200, Data(unparseable.utf8))
        StubURLProtocol.routes[listingRoute] = (200, emptyListing)
        do {
            _ = try await service().fetchFullText(pmcId: pmcid, doi: nil, pmid: "")
            XCTFail("expected an error")
        } catch let error as FullTextError {
            guard case .noFullTextAvailable = error else { return XCTFail("got \(error)") }
        }
        XCTAssertTrue(StubURLProtocol.requested(listingRoute))
    }

    func testTheBucketsShortfallWhenEuropePMCHadNone() {
        let error = FullTextService.exhaustedChainError(
            primarySlot: "1", primaryKind: .pubmed, europePMCShortfall: nil,
            pmcOpenDataShortfall: .httpStatus(503), openAccessShortfall: nil, articleName: "x")
        guard case .pmcOpenDataNotEstablished(let failure) = error else {
            return XCTFail("got \(error)")
        }
        XCTAssertEqual(failure, .httpStatus(503))
        XCTAssertFalse(error.isRetryable)
        XCTAssertEqual(
            error.errorDescription,
            "No source provided this article's full text. PMC's open-access collection could "
                + "not be asked (HTTP 503 Service Unavailable), so it may still exist. Try again later.")
    }

    func testPrecedenceEuropePMCThenTheBucketThenOpenAccess() {
        let open = OpenAccessShortfall(source: .unpaywall, failure: .httpStatus(429))
        let all = FullTextService.exhaustedChainError(
            primarySlot: "1", primaryKind: .pubmed, europePMCShortfall: .timeout,
            pmcOpenDataShortfall: .httpStatus(503), openAccessShortfall: open, articleName: "x")
        guard case .absenceNotEstablished(.timeout) = all else { return XCTFail("got \(all)") }

        let bucketAndOpen = FullTextService.exhaustedChainError(
            primarySlot: "1", primaryKind: .pubmed, europePMCShortfall: nil,
            pmcOpenDataShortfall: .httpStatus(503), openAccessShortfall: open, articleName: "x")
        guard case .pmcOpenDataNotEstablished(.httpStatus(503)) = bucketAndOpen else {
            return XCTFail("got \(bucketAndOpen)")
        }

        let openOnly = FullTextService.exhaustedChainError(
            primarySlot: "1", primaryKind: .pubmed, europePMCShortfall: nil,
            pmcOpenDataShortfall: nil, openAccessShortfall: open, articleName: "x")
        guard case .openAccessNotEstablished = openOnly else { return XCTFail("got \(openOnly)") }
    }

    func testControlNoShortfallsIsNoFullText() {
        let error = FullTextService.exhaustedChainError(
            primarySlot: "1", primaryKind: .pubmed, europePMCShortfall: nil,
            pmcOpenDataShortfall: nil, openAccessShortfall: nil, articleName: "x")
        guard case .noFullTextAvailable = error else { return XCTFail("got \(error)") }
    }

    func testAPreprintNeverAsksTheBucket() async throws {
        StubURLProtocol.stubbed = (404, Data())
        _ = try? await service().fetchFullText(pmcId: "PPR1316954", doi: nil, pmid: "1")
        XCTAssertTrue(StubURLProtocol.requested("PPR1316954/fullTextXML"),
                      "control: the chain ran: \(StubURLProtocol.requestedURLs)")
        XCTAssertFalse(StubURLProtocol.requested("pmc-oa-opendata"))
    }

    func testEuropePMCServedSoTheBucketIsNotAsked() async throws {
        StubURLProtocol.routes["fullTextXML"] = (200, Data(fullJATS.utf8))
        let result = try await service().fetchFullText(pmcId: pmcid, doi: nil, pmid: "1")
        XCTAssertEqual(result.source, .europePMC)
        XCTAssertFalse(StubURLProtocol.requested("pmc-oa-opendata"))
    }

    func testACatchAllStubLeavesTheEuropePMCOutcomeAlone() async throws {
        // Every URL answers the same body-less JATS, as the abstract-holdback
        // tests do. Europe PMC's body-less deposit is held, so the bucket is
        // not asked (Python and Kotlin read such a deposit as served), and the
        // held abstract is still what comes back.
        StubURLProtocol.stubbed = (200, Data(bodylessJATS.utf8))
        let result = try await service().fetchFullText(pmcId: pmcid, doi: nil, pmid: "1")
        XCTAssertEqual(result.source, .europePMC)
        XCTAssertEqual(result.contentKind, .abstract)
        XCTAssertFalse(StubURLProtocol.requested("pmc-oa-opendata"))
    }

    func testACatchAll404IsTheBucketsAbsence() async throws {
        StubURLProtocol.stubbed = (404, Data())
        do {
            _ = try await service().fetchFullText(pmcId: pmcid, doi: nil, pmid: "")
            XCTFail("expected an error")
        } catch let error as FullTextError {
            guard case .absenceNotEstablished(.httpStatus(404)) = error else {
                return XCTFail("got \(error)")
            }
        }
        XCTAssertTrue(StubURLProtocol.requested(listingRoute))
    }

    // MARK: - The fetch

    func testACatchAllJATSListingIsMalformedNotAbsent() async throws {
        StubURLProtocol.stubbed = (200, Data(fullJATS.utf8))
        let fetch = try await service().fetchPMCOpenDataXML(pmcid: pmcid)
        XCTAssertEqual(fetch, .unreachable(.malformedResponse))
    }

    func testAListingWithoutTheS3NamespaceIsMalformed() async throws {
        StubURLProtocol.routes[listingRoute] = (200, Data("""
            <ListBucketResult><KeyCount>1</KeyCount><Contents>\
            <Key>metadata/PMC10358571.1.json</Key></Contents></ListBucketResult>
            """.utf8))
        let fetch = try await service().fetchPMCOpenDataXML(pmcid: pmcid)
        XCTAssertEqual(fetch, .unreachable(.malformedResponse))
        XCTAssertFalse(StubURLProtocol.requested(metadataRoute))
    }

    func testAnEmptyListingIsAbsent() async throws {
        StubURLProtocol.routes[listingRoute] = (200, emptyListing)
        let fetch = try await service().fetchPMCOpenDataXML(pmcid: pmcid)
        XCTAssertEqual(fetch, .absent)
    }

    func testARecordNamingNoXMLIsAbsent() async throws {
        routeBucket()
        StubURLProtocol.routes[metadataRoute] = (200, Data(#"{"pdf_url":"s3://pmc-oa-opendata/x.pdf"}"#.utf8))
        let fetch = try await service().fetchPMCOpenDataXML(pmcid: pmcid)
        XCTAssertEqual(fetch, .absent)
        XCTAssertFalse(StubURLProtocol.requested(xmlRoute))
    }

    func testARecordThatIsNotJSONIsMalformed() async throws {
        routeBucket()
        StubURLProtocol.routes[metadataRoute] = (200, Data("not json".utf8))
        let fetch = try await service().fetchPMCOpenDataXML(pmcid: pmcid)
        XCTAssertEqual(fetch, .unreachable(.malformedResponse))
    }

    func testABlankXMLIsIncomplete() async throws {
        routeBucket()
        StubURLProtocol.routes[xmlRoute] = (200, Data("  \n".utf8))
        let fetch = try await service().fetchPMCOpenDataXML(pmcid: pmcid)
        XCTAssertEqual(fetch, .unreachable(.incompleteResponse))
    }

    func testATransportFailureIsUnreachableOfItsKind() async throws {
        StubURLProtocol.failures[listingRoute] = URLError(.timedOut)
        let fetch = try await service().fetchPMCOpenDataXML(pmcid: pmcid)
        XCTAssertEqual(fetch, .unreachable(.timeout))
    }

    func testACancelledFetchPropagates() async throws {
        StubURLProtocol.failures[listingRoute] = URLError(.cancelled)
        do {
            _ = try await service().fetchPMCOpenDataXML(pmcid: pmcid)
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // expected
        }
    }

    func testABarePMCNumberIsNormalisedAndAPreprintIsNeverAsked() async throws {
        routeBucket()
        let served = try await service().fetchPMCOpenDataXML(pmcid: "10358571")
        guard case .served = served else { return XCTFail("got \(served)") }

        StubURLProtocol.reset()
        let preprint = try await service().fetchPMCOpenDataXML(pmcid: "PPR1316954")
        XCTAssertEqual(preprint, .absent)
        XCTAssertTrue(StubURLProtocol.requestedURLs.isEmpty, "\(StubURLProtocol.requestedURLs)")
    }

    func testRequestsArePaced() async throws {
        routeBucket()
        let start = Date()
        let fetch = try await service().fetchPMCOpenDataXML(pmcid: pmcid)
        guard case .served = fetch else { return XCTFail("got \(fetch)") }
        // Three requests: two paced gaps at the least.
        XCTAssertGreaterThanOrEqual(
            Date().timeIntervalSince(start), 2 * BioMedLitConstants.pmcOpenDataMinimumInterval * 0.9)
    }

    /// The contract's status table: which status at which step settles what.
    func testTheContractsStatuses() async throws {
        let rows = try XCTUnwrap(PMCOpenDataContract.load()["status"] as? [[String: Any]])
        XCTAssertFalse(rows.isEmpty)
        for row in rows {
            let step = try XCTUnwrap(row["step"] as? String)
            let status = try XCTUnwrap(row["status"] as? Int)
            let outcome = try XCTUnwrap(row["outcome"] as? String)
            StubURLProtocol.reset()
            routeBucket()
            let route: String
            switch step {
            case "listing": route = listingRoute
            case "metadata": route = metadataRoute
            case "xml": route = xmlRoute
            default: return XCTFail("unknown step \(step)")
            }
            let original = try XCTUnwrap(StubURLProtocol.routes[route])
            StubURLProtocol.routes[route] = (status, status == 200 ? original.body : Data())
            let fetch = try await service().fetchPMCOpenDataXML(pmcid: pmcid)
            let label = "\(step) \(status)"
            switch outcome {
            case "read":
                guard case .served = fetch else { XCTFail("\(label): got \(fetch)"); continue }
            case "absent":
                XCTAssertEqual(fetch, .absent, label)
            case "unreachable":
                XCTAssertEqual(fetch, .unreachable(.httpStatus(status)), label)
            default:
                XCTFail("unknown outcome \(outcome)")
            }
        }
    }
}
