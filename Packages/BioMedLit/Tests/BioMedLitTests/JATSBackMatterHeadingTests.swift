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

/// An unsectioned container's own heading is kept (port of bmlib #231).
///
/// Nature and Springer deposit "Competing interests", "Data availability" and
/// "Funding" as `<notes>` and `<ack>` with a `<title>`, not as `<sec>`. The
/// title was dropped, so the prose arrived headless — and the transparency
/// extractors find a statement by its heading. PMC13458455 says "The authors
/// declare no competing interests." and was rated high risk for having no
/// conflict-of-interest statement.
final class JATSBackMatterHeadingTests: XCTestCase {

    /// PMC13458455's `<back>`, trimmed to its prose-bearing containers.
    private let lipokapBack = """
    <back>
      <fn-group><fn><p><bold>Publisher’s note</bold></p><p>Springer Nature remains neutral.</p></fn></fn-group>
      <ack><title>Acknowledgements</title><p>This research was financially supported by Pfizer (Grant No. 11531879).</p></ack>
      <notes notes-type="author-contribution"><title>Author contributions</title><p>N.M. and N.S. conceptualized the study.</p></notes>
      <notes notes-type="funding-information"><title>Funding</title><p>This study was funded by Pfizer (Grant No. 11531879).</p></notes>
      <notes notes-type="data-availability"><title>Data availability</title><p>The data that support the findings of this study are available from the corresponding author upon reasonable request.</p></notes>
      <notes><title>Declarations</title>
        <notes id="FPar2" notes-type="COI-statement"><title>Competing interests</title><p>The authors declare no competing interests.</p></notes>
        <notes><title>Human Ethics and Consent to Participate declarations</title><p>Approved by the International Atherosclerosis Society.</p></notes>
      </notes>
      <ref-list><title>References</title><ref id="CR1"><mixed-citation>WHO. Mental disorders.</mixed-citation></ref></ref-list>
    </back>
    """

    private func xml(back: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <article>
          <front><article-meta><article-id pub-id-type="pmc">PMC13458455</article-id>
            <title-group><article-title>T</article-title></title-group></article-meta></front>
          <body><sec><title>Methods</title><p>We enrolled 1994 adults.</p></sec></body>
        \(back)
        </article>
        """
    }

    private func article(back: String) throws -> JATSArticle {
        try JATSXMLParser(data: Data(xml(back: back).utf8)).parseToArticle()
    }

    private func markdown(back: String) throws -> String {
        try JATSXMLParser(data: Data(xml(back: back).utf8)).parseToMarkdown()
    }

    /// The title and paragraphs of every section after the body's own.
    private func backSections(_ back: String) throws -> [(title: String, paragraphs: [String])] {
        try article(back: back).bodySections.dropFirst().map { ($0.title, $0.paragraphs) }
    }

    func testEachContainerKeepsItsOwnHeading() throws {
        let sections = try backSections(lipokapBack)
        XCTAssertEqual(sections.map(\.title), [
            "",
            "Acknowledgements",
            "Author contributions",
            "Funding",
            "Data availability",
            "Competing interests",
            "Human Ethics and Consent to Participate declarations",
        ])
        XCTAssertEqual(
            sections.first { $0.title == "Competing interests" }?.paragraphs,
            ["The authors declare no competing interests."]
        )
    }

    /// An untitled container's prose does not inherit the previous heading:
    /// a wrong heading is worse than none.
    func testAnUntitledContainerAfterATitledOneStaysUntitled() throws {
        let sections = try backSections("""
        <back>
          <ack><title>Acknowledgements</title><p>We thank the staff.</p></ack>
          <fn-group><fn><p>The authors declare no competing interests.</p></fn></fn-group>
        </back>
        """)
        XCTAssertEqual(sections.map(\.title), ["Acknowledgements", ""])
        XCTAssertEqual(sections.last?.paragraphs, ["The authors declare no competing interests."])
    }

    /// Two sibling containers with the same heading are two sections.
    func testSiblingContainersWithOneHeadingStayTwoSections() throws {
        let sections = try backSections("""
        <back>
          <notes><title>Notes</title><p>First.</p></notes>
          <notes><title>Notes</title><p>Second.</p></notes>
        </back>
        """)
        XCTAssertEqual(sections.map(\.title), ["Notes", "Notes"])
    }

    /// A heading that titles nothing splits nothing.
    func testAHeadingThatTitlesNothingDoesNotSplitProse() throws {
        let sections = try backSections("""
        <back>
          <fn-group><fn><p>One.</p></fn></fn-group>
          <notes><title>Empty</title></notes>
          <fn-group><fn><p>Two.</p></fn></fn-group>
        </back>
        """)
        XCTAssertEqual(sections.map(\.title), [""])
        XCTAssertEqual(sections.first?.paragraphs, ["One.", "Two."])
    }

    /// A container heading inside a `<sec>` still does not rename it (#125).
    func testAHeadingInsideASectionDoesNotRenameIt() throws {
        let sections = try backSections("""
        <back><sec><title>Additional information</title>
          <fn-group><title>Author contributions</title><fn><p>A did it.</p></fn></fn-group>
        </sec></back>
        """)
        XCTAssertEqual(sections.map(\.title), ["Additional information"])
    }

    /// The reference list's heading titles no prose section.
    func testTheReferenceListHeadingOpensNoSection() throws {
        let sections = try backSections(lipokapBack)
        XCTAssertFalse(sections.contains { $0.title == "References" })
    }

    // MARK: - What the heading is for

    /// With its headings, PMC13458455's statements are found where the
    /// analysis looks for them (the extractors return lowercased text).
    func testTheStatementsAreFoundInTheRenderedText() throws {
        let text = try markdown(back: lipokapBack)
        XCTAssertEqual(
            TransparencyAnalysisService.extractCOISection(from: text),
            "the authors declare no competing interests."
        )
        XCTAssertEqual(
            TransparencyAnalysisService.extractDataAvailabilitySection(from: text),
            "the data that support the findings of this study are available from the corresponding author upon reasonable request."
        )
    }

    /// "Data Availability Statement" is a heading, not a statement whose text
    /// is "Statement" — the capture 110 of 220 surveyed articles gave.
    func testAQualifiedHeadingIsNotCapturedAsTheStatement() {
        XCTAssertEqual(
            TransparencyAnalysisService.extractDataAvailabilitySection(
                from: "## Data Availability Statement\n\nNo new data were created.\n\n## Next"
            ),
            "no new data were created."
        )
        XCTAssertEqual(
            TransparencyAnalysisService.extractCOISection(
                from: "Conflict of Interest Statement\n\nThe authors declare none.\n\n"
            ),
            "the authors declare none."
        )
        // The unqualified heading and the inline form are unchanged.
        XCTAssertEqual(
            TransparencyAnalysisService.extractCOISection(from: "Competing interests: None declared."),
            "none declared."
        )
    }
}
