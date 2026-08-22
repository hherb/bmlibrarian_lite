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

    /// An undecodable field is not a clean parse.
    ///
    /// The field is only ever written when something *was* lost, so reading back
    /// "clean" from corruption is the one answer that cannot be right: it renders
    /// a truncated article as complete, which is what this channel exists to stop.
    func testCorruptWarningsJSONIsNotReportedAsACleanParse() {
        let document = makeDocument()
        document.fullTextHTML = "<p>x</p>"
        document.fullTextSource = AppFullTextSource.europePMC.rawValue
        document.fullTextParseWarningsJSON = "{not json"

        let warnings = document.cachedFullTextResult?.warnings
        XCTAssertEqual(warnings?.isClean, false)
    }

    // MARK: - The cache reads as retrieved (#182 review)

    /// A PDF-only result has to leave the document looking retrieved.
    ///
    /// `applyFullTextResult` replaced three inline assignments that each stored
    /// the PDF URL. Without it `hasFullText` stayed false, so every Europe PMC
    /// PDF and Unpaywall hit read as never-fetched on the next launch and was
    /// re-fetched forever.
    func testAPDFResultIsCachedAsRetrieved() {
        let document = makeDocument()
        let url = URL(string: "https://example.org/a.pdf")!

        document.applyFullTextResult(
            AppFullTextResult(content: .pdfURL(url), source: .unpaywall)
        )

        XCTAssertEqual(document.fullTextPDFPath, url.absoluteString)
        XCTAssertTrue(document.hasFullText)
        XCTAssertNotNil(document.cachedFullTextResult)
    }

    /// Content the reader supplied replaces the warnings along with the text.
    ///
    /// The upload path assigned the cache fields by hand and never cleared the
    /// warnings, so a reader who uploaded a complete copy *because* the fetched
    /// parse was truncated was told their own upload was missing content.
    func testUploadedContentDoesNotInheritTheEarlierParsesWarnings() {
        for uploaded in [
            AppFullTextResult.uploaded(content: .html(content: "<p>whole</p>", markdown: "whole")),
            AppFullTextResult.uploaded(content: .markdown("whole")),
            AppFullTextResult.uploaded(content: .pdfURL(URL(string: "file:///tmp/a.pdf")!)),
        ] {
            let document = makeDocument()
            document.applyFullTextResult(
                AppFullTextResult(
                    content: .html(content: "<p>x</p>", markdown: "x"),
                    source: .europePMC,
                    warnings: Self.truncated
                )
            )

            document.applyFullTextResult(uploaded)

            XCTAssertNil(document.fullTextParseWarningsJSON, "\(uploaded.content)")
            XCTAssertTrue(
                document.cachedFullTextResult?.warnings.isClean ?? false,
                "\(uploaded.content)"
            )
        }
    }

    /// Uploading a PDF must not leave the superseded HTML behind to shadow it.
    ///
    /// `cachedFullTextResult` prefers HTML, so the stale text was what the viewer
    /// rendered — under a badge reading "Uploaded".
    func testUploadingAPDFClearsTheSupersededText() {
        let document = makeDocument()
        document.applyFullTextResult(
            AppFullTextResult(
                content: .html(content: "<p>stale</p>", markdown: "stale"),
                source: .europePMC,
                warnings: Self.truncated
            )
        )

        document.applyFullTextResult(
            .uploaded(content: .pdfURL(URL(string: "file:///tmp/a.pdf")!))
        )

        XCTAssertNil(document.fullTextHTML)
        XCTAssertNil(document.fullTextContent)
    }
}
