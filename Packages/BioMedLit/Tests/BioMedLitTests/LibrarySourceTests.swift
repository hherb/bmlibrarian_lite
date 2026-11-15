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

/// The fetch's library source reading and saving by bmlib's rules (design
/// §4.3–4.5). Each test works in a fresh library folder of its own.
final class LibrarySourceTests: XCTestCase {

    private var made: [URL] = []
    private var accesses: [LibraryAccess] = []

    override func tearDown() {
        for access in accesses { access.stop() }
        accesses = []
        for url in made { try? FileManager.default.removeItem(at: url) }
        made = []
        super.tearDown()
    }

    /// A fresh library in an empty temporary folder (resolved: `/var` is
    /// `/private/var`).
    private func freshLibrary() throws -> (LibraryAccess, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mfc-src-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        made.append(url)
        let access = try LibrarySetup.choose(url).access
        accesses.append(access)
        return (access, url)
    }

    /// A source over `access` as the installation `id`.
    private func source(_ access: LibraryAccess, id: String = "install-a") throws -> LibrarySource {
        try LibrarySource(access: access, installationID: id, label: "MedicalFactChecker on test")
    }

    /// A small JATS article with the given ids, with or without body prose.
    private func jats(pmid: String, doi: String, body: Bool = true) -> Data {
        let bodyXML = body ? "<body><sec><title>Methods</title><p>We measured things.</p></sec></body>" : ""
        return Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <article><front><article-meta>
            <article-id pub-id-type="pmid">\(pmid)</article-id>
            <article-id pub-id-type="doi">\(doi)</article-id>
            <title-group><article-title>A trial of things</article-title></title-group>
            <abstract><p>Things were tried.</p></abstract>
            </article-meta></front>\(bodyXML)</article>
            """.utf8)
    }

    private func paper(pmid: String? = "1", doi: String? = nil) -> LibraryPaper {
        LibraryPaper(pmid: pmid, doi: doi, pmcId: nil, title: "A trial of things", year: nil, firstAuthor: nil)
    }

    /// Keep `bytes` and return what was kept, failing the test otherwise.
    private func kept(_ src: LibrarySource, _ bytes: Data, kind: String, paper: LibraryPaper) throws -> LibraryKept {
        switch src.keep(bytes, kind: kind, paper: paper, origin: "Test tier") {
        case let .success(kept?): return kept
        case .success(nil):
            let failure = LibraryLookupFailure(description: "not kept: the paper has no identifiers", waits: false)
            XCTFail(failure.description)
            throw failure
        case let .failure(failure): XCTFail("keep failed: \(failure)"); throw failure
        }
    }

    /// Every regular file under `folder`, relative path to bytes.
    private func contents(of folder: URL) -> [String: Data] {
        var out: [String: Data] = [:]
        let base = folder.path
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else {
            return out
        }
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            out[String(url.resolvingSymlinksInPath().path.dropFirst(base.count))] = try? Data(contentsOf: url)
        }
        return out
    }

    func testJATSKeptThenFoundIsUsable() throws {
        let (access, _) = try freshLibrary()
        let src = try source(access)
        let bytes = jats(pmid: "1", doi: "10.1/a")
        let k = try kept(src, bytes, kind: "jats", paper: paper(doi: "10.1/a"))
        XCTAssertEqual(k.file.kind, "jats")
        guard case let .usable(data, file) = src.jats(for: paper(doi: "10.1/a")) else {
            return XCTFail("not usable: \(src.jats(for: paper(doi: "10.1/a")))")
        }
        XCTAssertEqual(data, bytes)
        XCTAssertEqual(file, k.file)
    }

    func testForeignLibraryJATSIsWrongPaper() throws {
        let (access, _) = try freshLibrary()
        // Planted by another installation under a record with the pmid only:
        // the JATS's own doi is one the record does not claim.
        let other = try source(access, id: "install-b")
        _ = try kept(other, jats(pmid: "1", doi: "10.1/a"), kind: "jats", paper: paper())
        let src = try source(access)
        guard case let .wrongPaper(message) = src.jats(for: paper(doi: "10.1/b")) else {
            return XCTFail("not wrong paper: \(src.jats(for: paper(doi: "10.1/b")))")
        }
        XCTAssertTrue(message.contains("10.1/a"), message)
        XCTAssertTrue(message.contains("10.1/b"), message)
        XCTAssertTrue(message.contains("another paper's"), message)
    }

    func testTamperedLibraryJATSIsFailedNamingDigest() throws {
        let (access, _) = try freshLibrary()
        let src = try source(access)
        let k = try kept(src, jats(pmid: "1", doi: "10.1/a"), kind: "jats", paper: paper())
        try Data("<article>not what was saved</article>".utf8).write(to: URL(fileURLWithPath: k.path))
        guard case let .failed(failure) = src.jats(for: paper()) else {
            return XCTFail("not failed: \(src.jats(for: paper()))")
        }
        let message = failure.description
        XCTAssertTrue(message.contains("digest"), message)
        XCTAssertTrue(message.contains(URL(fileURLWithPath: k.path).lastPathComponent), message)
        XCTAssertTrue(message.hasPrefix("library, paper pmid=1 file "), message)
        XCTAssertFalse(failure.waits, "the library was reached")
    }

    /// bmlib refuses to save a JATS whose own ids name another paper: the
    /// library was reached, so the source does not wait for it.
    func testForeignJATSSaveDoesNotWait() throws {
        let (access, _) = try freshLibrary()
        let src = try source(access)
        guard case let .failure(failure) = src.keep(jats(pmid: "1", doi: "10.1/a"), kind: "jats",
                                                   paper: paper(doi: "10.1/b"), origin: "Test") else {
            return XCTFail("kept another paper's JATS")
        }
        XCTAssertFalse(failure.waits, failure.description)
    }

    /// Which of bmlib's errors leave a source waiting (Ruling R): the library
    /// not reached, read or written waits; one reached that refused does not.
    func testWhichFailuresWait() {
        let waiting: [LibraryError] = [
            .Unreachable(path: "/l", reason: "gone"), .NotALibrary(path: "/l", reason: "no marker"),
            .NewerLibrary(version: 9), .ReadOnly(path: "/l"), .Missing(folder: "f", name: "n"),
            .NotDownloaded(folder: "f", name: "n"), .Io(path: "/l", reason: "denied"),
        ]
        let refused: [LibraryError] = [
            .BadIdentifier(field: "pmid", value: "x"), .BadInstallation(field: "id", reason: "r"),
            .BadName(name: "a/b"), .DigestMismatch(folder: "f", name: "n", expected: "a", found: "b"),
            .FileClash(folder: "/l/papers/f", name: "n"), .NewerRecord(folder: "f", file: "r", version: 9),
            .ForeignJats(folder: nil, name: "n", field: "doi", theirs: "a", ours: "b"),
        ]
        for error in waiting { XCTAssertTrue(LibrarySource.waits(error), "\(error)") }
        for error in refused { XCTAssertFalse(LibrarySource.waits(error), "\(error)") }
        XCTAssertFalse(LibrarySource.waits("pdfx is not a kind of file the library holds"), "our own reason")
        XCTAssertTrue(LibrarySource.waits(CocoaError(.fileReadUnknown)), "anything else keeps the source")
    }

    func testBodylessJATSIsUnusable() throws {
        let (access, _) = try freshLibrary()
        let src = try source(access)
        _ = try kept(src, jats(pmid: "1", doi: "10.1/a", body: false), kind: "jats", paper: paper())
        guard case let .unusable(note) = src.jats(for: paper()) else {
            return XCTFail("not unusable: \(src.jats(for: paper()))")
        }
        XCTAssertTrue(note.contains("no body"), note)
    }

    func testNoIdentifiersTouchesNothing() throws {
        let (access, root) = try freshLibrary()
        let src = try source(access)
        let before = contents(of: root)
        let none = paper(pmid: "not a pmid", doi: nil)
        guard case .none = src.jats(for: none) else { return XCTFail("jats was not .none") }
        guard case .success(nil) = src.pdf(for: none) else { return XCTFail("pdf was not nil") }
        guard case .success(nil) = src.keep(Data("%PDF-1.4".utf8), kind: "pdf", paper: none, origin: "Test") else {
            return XCTFail("keep was not nil")
        }
        XCTAssertNil(src.noteUse(LibraryFileReference(sha256: String(repeating: "a", count: 64), kind: "pdf"),
                                 paper: none))
        XCTAssertEqual(contents(of: root), before)
    }

    func testNoteUseWritesOnce() throws {
        let (access, root) = try freshLibrary()
        let k = try kept(try source(access, id: "install-a"), Data("%PDF-1.4 one".utf8), kind: "pdf", paper: paper())
        let b = try source(access, id: "install-b")
        XCTAssertNil(b.noteUse(k.file, paper: paper()))
        let record = try XCTUnwrap(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .first { $0.lastPathComponent.contains("install-b") },
            "no record of install-b")
        let bytes = try Data(contentsOf: record)
        let modified = try record.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        XCTAssertNil(b.noteUse(k.file, paper: paper()))
        XCTAssertEqual(try Data(contentsOf: record), bytes)
        XCTAssertEqual(try record.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                       modified)
    }

    func testKeepSameBytesTwiceGivesOneFile() throws {
        let (access, root) = try freshLibrary()
        let src = try source(access)
        let bytes = Data("%PDF-1.4 same".utf8)
        let first = try kept(src, bytes, kind: "pdf", paper: paper())
        let second = try kept(src, bytes, kind: "pdf", paper: paper())
        XCTAssertEqual(first, second)
        XCTAssertEqual(contents(of: root).values.filter { $0 == bytes }.count, 1)
        guard case let .success(held?) = src.pdf(for: paper()) else { return XCTFail("no PDF held") }
        XCTAssertEqual(held.path, first.path)
        XCTAssertEqual(held.file, first.file)
    }

    func testPathByDigest() throws {
        let (access, root) = try freshLibrary()
        let src = try source(access)
        let k = try kept(src, Data("%PDF-1.4 path".utf8), kind: "pdf", paper: paper())
        XCTAssertEqual(src.path(of: k.file), k.path)
        XCTAssertTrue(k.path.hasPrefix(root.appendingPathComponent("papers").path + "/"), k.path)
        XCTAssertNil(src.path(of: LibraryFileReference(sha256: k.file.sha256, kind: "jats")))
        XCTAssertNil(src.path(of: LibraryFileReference(sha256: String(repeating: "0", count: 64), kind: "pdf")))
    }

    func testJATSParseReasonIsBmlibsText() {
        XCTAssertEqual(LibrarySource.jatsReason(JatsError.Xml(reason: "unexpected end")), "unexpected end")
        XCTAssertEqual(LibrarySource.jatsReason(JatsError.Resource(reason: "no thread")), "no thread")
        XCTAssertEqual(LibrarySource.jatsReason(JatsError.NestingTooDeep(depth: 600, limit: 512)),
                       "JATS document nests 600 elements deep, beyond the 512 this reader accepts")
        XCTAssertThrowsError(try parseJats(xml: "<article><front>")) { error in
            XCTAssertFalse(LibrarySource.jatsReason(error).contains("Xml("), LibrarySource.jatsReason(error))
        }
    }

    func testRemovedRootIsFailure() throws {
        let (access, root) = try freshLibrary()
        let src = try source(access)
        try FileManager.default.removeItem(at: root)
        guard case let .failed(jatsFailure) = src.jats(for: paper()) else {
            return XCTFail("not failed: \(src.jats(for: paper()))")
        }
        XCTAssertTrue(jatsFailure.description.hasPrefix("library, paper pmid=1: "), jatsFailure.description)
        XCTAssertTrue(jatsFailure.waits, "a library gone may come back")
        guard case let .failure(failure) = src.pdf(for: paper()) else { return XCTFail("pdf did not fail") }
        XCTAssertTrue(failure.description.hasPrefix("library, paper pmid=1"), failure.description)
        XCTAssertTrue(failure.waits)
        guard case let .failure(keepFailure) = src.keep(Data("%PDF-1.4".utf8), kind: "pdf", paper: paper(),
                                                        origin: "Test") else {
            return XCTFail("keep did not fail")
        }
        XCTAssertTrue(keepFailure.waits, keepFailure.description)
    }
}
#endif
