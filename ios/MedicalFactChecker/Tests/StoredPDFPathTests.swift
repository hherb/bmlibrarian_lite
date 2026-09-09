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

/// `fullTextPDFPath` holds either a filesystem path or a remote URL string, and
/// only the writer knows which. Every read that guesses gets it wrong for one of
/// the two.
final class StoredPDFPathTests: XCTestCase {
    private func makeDocument() -> Document {
        Document(pmid: "12345678", title: "A Study", abstract: "")
    }

    /// The upload regression, as a test.
    ///
    /// `AppFullTextResult.uploaded` carried no `localPDFPath`, so
    /// `applyFullTextResult` recorded the file's URL string with the flag set to
    /// `false`. The call site then assigned the real path over the top — and
    /// could not touch the flag, because `storePDFPath` is private. The record
    /// held a filesystem path labelled as a remote link, `URL(string:)` turned
    /// it into a schemeless URL, and every reopen of an uploaded PDF failed with
    /// "The server did not return the PDF."
    func testAnUploadedPDFIsRecordedAsALocalFile() {
        let document = makeDocument()
        let destination = URL(fileURLWithPath: "/tmp/uploads/12345678.pdf")

        document.applyFullTextResult(
            .uploaded(content: .pdfURL(destination), localPDFPath: destination.path)
        )

        XCTAssertEqual(document.fullTextPDFPath, destination.path)
        XCTAssertEqual(document.fullTextPDFPathIsLocalFile, true)
        XCTAssertEqual(document.localPDFFilePath, destination.path)
        XCTAssertEqual(document.displayedFullText, .localPDF(path: destination.path))
        XCTAssertEqual(
            document.cachedFullTextResult?.localPDFPath, destination.path,
            "the rebuilt result must find the file the reader chose"
        )
    }

    /// A non-PDF upload has no file to point at, and must not claim one.
    func testAnUploadedHTMLDocumentRecordsNoPDFPath() {
        let document = makeDocument()
        document.applyFullTextResult(
            .uploaded(content: .html(content: "<p>x</p>", markdown: "x"))
        )

        XCTAssertNil(document.fullTextPDFPath)
        XCTAssertNil(document.fullTextPDFPathIsLocalFile)
        XCTAssertNil(document.localPDFFilePath)
    }

    /// Nothing was downloaded, so what is stored is a link. The file-only
    /// actions — reveal in Finder, open in Preview — must not be offered for it:
    /// they build a `file://` URL that names nothing.
    func testARemoteLinkIsNotOfferedAsAFile() {
        let document = makeDocument()
        document.applyFullTextResult(
            AppFullTextResult(
                content: .pdfURL(URL(string: "https://example.org/paper.pdf")!),
                source: .europePMCPDF
            )
        )

        XCTAssertEqual(document.fullTextPDFPath, "https://example.org/paper.pdf")
        XCTAssertEqual(document.fullTextPDFPathIsLocalFile, false)
        XCTAssertNil(
            document.localPDFFilePath,
            "a remote URL string is not a path Finder can open"
        )
    }

    /// A scan: downloaded and cached fine, no prose recovered. It is a real file
    /// and must stay openable — reading "is this a file?" off the content kind
    /// is what sent exactly this record down the remote-URL branch.
    func testAScanIsStillALocalFile() {
        let document = makeDocument()
        document.applyFullTextResult(
            AppFullTextResult(
                content: .pdfURL(URL(fileURLWithPath: "/tmp/scan.pdf")),
                source: .unpaywall,
                contentKind: .none,
                localPDFPath: "/tmp/scan.pdf"
            )
        )

        XCTAssertEqual(document.localPDFFilePath, "/tmp/scan.pdf")
        XCTAssertNil(document.analyzableFullText, "there is no prose to analyse")
    }

    /// A record written before the flag existed answers `false`, which is what
    /// `URL(string:)` was always applied to — so those records keep behaving
    /// exactly as they did rather than newly claiming to be files.
    func testALegacyRecordIsNotTreatedAsAFile() {
        let document = makeDocument()
        document.fullTextPDFPath = "/tmp/legacy.pdf"
        document.fullTextPDFPathIsLocalFile = nil

        XCTAssertNil(document.localPDFFilePath)
    }
}
