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

import BioMedLit
import XCTest
@testable import MedicalFactChecker

/// What the on-screen report shows, and where each tap leads.
///
/// Each report view carried a private parser that required a reference's
/// display text to read `Author, Year` and its target to follow `]` directly.
/// Everything else went to SwiftUI's markdown parser or straight to the screen,
/// so a spaced, unterminated or bare target printed a row's identity, and a
/// reference worded any other way became a link to `doc:<identity>`, which the
/// system cannot open (#233). The export path had stopped doing either.
final class ReportRichTextTests: XCTestCase {

    private let identity = "8A1D4C22-0000-4000-8000-000000000001"

    // MARK: - Helpers

    /// The text a reader sees.
    private func shownText(_ markdown: String) -> String {
        String(ReportRichText.attributedString(from: ReportInlineText(parsing: markdown)).characters)
    }

    /// Each linked run's text and destination, in order.
    private func links(_ markdown: String) -> [(text: String, url: URL)] {
        let attributed = ReportRichText.attributedString(from: ReportInlineText(parsing: markdown))
        return attributed.runs.compactMap { run in
            run.link.map { (String(attributed[run.range].characters), $0) }
        }
    }

    // MARK: - References lead to their document

    /// A well-formed reference is shown bracketed and opens its document.
    func testADocumentReferenceOpensItsDocument() {
        let markdown = "Evidence is mixed [Smith et al., 2016](doc:\(identity))."

        XCTAssertEqual(shownText(markdown), "Evidence is mixed [Smith et al., 2016].")
        let found = links(markdown)
        XCTAssertEqual(found.map(\.text), ["[Smith et al., 2016]"])
        XCTAssertEqual(found.map { ReportReferenceLink(url: $0.url) }, [.documentIdentity(identity)])
    }

    /// A reference not worded `Author, Year` opens its document too, rather than
    /// being a link nothing can open.
    func testAReferenceNotWordedAsAuthorAndYearIsNotADeadLink() {
        let found = links("As [the WHO guideline](doc:\(identity)) says.")

        XCTAssertEqual(found.map { ReportReferenceLink(url: $0.url) }, [.documentIdentity(identity)])
        XCTAssertFalse(found.contains { $0.url.scheme == "doc" }, "\(found)")
    }

    /// A citation with no target opens the document its text names, whatever
    /// characters that text carries.
    func testACitationWithNoTargetLeadsToItsText() {
        let found = links("As shown [Smith & Jones, 2016].")

        XCTAssertEqual(found.map { ReportReferenceLink(url: $0.url) }, [.citationText("Smith & Jones, 2016")])
    }

    // MARK: - No identity reaches the screen

    /// Every malformed shape the issue measured leaves no identity on screen.
    ///
    /// `889149` pasted into PubMed is a real 1977 paper on mouse courtship, not
    /// the article cited (#212), and a reader has no way to tell.
    func testNoMalformedReferencePutsItsTargetOnScreen() {
        let cases: [(markdown: String, shown: String)] = [
            ("A [Smith, 2016] (doc:pmid-889149) study.", "A [Smith, 2016] study."),
            ("A [Smith, 2016](doc:pmid-889149 study.", "A [Smith, 2016] study."),
            ("A (doc:pmid-889149) bare target.", "A bare target."),
            ("Nested [Smith [Jr], 2016](doc:pmid-889149) case.", "Nested [Smith [Jr], 2016] case."),
        ]

        for (markdown, shown) in cases {
            XCTAssertEqual(shownText(markdown), shown, markdown)
        }
    }

    /// A malformed reference does not take the prose or the citation after it.
    ///
    /// Its target used to run on to the next `)`, so the Jones citation and
    /// everything before that parenthesis vanished from the screen with no note.
    func testAMalformedReferenceKeepsTheTextAfterIt() {
        let markdown = "Benefit ([Smith, 2016](doc:abc; [Jones, 2019](doc:def)) in adults."

        XCTAssertEqual(shownText(markdown), "Benefit ([Smith, 2016]; [Jones, 2019]) in adults.")
        XCTAssertEqual(
            links(markdown).map { ReportReferenceLink(url: $0.url) },
            [.citationText("Smith, 2016"), .documentIdentity("def")]
        )
    }

    // MARK: - Everything else

    /// An ordinary link keeps a destination the reader can follow.
    func testAnOrdinaryLinkKeepsItsDestination() {
        let found = links("See [the guideline](https://example.org/guideline) for detail.")

        XCTAssertEqual(found.map(\.text), ["the guideline"])
        XCTAssertEqual(found.map(\.url), [URL(string: "https://example.org/guideline")])
    }

    /// Emphasis is rendered, not printed.
    func testEmphasisIsRenderedRatherThanPrinted() {
        let attributed = ReportRichText.attributedString(
            from: ReportInlineText(parsing: "**Key finding:** it helped [Smith, 2016](doc:abc).")
        )

        XCTAssertEqual(String(attributed.characters), "Key finding: it helped [Smith, 2016].")
        XCTAssertTrue(
            attributed.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
        )
    }

    /// Bracketed prose is neither a citation nor a link.
    func testBracketedProseIsShownAsWritten() {
        let markdown = "The trial reported a 12% [sic] (95% CI 4-19) reduction."

        XCTAssertEqual(shownText(markdown), markdown)
        XCTAssertTrue(links(markdown).isEmpty)
    }

    // MARK: - Telling the reader

    /// Nothing removed, nothing said.
    ///
    /// A note over a report that is fine teaches the reader to ignore the one
    /// over a report that is not.
    func testNoNoticeWhenNothingWasRemoved() {
        XCTAssertNil(RemovedCitationNotice(removedReferences: []))
    }

    /// The note counts removed links, in agreement with the number.
    ///
    /// It counts links, not citations: an unterminated target leaves its
    /// citation on the page, and one reference can lose two targets, so a count
    /// of "citations" would claim losses that did not happen.
    func testTheNoticeCountsRemovedLinks() throws {
        let one = try XCTUnwrap(RemovedCitationNotice(removedReferences: ["(doc:abc"]))
        let three = try XCTUnwrap(RemovedCitationNotice(removedReferences: ["(doc:a", "(doc:b)", "(doc:c"]))

        XCTAssertTrue(one.sentence.hasPrefix("1 malformed citation link was "), one.sentence)
        XCTAssertTrue(three.sentence.hasPrefix("3 malformed citation links were "), three.sentence)
    }
}
