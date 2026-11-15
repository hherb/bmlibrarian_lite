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
import XCTest
@testable import BioMedLit

/// Choosing, resuming and stopping a library folder through its bookmark
/// (design §4.1, §4.6). Each test works in a fresh folder of its own.
final class LibraryAccessTests: XCTestCase {

    private var made: [URL] = []

    override func tearDown() {
        for url in made { try? FileManager.default.removeItem(at: url) }
        made = []
        super.tearDown()
    }

    /// A fresh, empty folder under the temporary directory.
    private func freshFolder(_ name: String = UUID().uuidString) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mfc-lib-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        made.append(url)
        return url
    }

    /// The same folder however it is spelled (`/var` is `/private/var`).
    private func samePath(_ a: URL, _ b: URL) -> Bool {
        a.resolvingSymlinksInPath().standardizedFileURL.path
            == b.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func marker(in folder: URL) -> URL {
        folder.appendingPathComponent(BioMedLitConstants.libraryMarkerFileName)
    }

    func testBookmarkResolvesToItsFolder() throws {
        let dir = try freshFolder()
        let data = try LibraryBookmark.make(for: dir)
        let resolved = try LibraryBookmark.resolve(data)
        XCTAssertTrue(samePath(resolved.url, dir), "\(resolved.url.path) vs \(dir.path)")
        XCTAssertFalse(resolved.isStale)
    }

    func testChooseMakesLibraryInEmptyFolder() throws {
        let dir = try freshFolder()
        let choice = try LibrarySetup.choose(dir)
        defer { choice.access.stop() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker(in: dir).path))
        XCTAssertEqual(choice.access.folderName, dir.lastPathComponent)
        XCTAssertFalse(choice.bookmark.isEmpty)
    }

    func testChooseRefusesFolderWithOtherFiles() throws {
        let dir = try freshFolder()
        try Data("my notes".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        XCTAssertThrowsError(try LibrarySetup.choose(dir)) { error in
            XCTAssertFalse(String(describing: error).isEmpty)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker(in: dir).path))
    }

    func testIsInTrashByPathComponent() {
        for path in ["/Users/x/.Trash/lib", "/Users/x/.Trash", "/Volumes/Ext/.Trashes/501/Papers"] {
            XCTAssertTrue(LibrarySetup.isInTrash(URL(fileURLWithPath: path, isDirectory: true)), path)
        }
        for path in ["/Users/x/.Trash-not/lib", "/Users/x/Papers", "/Volumes/Ext/Trashes/Papers"] {
            XCTAssertFalse(LibrarySetup.isInTrash(URL(fileURLWithPath: path, isDirectory: true)), path)
        }
    }

    func testChooseWorksWithoutStartedAccess() throws {
        let dir = try freshFolder()
        // The panel's grant already reaches the folder, so a start that does
        // not happen (as StudyAnalyzer's choose allows) must not refuse it.
        let choice = try LibrarySetup.choose(dir, startAccess: { _ in false })
        choice.access.stop()
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker(in: dir).path))
    }

    func testResumeOfRecreatedEmptyFolderIsLost() throws {
        let dir = try freshFolder()
        let choice = try LibrarySetup.choose(dir)
        choice.access.stop()
        try FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)

        guard case let .lost(reason) = LibrarySetup.resume(bookmark: choice.bookmark) else {
            return XCTFail("an empty folder in the library's place is not the library")
        }
        XCTAssertTrue(reason.contains("no longer holds"), reason)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker(in: dir).path))
    }

    func testChooseRefusesFolderInTrash() throws {
        guard let trash = try? FileManager.default.url(
            for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        else { throw XCTSkip("no Trash folder here") }
        let dir = trash.appendingPathComponent("mfc-lib-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        } catch {
            throw XCTSkip("this process may not write to the Trash: \(error)")
        }
        made.append(dir)
        XCTAssertThrowsError(try LibrarySetup.choose(dir)) { error in
            XCTAssertTrue(String(describing: error).contains("Trash"), "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker(in: dir).path))
    }

    func testResumeFollowsRenamedFolder() throws {
        let dir = try freshFolder()
        let choice = try LibrarySetup.choose(dir)
        choice.access.stop()
        let moved = dir.deletingLastPathComponent()
            .appendingPathComponent("mfc-lib-moved-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.moveItem(at: dir, to: moved)
        made.append(moved)

        guard case let .held(access, renewed) = LibrarySetup.resume(bookmark: choice.bookmark) else {
            return XCTFail("a renamed folder is followed")
        }
        defer { access.stop() }
        XCTAssertTrue(samePath(access.folderURL, moved), access.folderURL.path)
        XCTAssertEqual(access.folderName, moved.lastPathComponent)
        XCTAssertNotNil(renewed)
    }

    func testResumeOfDeletedFolderIsLostAndKeepsNoAccess() throws {
        let dir = try freshFolder()
        let choice = try LibrarySetup.choose(dir)
        choice.access.stop()
        try FileManager.default.removeItem(at: dir)

        guard case let .lost(reason) = LibrarySetup.resume(bookmark: choice.bookmark) else {
            return XCTFail("a deleted folder cannot be resumed")
        }
        XCTAssertFalse(reason.isEmpty)
    }

    func testResumeOfGarbageIsLost() {
        guard case let .lost(reason) = LibrarySetup.resume(bookmark: Data([1, 2, 3])) else {
            return XCTFail("garbage is no bookmark")
        }
        XCTAssertFalse(reason.isEmpty)
    }

    func testResumeRefusedAccessIsLostOnlyWhenSandboxed() {
        XCTAssertTrue(LibrarySetup.accessRefused(started: false, sandboxed: true))
        XCTAssertFalse(LibrarySetup.accessRefused(started: false, sandboxed: false))
        XCTAssertFalse(LibrarySetup.accessRefused(started: true, sandboxed: true))
        XCTAssertFalse(LibrarySetup.accessRefused(started: true, sandboxed: false))
    }

    func testStopTwiceIsSafe() throws {
        let dir = try freshFolder()
        let choice = try LibrarySetup.choose(dir)
        choice.access.stop()
        choice.access.stop()
    }
}
#endif
