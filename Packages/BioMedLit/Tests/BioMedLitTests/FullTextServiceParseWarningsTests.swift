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

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, body) = Self.stubbed
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
    private func service(serving body: String, status: Int = 200) -> FullTextService {
        StubURLProtocol.stubbed = (status, Data(body.utf8))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return FullTextService(email: "test@example.com", session: URLSession(configuration: config))
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

        guard case .europePMC(_, _, let warnings) = result else {
            return XCTFail("expected a Europe PMC result, got \(result)")
        }
        XCTAssertFalse(warnings.isClean, "the reader was shown an accession number and nothing else")
        XCTAssertTrue(
            warnings.diagnostics.contains { $0.contains("no title, abstract or body") },
            "\(warnings.diagnostics)"
        )
    }

    /// The negative control. Without it the assertion above passes just as
    /// happily against a channel that reports every article as truncated.
    func testACompleteArticleCarriesNoWarnings() async throws {
        let result = try await service(serving: Self.completeArticle)
            .fetchFullText(pmcId: "PMC12759138", doi: nil, pmid: "1")

        guard case .europePMC(let html, _, let warnings) = result else {
            return XCTFail("expected a Europe PMC result, got \(result)")
        }
        XCTAssertTrue(html.contains("A whole article"))
        XCTAssertTrue(warnings.isClean, "\(warnings.diagnostics)")
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
}
