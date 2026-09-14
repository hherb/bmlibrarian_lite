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

/// The NCBI API key reaches NCBI and nothing else (#243, the Swift half of #196).
///
/// A query string is part of the URL, and a URL is what gets printed: this
/// service logged it at debug level as a public value in release builds, and a
/// `URLError` carries it in its `userInfo`. So the key must travel in a POST
/// body, and because a body is re-sent by a 307 or 308, a redirect must be
/// refused rather than followed.
final class PubMedCredentialConfinementTests: EutilsStubTestCase {
    /// A key shaped like a real one, distinctive enough to find anywhere.
    private let apiKey = "0123456789abcdef0123456789abcdef0123"

    /// The contact address sent with each request.
    private let email = "researcher@example.org"

    // MARK: - Fixtures

    /// A service whose requests go to the recording stub.
    private func service(apiKey: String?) -> PubMedService {
        PubMedService(email: email, apiKey: apiKey, session: EutilsRecordingURLProtocol.session())
    }

    /// Answer esearch and efetch as NCBI would for a one-article search.
    private func serveOneArticle() {
        EutilsRecordingURLProtocol.reply = { request, _ in
            request.url?.lastPathComponent == "esearch.fcgi"
                ? .ok(EutilsFixture.searchAnswer)
                : .ok(EutilsFixture.fetchAnswer)
        }
    }

