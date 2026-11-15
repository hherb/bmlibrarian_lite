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
import CryptoKit
import XCTest
@testable import BioMedLit

/// A library whose `keep` and `read` answer what the test sets: the faults a
/// real library cannot be made to show on demand.
private final class ScriptedLibrary: FullTextLibrary, @unchecked Sendable {
    var keepAnswer: Result<LibraryKept?, LibraryLookupFailure> = .success(nil)
    var readAnswer: Result<Data, LibraryLookupFailure> = .success(Data())

    func jats(for paper: LibraryPaper) -> LibraryJATSLookup { .none }
    func pdf(for paper: LibraryPaper) -> Result<LibraryHeldPDF?, LibraryLookupFailure> { .success(nil) }
    func keep(_ bytes: Data, kind: String, paper: LibraryPaper, origin: String)
        -> Result<LibraryKept?, LibraryLookupFailure> { keepAnswer }
    func noteUse(_ file: LibraryFileReference, paper: LibraryPaper) -> LibraryLookupFailure? { nil }
    func path(of file: LibraryFileReference) -> String? { nil }
    func read(_ file: LibraryFileReference) -> Result<Data, LibraryLookupFailure> { readAnswer }
}

final class LibraryMoveTests: XCTestCase {

    private var made: [URL] = []
    private var accesses: [LibraryAccess] = []

    override func tearDown() {
        for access in accesses { access.stop() }
        accesses = []
        for url in made { try? FileManager.default.removeItem(at: url) }
        made = []
        super.tearDown()
    }

    /// A fresh empty temporary folder (resolved: `/var` is `/private/var`).
    private func folder(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mfc-move-\(name)-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        made.append(url)
        return url
    }

    /// A fresh real library as one installation.
    private func library(id: String = "install-a") throws -> (LibrarySource, LibraryAccess) {
        let access = try LibrarySetup.choose(try folder("lib")).access
        accesses.append(access)
        return (try LibrarySource(access: access, installationID: id, label: "MedicalFactChecker on test"), access)
    }

    private let paper = LibraryPaper(pmid: "99999201", doi: "10.99999/move-test", pmcId: nil,
                                     title: "A trial of moving files")

    private let pdfBytes = Data("%PDF-1.4\nmove test\n%%EOF\n".utf8)

    /// `bytes` written in a fresh app folder, as an item for `paper`.
    private func item(_ bytes: Data, kind: String = BioMedLitConstants.libraryKindPDF,
                      paper: LibraryPaper? = nil) throws -> LibraryMoveItem {
        let url = try folder("app").appendingPathComponent("cached.pdf")
        try bytes.write(to: url)
        return LibraryMoveItem(paper: paper ?? self.paper, path: url.path, kind: kind, origin: "Unpaywall")
    }

    private func failure(_ text: String, waits: Bool = false) -> LibraryLookupFailure {
        LibraryLookupFailure(description: text, waits: waits)
    }

