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

    // MARK: - Capturing what the flattener reports

    /// Records the library's diagnostics so a test can assert on them.
    ///
    /// `@unchecked Sendable` with a lock because `BioMedLitLogger` requires
    /// `Sendable` and this is mutable; the lock is what makes that claim true.
    private final class RecordingLogger: BioMedLitLogger, @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [String] = []

        private func record(_ level: String, _ message: String) {
            lock.lock(); defer { lock.unlock() }
            messages.append("\(level): \(message)")
        }

        func debug(_ message: String, category: BioMedLitLogCategory) {
            record("DEBUG", message)
        }

        func info(_ message: String, category: BioMedLitLogCategory) {
            record("INFO", message)
        }

        func warning(_ message: String, category: BioMedLitLogCategory) {
            record("WARNING", message)
        }

        func error(_ message: String, category: BioMedLitLogCategory) {
            record("ERROR", message)
        }

        var recorded: [String] {
            lock.lock(); defer { lock.unlock() }
            return messages
        }

        var errors: [String] {
            recorded.filter { $0.hasPrefix("ERROR") }
        }

        func reset() {
            lock.lock(); defer { lock.unlock() }
            messages.removeAll()
        }
    }

    private let logger = RecordingLogger()

    override func setUp() {
        super.setUp()
        logger.reset()
        BioMedLitLib.configure(with: BioMedLitConfiguration(
            ncbiEmail: "tests@example.com", logger: logger
        ))
    }

    /// Restore the configuration the rest of the package's tests expect: the
    /// library cannot be un-configured, so put back "configured, no logger".
    override func tearDown() {
        BioMedLitLib.configure(with: BioMedLitConfiguration(
            ncbiEmail: "tests@example.com", logger: nil
        ))
        super.tearDown()
    }

    // MARK: - Well-formed references

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

    // MARK: - References the pattern used to miss (#230)

    /// A space between the display text and its target is still a reference.
    ///
    /// The report body is written by a language model, which is not a markdown
    /// conformance suite: a stray space after `]` is ordinary output. CommonMark
    /// says that is not a link, and by that reading the whole construct is prose
    /// — which put the literal `(doc:pmid-889149)` onto an exported page, `#212`
    /// reaching a reader through a different door. The tolerance is granted to
    /// `doc:` targets alone, because that scheme is written by our own prompt and
    /// never occurs in an article's prose.
    func testAReferenceSeparatedFromItsTargetByASpaceIsFlattened() {
        let flattened = ReportFormatter.flattenedReferenceLinks(
            in: "A [Smith, 2016] (doc:pmid-889149) study."
        )

        XCTAssertEqual(flattened, "A Smith, 2016 study.")
        XCTAssertFalse(flattened.contains("889149"), flattened)
    }

    /// Display text may carry a bracketed aside.
    ///
    /// `[^\]]+` stopped at the inner `]`, so the whole reference failed to match
    /// and passed through with its target intact.
    func testDisplayTextMayCarryNestedBrackets() {
        let flattened = ReportFormatter.flattenedReferenceLinks(
            in: "Nested [Smith [Jr], 2016](doc:abc) case."
        )

        XCTAssertEqual(flattened, "Nested Smith [Jr], 2016 case.")
    }

    /// A parenthesis inside a link target does not end the target.
    ///
    /// Wiley's DOIs embed one — `10.1002/(SICI)1097-0258` — and `[^)]+` stopped
    /// at the first `)`, so the link was replaced by its display text plus the
    /// tail of its own URL: text a reader keeps, corrupted rather than cleaned.
    func testAParenthesisInsideALinkTargetDoesNotEndIt() {
        let flattened = ReportFormatter.flattenedReferenceLinks(
            in: "See [DOI](https://doi.org/10.1002/(SICI)1097-0258) for detail."
        )

        XCTAssertEqual(flattened, "See DOI for detail.")
    }

    /// An image's leading marker is consumed with the link it belongs to.
    ///
    /// Flattening `![Figure 1](url)` to its display text alone left the `!`
    /// stranded against the caption.
    func testAnImageMarkerIsConsumedWithItsLink() {
        let flattened = ReportFormatter.flattenedReferenceLinks(
            in: "![Figure 1](https://example.org/f1.png)"
        )

        XCTAssertEqual(flattened, "Figure 1")
    }

    // MARK: - Targets that cannot be parsed at all (#230)

    /// An unterminated target is removed rather than printed, and reported.
    ///
    /// Nothing can tell where a target with no closing parenthesis was meant to
    /// end, so the display text keeps its brackets. What may not happen is the
    /// identity reaching the page: `889149` pasted into PubMed is a real 1977
    /// paper on mouse courtship, and an exported report outlives the app.
    func testAnUnterminatedDocumentTargetIsRemovedAndReported() {
        let flattened = ReportFormatter.flattenedReferenceLinks(
            in: "A [Smith, 2016](doc:pmid-889149 study."
        )

        XCTAssertEqual(flattened, "A [Smith, 2016] study.")
        XCTAssertFalse(flattened.contains("doc:"), flattened)
        XCTAssertFalse(flattened.contains("889149"), flattened)
        XCTAssertEqual(logger.errors.count, 1, "\(logger.recorded)")
    }

    /// A target with no display text is removed rather than printed, and reported.
    ///
    /// There is nothing to keep, so the reference goes entirely, taking the
    /// space that preceded it so the sentence does not gain a double gap.
    func testABareDocumentTargetIsRemovedAndReported() {
        let flattened = ReportFormatter.flattenedReferenceLinks(
            in: "A (doc:8A1D4C22-0000-4000-8000-000000000001) bare target."
        )

        XCTAssertEqual(flattened, "A bare target.")
        XCTAssertFalse(flattened.contains("doc:"), flattened)
        XCTAssertEqual(logger.errors.count, 1, "\(logger.recorded)")
    }

    /// The report says what it could not parse, not merely that it failed.
    ///
    /// Golden rule 8. A count alone leaves the next reader of the log guessing
    /// which reference was malformed and in what way.
    func testAnUnparseableTargetIsNamedInTheReport() {
        _ = ReportFormatter.flattenedReferenceLinks(
            in: "A [Smith, 2016](doc:pmid-889149 study."
        )

        let reported = logger.errors.joined(separator: "\n")
        XCTAssertTrue(reported.contains("doc:pmid-889149"), reported)
    }

    // MARK: - What must not be mistaken for a reference (#230)

    /// A parenthetical following bracketed prose is not a link.
    ///
    /// The whitespace tolerance above is deliberately confined to `doc:`
    /// targets. Granted generally, this sentence would lose its confidence
    /// interval and read "a 12% sic reduction".
    func testAParentheticalAfterBracketedProseIsNotTreatedAsALink() {
        let prose = "The trial reported a 12% [sic] (95% CI 4-19) reduction."

        XCTAssertEqual(ReportFormatter.flattenedReferenceLinks(in: prose), prose)
    }

    /// Well-formed references are flattened silently.
    ///
    /// A diagnostic raised over text that is fine teaches the next reader of
    /// the log to ignore the one raised over text that is not.
    func testWellFormedReferencesReportNothing() {
        _ = ReportFormatter.flattenedReferenceLinks(
            in: "Both [Smith, 2016](doc:abc) and [Jones, 2019](doc:def) agree."
        )

        XCTAssertEqual(logger.errors, [], "\(logger.recorded)")
    }
}
