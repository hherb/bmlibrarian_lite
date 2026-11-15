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

#if os(macOS)
import BioMedLit
import XCTest
@testable import MedicalFactChecker

/// 3c: which of the documents' files the move takes, and what each outcome
/// writes back to them. Pure: the cache is a folder URL and the names in it.
@MainActor
final class LibraryMoverTests: XCTestCase {

    private let cache = URL(fileURLWithPath: "/tmp/mfc-cache", isDirectory: true)
    private let digest = String(repeating: "c", count: 64)

    /// A document whose local PDF is `name` in the cache (nil: no PDF).
    private func document(pmid: String = "99999301", title: String = "A paper", pdf name: String? = nil,
                          waiting: String? = nil) -> Document {
        let document = Document(pmid: pmid, title: title, abstract: "")
        document.fullTextSource = AppFullTextSource.unpaywall.rawValue
        if let name {
            document.fullTextPDFPath = cache.appendingPathComponent(name).path
            document.fullTextPDFPathIsLocalFile = true
        }
        document.fullTextLibraryWaiting = waiting
        return document
    }

    private func key(_ document: Document) throws -> ArticleCacheKey {
        try XCTUnwrap(ArticleCacheKey(pmid: document.pmid, pmcId: document.pmcId, doi: document.doi,
                                      primaryKind: document.resolvedIdentifierKind))
    }

    private func kept(_ path: String, kind: String = BioMedLitConstants.libraryKindPDF) -> LibraryKept {
        LibraryKept(file: LibraryFileReference(sha256: digest, kind: kind), path: path)
    }

    func testSharedCacheFileMovesOnceForEveryDocument() throws {
        let one = document(pdf: "p.pdf")
        let two = document(pdf: "p.pdf")
        let groups = LibraryMover.moveItems([one, two], cacheDirectory: cache, cacheNames: ["p.pdf"],
                                            onlyWaiting: false)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.item.path, cache.appendingPathComponent("p.pdf").path)
        XCTAssertEqual(groups.first?.item.kind, BioMedLitConstants.libraryKindPDF)
        XCTAssertEqual(groups.first?.item.origin, AppFullTextSource.unpaywall.displayName)
        XCTAssertEqual(groups.first?.item.paper.pmid, "99999301")
        XCTAssertEqual(groups.first?.documents.count, 2)

