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

/// Serves canned E-utilities answers and records every request in full.
///
/// Unlike ``RecordingURLProtocol``, which keeps only URLs, this keeps method,
/// headers and body, because the subject is where the API key travels.
final class EutilsRecordingURLProtocol: URLProtocol {
    /// One request as the transport saw it.
    struct Recorded {
        /// The URL requested.
        let url: URL
        /// The HTTP method.
        let method: String?
        /// The `Content-Type` header, if any.
        let contentType: String?
        /// The request body, read from its stream.
        let body: Data
    }

    /// How the stub answers one request.
    enum Reply {
        /// A 200 with this body.
        case ok(Data)
        /// An empty response with this status.
        case status(Int)
        /// A redirect with this status to this location.
        case redirect(Int, to: URL)
    }

    /// Size of each read from a request's body stream.
    private static let bodyReadChunkSize = 4096

    /// Every request made through this protocol, in order.
    nonisolated(unsafe) static var recorded: [Recorded] = []

    /// Chooses the reply, given the request and how many earlier requests went
    /// to the same path.
    nonisolated(unsafe) static var reply: (URLRequest, Int) -> Reply = { _, _ in .status(404) }

    /// Forget recorded requests and restore the default reply.
    static func reset() {
        recorded = []
        reply = { _, _ in .status(404) }
    }