    /// Decode a form-encoded body into its pairs, in order.
    private func formFields(_ body: Data) -> [(name: String, value: String)] {
        let text = String(decoding: body, as: UTF8.self)
        guard !text.isEmpty else { return [] }
        return text.split(separator: "&").map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let decode = { (part: Substring) in
                String(part).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? ""
            }
            return (decode(parts[0]), parts.count > 1 ? decode(parts[1]) : "")
        }
    }

    /// The value of the first field with this name.
    private func field(_ name: String, in body: Data) -> String? {
        formFields(body).first { $0.name == name }?.value
    }

    /// Fail the test for every recorded log line that names the key.
    private func assertNoLogLineCarriesTheKey(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(logger.recorded.isEmpty, "nothing was logged, so nothing was checked", file: file, line: line)
        for logged in logger.recorded {
            XCTAssertFalse(logged.contains(apiKey), "logged the key: \(logged)", file: file, line: line)
        }
    }

    // MARK: - Where the key travels

    /// Both requests of a search carry the key in the body and nowhere in the URL.
    func testTheKeyTravelsInTheBodyOfEveryRequestAndInNoURL() async throws {
        serveOneArticle()

        let result = try await service(apiKey: apiKey).search(query: "aspirin")

        XCTAssertEqual(result.articles.map(\.pmid), ["12345"])
        let requests = EutilsRecordingURLProtocol.recorded
        XCTAssertEqual(requests.map(\.url.lastPathComponent), ["esearch.fcgi", "efetch.fcgi"])
        for request in requests {
            let name = request.url.lastPathComponent
            XCTAssertNil(request.url.query, "\(name) carried a query string")
            XCTAssertFalse(request.url.absoluteString.contains(apiKey), "\(name) URL carried the key")
            XCTAssertEqual(request.method, "POST", name)
            XCTAssertEqual(request.contentType, EutilsRequest.formContentType, name)
            XCTAssertEqual(field("api_key", in: request.body), apiKey, "\(name) body lacked the key")
            XCTAssertEqual(field("email", in: request.body), email, name)
        }
    }

    /// The search's own parameters arrive intact beside the credentials.
    func testTheSearchParametersArriveInTheBody() async throws {
        serveOneArticle()

        _ = try await service(apiKey: apiKey).search(query: "aspirin", maxResults: 7, offset: 14)

        let requests = EutilsRecordingURLProtocol.recorded
        let search = try XCTUnwrap(requests.first { $0.url.lastPathComponent == "esearch.fcgi" })
        XCTAssertEqual(field("db", in: search.body), "pubmed")
        XCTAssertEqual(field("term", in: search.body), "aspirin")
        XCTAssertEqual(field("retmax", in: search.body), "7")
        XCTAssertEqual(field("retstart", in: search.body), "14")
        XCTAssertEqual(field("retmode", in: search.body), "json")
        let fetch = try XCTUnwrap(requests.first { $0.url.lastPathComponent == "efetch.fcgi" })
        XCTAssertEqual(field("id", in: fetch.body), "12345")
    }

    /// A query full of form delimiters reaches NCBI as the user wrote it.
    ///
    /// Unescaped, `+` would arrive as a space and `&retmax=1` would become a
    /// parameter the user never sent.
    func testAQueryWithFormDelimitersArrivesVerbatim() async throws {
        serveOneArticle()
        let query = #"C++ & "x=y" #1 100% [tiab] ß→é&retmax=1"#

        _ = try await service(apiKey: apiKey).search(query: query)

        let search = try XCTUnwrap(EutilsRecordingURLProtocol.recorded.first)
        XCTAssertEqual(field("term", in: search.body), query)
        XCTAssertEqual(formFields(search.body).filter { $0.name == "retmax" }.count, 1)
    }

    /// Without a key, no `api_key` parameter is sent at all, not even an empty one.
    func testNoKeyMeansNoKeyParameter() async throws {
        for missing in [nil, ""] as [String?] {
            EutilsRecordingURLProtocol.reset()
            serveOneArticle()

            _ = try await service(apiKey: missing).search(query: "aspirin")

            for request in EutilsRecordingURLProtocol.recorded {
                XCTAssertNil(field("api_key", in: request.body), "key \(String(describing: missing))")
            }
        }
    }

    // MARK: - What gets printed

    /// Nothing the service logs on a search, successful or failed, names the key.
    func testNoLogLineCarriesTheKey() async throws {
        serveOneArticle()
        _ = try await service(apiKey: apiKey).search(query: "aspirin")

        EutilsRecordingURLProtocol.reply = { _, _ in .status(403) }
        do {
            _ = try await service(apiKey: apiKey).search(query: "aspirin")
            XCTFail("a 403 should fail the search")
        } catch {
            XCTAssertFalse("\(error)".contains(apiKey), "the error carried the key")
            XCTAssertFalse(error.localizedDescription.contains(apiKey), "the error carried the key")
        }

        assertNoLogLineCarriesTheKey()
    }

    /// A failed answer whose body echoes the key leaves the key unprinted.
    ///
    /// NCBI's HTTP 400 for a bad key repeats the key in its body, so the body of
    /// a failed answer must never reach an error or a log line.
    func testAFailedAnswerThatEchoesTheKeyPrintsNoKey() async throws {
        let echo = Data(#"{"error":"API key invalid","api-key":"\#(apiKey)"}"#.utf8)
        EutilsRecordingURLProtocol.reply = { _, _ in .status(400, body: echo) }

        do {
            _ = try await service(apiKey: apiKey).search(query: "aspirin")
            XCTFail("a 400 should fail the search")
        } catch {
            XCTAssertFalse("\(error)".contains(apiKey), "the error carried the key")
            XCTAssertFalse(error.localizedDescription.contains(apiKey), "the error carried the key")
            guard case PubMedError.httpError(statusCode: 400) = error else {
                return XCTFail("expected httpError(400), got \(error)")
            }
        }

        assertNoLogLineCarriesTheKey()
    }

    // MARK: - Redirects

    /// The stub can make the transport follow a redirect.
    ///
    /// Without this control, the refusal tests below would pass just as well if
    /// the stub's redirect never reached the transport at all.
    func testTheHarnessCanObserveAFollowedRedirect() async throws {
        EutilsRecordingURLProtocol.reply = { request, _ in
            request.url?.host == EutilsFixture.elsewhere.host
                ? .status(BioMedLitConstants.httpStatusOK)
                : .redirect(307, to: EutilsFixture.elsewhere)
        }
        var request = URLRequest(url: URL(string: BioMedLitConstants.pubmedSearchURL)!)
        request.httpMethod = "POST"

        _ = try await EutilsRecordingURLProtocol.session().data(for: request)

        XCTAssertEqual(
            EutilsRecordingURLProtocol.recorded.map { $0.url.host },
            [EutilsFixture.ncbiHost, EutilsFixture.elsewhere.host]
        )
    }

    /// A redirect fails the search and is not followed, whatever its status.
    ///
    /// 307 and 308 would re-send the body, key included, to the new host; 301,
    /// 302 and 303 would re-send the request as a GET without its parameters.
    func testARedirectIsRefusedNotFollowed() async throws {
        for statusCode in [301, 302, 303, 307, 308] {
            EutilsRecordingURLProtocol.reset()
            logger.reset()
            EutilsRecordingURLProtocol.reply = { _, _ in .redirect(statusCode, to: EutilsFixture.elsewhere) }

            await assertRedirectRefused(statusCode)

            let hosts = EutilsRecordingURLProtocol.recorded.map { $0.url.host }
            XCTAssertEqual(hosts, [EutilsFixture.ncbiHost], "HTTP \(statusCode) was followed")
            XCTAssertEqual(logger.errors.count, 1, "HTTP \(statusCode): \(logger.recorded)")
        }
    }

    /// A redirect on the fetch is refused as well as one on the search.
    ///
    /// The refusal is passed per request, so a fetch that stopped going through
    /// the shared sender would silently lose it and follow a 307 with the key.
    func testARedirectOnTheFetchIsRefusedNotFollowed() async throws {
        for statusCode in [301, 302, 303, 307, 308] {
            EutilsRecordingURLProtocol.reset()
            EutilsRecordingURLProtocol.reply = { request, _ in
                request.url?.lastPathComponent == "esearch.fcgi"
                    ? .ok(EutilsFixture.searchAnswer)
                    : .redirect(statusCode, to: EutilsFixture.elsewhere)
            }

            await assertRedirectRefused(statusCode)

            let requests = EutilsRecordingURLProtocol.recorded
            XCTAssertEqual(
                requests.map(\.url.lastPathComponent), ["esearch.fcgi", "efetch.fcgi"],
                "HTTP \(statusCode) on the fetch"
            )
            XCTAssertEqual(
                requests.map { $0.url.host }, [EutilsFixture.ncbiHost, EutilsFixture.ncbiHost],
                "HTTP \(statusCode) on the fetch was followed"
            )
        }
    }

    /// Run a search that must fail with ``PubMedError/redirectRefused(statusCode:)``.
    private func assertRedirectRefused(
        _ statusCode: Int, file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await service(apiKey: apiKey).search(query: "aspirin")
            XCTFail("HTTP \(statusCode): a redirect should fail the search", file: file, line: line)
        } catch PubMedError.redirectRefused(let refused) {
            XCTAssertEqual(refused, statusCode, file: file, line: line)
        } catch {
            XCTFail("HTTP \(statusCode): expected redirectRefused, got \(error)", file: file, line: line)
        }
    }

    // MARK: - One sender for both requests

    /// A server error on the fetch is retried, as it always was on the search.
    ///
    /// Before both requests shared one sender, the fetch reported a 429 or 503
    /// as a final, non-retryable `httpError`.
    func testAFetchThatMeetsAServerErrorIsRetried() async throws {
        EutilsRecordingURLProtocol.reply = { request, earlier in
            if request.url?.lastPathComponent == "esearch.fcgi" { return .ok(EutilsFixture.searchAnswer) }
            return earlier == 0 ? .status(503) : .ok(EutilsFixture.fetchAnswer)
        }

        let result = try await service(apiKey: apiKey).search(query: "aspirin")

        XCTAssertEqual(result.articles.map(\.pmid), ["12345"])
        XCTAssertEqual(
            EutilsRecordingURLProtocol.recorded.map(\.url.lastPathComponent),
            ["esearch.fcgi", "efetch.fcgi", "efetch.fcgi"]
        )
    }

    /// A 429 that outlasts every retry is reported as rate limiting.
    ///
    /// It was reported as a server error whose text promised a retry that had
    /// already run out.
    func testARateLimitThatPersistsIsReportedAsRateLimited() async throws {
        EutilsRecordingURLProtocol.reply = { _, _ in .status(BioMedLitConstants.httpStatusRateLimited) }

        do {
            _ = try await service(apiKey: apiKey).search(query: "aspirin")
            XCTFail("a persistent 429 should fail the search")
        } catch PubMedError.rateLimited {
            XCTAssertEqual(
                EutilsRecordingURLProtocol.recorded.count, RetryConfiguration.networkDefault.maxAttempts,
                "a 429 is retried"
            )
        } catch {
            XCTFail("expected rateLimited, got \(error)")
        }
    }

    /// A final server error does not promise a retry.
    func testAServerErrorDescriptionPromisesNoRetry() throws {
        let description = try XCTUnwrap(PubMedError.serverError(statusCode: 503).errorDescription)

        XCTAssertFalse(description.contains("Retrying"), description)
        XCTAssertTrue(description.contains("503"), description)
    }
}

