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
    /// Directories a test made read-only, given back their permissions first.
    private var locked: [URL] = []

    private let here = "install-here"
    private let otherLabel = "StudyAnalyzer on a test"
    private let paper = LibraryPaper(pmid: "99999301", doi: nil, pmcId: nil, title: "A trial of clearing")
    private let pdfBytes = Data("%PDF-1.4\nclear test\n%%EOF\n".utf8)
    private let textBytes = Data("seven".utf8)

    override func tearDown() {
        for url in locked { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        locked = []
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

    /// The files a removal that must succeed took.
    private func removing(_ access: LibraryAccess, folder: String, name: String?) throws -> [LibraryFileReference] {
        switch LibraryClear.remove(access, folder: folder, name: name) {
        case let .removed(files): return files
        case let .failed(why, _): throw why
        }
    }

    /// Another paper's folder holding a copy of `kept` (bmlib keeps bytes
    /// once, but a folder copied by hand or synced in can repeat them).
    private func copiedToAnotherPaper(_ access: LibraryAccess, root: URL, kept: LibraryKept) throws {
        let other = try installationNew(app: "studyanalyzer", id: "0-other", label: otherLabel)
        let info = PaperInfo(ids: try XCTUnwrap(LibraryPaper(pmid: "99999302", doi: nil, pmcId: nil, title: "Another")
            .libraryRequestIDs), title: "Another", year: nil, firstAuthor: nil)
        let saved = try access.library.save(who: other, paper: info, bytes: Data("eight".utf8), kind: .text,
                                            origin: "pasted")
        let copy = URL(fileURLWithPath: kept.path)
        try FileManager.default.copyItem(
            at: copy, to: root.appendingPathComponent("papers/\(saved.folder)/\(copy.lastPathComponent)"))
    }

    private func lock(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: url.path)
        locked.append(url)
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
        XCTAssertFalse(listed.usersUnknown)
        XCTAssertTrue(listing.problems.isEmpty, "\(listing.problems)")
    }

    func testThisAppOnAnotherMacIsAnotherUser() throws {
        let (access, _, _) = try shared()
        let elsewhere = "MedicalFactChecker on another Mac"
        let mac = try installationNew(app: BioMedLitConstants.libraryAppName, id: "install-elsewhere", label: elsewhere)
        let info = PaperInfo(ids: try XCTUnwrap(paper.libraryRequestIDs), title: paper.title, year: nil,
                             firstAuthor: nil)
        _ = try access.library.save(who: mac, paper: info, bytes: textBytes, kind: .text, origin: "pasted")
        let listed = try XCTUnwrap(try listing(access).papers.first)
        let text = try XCTUnwrap(listed.files.first { $0.name.hasPrefix("text-") })
        XCTAssertEqual(Set(text.usedBy), [otherLabel, elsewhere], "\(text)")
        XCTAssertFalse(text.usedHere, "the same app's id tells this installation apart")
        XCTAssertEqual(Set(listed.usedBy), [otherLabel, elsewhere])
    }

    func testAPaperIsUsedByItsRecordsThoughItsFilesAreGone() throws {
        let (access, _, _) = try shared()
        let listed = try XCTUnwrap(try listing(access).papers.first)
        for file in listed.files { _ = try removing(access, folder: listed.folder, name: file.name) }
        let after = try XCTUnwrap(try listing(access).papers.first)
        XCTAssertTrue(after.files.isEmpty)
        XCTAssertEqual(after.usedBy, [otherLabel], "removing the folder deletes its record")
        XCTAssertTrue(after.usedHere)
    }

    func testARecordTheScanCannotReadLeavesTheUsersUnknown() throws {
        let (access, root, _) = try shared()
        let folder = try XCTUnwrap(try listing(access).papers.first).folder
        try Data("not a record".utf8).write(to: root.appendingPathComponent("papers/\(folder)/records/broken.json"))
        let listing = try listing(access)
        XCTAssertFalse(listing.problems.isEmpty)
        XCTAssertTrue(try XCTUnwrap(listing.papers.first).usersUnknown, "\(listing.problems)")
    }

    func testAnUnrecordedFileIsListedForNoAppAndRemoved() throws {
        let (access, root, _) = try shared()
        let before = try XCTUnwrap(try listing(access).papers.first)
        let folder = root.appendingPathComponent("papers/\(before.folder)", isDirectory: true)
        try pdfBytes.write(to: folder.appendingPathComponent("stray.pdf"))
        let listing = try listing(access)
        XCTAssertFalse(listing.problems.isEmpty, "an unrecorded file is a problem")
        let stray = try XCTUnwrap(listing.papers.first?.files.first { $0.name == "stray.pdf" })
        XCTAssertEqual(stray.usedBy, [])
        XCTAssertFalse(stray.usedHere)
        XCTAssertEqual(try removing(access, folder: before.folder, name: "stray.pdf"), [], "no record names it")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("stray.pdf").path))
        XCTAssertEqual(try self.listing(access).papers.first?.files.map(\.name), before.files.map(\.name))
    }

    func testRemovingOneFileLeavesTheRestAndTheRecords() throws {
        let (access, root, kept) = try shared()
        let listed = try XCTUnwrap(try listing(access).papers.first)
        let pdf = try XCTUnwrap(listed.files.first { $0.usedHere })
        let removed = try removing(access, folder: listed.folder, name: pdf.name)
        XCTAssertEqual(removed, [kept.file])
        XCTAssertEqual(try LibraryClear.gone(removed, in: access).get(), removed, "the records still list it")
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
        let removed = try removing(access, folder: folder, name: nil)
        XCTAssertEqual(Set(removed.map(\.kind)), [BioMedLitConstants.libraryKindPDF, BioMedLitConstants.libraryKindText])
        XCTAssertTrue(removed.contains(kept.file))
        XCTAssertEqual(removed.count, 2, "each file once, though two records list the PDF")
        XCTAssertTrue(try listing(access).papers.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("papers/\(folder)").path))
    }

    func testTheSameBytesInAnotherFolderAreNotGone() throws {
        let (access, root, kept) = try shared()
        try copiedToAnotherPaper(access, root: root, kept: kept)
        let folders = try listing(access).papers.map(\.folder)
        XCTAssertEqual(folders.count, 2)
        let first = try XCTUnwrap(try listing(access).papers.first { $0.title == paper.title }).folder
        let removed = try removing(access, folder: first, name: nil)
        XCTAssertTrue(removed.contains(kept.file))
        let gone = try LibraryClear.gone(removed, in: access).get()
        XCTAssertFalse(gone.contains(kept.file), "the other folder still holds it")
        XCTAssertEqual(gone.map(\.kind), [BioMedLitConstants.libraryKindText])
        // The control: the last copy goes
        let last = try XCTUnwrap(folders.first { $0 != first })
        XCTAssertEqual(try LibraryClear.gone(try removing(access, folder: last, name: nil) + [kept.file], in: access)
            .get().filter { $0 == kept.file }, [kept.file])
    }

    func testALibraryThatCannotBeReadIsNoAnswerToWhatIsGone() throws {
        let (access, root, kept) = try shared()
        let papers = root.appendingPathComponent("papers", isDirectory: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: papers.path)
        locked.append(papers)
        guard case let .failure(why) = LibraryClear.gone([kept.file], in: access) else {
            return XCTFail("an unreadable library read as an answer")
        }
        XCTAssertTrue(why.description.hasPrefix(BioMedLitConstants.libraryClearGoneUnchecked(reason: "")
            .dropLast()), why.description)
    }

    func testAFolderRemovedOnlyInPartGivesWhatMayHaveGone() throws {
        let (access, root, kept) = try shared()
        let folder = try XCTUnwrap(try listing(access).papers.first).folder
        try lock(root.appendingPathComponent("papers/\(folder)", isDirectory: true))
        guard case let .failed(why, mayBeGone) = LibraryClear.remove(access, folder: folder, name: nil) else {
            return XCTFail("removed")
        }
        XCTAssertTrue(why.description.hasPrefix(BioMedLitConstants.libraryClearPartlyText(folder: folder, reason: "")),
                      why.description)
        XCTAssertEqual(mayBeGone.count, 2, "\(mayBeGone)")
        XCTAssertTrue(mayBeGone.contains(kept.file))
        // Nothing went here, so no document is told
        XCTAssertEqual(try LibraryClear.gone(mayBeGone, in: access).get(), [])
        XCTAssertEqual(try listing(access).papers.map(\.folder), [folder])
    }

    func testWhatAFreshScanDoesNotListIsRefusedAndNothingRemoved() throws {
        let (access, _, _) = try shared()
        let before = try listing(access)
        let listed = try XCTUnwrap(before.papers.first)
        for (folder, name) in [("no such paper", nil), (listed.folder, "pdf-000000000000.pdf"),
                               (listed.folder, "../bmlib-library.json"), ("..", nil)] as [(String, String?)] {
            switch LibraryClear.remove(access, folder: folder, name: name) {
            case .removed: XCTFail("\(folder) \(name ?? "") was removed")
            case let .failed(failure, mayBeGone):
                XCTAssertTrue(failure.description.contains(BioMedLitConstants.libraryClearStaleReason),
                              failure.description)
                XCTAssertEqual(mayBeGone, [], "nothing was touched")
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
        guard case let .failed(failure, mayBeGone) = LibraryClear.remove(access, folder: "con", name: nil) else {
            return XCTFail("removed")
        }
        XCTAssertEqual(failure.description, BioMedLitConstants.libraryClearRenameText(folder: "con"))
        XCTAssertEqual(mayBeGone, [], "bmlib refuses the name before it deletes anything")
        XCTAssertTrue(FileManager.default.fileExists(atPath: papers.appendingPathComponent("con").path))
    }

    // MARK: The wording

    func testUsersText() {
        XCTAssertEqual(LibraryClear.usersText(usedBy: [], usedHere: false, usersUnknown: false), "used by no app")
        XCTAssertEqual(LibraryClear.usersText(usedBy: ["SA"], usedHere: true, usersUnknown: false),
                       "used by this app, SA")
        XCTAssertEqual(LibraryClear.usersText(usedBy: ["SA", "SA on B"], usedHere: false, usersUnknown: false),
                       "used by SA, SA on B")
        XCTAssertEqual(LibraryClear.usersText(usedBy: [], usedHere: false, usersUnknown: true),
                       "other users unknown (a record could not be read)")
        XCTAssertEqual(LibraryClear.usersText(usedBy: ["SA"], usedHere: false, usersUnknown: true),
                       "used by SA; other users unknown (a record could not be read)")
    }

    func testRemoveQuestionNamesTheOtherApps() {
        XCTAssertEqual(LibraryClear.removeQuestion(what: "T", usedBy: ["SA"], usedHere: false, usersUnknown: false),
                       "Remove “T” from the paper library? It is deleted from the folder. "
                       + "Still used by SA: it reports it missing and will not download it again.")
        XCTAssertTrue(LibraryClear.removeQuestion(what: "T", usedBy: ["SA", "SA on B"], usedHere: true, usersUnknown: false)
            .contains("Still used by SA, SA on B: they report it missing"))
        XCTAssertTrue(LibraryClear.removeQuestion(what: "T", usedBy: ["SA"], usedHere: true, usersUnknown: false)
            .hasSuffix(BioMedLitConstants.libraryClearUsedHere))
        XCTAssertTrue(LibraryClear.removeQuestion(what: "T", usedBy: [], usedHere: false, usersUnknown: false)
            .hasSuffix(BioMedLitConstants.libraryClearUsedByNone))
        XCTAssertFalse(LibraryClear.removeQuestion(what: "T", usedBy: [], usedHere: true, usersUnknown: false)
            .contains(BioMedLitConstants.libraryClearUsedByNone))
        let unknown = LibraryClear.removeQuestion(what: "T", usedBy: [], usedHere: false, usersUnknown: true)
        XCTAssertTrue(unknown.hasSuffix(BioMedLitConstants.libraryClearMaybeUsed), unknown)
        XCTAssertFalse(unknown.contains(BioMedLitConstants.libraryClearUsedByNone), "unknown is not no app")
        XCTAssertTrue(LibraryClear.removeQuestion(what: "T", usedBy: ["SA"], usedHere: false, usersUnknown: true)
            .contains(BioMedLitConstants.libraryClearStillUsed(by: ["SA"]) + " " + BioMedLitConstants.libraryClearMaybeUsed))
    }

    func testPaperSizeSaysWhenSomeAreUnknown() {
        let file = { (size: UInt64?) in LibraryListedFile(name: "f", size: size, usedBy: [], usedHere: false) }
        let sizes = { (files: [LibraryListedFile]) in
            LibraryClear.sizeText(of: LibraryListedPaper(folder: "p", title: nil, files: files, usedBy: [], usedHere: false,
                                                    usersUnknown: false))
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
        func paper(title: String?) -> LibraryListedPaper {
            LibraryListedPaper(folder: "p", title: title, files: [], usedBy: [], usedHere: false, usersUnknown: false)
        }
        XCTAssertEqual(paper(title: "T").label, "T")
        XCTAssertEqual(paper(title: nil).label, "p")
    }
}
#endif