    /// A session whose every request is served by this protocol.
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [EutilsRecordingURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// Serve every request, whatever its scheme or host.
    override class func canInit(with request: URLRequest) -> Bool { true }

    /// Leave the request as it is, so what is recorded is what was sent.
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// Record the request, then answer it as ``reply`` says.
    override func startLoading() {
        guard let url = request.url else { return }
        let earlier = Self.recorded.filter { $0.url.path == url.path }.count
        Self.recorded.append(Recorded(
            url: url,
            method: request.httpMethod,
            contentType: request.value(forHTTPHeaderField: EutilsRequest.contentTypeHeader),
            body: Self.body(of: request)
        ))

        switch Self.reply(request, earlier) {
        case .ok(let data):
            finish(url: url, statusCode: BioMedLitConstants.httpStatusOK, headers: [:], body: data)
        case .status(let statusCode):
            finish(url: url, statusCode: statusCode, headers: [:], body: Data())
        case .redirect(let statusCode, let location):
            let response = HTTPURLResponse(
                url: url, statusCode: statusCode, httpVersion: "HTTP/1.1",
                headerFields: ["Location": location.absoluteString]
            )!
            var redirected = request
            redirected.url = location
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            // Reached as the task's result only if the redirect is declined;
            // following it stops this protocol and starts a new request instead.
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    /// Nothing to cancel: every answer is delivered synchronously.
    override func stopLoading() {}

    /// Deliver a complete response.
    private func finish(url: URL, statusCode: Int, headers: [String: String], body: Data) {
        let response = HTTPURLResponse(
            url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    /// The body of a request as a protocol receives it.
    ///
    /// `URLSession` hands a protocol the body as `httpBodyStream`, not
    /// `httpBody`, so reading only the property would record every body empty.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: bodyReadChunkSize)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// The NCBI API key reaches NCBI and nothing else (#243, the Swift half of #196).
///
/// A query string is part of the URL, and a URL is what gets printed: this
/// service logged it at debug level as a public value in release builds, and a
/// `URLError` carries it in its `userInfo`. So the key must travel in a POST
/// body, and because a body is re-sent by a 307 or 308, a redirect must be
/// refused rather than followed.
final class PubMedCredentialConfinementTests: RecordingLoggerTestCase {
    /// A key shaped like a real one, distinctive enough to find anywhere.
    private let apiKey = "0123456789abcdef0123456789abcdef0123"

    /// The contact address sent with each request.
    private let email = "researcher@example.org"

    /// A host that is not NCBI, where a followed redirect would land.
    private let elsewhere = URL(string: "https://collector.example/eutils")!

    /// Start each test with no recorded requests and the default reply.
    override func setUp() {
        super.setUp()
        EutilsRecordingURLProtocol.reset()
    }

    /// Leave the stub's shared state clean for the next test class.
    override func tearDown() {
        EutilsRecordingURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Fixtures

    /// A service whose requests go to the recording stub.
    private func service(apiKey: String?) -> PubMedService {
        PubMedService(email: email, apiKey: apiKey, session: EutilsRecordingURLProtocol.session())
    }

    /// An esearch answer naming one PMID.
    private let searchAnswer = Data(#"{"esearchresult":{"count":"1","idlist":["12345"]}}"#.utf8)

    /// An efetch answer for that PMID.
    private let fetchAnswer = Data("""
        <PubmedArticleSet><PubmedArticle><MedlineCitation><PMID>12345</PMID>\
        <Article><ArticleTitle>A title</ArticleTitle></Article></MedlineCitation>\
        </PubmedArticle></PubmedArticleSet>
        """.utf8)

    /// Answer esearch and efetch as NCBI would for a one-article search.
    private func serveOneArticle() {
        let searchAnswer = searchAnswer
        let fetchAnswer = fetchAnswer
        EutilsRecordingURLProtocol.reply = { request, _ in
            request.url?.lastPathComponent == "esearch.fcgi" ? .ok(searchAnswer) : .ok(fetchAnswer)
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

        XCTAssertFalse(logger.recorded.isEmpty, "nothing was logged, so nothing was checked")
        for line in logger.recorded {
            XCTAssertFalse(line.contains(apiKey), "logged the key: \(line)")
        }
    }

    // MARK: - Redirects

    /// The stub can make the transport follow a redirect.
    ///
    /// Without this control, the refusal test below would pass just as well if
    /// the stub's redirect never reached the transport at all.
    func testTheHarnessCanObserveAFollowedRedirect() async throws {
        let elsewhere = elsewhere
        EutilsRecordingURLProtocol.reply = { request, _ in
            request.url?.host == elsewhere.host ? .status(BioMedLitConstants.httpStatusOK) : .redirect(307, to: elsewhere)
        }
        var request = URLRequest(url: URL(string: BioMedLitConstants.pubmedSearchURL)!)
        request.httpMethod = "POST"

        _ = try await EutilsRecordingURLProtocol.session().data(for: request)

        XCTAssertEqual(
            EutilsRecordingURLProtocol.recorded.map { $0.url.host },
            [URL(string: BioMedLitConstants.pubmedSearchURL)!.host, elsewhere.host]
        )
    }

    /// A redirect fails the request and is not followed, whatever its status.
    ///
    /// 307 and 308 would re-send the body, key included, to the new host; 301,
    /// 302 and 303 would re-send the request as a GET without its parameters.
    func testARedirectIsRefusedNotFollowed() async throws {
        for statusCode in [301, 302, 303, 307, 308] {
            EutilsRecordingURLProtocol.reset()
            logger.reset()
            let elsewhere = elsewhere
            EutilsRecordingURLProtocol.reply = { _, _ in .redirect(statusCode, to: elsewhere) }

            do {
                _ = try await service(apiKey: apiKey).search(query: "aspirin")
                XCTFail("HTTP \(statusCode): a redirect should fail the search")
            } catch PubMedError.redirectRefused(let refused) {
                XCTAssertEqual(refused, statusCode)
            } catch {
                XCTFail("HTTP \(statusCode): expected redirectRefused, got \(error)")
            }

            let hosts = EutilsRecordingURLProtocol.recorded.map { $0.url.host }
            XCTAssertEqual(hosts, ["eutils.ncbi.nlm.nih.gov"], "HTTP \(statusCode) was followed")
            XCTAssertEqual(logger.errors.count, 1, "HTTP \(statusCode): \(logger.recorded)")
        }
    }

    // MARK: - One sender for both requests

    /// A server error on the fetch is retried, as it always was on the search.
    ///
    /// Before both requests shared one sender, the fetch reported a 429 or 503
    /// as a final, non-retryable `httpError`.
    func testAFetchThatMeetsAServerErrorIsRetried() async throws {
        let searchAnswer = searchAnswer
        let fetchAnswer = fetchAnswer
        EutilsRecordingURLProtocol.reply = { request, earlier in
            if request.url?.lastPathComponent == "esearch.fcgi" { return .ok(searchAnswer) }
            return earlier == 0 ? .status(503) : .ok(fetchAnswer)
        }

        let result = try await service(apiKey: apiKey).search(query: "aspirin")

        XCTAssertEqual(result.articles.map(\.pmid), ["12345"])
        XCTAssertEqual(
            EutilsRecordingURLProtocol.recorded.map(\.url.lastPathComponent),
            ["esearch.fcgi", "efetch.fcgi", "efetch.fcgi"]
        )
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
