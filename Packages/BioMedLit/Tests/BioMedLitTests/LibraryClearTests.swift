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
import BmlibCore
import XCTest
@testable import BioMedLit

/// The manual clear (design §4.8): the listing's users and sizes, and the
/// removal of a paper or one file, refusing what a fresh scan does not list.
/// Each test works in a fresh library of its own, which this app and
/// StudyAnalyzer both use.
final class LibraryClearTests: XCTestCase {

    private var made: [URL] = []
    private var accesses: [LibraryAccess] = []

    private let here = "install-here"
    private let otherLabel = "StudyAnalyzer on a test"
    private let paper = LibraryPaper(pmid: "99999301", doi: nil, pmcId: nil, title: "A trial of clearing")
    private let pdfBytes = Data("%PDF-1.4\nclear test\n%%EOF\n".utf8)
    private let textBytes = Data("seven".utf8)

    override func tearDown() {
        for access in accesses { access.stop() }
        accesses = []
        for url in made { try? FileManager.default.removeItem(at: url) }
        made = []
        super.tearDown()
    }

    /// A fresh library holding one paper: a PDF this app and StudyAnalyzer
    /// use, and a text file only StudyAnalyzer uses.
    private func shared() throws -> (LibraryAccess, URL, LibraryKept) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mfc-clear-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        made.append(url)
        let access = try LibrarySetup.choose(url).access
        accesses.append(access)
        let source = try LibrarySource(access: access, installationID: here, label: "MedicalFactChecker on test")
        let kept = try XCTUnwrap(try source.keep(pdfBytes, kind: BioMedLitConstants.libraryKindPDF,
                                                 paper: paper, origin: "Unpaywall").get())
        let other = try installationNew(app: "studyanalyzer", id: "0-other", label: otherLabel)
        let info = PaperInfo(ids: try XCTUnwrap(paper.libraryRequestIDs), title: paper.title, year: nil,
                             firstAuthor: nil)
        _ = try access.library.save(who: other, paper: info, bytes: pdfBytes, kind: .pdf, origin: "Europe PMC")
        _ = try access.library.save(who: other, paper: info, bytes: textBytes, kind: .text, origin: "pasted")
        return (access, url, kept)
    }

    private func listing(_ access: LibraryAccess) throws -> LibraryListing {
        try LibraryClear.list(access, installationID: here).get()
    }

    func testListingNamesUsersAndSizes() throws {
        let (access, _, _) = try shared()
        let listing = try listing(access)
        XCTAssertEqual(listing.papers.count, 1, "\(listing)")
        let listed = try XCTUnwrap(listing.papers.first)
        XCTAssertEqual(listed.title, "A trial of clearing")
        let pdf = try XCTUnwrap(listed.files.first { $0.name.hasPrefix("pdf-") })
        XCTAssertEqual(pdf, LibraryListedFile(name: pdf.name, size: UInt64(pdfBytes.count),
                                              usedBy: [otherLabel], usedHere: true))
        let text = try XCTUnwrap(listed.files.first { $0.name.hasPrefix("text-") })
        XCTAssertEqual(text, LibraryListedFile(name: text.name, size: 5, usedBy: [otherLabel], usedHere: false))
        XCTAssertEqual(listed.usedBy, [otherLabel], "each other app once")
        XCTAssertTrue(listed.usedHere)
        XCTAssertTrue(listing.problems.isEmpty, "\(listing.problems)")
    }

    func testRemovingOneFileLeavesTheRestAndTheRecords() throws {
        let (access, root, kept) = try shared()
        let listed = try XCTUnwrap(try listing(access).papers.first)
        let pdf = try XCTUnwrap(listed.files.first { $0.usedHere })
        let removed = try LibraryClear.remove(access, folder: listed.folder, name: pdf.name).get()
        XCTAssertEqual(removed, [kept.file])
        XCTAssertFalse(FileManager.default.fileExists(atPath: kept.path))
        let after = try XCTUnwrap(try listing(access).papers.first)
        XCTAssertEqual(after.files.map(\.name), listed.files.map(\.name).filter { $0 != pdf.name })
        // The records still list it, so each app reports it missing
        let records = try XCTUnwrap(try access.library.scan().folders().first).records
        XCTAssertTrue(records.allSatisfy { $0.files.contains { $0.name == pdf.name } }, "\(records)")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("papers/\(listed.folder)").path))
    }

    func testRemovingAPaperTakesItsFolder() throws {
        let (access, root, kept) = try shared()
        let folder = try XCTUnwrap(try listing(access).papers.first).folder
        let removed = try LibraryClear.remove(access, folder: folder, name: nil).get()
        XCTAssertEqual(Set(removed.map(\.kind)), [BioMedLitConstants.libraryKindPDF, BioMedLitConstants.libraryKindText])
        XCTAssertTrue(removed.contains(kept.file))
        XCTAssertEqual(removed.count, 2, "each file once, though two records list the PDF")
        XCTAssertTrue(try listing(access).papers.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("papers/\(folder)").path))
    }

    func testWhatAFreshScanDoesNotListIsRefusedAndNothingRemoved() throws {
        let (access, _, _) = try shared()
        let before = try listing(access)
        let listed = try XCTUnwrap(before.papers.first)
        for (folder, name) in [("no such paper", nil), (listed.folder, "pdf-000000000000.pdf"),
                               (listed.folder, "../bmlib-library.json"), ("..", nil)] as [(String, String?)] {
            switch LibraryClear.remove(access, folder: folder, name: name) {
            case .success: XCTFail("\(folder) \(name ?? "") was removed")
            case let .failure(failure):
                XCTAssertTrue(failure.description.contains(BioMedLitConstants.libraryClearStaleReason),
                              failure.description)
            }
        }
        XCTAssertEqual(try listing(access), before)
    }

    func testAFolderBmlibCannotNameIsListedAndNotRemoved() throws {
        let (access, root, _) = try shared()
        let folder = try XCTUnwrap(try listing(access).papers.first).folder
        let papers = root.appendingPathComponent("papers", isDirectory: true)
        try FileManager.default.moveItem(at: papers.appendingPathComponent(folder),
                                         to: papers.appendingPathComponent("con"))
        let listing = try listing(access)
        // Still listed, so it can be seen; the scan's problem for it is newer than the pin
        XCTAssertEqual(listing.papers.map(\.folder), ["con"])
        guard case let .failure(failure) = LibraryClear.remove(access, folder: "con", name: nil) else {
            return XCTFail("removed")
        }
        XCTAssertEqual(failure.description, BioMedLitConstants.libraryClearRenameText(folder: "con"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: papers.appendingPathComponent("con").path))
    }

    // MARK: The wording

    func testUsersText() {
        XCTAssertEqual(LibraryClear.usersText(usedBy: [], usedHere: false), "used by no app")
        XCTAssertEqual(LibraryClear.usersText(usedBy: ["SA"], usedHere: true), "used by this app, SA")
        XCTAssertEqual(LibraryClear.usersText(usedBy: ["SA", "SA on B"], usedHere: false), "used by SA, SA on B")
    }

    func testRemoveQuestionNamesTheOtherApps() {
        XCTAssertEqual(LibraryClear.removeQuestion(what: "T", usedBy: ["SA"], usedHere: false),
                       "Remove “T” from the paper library? It is deleted from the folder. "
                       + "Still used by SA: it reports it missing and will not download it again.")
        XCTAssertTrue(LibraryClear.removeQuestion(what: "T", usedBy: ["SA", "SA on B"], usedHere: true)
            .contains("Still used by SA, SA on B: they report it missing"))
        XCTAssertTrue(LibraryClear.removeQuestion(what: "T", usedBy: ["SA"], usedHere: true)
            .hasSuffix(BioMedLitConstants.libraryClearUsedHere))
        XCTAssertTrue(LibraryClear.removeQuestion(what: "T", usedBy: [], usedHere: false)
            .hasSuffix(BioMedLitConstants.libraryClearUsedByNone))
        XCTAssertFalse(LibraryClear.removeQuestion(what: "T", usedBy: [], usedHere: true)
            .contains(BioMedLitConstants.libraryClearUsedByNone))
    }

    func testPaperSizeSaysWhenSomeAreUnknown() {
        let file = { (size: UInt64?) in LibraryListedFile(name: "f", size: size, usedBy: [], usedHere: false) }
        let sizes = { (files: [LibraryListedFile]) in
            LibraryClear.sizeText(of: LibraryListedPaper(folder: "p", title: nil, files: files))
        }
        XCTAssertEqual(sizes([file(nil)]), BioMedLitConstants.libraryClearSizeUnknown)
        XCTAssertEqual(sizes([file(2_000), file(3_000)]), LibraryClear.sizeText(5_000))
        XCTAssertEqual(sizes([file(2_000), file(nil)]),
                       LibraryClear.sizeText(2_000) + BioMedLitConstants.libraryClearSomeSizesUnknown)
    }

    func testProblemsText() {
        XCTAssertNil(LibraryClear.problemsText([]))
        XCTAssertEqual(LibraryClear.problemsText(["a"]), "The library scan also found 1 thing it did not use: a.")
        XCTAssertEqual(LibraryClear.problemsText(["a", "b"]),
                       "The library scan also found 2 things it did not use: a; b.")
    }

    func testLabelIsTheTitleOrTheFolder() {
        XCTAssertEqual(LibraryListedPaper(folder: "p", title: "T", files: []).label, "T")
        XCTAssertEqual(LibraryListedPaper(folder: "p", title: nil, files: []).label, "p")
    }
}
#endif
