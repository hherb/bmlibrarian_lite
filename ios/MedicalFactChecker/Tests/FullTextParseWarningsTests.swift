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
import BioMedLit
@testable import MedicalFactChecker

/// A truncated parse has to survive every hop between the parser and the reader
/// (#181). The hop that is easiest to miss is the cache: full text is stored on
/// the `Document` and re-rendered from it, so warnings that live only on the
/// in-flight result vanish the moment the viewer is reopened — and on macOS,
/// which renders only from the `Document`, they would never be seen at all.
final class FullTextParseWarningsTests: XCTestCase {
    private static let truncated = JATSParseWarnings(diagnostics: [
        "JATS parse ended with 2 open <table-wrap> — those tables and their content were discarded"
    ])

    private func makeDocument() -> Document {
        Document(pmid: "12345678", title: "A Study", abstract: "")
    }

    // MARK: - The adapter

    func testTheAdapterCarriesWarningsOntoTheAppResult() {
        let result = BioMedLitAdapters.toAppFullTextResult(
            .europePMC(html: "<p>x</p>", markdown: "x", warnings: Self.truncated)
        )

        XCTAssertEqual(result.warnings, Self.truncated)
    }

    /// The negative control: a complete article must not raise the banner.
    func testACleanParseCarriesNoWarnings() {
        let result = BioMedLitAdapters.toAppFullTextResult(
            .europePMC(html: "<p>x</p>", markdown: "x", warnings: JATSParseWarnings())
        )

        XCTAssertTrue(result.warnings.isClean)
    }

    /// A PDF or a publisher link is not a parse, so it has nothing to warn about.
    func testANonParsedSourceCarriesNoWarnings() {
        let result = BioMedLitAdapters.toAppFullTextResult(
            .unpaywall(pdfURL: URL(string: "https://example.org/a.pdf")!)
        )

        XCTAssertTrue(result.warnings.isClean)
    }

    // MARK: - The cache

    func testWarningsSurviveTheDocumentRoundTrip() {
        let document = makeDocument()

        document.applyFullTextResult(
            AppFullTextResult(
                content: .html(content: "<p>x</p>", markdown: "x"),
                source: .europePMC,
                warnings: Self.truncated
            )
        )

        XCTAssertEqual(document.cachedFullTextResult?.warnings, Self.truncated)
    }

    /// The stale-warning trap: warnings that outlive the content they describe
    /// would label the next article with the last one's losses.
    func testClearingTheCacheClearsTheWarnings() {
        let document = makeDocument()
        document.applyFullTextResult(
            AppFullTextResult(
                content: .html(content: "<p>x</p>", markdown: "x"),
                source: .europePMC,
                warnings: Self.truncated
            )
        )

        document.clearFullTextCache()

        XCTAssertNil(document.fullTextParseWarningsJSON)
        XCTAssertNil(document.cachedFullTextResult)
    }

    func testMarkingUnavailableClearsTheWarnings() {
        let document = makeDocument()
        document.applyFullTextResult(
            AppFullTextResult(
                content: .html(content: "<p>x</p>", markdown: "x"),
                source: .europePMC,
                warnings: Self.truncated
            )
        )

        document.markFullTextUnavailable()

        XCTAssertNil(document.fullTextParseWarningsJSON)
    }

    /// Re-storing a clean parse over a truncated one must not leave the old
    /// warnings behind — the same statement writes both, or they drift.
    func testAFreshCleanParseReplacesEarlierWarnings() {
        let document = makeDocument()
        document.applyFullTextResult(
            AppFullTextResult(
                content: .html(content: "<p>x</p>", markdown: "x"),
                source: .europePMC,
                warnings: Self.truncated
            )
        )

        document.applyFullTextResult(
            AppFullTextResult(
                content: .html(content: "<p>whole</p>", markdown: "whole"),
                source: .europePMC,
                warnings: JATSParseWarnings()
            )
        )

        XCTAssertTrue(document.cachedFullTextResult?.warnings.isClean ?? false)
    }

    /// A document cached before this field existed reads back as "nothing known",
    /// not as a truncation.
    func testADocumentCachedBeforeWarningsExistedIsNotReportedAsTruncated() {
        let document = makeDocument()
        document.fullTextHTML = "<p>x</p>"
        document.fullTextSource = AppFullTextSource.europePMC.rawValue

        XCTAssertTrue(document.cachedFullTextResult?.warnings.isClean ?? false)
    }
}
