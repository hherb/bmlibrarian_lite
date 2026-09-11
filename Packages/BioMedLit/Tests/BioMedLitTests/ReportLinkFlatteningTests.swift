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

/// Flattening a report's interactive references for a renderer that cannot
/// follow links.
///
/// The function lived in three private copies — `PDFExporter` and both
/// `PrintableReportView`s — which is how one defect sat in all three at once.
/// They were *not* identical, and consolidating on that assumption dropped
/// behaviour: the two view copies also stripped `**` and `__`, while
/// `PDFExporter` relied on `**` surviving so `drawFormattedText` could set a
/// bold font. That is why there are two functions here and not one.
final class ReportLinkFlatteningTests: XCTestCase {
    /// A document link is replaced by the text a reader is meant to see.
    func testADocumentLinkIsReducedToItsDisplayText() {
        let flattened = ReportFormatter.flattenedReferenceLinks(
            in: "Evidence is mixed [Smith et al., 2016](doc:8A1D4C22-0000-4000-8000-000000000001)."
        )

        XCTAssertEqual(flattened, "Evidence is mixed Smith et al., 2016.")
    }

    /// An ordinary markdown link is flattened too: the exported page has no
    /// way to offer the destination either.
    func testAnOrdinaryMarkdownLinkIsReducedToItsText() {
        let flattened = ReportFormatter.flattenedReferenceLinks(
            in: "See [the guideline](https://example.org/guideline) for detail."
        )

        XCTAssertEqual(flattened, "See the guideline for detail.")
    }

    /// Every reference in a paragraph is flattened, not only the first.
    func testEveryReferenceInAParagraphIsFlattened() {
        let flattened = ReportFormatter.flattenedReferenceLinks(
            in: "Both [Smith, 2016](doc:abc) and [Jones, 2019](doc:def) agree."
        )

        XCTAssertEqual(flattened, "Both Smith, 2016 and Jones, 2019 agree.")
    }

    /// A legacy link target must not be read as a PubMed ID.
    ///
    /// Documents were once identified as `pmid-<primary slot>`, and the slot
    /// also holds Europe PMC thesis, case-report and `HIR` accessions — bare
    /// decimals, indistinguishable from a PubMed ID (#212). Every saved report
    /// written before #208 carries such targets, and this renderer turned
    /// `doc:pmid-889149` into `(PMID: 889149)`: pasted into PubMed, that is a
    /// real 1977 paper on mouse courtship, not this article.
    ///
    /// The renderer receives the report text alone and never the documents, so
    /// it cannot tell the two apart and must not try. The numbered reference
    /// list carries the namespace-labelled identifier instead, established by
    /// the caller that has the document.
    func testALegacyPMIDStyleTargetYieldsNoIdentifier() {
        let flattened = ReportFormatter.flattenedReferenceLinks(
            in: "A thesis reported this [Nyby, 1977](doc:pmid-889149)."
        )

        XCTAssertEqual(flattened, "A thesis reported this Nyby, 1977.")
        XCTAssertFalse(flattened.contains("PMID"), flattened)
        XCTAssertFalse(flattened.contains("889149"), flattened)
    }

    /// Prose carrying no links is returned untouched, brackets included.
    func testTextWithNoLinksIsUnchanged() {
        let prose = "The trial reported a 12% [sic] reduction in mortality."

        XCTAssertEqual(ReportFormatter.flattenedReferenceLinks(in: prose), prose)
    }

    // MARK: - Emphasis

    /// Emphasis markers survive link flattening, because one caller needs them.
    ///
    /// `PDFExporter.drawFormattedText` consumes `**` itself to switch to a bold
    /// font. Stripping it here would turn real bold in an exported PDF into
    /// plain text, which is why this function does not do the whole job.
    func testEmphasisMarkersSurviveForARendererThatUnderstandsThem() {
        let flattened = ReportFormatter.flattenedReferenceLinks(
            in: "**Key finding:** it helped [Smith, 2016](doc:abc)."
        )

        XCTAssertEqual(flattened, "**Key finding:** it helped Smith, 2016.")
    }

    /// A verbatim renderer gets no markers, because it would print them.
    ///
    /// SwiftUI's `Text(_:)` over a runtime `String` does not parse markdown, so
    /// `**` reaches the page as two asterisks. Both printable report views feed
    /// it exactly that.
    func testPlainTextRemovesEmphasisMarkers() {
        let plain = ReportFormatter.plainText(
            fromReportMarkdown: "**Key finding:** it __helped__ [Smith, 2016](doc:abc)."
        )

        XCTAssertEqual(plain, "Key finding: it helped Smith, 2016.")
    }

    /// The reference list is the worst case, so it is pinned directly.
    ///
    /// ``ReportFormatter/formatReferences(_:)`` opens every entry with `**1.**`,
    /// so a renderer that shows markers verbatim gains four asterisks on every
    /// line of the list a reader is most likely to read.
    func testPlainTextCleansAFormattedReferenceLine() {
        let plain = ReportFormatter.plainText(
            fromReportMarkdown: "**1.** **Nyby, J (1977).** Mouse courtship. Europe PMC: 889149"
        )

        XCTAssertEqual(plain, "1. Nyby, J (1977). Mouse courtship. Europe PMC: 889149")
        XCTAssertFalse(plain.contains("*"), plain)
    }

    /// A single asterisk is left alone: in a title it is far more often literal.
    func testPlainTextLeavesUnpairedMarkersAlone() {
        let plain = ReportFormatter.plainText(
            fromReportMarkdown: "Survival at 5* years was 80%."
        )

        XCTAssertEqual(plain, "Survival at 5* years was 80%.")
    }
}
