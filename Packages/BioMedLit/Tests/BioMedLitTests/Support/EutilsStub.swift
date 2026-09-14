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
///
/// Its state is static and unlocked, so it relies on the same one-test-at-a-time
/// execution as ``RecordingLoggerTestCase``, which explains that assumption.
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
        /// A response with this status and body, empty unless given.
        case status(Int, body: Data = Data())
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
            finish(url: url, statusCode: BioMedLitConstants.httpStatusOK, body: data)
        case .status(let statusCode, let body):
            finish(url: url, statusCode: statusCode, body: body)
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
    private func finish(url: URL, statusCode: Int, body: Data) {
        let response = HTTPURLResponse(
            url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: [:]
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

/// Canned E-utilities answers for a one-article search.
enum EutilsFixture {
    /// An esearch answer naming one PMID.
    static let searchAnswer = Data(#"{"esearchresult":{"count":"1","idlist":["12345"]}}"#.utf8)

    /// An efetch answer for that PMID.
    static let fetchAnswer = Data("""
        <PubmedArticleSet><PubmedArticle><MedlineCitation><PMID>12345</PMID>\
        <Article><ArticleTitle>A title</ArticleTitle></Article></MedlineCitation>\
        </PubmedArticle></PubmedArticleSet>
        """.utf8)

    /// A host that is not NCBI, where a followed redirect would land.
    static let elsewhere = URL(string: "https://collector.example/eutils")!

    /// The host every E-utilities request is meant for.
    static let ncbiHost = URL(string: BioMedLitConstants.pubmedSearchURL)!.host
}

/// A test case whose requests go to a freshly reset ``EutilsRecordingURLProtocol``
/// and whose library diagnostics are recorded.
class EutilsStubTestCase: RecordingLoggerTestCase {
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
}
