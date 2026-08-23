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
    private static let truncated = JATSParseWarnings(losses: [.openTables(2)])

    private func makeDocument() -> Document {
        Document(pmid: "12345678", title: "A Study", abstract: "")
    }

    // MARK: - The adapter

    func testTheAdapterCarriesWarningsOntoTheAppResult() {
        let result = BioMedLitAdapters.toAppFullTextResult(
            BMLFullTextResult(
                content: .europePMC(html: "<p>x</p>", markdown: "x"),
                warnings: Self.truncated
            )
        )

        XCTAssertEqual(result.warnings, Self.truncated)
    }

    /// The negative control: a complete article must not raise the banner.
    func testACleanParseCarriesNoWarnings() {
        let result = BioMedLitAdapters.toAppFullTextResult(
            BMLFullTextResult(content: .europePMC(html: "<p>x</p>", markdown: "x"))
        )

        XCTAssertTrue(result.warnings.isClean)
        XCTAssertNil(result.degradation)
    }

    /// A PDF or a publisher link is not a parse, so it has nothing to warn about.
    func testANonParsedSourceCarriesNoWarnings() {
        let result = BioMedLitAdapters.toAppFullTextResult(
            BMLFullTextResult(content: .unpaywall(pdfURL: URL(string: "https://example.org/a.pdf")!))
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

    /// A record written before the losses were typed holds a bare array of the
    /// old English lines, which no longer decodes — and must therefore report an
    /// unspecified loss rather than a clean parse (#184).
    ///
    /// Deliberately not migrated. Mapping those sentences back to cases would
    /// re-create, in a persisted format, the very wording coupling that typing
    /// the losses removed; the record is rewritten from the parser on the next
    /// fetch.
    func testALegacyStringWarningsPayloadIsNotReportedAsClean() {
        let document = makeDocument()
        document.fullTextHTML = "<p>x</p>"
        document.fullTextSource = AppFullTextSource.europePMC.rawValue
        document.fullTextParseWarningsJSON = """
        ["JATS parse ended with 2 open <table-wrap> — those tables and their content were discarded"]
        """

        let warnings = document.cachedFullTextResult?.warnings
        XCTAssertEqual(warnings?.isClean, false)
        XCTAssertEqual(warnings?.losses, [.unspecified])
    }

    // MARK: - The fallback's own note (#183)

    /// A degradation reaches the app result the same way warnings do.
    func testTheAdapterCarriesTheDegradationOntoTheAppResult() {
        let result = BioMedLitAdapters.toAppFullTextResult(
            BMLFullTextResult(
                content: .unpaywall(pdfURL: URL(string: "https://example.org/a.pdf")!),
                degradation: .jatsParseFailed
            )
        )

        XCTAssertEqual(result.degradation, .jatsParseFailed)
    }

    /// And survives the cache, which is the hop that matters most: macOS renders
    /// the banner from the stored `Document` and never sees the in-flight result.
    func testTheDegradationSurvivesTheDocumentRoundTrip() {
        let document = makeDocument()

        document.applyFullTextResult(
            AppFullTextResult(
                content: .pdfURL(URL(string: "https://example.org/a.pdf")!),
                source: .unpaywall,
                degradation: .jatsParseFailed
            )
        )

        XCTAssertEqual(document.cachedFullTextResult?.degradation, .jatsParseFailed)
    }

    /// A later result that was not degraded clears the note.
    ///
    /// The same trap the warnings had: a value that outlives the content it
    /// describes labels the next article with the last one's problem.
    func testASubsequentGoodParseClearsTheDegradation() {
        let document = makeDocument()
        document.applyFullTextResult(
            AppFullTextResult(
                content: .pdfURL(URL(string: "https://example.org/a.pdf")!),
                source: .unpaywall,
                degradation: .jatsParseFailed
            )
        )

        document.applyFullTextResult(
            AppFullTextResult(
                content: .html(content: "<p>whole</p>", markdown: "whole"),
                source: .europePMC
            )
        )

        XCTAssertNil(document.cachedFullTextResult?.degradation)
    }

    /// Including when the reader supplies the content themselves — the path that
    /// already once told an uploader their own upload was missing content.
    func testUploadedContentDoesNotInheritTheDegradation() {
        let document = makeDocument()
        document.applyFullTextResult(
            AppFullTextResult(
                content: .pdfURL(URL(string: "https://example.org/a.pdf")!),
                source: .unpaywall,
                degradation: .jatsParseFailed
            )
        )

        document.applyFullTextResult(
            .uploaded(content: .pdfURL(URL(string: "file:///tmp/a.pdf")!))
        )

        XCTAssertNil(document.fullTextDegradedReasonRaw)
        XCTAssertNil(document.cachedFullTextResult?.degradation)
    }

    func testClearingTheCacheClearsTheDegradation() {
        let document = makeDocument()
        document.applyFullTextResult(
            AppFullTextResult(
                content: .pdfURL(URL(string: "https://example.org/a.pdf")!),
                source: .unpaywall,
                degradation: .jatsParseFailed
            )
        )

        document.clearFullTextCache()

        XCTAssertNil(document.fullTextDegradedReasonRaw)
    }

    func testMarkingUnavailableClearsTheDegradation() {
        let document = makeDocument()
        document.applyFullTextResult(
            AppFullTextResult(
                content: .pdfURL(URL(string: "https://example.org/a.pdf")!),
                source: .unpaywall,
                degradation: .jatsParseFailed
            )
        )

        document.markFullTextUnavailable()

        XCTAssertNil(document.fullTextDegradedReasonRaw)
    }

    /// A stored reason this build does not recognise still means a better source
    /// was lost.
    ///
    /// Same reasoning as an undecodable warnings payload: the field is only ever
    /// written when something *was* lost, so reporting "no degradation" would
    /// tell the reader the publisher had no machine-readable text when we know
    /// otherwise.
    ///
    /// It reports `.unspecified` rather than guessing a reason. Before there
    /// were three reasons, answering `.jatsParseFailed` was a one-in-one guess;
    /// it is now a one-in-three guess that names our own parser as the culprit,
    /// which is exactly the misattribution this channel exists to prevent (#186).
    func testAnUnknownStoredDegradationIsReportedAsUnspecified() {
        let document = makeDocument()
        document.fullTextPDFPath = "https://example.org/a.pdf"
        document.fullTextSource = AppFullTextSource.unpaywall.rawValue
        document.fullTextDegradedReasonRaw = "somethingANewerBuildKnowsAbout"

        XCTAssertEqual(document.cachedFullTextResult?.degradation, .unspecified)
        XCTAssertEqual(document.cachedRetrievalNotice.degradation, .unspecified)
    }

    /// A reason this build *does* know is not flattened into the unknown one.
    func testAKnownStoredDegradationSurvives() {
        let document = makeDocument()
        document.fullTextPDFPath = "https://example.org/a.pdf"
        document.fullTextSource = AppFullTextSource.unpaywall.rawValue
        document.fullTextDegradedReasonRaw = FullTextDegradation.europePMCUnreachable.rawValue

        XCTAssertEqual(document.cachedRetrievalNotice.degradation, .europePMCUnreachable)
    }

    /// The negative control: an ordinary cached result carries no note.
    func testANormalCachedResultHasNoDegradation() {
        let document = makeDocument()
        document.fullTextHTML = "<p>x</p>"
        document.fullTextSource = AppFullTextSource.europePMC.rawValue

        XCTAssertNil(document.cachedFullTextResult?.degradation)
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

    // MARK: - A link-only fallback still speaks (#183)

    /// The outcome the degradation was added for, and the one it could not
    /// reach: Europe PMC had the machine-readable copy, our parser choked, and
    /// the chain fell through to a publisher link.
    ///
    /// A `.webURL` result caches no content — a link is opened in a browser
    /// rather than held as text — so `cachedFullTextResult` returns `nil` and
    /// took the degradation down with it. The reader was then shown "no full
    /// text available" for an article whose own record says we had the text and
    /// lost it: #183's conclusion exactly inverted, and cached, so every reopen
    /// repeated it.
    func testALinkOnlyFallbackStillReportsItsDegradation() {
        let document = makeDocument()

        document.applyFullTextResult(
            AppFullTextResult(
                content: .webURL(URL(string: "https://doi.org/10.1234/example")!),
                source: .doi,
                degradation: .jatsParseFailed
            )
        )

        // The precondition that made this invisible: nothing displayable is
        // cached, so the result cannot be rebuilt.
        XCTAssertNil(document.cachedFullTextResult)
        XCTAssertFalse(document.hasFullText)

        // The note survives that anyway, which is the whole point.
        XCTAssertEqual(document.cachedRetrievalNotice.degradation, .jatsParseFailed)
    }

    /// The same for warnings, so a link-only record cannot report a truncation
    /// as a clean parse either.
    func testALinkOnlyRecordStillReportsItsWarnings() {
        let document = makeDocument()

        document.applyFullTextResult(
            AppFullTextResult(
                content: .webURL(URL(string: "https://doi.org/10.1234/example")!),
                source: .doi,
                warnings: JATSParseWarnings(losses: [.unspecified])
            )
        )

        XCTAssertNil(document.cachedFullTextResult)
        XCTAssertEqual(document.cachedRetrievalNotice.warnings.losses, [.unspecified])
    }

    /// The negative control: a link-only record with nothing to report says
    /// nothing, so the banner stays silent on an ordinary fallback.
    func testALinkOnlyRecordWithNothingToReportIsSilent() {
        let document = makeDocument()

        document.applyFullTextResult(
            AppFullTextResult(
                content: .webURL(URL(string: "https://doi.org/10.1234/example")!),
                source: .doi
            )
        )

        XCTAssertTrue(document.cachedRetrievalNotice.warnings.isClean)
        XCTAssertNil(document.cachedRetrievalNotice.degradation)
    }

    /// A record whose warnings could not be encoded reads back as a loss, not as
    /// a clean parse.
    ///
    /// The field is only written when something *was* lost, so clearing it on an
    /// encode failure would record a truncated article as complete — the one
    /// failure this whole channel exists to prevent, arrived at from the write
    /// side rather than the read side.
    func testAnUnencodableWarningsRecordIsNotReportedAsClean() {
        let document = makeDocument()
        document.fullTextParseWarningsJSON = "not json at all"

        XCTAssertFalse(document.cachedRetrievalNotice.warnings.isClean)
        XCTAssertEqual(document.cachedRetrievalNotice.warnings.losses, [.unspecified])
    }

    /// A payload from a newer build is a loss of unknown size, not a clean parse.
    ///
    /// The stated purpose of the schema version, exercised end to end at the
    /// layer that actually reads a user's database.
    func testAForwardSchemaVersionRecordIsNotReportedAsClean() {
        let document = makeDocument()
        document.fullTextParseWarningsJSON =
            #"{"schemaVersion":99,"losses":[{"kind":"openFigures","count":2}]}"#

        XCTAssertEqual(document.cachedRetrievalNotice.warnings.losses, [.unspecified])
    }

    // MARK: - The link-only record (#187)

    /// The four states that reach the predicate, in one test so that a change
    /// widening it has to face the three it must stay false for.
    ///
    /// It lives on the model rather than inside a view because it is the whole
    /// judgement behind two surfaces, and a private computed property in a
    /// `View` cannot be tested at all (#185).
    func testALinkOnlyRecordIsTheOneThatWasFetchedAndCachedNothing() {
        let neverAttempted = makeDocument()
        XCTAssertFalse(neverAttempted.isLinkOnly)

        let cachedContent = makeDocument()
        cachedContent.applyFullTextResult(
            AppFullTextResult(
                content: .pdfURL(URL(string: "https://example.org/a.pdf")!), source: .unpaywall
            )
        )
        XCTAssertFalse(cachedContent.isLinkOnly)

        let unavailable = makeDocument()
        unavailable.fullTextUnavailable = true
        XCTAssertFalse(unavailable.isLinkOnly)

        let linkOnly = makeDocument()
        linkOnly.applyFullTextResult(
            AppFullTextResult(
                content: .webURL(URL(string: "https://doi.org/10.1234/example")!), source: .doi
            )
        )
        XCTAssertTrue(linkOnly.isLinkOnly)
        XCTAssertFalse(linkOnly.hasFullText, "a web URL is opened, not cached as text")
    }
}