    func testMovedFileIsInTheLibraryAndTheAppCopyIsGone() throws {
        let (library, _) = try library()
        let item = try item(pdfBytes)
        let outcomes = LibraryMove.moveIn([item], into: library)
        guard case let .moved(kept) = try XCTUnwrap(outcomes.first) else {
            return XCTFail("not moved: \(outcomes)")
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: kept.path)), pdfBytes)
        XCTAssertEqual(kept.file.kind, BioMedLitConstants.libraryKindPDF)
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.path), "the app's copy goes once checked")
    }

    func testRefusedSaveLeavesTheAppCopy() throws {
        let library = ScriptedLibrary()
        library.keepAnswer = .failure(failure("library, paper pmid=99999201: a name clash"))
        let item = try item(pdfBytes)
        XCTAssertEqual(LibraryMove.moveIn([item], into: library),
                       [.failed("library, paper pmid=99999201: a name clash")])
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.path))
    }

    func testReadBackMismatchLeavesTheAppCopy() throws {
        let library = ScriptedLibrary()
        let kept = LibraryKept(file: LibraryFileReference(sha256: String(repeating: "a", count: 64),
                                                          kind: BioMedLitConstants.libraryKindPDF),
                               path: "/nowhere/x.pdf")
        library.keepAnswer = .success(kept)
        library.readAnswer = .success(Data("other bytes".utf8))
        let item = try item(pdfBytes)
        let outcome = try XCTUnwrap(LibraryMove.moveIn([item], into: library).first)
        guard case let .failed(reason) = outcome else { return XCTFail("moved: \(outcome)") }
        XCTAssertTrue(reason.contains(BioMedLitConstants.libraryMoveReadBackMismatchReason), reason)
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.path))
    }

    func testFailedReadBackLeavesTheAppCopy() throws {
        let library = ScriptedLibrary()
        library.keepAnswer = .success(LibraryKept(
            file: LibraryFileReference(sha256: String(repeating: "b", count: 64), kind: BioMedLitConstants.libraryKindPDF),
            path: "/nowhere/x.pdf"))
        library.readAnswer = .failure(failure("library, file pdf bbbb: digest mismatch"))
        let item = try item(pdfBytes)
        XCTAssertEqual(LibraryMove.moveIn([item], into: library), [.failed("library, file pdf bbbb: digest mismatch")])
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.path))
    }

    func testUnreadableSourceFails() throws {
        let (library, _) = try library()
        let gone = LibraryMoveItem(paper: paper, path: try folder("app").appendingPathComponent("gone.pdf").path,
                                   kind: BioMedLitConstants.libraryKindPDF, origin: "Unpaywall")
        let outcome = try XCTUnwrap(LibraryMove.moveIn([gone], into: library).first)
        guard case .failed = outcome else { return XCTFail("moved: \(outcome)") }
    }

    func testNoIdentifierFails() throws {
        let (library, _) = try library()
        let item = try item(pdfBytes, paper: LibraryPaper(pmid: nil, doi: nil, pmcId: nil))
        XCTAssertEqual(LibraryMove.moveIn([item], into: library),
                       [.failed(BioMedLitConstants.libraryMoveNoIdentifierReason)])
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.path))
    }

    func testUnreachableLibraryLeavesEveryAppCopy() throws {
        let library = UnreachableLibrary(reason: "the folder could not be found")
        let items = try (0..<3).map { _ in try item(pdfBytes) }
        let outcomes = LibraryMove.moveIn(items, into: library)
        XCTAssertEqual(outcomes.count, 3)
        for outcome in outcomes {
            guard case let .failed(reason) = outcome else { return XCTFail("moved: \(outcome)") }
            XCTAssertTrue(reason.contains("the folder could not be found"), reason)
        }
        for item in items { XCTAssertTrue(FileManager.default.fileExists(atPath: item.path)) }
    }

    func testCopyLeavesTheOldLibraryUnchanged() throws {
        let (old, oldAccess) = try library()
        let (new, _) = try library()
        guard case let .moved(first) = try XCTUnwrap(LibraryMove.moveIn([try item(pdfBytes)], into: old).first) else {
            return XCTFail("not kept in the old library")
        }
        let before = try FileManager.default.subpathsOfDirectory(atPath: oldAccess.folderURL.path).sorted()
        let outcome = try XCTUnwrap(LibraryMove.copy([(first.file, paper)], from: old, to: new).first)
        guard case let .moved(copied) = outcome else { return XCTFail("not copied: \(outcome)") }
        XCTAssertEqual(copied.file, first.file)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: copied.path)), pdfBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path), "the old folder keeps its file")
        XCTAssertEqual(try FileManager.default.subpathsOfDirectory(atPath: oldAccess.folderURL.path).sorted(), before)
    }

    func testCopyBackWritesTheAppName() throws {
        let (library, _) = try library()
        let jatsBytes = Data("<article/>".utf8)
        guard case let .moved(pdf) = try XCTUnwrap(LibraryMove.moveIn([try item(pdfBytes)], into: library).first),
              case let .moved(jats) = try XCTUnwrap(LibraryMove.moveIn(
                [try item(jatsBytes, kind: BioMedLitConstants.libraryKindJATS)], into: library).first) else {
            return XCTFail("not kept")
        }
        let key = try XCTUnwrap(ArticleCacheKey(pmid: "99999201", pmcId: nil, doi: nil))
        let cache = try folder("cache")
        let paths = LibraryMove.copyBack([(pdf.file, key), (jats.file, key)], from: library, into: cache)
            .map { try? $0.get() }
        let sha12 = { (data: Data) in
            String(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(12))
        }
        XCTAssertEqual(paths, [
            cache.appendingPathComponent("\(key.filenameComponent)-\(sha12(pdfBytes)).pdf").path,
            cache.appendingPathComponent("\(key.filenameComponent)-\(sha12(jatsBytes)).xml").path,
        ])
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(paths[0]))), pdfBytes)
    }
}
#endif
