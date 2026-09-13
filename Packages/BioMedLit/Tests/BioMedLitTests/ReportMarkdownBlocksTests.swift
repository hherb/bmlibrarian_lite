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

/// Splitting a report into the blocks a renderer lays out.
///
/// The iOS screen, the macOS screen and the PDF exporter each carried a private
/// copy of this splitter. Only the two screens learned to parse a paragraph
/// before joining its lines, so the PDF — the document a reader keeps — went on
/// deleting prose the screen showed (#233). One splitter is what keeps them in
/// step.
///
/// Every expectation is a literal written by hand.
final class ReportMarkdownBlocksTests: XCTestCase {

    /// Parses one run of markdown, for building expectations.
    private func parsed(_ markdown: String) -> ReportInlineText {
        ReportInlineText(parsing: markdown)
    }

    // MARK: - Block kinds

    /// A heading keeps its level and its text.
    func testHeadingsKeepTheirLevel() {
        let blocks = ReportMarkdownBlock.blocks(fromReportMarkdown: "# One\n## Two\n### Three")

        XCTAssertEqual(blocks, [
            .heading(level: 1, text: parsed("One")),
            .heading(level: 2, text: parsed("Two")),
            .heading(level: 3, text: parsed("Three")),
        ])
    }

    /// Wrapped lines form one paragraph, and a blank line starts the next.
    func testWrappedLinesFormOneParagraph() {
        let blocks = ReportMarkdownBlock.blocks(
            fromReportMarkdown: "First line\n  second line\n\nNext paragraph"
        )

        XCTAssertEqual(blocks.map(\.inlineText.flattened), [
            "First line second line",
            "Next paragraph",
        ])
        XCTAssertEqual(blocks.count, 2)
        guard case .paragraph = blocks.first else {
            return XCTFail("expected a paragraph, got \(blocks)")
        }
    }

    /// Ordered items are numbered in sequence, and the count restarts after a
    /// blank line, a heading or an unordered item.
    func testListItemsAreNumberedInSequence() {
        let blocks = ReportMarkdownBlock.blocks(
            fromReportMarkdown: "1. a\n7. b\n\n1. c\n- d\n* e\n3. f\n# H\n1. g"
        )

        XCTAssertEqual(blocks, [
            .listItem(text: parsed("a"), ordinal: 1),
            .listItem(text: parsed("b"), ordinal: 2),
            .listItem(text: parsed("c"), ordinal: 1),
            .listItem(text: parsed("d"), ordinal: nil),
            .listItem(text: parsed("e"), ordinal: nil),
            .listItem(text: parsed("f"), ordinal: 1),
            .heading(level: 1, text: parsed("H")),
            .listItem(text: parsed("g"), ordinal: 1),
        ])
    }

    /// A line break escaped by the model as `\n` is read as a line break.
    func testEscapedLineBreaksAreRead() {
        let blocks = ReportMarkdownBlock.blocks(fromReportMarkdown: "Para one\\n\\nPara two")

        XCTAssertEqual(blocks.map(\.inlineText.flattened), ["Para one", "Para two"])
    }

    // MARK: - References

    /// A paragraph is parsed with its line breaks, then joined.
    ///
    /// Joined first, an ordinary link's unclosed target crossed the break and
    /// reached the `)` on the next line: the PDF printed "See the guideline
    /// text." and the words between were gone, reported nowhere.
    func testAParagraphIsParsedBeforeItsLinesAreJoined() {
        let blocks = ReportMarkdownBlock.blocks(
            fromReportMarkdown: "See [the guideline](https://example.org/a\nand more) text."
        )

        XCTAssertEqual(
            blocks.map(\.inlineText.flattened),
            ["See [the guideline](https://example.org/a and more) text."]
        )
    }

    /// Every kind of block has its references parsed.
    func testReferencesInEveryKindOfBlockAreParsed() {
        let blocks = ReportMarkdownBlock.blocks(
            fromReportMarkdown: "# Heading [Smith, 2016](doc:abc)\n- item (doc:def)\n1. first [Li, 2020](doc:ghi"
        )

        XCTAssertEqual(blocks.map(\.inlineText.flattened), [
            "Heading Smith, 2016",
            "item",
            "first [Li, 2020]",
        ])
        XCTAssertEqual(blocks.flatMap(\.inlineText.removedReferences), ["(doc:def)", "(doc:ghi"])
    }

    /// Block by block, a report loses exactly what it loses parsed whole.
    ///
    /// The text export parses the whole report at once; the screen and the PDF
    /// parse it block by block. Where no reference is wrapped across a block
    /// boundary (#241), the two must remove the same references.
    func testBlocksRemoveWhatTheWholeReportRemoves() {
        let report = """
            # Findings

            Mortality fell [Smith, 2016](doc:abc
            in adults (doc:pmid 1) overall.

            - A list item [Jones, 2019](doc:def) (doc:x

            Closing [x](https://example.org) text.
            """

        let blocks = ReportMarkdownBlock.blocks(fromReportMarkdown: report)

        XCTAssertEqual(
            blocks.flatMap(\.inlineText.removedReferences),
            ReportInlineText(parsing: report).removedReferences
        )
        XCTAssertEqual(
            blocks.flatMap(\.inlineText.removedReferences),
            ["(doc:abc", "(doc:pmid 1)", "(doc:x"]
        )
    }

    /// Empty or blank markdown has no blocks.
    func testBlankMarkdownHasNoBlocks() {
        XCTAssertEqual(ReportMarkdownBlock.blocks(fromReportMarkdown: " \n\n \\n "), [])
    }
}
