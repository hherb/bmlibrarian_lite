import XCTest
@testable import BioMedLit

/// Serves a fixed extraction result, so a PDF tier can win without a real PDF.
private struct BucketTestExtractor: PDFTextExtracting {
    let result: PDFExtractionResult
    func extract(from fileURL: URL) -> PDFExtractionResult { result }
}

/// PMC's open-data bucket inside the chain (#480).
///
/// The bucket is asked after Europe PMC's `fullTextXML` gave no article, by
/// PMC ID only. A listing naming no version, or a record naming no XML, is its
/// answer that it holds nothing; a listing 404, and anything else it could not
/// be asked for or that we could not read, is a shortfall, named only when
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

    /// The primary slot of the one test that lets a PDF tier download.
    ///
    /// Not a number: the service caches PDFs into the real Application
    /// Support directory, and no real article has this identifier.
    private static let pdfTestPMID = "pmc-open-data-test-99003"

    /// A byte that is not UTF-8 on its own (Latin-1's `é`).
    private static let latin1Byte: UInt8 = 0xE9

    private static func clearPDFCache() {
        FullTextService.deleteCachedPDF(
            for: ArticleCacheKey(pmid: pdfTestPMID, pmcId: nil, doi: nil)!)
    }

    override func setUp() { super.setUp(); StubURLProtocol.reset(); Self.clearPDFCache() }
    override func tearDown() { StubURLProtocol.reset(); Self.clearPDFCache(); super.tearDown() }

    /// Retries with no wait, so a test of the policy does not sleep.
    private static func immediateRetry(attempts: Int) -> RetryConfiguration {
        RetryConfiguration(maxAttempts: attempts, initialDelay: 0, maxDelay: 0,
                           backoffMultiplier: 1, jitterFactor: 0)
    }

    private func service(bucketAttempts: Int = 1,
                         extractor: PDFTextExtracting = PDFKitTextExtractor()) -> FullTextService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        return FullTextService(email: "reader@example.org", session: session,
                               europePMCService: EuropePMCService(session: session),
                               extractor: extractor,
                               europePMCRetry: Self.immediateRetry(attempts: 1),
                               pmcOpenDataRetry: Self.immediateRetry(attempts: bucketAttempts))
    }

    /// `text` with one byte that is not UTF-8 spliced in after `marker`.
    private static func notUTF8(_ text: String, after marker: String) -> Data {
        let range = text.range(of: marker)!
        var data = Data(text[..<range.upperBound].utf8)
        data.append(latin1Byte)
        data.append(Data(text[range.upperBound...].utf8))
        return data
    }

    private func listingRequests() -> Int {
        StubURLProtocol.requestedURLs.filter { $0.contains(listingRoute) }.count
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
        // The bucket was asked, and its 503 is what it answered: without
        // this the test passes on a chain that never asks the bucket.
        XCTAssertEqual(listingRequests(), 1, "\(StubURLProtocol.requestedURLs)")
        XCTAssertFalse(StubURLProtocol.requested(metadataRoute))
    }

    func testABodylessBucketDepositIsHeldBackLikeEuropePMCs() async throws {
        routeBucket()
        StubURLProtocol.routes[xmlRoute] = (200, Data(bodylessJATS.utf8))
        let result = try await service().fetchFullText(pmcId: pmcid, doi: nil, pmid: "")
        XCTAssertEqual(result.source, .pmcOpenData)
        XCTAssertEqual(result.contentKind, .abstract)
    }

    /// Held back, not returned: a PDF tier after the bucket still wins over
    /// the bucket's body-less deposit.
    func testAPDFBeatsTheBucketsHeldAbstract() async throws {
        routeBucket()
        StubURLProtocol.routes[xmlRoute] = (200, Data(bodylessJATS.utf8))
        StubURLProtocol.routes["unpaywall"] = (200, Data(
            #"{"best_oa_location":{"url_for_pdf":"https://example.org/a.pdf"}}"#.utf8))
        StubURLProtocol.routes["example.org/a.pdf"] = (200, Data("%PDF-1.4".utf8))
        let extractor = BucketTestExtractor(result: PDFExtractionResult(
            text: "Recovered prose.", success: true, pageCount: 1, convertedPages: 1, warnings: []))
        let result = try await service(extractor: extractor)
            .fetchFullText(pmcId: pmcid, doi: "10.1/x", pmid: Self.pdfTestPMID)
        XCTAssertEqual(result.source, .unpaywall)
        XCTAssertEqual(result.contentKind, .extracted)
        XCTAssertEqual(result.extractedText, "Recovered prose.")
        // The control that the bucket was what it beat.
        XCTAssertTrue(StubURLProtocol.requested(xmlRoute), "\(StubURLProtocol.requestedURLs)")
    }

    /// An article that is not UTF-8 is an answer we cannot read: through the
    /// chain it is the bucket's malformed shortfall, never "no full text".
    /// The control is ``testAnAbsentBucketAfterAParseFailureIsNoFullText``.
    func testAnArticleThatIsNotUTF8IsTheBucketsShortfall() async throws {
        routeBucket()
        StubURLProtocol.routes["fullTextXML"] = (200, Data(unparseable.utf8))
        StubURLProtocol.routes[xmlRoute] = (200, Self.notUTF8(fullJATS, after: "We randomised"))
        do {
            _ = try await service().fetchFullText(pmcId: pmcid, doi: nil, pmid: "")
            XCTFail("expected an error")
        } catch let error as FullTextError {
            guard case .pmcOpenDataNotEstablished(.malformedResponse) = error else {
                return XCTFail("got \(error)")
            }
        }
    }

    /// The control for the strict decode: UTF-8 that is not ASCII reaches the
    /// reader intact.
    func testNonASCIIUTF8ArticleTextSurvives() async throws {
        routeBucket()
        let prose = "Müller et al. randomised 40 patients – β-blockers, 37 °C."
        StubURLProtocol.routes[xmlRoute] = (200, Data(
            fullJATS.replacingOccurrences(of: "We randomised 40 patients.", with: prose).utf8))
        let result = try await service().fetchFullText(pmcId: pmcid, doi: nil, pmid: "")
        XCTAssertEqual(result.source, .pmcOpenData)
        XCTAssertTrue(result.content.markdown?.contains(prose) ?? false,
                      result.content.markdown ?? "no markdown")
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

    /// Europe PMC's 404 is set first, so its sentence stands; the bucket's
    /// listing 404 behind it is unreachable, never an absence.
    func testACatchAll404KeepsEuropePMCsSentence() async throws {
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

    /// A listing 404 is S3's `NoSuchBucket` or something between us and it:
    /// unreachable. Its control is ``testAnEmptyListingIsAbsent``.
    func testAListing404IsUnreachableNotAbsent() async throws {
        routeBucket()
        StubURLProtocol.routes[listingRoute] = (404, Data())
        let fetch = try await service().fetchPMCOpenDataXML(pmcid: pmcid)
        XCTAssertEqual(fetch, .unreachable(.httpStatus(404)))
        XCTAssertFalse(StubURLProtocol.requested(metadataRoute))
    }

    /// Unreadable versions are not an absence. Its control is
    /// ``testAnEmptyListingIsAbsent``.
    func testAListingNamingOnlyAnUnreadableVersionIsMalformed() async throws {
        routeBucket()
        StubURLProtocol.routes[listingRoute] = (200, Data("""
            <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Contents>\
            <Key>metadata/PMC10358571.x.json</Key></Contents></ListBucketResult>
            """.utf8))
        let fetch = try await service().fetchPMCOpenDataXML(pmcid: pmcid)
        XCTAssertEqual(fetch, .unreachable(.malformedResponse))
        XCTAssertFalse(StubURLProtocol.requested(metadataRoute))
    }

    func testAListingThatIsNotUTF8IsMalformed() async throws {
        routeBucket()
        let text = String(decoding: listing, as: UTF8.self)
        StubURLProtocol.routes[listingRoute] = (200, Self.notUTF8(text, after: "<KeyCount>"))
        let fetch = try await service().fetchPMCOpenDataXML(pmcid: pmcid)
        XCTAssertEqual(fetch, .unreachable(.malformedResponse))
        XCTAssertFalse(StubURLProtocol.requested(metadataRoute))
    }

    func testARecordThatIsNotUTF8IsMalformed() async throws {
        routeBucket()
        let text = #"{"license_code": "CC BY", "xml_url":"s3://pmc-oa-opendata/PMC10358571.1/PMC10358571.1.xml"}"#
        StubURLProtocol.routes[metadataRoute] = (200, Self.notUTF8(text, after: "CC BY"))
        let fetch = try await service().fetchPMCOpenDataXML(pmcid: pmcid)
        XCTAssertEqual(fetch, .unreachable(.malformedResponse))
        XCTAssertFalse(StubURLProtocol.requested(xmlRoute))
    }

    func testAnArticleThatIsNotUTF8IsMalformed() async throws {
        routeBucket()
        StubURLProtocol.routes[xmlRoute] = (200, Self.notUTF8(fullJATS, after: "We randomised"))
        let fetch = try await service().fetchPMCOpenDataXML(pmcid: pmcid)
        XCTAssertEqual(fetch, .unreachable(.malformedResponse))
    }

    /// An `xml_url` naming another bucket is an answer we cannot read, not
    /// the record saying it has no XML. Its controls are
    /// ``testARecordNamingNoXMLIsAbsent`` and the null row below.
    func testAnXMLURLInAnotherBucketIsMalformedNotAbsent() async throws {
        routeBucket()
        StubURLProtocol.routes[metadataRoute] = (200, Data(
            #"{"xml_url":"s3://some-other-bucket/PMC10358571.1/PMC10358571.1.xml"}"#.utf8))
        let fetch = try await service().fetchPMCOpenDataXML(pmcid: pmcid)
        XCTAssertEqual(fetch, .unreachable(.malformedResponse))
        XCTAssertFalse(StubURLProtocol.requested("some-other-bucket"))
    }

    func testAnXMLURLOfNullIsAbsent() async throws {
        routeBucket()
        StubURLProtocol.routes[metadataRoute] = (200, Data(#"{"xml_url":null}"#.utf8))
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

    // MARK: - Retries

    /// A transient 503 on the listing is retried, as Python's client does,
    /// and the article is served; each attempt still takes a pacing slot.
    func testATransient503IsRetriedAndServed() async throws {
        routeBucket()
        StubURLProtocol.sequences[listingRoute] = [(503, Data())]
        let start = Date()
        let fetch = try await service(bucketAttempts: 3).fetchPMCOpenDataXML(pmcid: pmcid)
        guard case .served = fetch else { return XCTFail("got \(fetch)") }
        XCTAssertEqual(listingRequests(), 2)
        // Four requests (503, listing, record, XML): three paced gaps.
        XCTAssertGreaterThanOrEqual(
            Date().timeIntervalSince(start), 3 * BioMedLitConstants.pmcOpenDataMinimumInterval * 0.9)
    }

    /// A 503 that outlasts its retries reads as that 503, after every attempt.
    func testA503ThatOutlastsItsRetriesIsUnreachable() async throws {
        routeBucket()
        StubURLProtocol.routes[listingRoute] = (503, Data())
        let fetch = try await service(bucketAttempts: 3).fetchPMCOpenDataXML(pmcid: pmcid)
        XCTAssertEqual(fetch, .unreachable(.httpStatus(503)))
        XCTAssertEqual(listingRequests(), 3)
    }

    /// Every step retries: a 429 on the XML, then the article.
    func testAThrottledXMLIsRetried() async throws {
        routeBucket()
        StubURLProtocol.sequences[xmlRoute] = [(429, Data())]
        let fetch = try await service(bucketAttempts: 2).fetchPMCOpenDataXML(pmcid: pmcid)
        guard case .served = fetch else { return XCTFail("got \(fetch)") }
    }

    /// The controls: an answer is not retried. A listing 404 and a 403 are
    /// each unreachable after one request.
    func testAnAnswerIsNotRetried() async throws {
        for (status, expected) in [(404, PMCOpenDataFetch.unreachable(.httpStatus(404))),
                                   (403, .unreachable(.httpStatus(403)))] {
            StubURLProtocol.reset()
            StubURLProtocol.routes[listingRoute] = (status, Data())
            let fetch = try await service(bucketAttempts: 3).fetchPMCOpenDataXML(pmcid: pmcid)
            XCTAssertEqual(fetch, expected, "\(status)")
            XCTAssertEqual(listingRequests(), 1, "\(status)")
        }
    }

    /// Production's default makes four attempts, as Python's does; the
    /// backoff between them is BioMedLit's own.
    func testTheDefaultPolicyMakesPythonsAttempts() {
        XCTAssertEqual(RetryConfiguration.pmcOpenData.maxAttempts, 4)
        XCTAssertEqual(RetryConfiguration.pmcOpenData.initialDelay, 1)
        XCTAssertEqual(RetryConfiguration.pmcOpenData.backoffMultiplier, 2)
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
