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

/// The settings a session reads and writes, held in memory.
private final class MemoryStore: LibrarySettingsStore {
    /// How many times the bookmark was written.
    var bookmarkWrites = 0
    var libraryBookmark: Data? { didSet { bookmarkWrites += 1 } }
    var libraryInstallationID: String?
}

/// The Library setting's behaviour: what a choice, a failed choice, a launch
/// and *Stop using* leave in the settings and the state the tab shows.
@MainActor
final class LibrarySessionTests: XCTestCase {

    private var made: [URL] = []

    override func tearDown() async throws {
        for url in made { try? FileManager.default.removeItem(at: url) }
        made = []
        try await super.tearDown()
    }

    private func freshFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mfc-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        made.append(url)
        return url
    }

    func testNoBookmarkIsNotChosen() async {
        let session = LibrarySession(store: MemoryStore())
        await session.resumeAtLaunch()
        XCTAssertEqual(session.state, .notChosen)
        XCTAssertNil(session.access)
    }

    func testChooseStoresBookmarkAndMakesInstallationID() async throws {
        let store = MemoryStore()
        let session = LibrarySession(store: store)
        let dir = try freshFolder()
        await session.choose(dir)
        defer { session.stopAccess() }
        XCTAssertNotNil(store.libraryBookmark)
        XCTAssertTrue(LibraryInstallation.isValidID(store.libraryInstallationID ?? ""))
        guard case let .reachable(name, _) = session.state else {
            return XCTFail("chosen: \(session.state)")
        }
        XCTAssertEqual(name, dir.lastPathComponent)
        XCTAssertNil(session.lastError)
    }

    func testFailedChooseKeepsPreviousLibrary() async throws {
        let store = MemoryStore()
        let session = LibrarySession(store: store)
        let good = try freshFolder()
        await session.choose(good)
        defer { session.stopAccess() }
        let before = (store.libraryBookmark, session.state)

        let own = try freshFolder()
        try Data("mine".utf8).write(to: own.appendingPathComponent("notes.txt"))
        await session.choose(own)

        XCTAssertEqual(store.libraryBookmark, before.0)
        XCTAssertEqual(session.state, before.1)
        XCTAssertNotNil(session.access)
        XCTAssertFalse((session.lastError ?? "").isEmpty)
    }

    func testStopUsingClearsBookmarkAndKeepsInstallationID() async throws {
        let store = MemoryStore()
        let session = LibrarySession(store: store)
        await session.choose(try freshFolder())
        let id = store.libraryInstallationID
        session.stopUsing()
        XCTAssertNil(store.libraryBookmark)
        XCTAssertNil(session.access)
        XCTAssertEqual(session.state, .notChosen)
        XCTAssertEqual(store.libraryInstallationID, id)
    }

    func testInstallationIDIsMadeOnceAndKept() async throws {
        let store = MemoryStore()
        let session = LibrarySession(store: store)
        let first = session.installationID()
        XCTAssertEqual(session.installationID(), first)
        await session.choose(try freshFolder())
        session.stopUsing()
        await session.choose(try freshFolder())
        defer { session.stopAccess() }
        XCTAssertEqual(store.libraryInstallationID, first)
        XCTAssertEqual(LibrarySession(store: store).installationID(), first)
    }

    func testUpperCaseStoredIDIsReplaced() {
        let store = MemoryStore()
        store.libraryInstallationID = "ABC-DEF"
        let id = LibrarySession(store: store).installationID()
        XCTAssertNotEqual(id, "ABC-DEF")
        XCTAssertTrue(LibraryInstallation.isValidID(id))
        XCTAssertEqual(store.libraryInstallationID, id)
    }

    func testResumeOfDeletedFolderIsUnreachableAndKeepsBookmark() async throws {
        let store = MemoryStore()
        let dir = try freshFolder()
        let chooser = LibrarySession(store: store)
        await chooser.choose(dir)
        chooser.stopAccess()
        try FileManager.default.removeItem(at: dir)
        let bookmark = store.libraryBookmark

        let session = LibrarySession(store: store)
        await session.resumeAtLaunch()
        guard case let .unreachable(reason) = session.state else {
            return XCTFail("deleted: \(session.state)")
        }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertNil(session.access)
        XCTAssertEqual(store.libraryBookmark, bookmark)
    }

    func testResumeHoldsAccessAndStoresRenewedBookmark() async throws {
        let store = MemoryStore()
        let dir = try freshFolder()
        let chooser = LibrarySession(store: store)
        await chooser.choose(dir)
        chooser.stopAccess()
        let writes = store.bookmarkWrites

        let session = LibrarySession(store: store)
        await session.resumeAtLaunch()
        defer { session.stopAccess() }
        XCTAssertNotNil(session.access)
        guard case .reachable = session.state else { return XCTFail("\(session.state)") }
        XCTAssertEqual(store.bookmarkWrites, writes + 1, "the renewed bookmark is stored")
        XCTAssertNotNil(store.libraryBookmark)
    }
}
#endif
