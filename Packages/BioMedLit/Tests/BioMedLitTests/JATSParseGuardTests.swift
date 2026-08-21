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

/// Tests that a failed parse announces itself rather than returning an empty
/// article, and that an empty typed identifier does not latch.
final class JATSParseGuardTests: XCTestCase {

    // MARK: - Empty result

    /// `parseToMarkdown` and `parseToHTML` both refuse an empty result. Without
    /// the same guard, `parseToArticle` returned a well-formed article with no
    /// title, no authors and no body — indistinguishable from a publisher stub,
    /// which is how a 57%-of-articles author loss went unobserved.
    func testAnEmptyArticleThrowsRatherThanReturningAnEmptyResult() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <article><front><article-meta></article-meta></front><body></body></article>
        """
        XCTAssertThrowsError(try JATSXMLParser(data: Data(xml.utf8)).parseToArticle()) { error in
            guard case JATSParseError.noContent = error else {
                return XCTFail("expected .noContent, got \(error)")
            }
        }
    }

    /// A title alone is content: some deposits carry metadata and no body, and
    /// refusing those would be its own kind of data loss.
    func testAnArticleWithOnlyATitleIsStillReturned() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <article><front><article-meta>
          <title-group><article-title>Metadata only</article-title></title-group>
        </article-meta></front><body></body></article>
        """
        let article = try JATSXMLParser(data: Data(xml.utf8)).parseToArticle()
        XCTAssertEqual(article.title, "Metadata only")
    }

    // MARK: - Empty typed identifiers

    private func parseIds(_ ids: String, knownPMCId: String? = nil) throws -> JATSArticle {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <article><front><article-meta>
        \(ids)
          <title-group><article-title>T</article-title></title-group>
        </article-meta></front><body><sec><p>Prose.</p></sec></body></article>
        """
        let parser = knownPMCId.map { JATSXMLParser(data: Data(xml.utf8), knownPMCId: $0) }
            ?? JATSXMLParser(data: Data(xml.utf8))
        return try parser.parseToArticle()
    }

    /// An empty typed element stored an empty DOI *and* latched the flag that
    /// stops pattern matching recovering a real one later in the document.
    func testAnEmptyTypedDOIDoesNotBlockRecovery() throws {
        let article = try parseIds("""
          <article-id pub-id-type="doi"></article-id>
          <article-id>10.1371/journal.pgen.1012008</article-id>
        """)

        XCTAssertEqual(article.doi, "10.1371/journal.pgen.1012008")
    }

    func testAnEmptyTypedPMCIdDoesNotBlockRecovery() throws {
        let article = try parseIds("""
          <article-id pub-id-type="pmc"></article-id>
          <article-id>PMC12759138</article-id>
        """)

        XCTAssertEqual(article.pmcId, "PMC12759138")
    }

    /// The typed value still wins when it is actually present.
    func testATypedDOIStillBeatsAPublisherId() throws {
        let article = try parseIds("""
          <article-id pub-id-type="publisher-id">10.1177_20552076251406653</article-id>
          <article-id pub-id-type="doi">10.1177/20552076251406653</article-id>
        """)

        XCTAssertEqual(article.doi, "10.1177/20552076251406653")
    }

    /// A caller-supplied PMC ID still wins over the document's.
    func testKnownPMCIdStillWins() throws {
        let article = try parseIds("""
          <article-id pub-id-type="pmc">PMC9999999</article-id>
        """, knownPMCId: "PMC12759138")

        XCTAssertEqual(article.pmcId, "PMC12759138")
    }
}
