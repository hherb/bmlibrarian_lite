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

/// Author extraction across the two `<contrib>` conventions JATS allows.
///
/// `contrib-type="author"` on each `<contrib>` is one; declaring it once on the
/// enclosing `<contrib-group content-type="author">` and leaving the children
/// bare is the other. PLOS uses the second for every article it deposits, so
/// requiring the attribute on the `<contrib>` lost every author it has.
final class JATSContribTests: XCTestCase {

    private func parse(front: String) throws -> JATSArticle {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <article>
          <front><article-meta>
            <title-group><article-title>T</article-title></title-group>
        \(front)
          </article-meta></front>
          <body><p>Prose.</p></body>
        </article>
        """
        return try JATSXMLParser(data: Data(xml.utf8)).parseToArticle()
    }

    /// The convention the parser already handled.
    func testContribTypeOnEachContrib() throws {
        let article = try parse(front: """
            <contrib-group>
              <contrib contrib-type="author"><name><surname>Smith</surname><given-names>John</given-names></name></contrib>
              <contrib contrib-type="author"><name><surname>Doe</surname><given-names>Jane</given-names></name></contrib>
            </contrib-group>
        """)

        XCTAssertEqual(article.authors.map(\.surname), ["Smith", "Doe"])
    }

    /// PLOS's shape: the group declares the role, the children are bare.
    func testContentTypeOnTheGroupWithBareContribs() throws {
        let article = try parse(front: """
            <contrib-group content-type="author">
              <contrib><name name-style="western"><surname>Hwang</surname><given-names initials="SH">Sun-Hee</given-names></name></contrib>
              <contrib><name name-style="western"><surname>Choi</surname><given-names initials="K">Kyungsuk</given-names></name></contrib>
            </contrib-group>
        """)

        XCTAssertEqual(article.authors.map(\.surname), ["Hwang", "Choi"])
    }

    /// A plain `<contrib-group>` with bare children: authors by JATS convention.
    func testBareGroupWithBareContribs() throws {
        let article = try parse(front: """
            <contrib-group>
              <contrib><name><surname>Solo</surname><given-names>Ann</given-names></name></contrib>
            </contrib-group>
        """)

        XCTAssertEqual(article.authors.map(\.surname), ["Solo"])
    }

    // MARK: - Non-authors must stay out

    func testEditorsAreNotAuthors() throws {
        let article = try parse(front: """
            <contrib-group content-type="author">
              <contrib><name><surname>Real</surname><given-names>Ada</given-names></name></contrib>
            </contrib-group>
            <contrib-group content-type="editor">
              <contrib><name><surname>Gatekeeper</surname><given-names>Ed</given-names></name></contrib>
            </contrib-group>
        """)

        XCTAssertEqual(article.authors.map(\.surname), ["Real"])
    }

    /// An explicit non-author type wins over a permissive group.
    func testExplicitEditorContribTypeIsNotAnAuthor() throws {
        let article = try parse(front: """
            <contrib-group>
              <contrib contrib-type="author"><name><surname>Real</surname><given-names>Ada</given-names></name></contrib>
              <contrib contrib-type="editor"><name><surname>Gatekeeper</surname><given-names>Ed</given-names></name></contrib>
            </contrib-group>
        """)

        XCTAssertEqual(article.authors.map(\.surname), ["Real"])
    }
}