/// The form serializer every E-utilities body goes through.
final class EutilsRequestFormEncodingTests: XCTestCase {
    /// Letters, digits and `*-._` are left alone.
    func testUnreservedCharactersAreKept() {
        XCTAssertEqual(EutilsRequest.formEncode("AZaz09*-._"), "AZaz09*-._")
    }

    /// A space becomes `+`, and a literal `+` is escaped so it cannot read as one.
    func testSpaceAndPlusAreDistinguished() {
        XCTAssertEqual(EutilsRequest.formEncode("a b+c"), "a+b%2Bc")
    }

    /// The delimiters that would split or end a field are escaped.
    func testDelimitersAreEscaped() {
        XCTAssertEqual(EutilsRequest.formEncode("&=#%?/"), "%26%3D%23%25%3F%2F")
    }

    /// Non-ASCII text is escaped byte by byte from its UTF-8 encoding.
    func testNonASCIIIsEscapedAsUTF8() {
        XCTAssertEqual(EutilsRequest.formEncode("é"), "%C3%A9")
    }

    /// Pairs are joined in order with `&`, name and value each encoded.
    func testPairsAreJoinedInOrder() {
        let body = EutilsRequest.formEncodedBody([
            (name: "term", value: "a&b"),
            (name: "api_key", value: "k=1")
        ])
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "term=a%26b&api_key=k%3D1")
    }

    /// The request is a POST to the endpoint as given, the body in form encoding.
    func testThePostCarriesNoQuery() throws {
        let endpoint = try XCTUnwrap(URL(string: BioMedLitConstants.pubmedFetchURL))

        let request = EutilsRequest.post(to: endpoint, parameters: [(name: "api_key", value: "secret")])

        XCTAssertEqual(request.url, endpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: EutilsRequest.contentTypeHeader),
            EutilsRequest.formContentType
        )
        XCTAssertEqual(request.httpBody, Data("api_key=secret".utf8))
    }
}