        let summary = LibraryMover.apply([.moved(kept("/lib/papers/a/p.pdf"))], to: groups.map(\.documents))
        XCTAssertEqual(summary, LibraryMoveSummary(moved: 1, failed: []))
        for document in [one, two] {
            XCTAssertEqual(document.localPDFFilePath, "/lib/papers/a/p.pdf")
            XCTAssertEqual(document.fullTextLibrarySHA256, digest)
            XCTAssertEqual(document.fullTextLibraryKind, BioMedLitConstants.libraryKindPDF)
        }
    }

    func testMissingCacheFileIsNotAnItem() {
        XCTAssertTrue(LibraryMover.moveItems([document(pdf: "gone.pdf")], cacheDirectory: cache, cacheNames: [],
                                             onlyWaiting: false).isEmpty)
    }

    func testPathOutsideTheCacheIsNotAnItem() {
        let document = document()
        document.fullTextPDFPath = "/lib/papers/a/p.pdf"
        document.fullTextPDFPathIsLocalFile = true
        XCTAssertTrue(LibraryMover.moveItems([document], cacheDirectory: cache, cacheNames: ["p.pdf"],
                                             onlyWaiting: false).isEmpty)
    }

    func testWaitingJATSIsAnItem() throws {
        let document = document(waiting: "the folder could not be found")
        let name = "\(try key(document).filenameComponent)-abc123def456.xml"
        let groups = LibraryMover.moveItems([document], cacheDirectory: cache,
                                            cacheNames: [name, "other-abc123def456.xml"], onlyWaiting: false)
        XCTAssertEqual(groups.map(\.item.path), [cache.appendingPathComponent(name).path])
        XCTAssertEqual(groups.first?.item.kind, BioMedLitConstants.libraryKindJATS)

        _ = LibraryMover.apply([.moved(kept("/lib/papers/a/x.xml", kind: BioMedLitConstants.libraryKindJATS))],
                               to: groups.map(\.documents))
        XCTAssertEqual(document.fullTextLibraryKind, BioMedLitConstants.libraryKindJATS)
        XCTAssertNil(document.fullTextLibraryWaiting, "moved in: it waits no more")
        XCTAssertNil(document.localPDFFilePath, "a JATS sets no PDF path")
    }

    func testAnotherKeysWaitingJATSIsNotTaken() throws {
        let document = document(pmid: "")
        document.doi = "10.99999/a"
        let other = try XCTUnwrap(ArticleCacheKey(pmid: "", pmcId: nil, doi: "10.99999/a-b"))
        let theirs = "\(other.filenameComponent)-abc123def456.xml"
        XCTAssertTrue(LibraryMover.isWaitingJATS(theirs, of: other))
        XCTAssertFalse(LibraryMover.isWaitingJATS(theirs, of: try key(document)))
    }

    func testOnlyWaitingSkipsPlainCache() {
        let plain = document(pmid: "99999302", pdf: "a.pdf")
        let waiting = document(pmid: "99999303", pdf: "b.pdf", waiting: "unplugged")
        let groups = LibraryMover.moveItems([plain, waiting], cacheDirectory: cache, cacheNames: ["a.pdf", "b.pdf"],
                                            onlyWaiting: true)
        XCTAssertEqual(groups.map(\.item.path), [cache.appendingPathComponent("b.pdf").path])
    }

    func testFailedMoveNamesThePaper() {
        let document = document(title: "Moving trial", pdf: "p.pdf", waiting: "unplugged")
        let groups = LibraryMover.moveItems([document], cacheDirectory: cache, cacheNames: ["p.pdf"],
                                            onlyWaiting: false)
        let summary = LibraryMover.apply([.failed("library, paper pmid=99999301: unreachable")], to: groups.map(\.documents))
        XCTAssertEqual(summary, LibraryMoveSummary(moved: 0, failed: ["Moving trial: library, paper pmid=99999301: unreachable"]))
        XCTAssertEqual(document.localPDFFilePath, cache.appendingPathComponent("p.pdf").path)
        XCTAssertEqual(document.fullTextLibraryWaiting, "unplugged", "still waiting")
    }

    /// A switch's copy: the documents of a file not copied are told where it was left.
    func testFailedCopyNotesTheDocument() {
        let document = document()
        document.fullTextLibrarySHA256 = digest
        document.fullTextLibraryKind = BioMedLitConstants.libraryKindJATS
        let groups = LibraryMover.libraryFiles([document])
        XCTAssertEqual(groups.map(\.file), [LibraryFileReference(sha256: digest, kind: BioMedLitConstants.libraryKindJATS)])
        let note = BioMedLitConstants.libraryNotCarriedNote(folderName: "Old")
        _ = LibraryMover.apply([.failed("unreadable")], to: groups.map(\.documents),
                               notCarriedNote: note)
        XCTAssertEqual(document.fullTextLibraryNote, note)
    }

    func testStopUsingNotesUncopiedDocuments() {
        let inLibrary = document()
        inLibrary.fullTextLibrarySHA256 = digest
        inLibrary.fullTextLibraryKind = BioMedLitConstants.libraryKindPDF
        let notInLibrary = document(pmid: "99999304")
        LibraryMover.notCarried([inLibrary, notInLibrary], note: BioMedLitConstants.libraryNoLongerUsedNote)
        XCTAssertEqual(inLibrary.fullTextLibraryNote, BioMedLitConstants.libraryNoLongerUsedNote)
        XCTAssertNil(notInLibrary.fullTextLibraryNote)
        XCTAssertEqual(inLibrary.libraryNotices(libraryState: .notChosen).count, 1)
        XCTAssertTrue(inLibrary.libraryNotices(libraryState: .notChosen)[0]
            .contains(BioMedLitConstants.libraryNoLongerUsedNote))
    }

    func testCopyBackPointsThePDFAtTheAppCopy() {
        let document = document()
        document.fullTextPDFPath = "/lib/papers/a/p.pdf"
        document.fullTextPDFPathIsLocalFile = true
        document.fullTextLibrarySHA256 = digest
        document.fullTextLibraryKind = BioMedLitConstants.libraryKindPDF
        document.storeAppCopy(at: "/tmp/mfc-cache/k-cccccccccccc.pdf", kind: BioMedLitConstants.libraryKindPDF)
        XCTAssertEqual(document.localPDFFilePath, "/tmp/mfc-cache/k-cccccccccccc.pdf")
        XCTAssertNil(document.fullTextLibrarySHA256)
        XCTAssertNil(document.fullTextLibraryKind)
    }
}
#endif
