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


import Foundation
import XCTest
@testable import BioMedLit

/// A failed PubMed request is never an empty page (#255, #256).
///
/// E-utilities reports some failures inside an HTTP 200, and every one of them
/// used to read as a search that matched nothing: the app then said "No results
/// found" about a source that had not answered.
final class PubMedSearchFailureTests: EutilsStubTestCase {
    /// A service whose requests go to the recording stub.
    private func service() -> PubMedService {
        PubMedService(email: "researcher@example.org", session: EutilsRecordingURLProtocol.session())
    }

    /// Answer esearch with this body, and efetch with this one.
    private func serve(searchAnswer: String, fetchAnswer: Data = EutilsFixture.fetchAnswer) {
        let searchData = Data(searchAnswer.utf8)
        EutilsRecordingURLProtocol.reply = { request, _ in
            request.url?.lastPathComponent == "efetch.fcgi" ? .ok(fetchAnswer) : .ok(searchData)
        }
    }

    /// Run a search that must fail, and return why.
    private func failedSearch(
        maxResults: Int = 10,
        offset: Int = 0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> RequestFailure? {
        do {
            _ = try await service().search(query: "aspirin", maxResults: maxResults, offset: offset)
            XCTFail("the search should have failed", file: file, line: line)
            return nil
        } catch let failed as SourceRequestError {
            XCTAssertEqual(failed.source, .pubmed, file: file, line: line)
            return failed.failure
        } catch {
            XCTFail("expected a source failure, got \(error)", file: file, line: line)
            return nil
        }
    }

    // MARK: - An error inside an HTTP 200

    /// An `ERROR` in esearch's answer is a failed search, not a search that matched nothing.
    func testAnEsearchErrorIsAFailedSearch() async {
        serve(searchAnswer: #"{"esearchresult":{"ERROR":"Search Backend failed: Search is temporarily unavailable."}}"#)

        let failure = await failedSearch()

        XCTAssertEqual(failure, .serviceError)
    }

    /// The `ERROR` text is never logged: it can repeat the request.
    func testTheEsearchErrorTextIsNeverLogged() async {
        let secret = "Search Backend failed: term=NEVERPRINTED"
        serve(searchAnswer: #"{"esearchresult":{"ERROR":"\#(secret)"}}"#)

        _ = await failedSearch()

        XCTAssertFalse(logger.recorded.contains { $0.contains("NEVERPRINTED") }, "\(logger.recorded)")
        XCTAssertEqual(logger.errors.count, 1, "\(logger.recorded)")
    }

    /// An `ERROR` text holding a raw newline is still a service error.
    ///
    /// Checked live on 2026-09-15, past the 9,999-record cap: strict JSON
    /// refuses the answer, which would have reported "the response could not be
    /// read" for a failure NCBI had described.
    func testAnErrorTextWithARawNewlineIsStillAServiceError() async {
        serve(searchAnswer: "{\"esearchresult\":{\"ERROR\":\"Search Backend failed:\nretstart too large\"}}")

        let failure = await failedSearch()

        XCTAssertEqual(failure, .serviceError)
    }

    /// An efetch error document costs the page's PMIDs, not the search.
    func testAnEfetchErrorDocumentCostsThePagesPMIDs() async throws {
        serve(
            searchAnswer: #"{"esearchresult":{"count":"2","idlist":["1","2"]}}"#,
            fetchAnswer: Data("<eFetchResult><ERROR>Empty id list</ERROR></eFetchResult>".utf8)
        )

        let result = try await service().search(query: "aspirin", maxResults: 2)

        XCTAssertEqual(result.articles, [])
        XCTAssertEqual(
            result.shortfalls,
            [RetrievalShortfall.missingRecords(2, from: .pubmed, failure: .serviceError)].compactMap { $0 }
        )
        XCTAssertFalse(logger.recorded.contains { $0.contains("Empty id list") }, "\(logger.recorded)")
    }

    // MARK: - Answers that cannot be read

    /// An answer that is not esearch's JSON cannot be read.
    func testAnAnswerThatIsNotEsearchsJSONCannotBeRead() async {
        for answer in ["<html>Gateway</html>", #"{"header":{"type":"esearch"}}"#, "[]"] {
            EutilsRecordingURLProtocol.reset()
            serve(searchAnswer: answer)

            let failure = await failedSearch()

            XCTAssertEqual(failure, .malformedResponse, answer)
        }
    }

    /// A listing with no `idlist` of strings cannot be read.
    func testAListingWithoutAnIdListCannotBeRead() async {
        for answer in [
            #"{"esearchresult":{"count":"2"}}"#,
            #"{"esearchresult":{"count":"2","idlist":"12345"}}"#,
            #"{"esearchresult":{"count":"2","idlist":[12345]}}"#
        ] {
            EutilsRecordingURLProtocol.reset()
            serve(searchAnswer: answer)

            let failure = await failedSearch()

            XCTAssertEqual(failure, .malformedResponse, answer)
        }
    }

    /// A count of zero with an empty listing is a search that matched nothing, not a failure.
    func testNoMatchesIsNotAFailure() async throws {
        serve(searchAnswer: #"{"esearchresult":{"count":"0","idlist":[]}}"#)

        let result = try await service().search(query: "aspirin", maxResults: 10)

        XCTAssertEqual(result.totalCount, 0)
        XCTAssertEqual(result.articles, [])
        XCTAssertEqual(result.shortfalls, [])
        XCTAssertNil(result.nextOffset)
        XCTAssertEqual(logger.problems, [])
    }

    // MARK: - A listing that holds less than it counts

    /// A page that lists none of the PMIDs it counts is a failed page.
    func testAPageThatListsNoneOfWhatItCountsIsAFailedPage() async {
        serve(searchAnswer: #"{"esearchresult":{"count":"200","idlist":[]}}"#)

        let failure = await failedSearch(maxResults: 10)

        XCTAssertEqual(failure, .incompleteResponse)
    }

    /// A page that lists some records the rest as missing, and pages on past them.
    func testAPageThatListsSomeRecordsTheRestAsMissing() async throws {
        serve(
            searchAnswer: #"{"esearchresult":{"count":"200","idlist":["12345"]}}"#,
            fetchAnswer: EutilsFixture.fetchAnswer
        )

        let result = try await service().search(query: "aspirin", maxResults: 10, offset: 20)

        XCTAssertEqual(result.articles.map(\.pmid), ["12345"])
        XCTAssertEqual(
            result.shortfalls,
            [RetrievalShortfall.missingRecords(9, from: .pubmed, failure: .incompleteResponse)].compactMap { $0 }
        )
        XCTAssertEqual(result.nextOffset, 30, "the next page starts after the unlisted PMIDs")
    }

    /// Articles efetch could not deliver are missing, and the ones it did are kept.
    func testArticlesTheFetchCouldNotDeliverAreMissing() async throws {
        let brokenOff = Data("""
            <PubmedArticleSet><PubmedArticle><MedlineCitation><PMID>12345</PMID>\
            <Article><ArticleTitle>A title</ArticleTitle></Article></MedlineCitation>\
            </PubmedArticle><PubmedArticle><MedlineCitation><PMID>2
            """.utf8)
        serve(searchAnswer: #"{"esearchresult":{"count":"2","idlist":["12345","2"]}}"#, fetchAnswer: brokenOff)

        let result = try await service().search(query: "aspirin", maxResults: 2)

        XCTAssertEqual(result.articles.map(\.pmid), ["12345"])
        XCTAssertEqual(
            result.shortfalls,
            [RetrievalShortfall.missingRecords(1, from: .pubmed, failure: .malformedResponse)].compactMap { $0 }
        )
    }

    /// A record that closes without a PMID or a title is one record missing.
    func testARecordWithoutAPMIDOrATitleIsMissing() async throws {
        let unreadable = Data("""
            <PubmedArticleSet><PubmedArticle><MedlineCitation><PMID>12345</PMID>\
            <Article><ArticleTitle>A title</ArticleTitle></Article></MedlineCitation></PubmedArticle>\
            <PubmedArticle><MedlineCitation><Article><ArticleTitle>No PMID</ArticleTitle></Article>\
            </MedlineCitation></PubmedArticle></PubmedArticleSet>
            """.utf8)
        serve(searchAnswer: #"{"esearchresult":{"count":"2","idlist":["12345","2"]}}"#, fetchAnswer: unreadable)

        let result = try await service().search(query: "aspirin", maxResults: 2)

        XCTAssertEqual(result.articles.map(\.pmid), ["12345"])
        XCTAssertEqual(result.shortfalls.map(\.recordsMissing), [1])
        XCTAssertEqual(result.shortfalls.map(\.failure), [.malformedResponse])
    }

    // MARK: - The end of what PubMed lists

    /// The last page PubMed can list has no next page (#253).
    func testTheLastListablePageHasNoNextPage() async throws {
        serve(searchAnswer: #"{"esearchresult":{"count":"25000","idlist":["12345"]}}"#)

        let result = try await service().search(
            query: "aspirin", maxResults: 1, offset: SearchPaging.pubMedListableRecords - 1
        )

        XCTAssertEqual(result.totalCount, 25000)
        XCTAssertNil(result.nextOffset, "PubMed lists no record past its cap")
    }

    /// A page past the cap is refused before a request is spent on it.
    func testAPagePastTheCapIsRefusedWithoutARequest() async {
        serve(searchAnswer: #"{"esearchresult":{"count":"25000","idlist":["12345"]}}"#)

        let failure = await failedSearch(maxResults: 1, offset: SearchPaging.pubMedListableRecords)

        XCTAssertEqual(failure, .requestFailed)
        XCTAssertTrue(EutilsRecordingURLProtocol.recorded.isEmpty, "no request was sent")
        XCTAssertEqual(logger.errors.count, 1, "\(logger.recorded)")
    }

    // MARK: - The transport

    /// A request that timed out after its retries is a timeout, not an empty page.
    func testATimeoutIsATimeout() async {
        EutilsRecordingURLProtocol.reply = { _, _ in .transportError(.timedOut) }

        let failure = await failedSearch()

        XCTAssertEqual(failure, .timeout)
        XCTAssertEqual(
            EutilsRecordingURLProtocol.recorded.count, RetryConfiguration.networkDefault.maxAttempts,
            "a timeout is retried"
        )
    }

    /// A connection that could not be made is a failed connection.
    func testAConnectionThatCouldNotBeMadeIsAFailedConnection() async {
        EutilsRecordingURLProtocol.reply = { _, _ in .transportError(.notConnectedToInternet) }

        let failure = await failedSearch()

        XCTAssertEqual(failure, .connection)
    }

    /// A cancelled request is the user's doing, not a source that failed.
    func testACancelledRequestIsNotASourceFailure() async {
        EutilsRecordingURLProtocol.reply = { _, _ in .transportError(.cancelled) }

        do {
            _ = try await service().search(query: "aspirin")
            XCTFail("a cancelled request should not return a page")
        } catch is CancellationError {
            // Expected: nothing is recorded as missing
        } catch {
            XCTFail("expected cancellation, got \(error)")
        }
    }

    /// Cancelling while efetch is in flight loses no record either.
    ///
    /// The esearch leg succeeds, so this reaches the fetch's own catch — which
    /// catches everything in order to report a page that holds no article. A
    /// cancellation caught there would tell the user PubMed lost the page's
    /// records, for a request they themselves stopped (#256).
    func testACancelledFetchIsNotASourceFailure() async {
        EutilsRecordingURLProtocol.reply = { request, _ in
            if request.url?.lastPathComponent == "efetch.fcgi" {
                return .transportError(.cancelled)
            }
            return .ok(Data(#"{"esearchresult":{"count":"2","idlist":["12345","67890"]}}"#.utf8))
        }

        do {
            _ = try await service().search(query: "aspirin", maxResults: 2)
            XCTFail("a cancelled fetch should not return a page")
        } catch is CancellationError {
            // Expected: nothing is recorded as missing
        } catch {
            XCTFail("expected cancellation, got \(error)")
        }
    }

    /// An empty article set is NCBI's answer for PMIDs it does not hold.
    ///
    /// One of the three answers the contract says must keep reading as empty. It
    /// costs no record: NCBI answered, it simply holds nothing for them. Counting
    /// them as missing would put a full page's `malformed_response` clause in the
    /// report every time a PMID has no article.
    func testAnEmptyArticleSetLosesNoRecord() async throws {
        serve(
            searchAnswer: #"{"esearchresult":{"count":"2","idlist":["12345","67890"]}}"#,
            fetchAnswer: Data("<PubmedArticleSet></PubmedArticleSet>".utf8)
        )

        let result = try await service().search(query: "aspirin", maxResults: 2)

        XCTAssertTrue(result.articles.isEmpty)
        XCTAssertTrue(result.shortfalls.isEmpty, "NCBI answered; it holds no article for those PMIDs")
    }
}
