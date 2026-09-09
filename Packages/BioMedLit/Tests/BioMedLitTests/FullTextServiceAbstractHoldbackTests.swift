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

/// An abstract-only Europe PMC deposit used to win the chain outright: it
/// parses, it renders, and nothing said it was not an article. It was then
/// cached and handed to the transparency analyzer as an article body.
final class FullTextServiceAbstractHoldbackTests: XCTestCase {
    private static let withBody = Data("""
    <article><front><article-meta>
      <title-group><article-title>A trial</article-title></title-group>
      <abstract><p>Background.</p></abstract>
    </article-meta></front>
    <body><sec><title>Methods</title><p>We enrolled 120 patients.</p></sec></body>
    </article>
    """.utf8)

    private static let bodyless = Data("""
    <article><front><article-meta>
      <title-group><article-title>A trial</article-title></title-group>
      <abstract><p>Background and findings only.</p></abstract>
    </article-meta></front></article>
    """.utf8)

    private func makeService() -> FullTextService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return FullTextService(email: "test@example.org", session: URLSession(configuration: config))
    }

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testAnArticleWithABodyIsReportedAsFulltext() async throws {
        StubURLProtocol.stubbed = (200, Self.withBody)
        let result = try await makeService().fetchFullText(pmcId: "PMC1", doi: nil, pmid: "1")
        XCTAssertEqual(result.source, .europePMC)
        XCTAssertEqual(result.contentKind, .fulltext)
    }

    /// The abstract is still returned when nothing better exists — the reader
    /// gets what there is — but it is labelled, which is what stops it being
    /// analysed as an article.
    func testABodylessDepositIsReturnedAsAnAbstract() async throws {
        StubURLProtocol.stubbed = (200, Self.bodyless)
        let result = try await makeService().fetchFullText(pmcId: "PMC1", doi: nil, pmid: "1")
        XCTAssertEqual(result.source, .europePMC)
        XCTAssertEqual(result.contentKind, .abstract)
        XCTAssertNotNil(result.markdown)
    }
}
