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
    /// The stored bookmark; each write is counted.
    var libraryBookmark: Data? { didSet { bookmarkWrites += 1 } }
    /// The stored installation id.
    var libraryInstallationID: String?
}

/// A step held on its thread until the test lets it go, so a test can act
/// while a resume or a re-check is under way. Counts the calls it saw.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let release = DispatchSemaphore(value: 0)
    /// Fulfilled when a held call has started.
    let entered = XCTestExpectation(description: "the held step started")
    /// Which call (1-based) is held; the others pass straight through.
    let heldCall: Int

    init(holding call: Int = 1) { heldCall = call }

    /// How many calls came through.
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }

    /// Count a call and, when it is the held one, wait to be let go.
    func pass() {
        lock.lock()
        count += 1
        let held = count == heldCall
        lock.unlock()
        if held {
            entered.fulfill()
            release.wait()
        }
    }

    /// Let the held call go on.
    func open() { release.signal() }
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

    /// #792 item 2: a bookmark not made again is a note, forgotten on a change.
    func testUnsavedBookmarkIsNotedAndForgottenOnChange() async throws {
        let store = MemoryStore()
        _ = try await chosenLibrary(in: store)
        struct Refused: Error, LocalizedError { var errorDescription: String? { "refused" } }
        let session = LibrarySession(store: store, resume: {
            LibrarySetup.resume(bookmark: $0, makeBookmark: { _ in throw Refused() })
        })
        await session.resumeAtLaunch()
        defer { session.stopAccess() }
        guard case .reachable = session.state else { return XCTFail("\(session.state)") }
        XCTAssertEqual(session.unsaved, "refused")
        await session.choose(try freshFolder())
        XCTAssertNil(session.unsaved)

        await session.resumeAtLaunch()
        XCTAssertEqual(session.unsaved, "refused")
        session.stopUsing()
        XCTAssertNil(session.unsaved)
    }

    /// #792 item 3: "Reaching…" only while a stored library is being reached.
    func testIsReachingOnlyWhileAStoredLibraryResumes() async throws {
        let store = MemoryStore()
        _ = try await chosenLibrary(in: store)
        let gate = Gate()
        let session = LibrarySession(store: store, resume: { gate.pass(); return LibrarySetup.resume(bookmark: $0) })
        XCTAssertFalse(session.isReaching)
        let resuming = Task { await session.resumeAtLaunch() }
        await fulfillment(of: [gate.entered], timeout: 10)
        XCTAssertTrue(session.isReaching)
        gate.open()
        await resuming.value
        defer { session.stopAccess() }
        XCTAssertFalse(session.isReaching)

        let none = LibrarySession(store: MemoryStore())
        await none.resumeAtLaunch()
        XCTAssertFalse(none.isReaching, "no bookmark, nothing to reach")
    }

    // MARK: - Re-check when the app becomes active (design §4.6)

    /// A library chosen in `store`, its access stopped, and its folder.
    private func chosenLibrary(in store: MemoryStore) async throws -> URL {
        let dir = try freshFolder()
        let chooser = LibrarySession(store: store)
        await chooser.choose(dir)
        chooser.stopAccess()
        return dir
    }

    private func marker(of dir: URL) -> URL {
        dir.appendingPathComponent(BioMedLitConstants.libraryMarkerFileName)
    }

    func testRecheckWithNoLibraryDoesNothing() async {
        let store = MemoryStore()
        let session = LibrarySession(store: store)
        await session.recheck()
        XCTAssertEqual(session.state, .notChosen)
        XCTAssertEqual(store.bookmarkWrites, 0)
    }

    func testRecheckOfAHeldLibraryStillThereKeepsIt() async throws {
        let session = LibrarySession(store: MemoryStore())
        await session.choose(try freshFolder())
        defer { session.stopAccess() }
        let before = session.state
        await session.recheck()
        XCTAssertEqual(session.state, before)
        XCTAssertNotNil(session.access)
    }

    /// The drive unplugged while the app was in the background.
    func testRecheckOfAHeldLibraryGoneIsUnreachableAndKeepsBookmark() async throws {
        let store = MemoryStore()
        let session = LibrarySession(store: store)
        let dir = try freshFolder()
        await session.choose(dir)
        let bookmark = store.libraryBookmark
        try FileManager.default.removeItem(at: marker(of: dir))

        await session.recheck()
        guard case let .unreachable(reason) = session.state else {
            return XCTFail("gone: \(session.state)")
        }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertNil(session.access)
        XCTAssertEqual(store.libraryBookmark, bookmark)
    }

    /// The drive plugged back in: the launch's resume runs again.
    func testRecheckOfAnUnreachableLibraryReachesItAgain() async throws {
        let store = MemoryStore()
        let dir = try await chosenLibrary(in: store)
        let aside = try freshFolder().appendingPathComponent("marker")
        try FileManager.default.moveItem(at: marker(of: dir), to: aside)
        let session = LibrarySession(store: store)
        await session.resumeAtLaunch()
        guard case .unreachable = session.state else { return XCTFail("\(session.state)") }

        try FileManager.default.moveItem(at: aside, to: marker(of: dir))
        await session.recheck()
        defer { session.stopAccess() }
        guard case .reachable = session.state else { return XCTFail("back: \(session.state)") }
        XCTAssertNotNil(session.access)
    }

    /// #792 item 4: *Stop using* while a resume runs stands.
    func testStopUsingDuringAResumeStands() async throws {
        let store = MemoryStore()
        _ = try await chosenLibrary(in: store)
        let gate = Gate()
        let session = LibrarySession(store: store, resume: { gate.pass(); return LibrarySetup.resume(bookmark: $0) })
        let resuming = Task { await session.resumeAtLaunch() }
        await fulfillment(of: [gate.entered], timeout: 10)

        session.stopUsing()
        gate.open()
        await resuming.value
        XCTAssertEqual(session.state, .notChosen)
        XCTAssertNil(session.access)
        XCTAssertNil(store.libraryBookmark, "the renewed bookmark is not stored")
    }

    /// #792 item 4: a library chosen while a resume runs stands.
    func testChooseDuringAResumeStands() async throws {
        let store = MemoryStore()
        _ = try await chosenLibrary(in: store)
        let gate = Gate()
        let session = LibrarySession(store: store, resume: { gate.pass(); return LibrarySetup.resume(bookmark: $0) })
        let resuming = Task { await session.resumeAtLaunch() }
        await fulfillment(of: [gate.entered], timeout: 10)

        let other = try freshFolder()
        await session.choose(other)
        defer { session.stopAccess() }
        let chosen = store.libraryBookmark
        gate.open()
        await resuming.value
        XCTAssertEqual(session.access?.folderURL.lastPathComponent, other.lastPathComponent)
        guard case let .reachable(name, _) = session.state else { return XCTFail("\(session.state)") }
        XCTAssertEqual(name, other.lastPathComponent)
        XCTAssertEqual(store.libraryBookmark, chosen)
    }

    /// #792 item 4: a library chosen while a re-check runs stands, even when
    /// the re-check finds the old one gone.
    func testChooseDuringARecheckStands() async throws {
        let store = MemoryStore()
        let gate = Gate()
        let session = LibrarySession(
            store: store, resume: { LibrarySetup.resume(bookmark: $0) }, recheckFolder: { _ in gate.pass(); return "gone" })
        await session.choose(try freshFolder())
        let rechecking = Task { await session.recheck() }
        await fulfillment(of: [gate.entered], timeout: 10)

        let other = try freshFolder()
        await session.choose(other)
        defer { session.stopAccess() }
        gate.open()
        await rechecking.value
        guard case let .reachable(name, _) = session.state else { return XCTFail("\(session.state)") }
        XCTAssertEqual(name, other.lastPathComponent)
        XCTAssertNotNil(session.access)
    }

    /// Two never run at once: a re-check while a resume runs is skipped.
    func testRecheckWhileAResumeRunsIsSkipped() async throws {
        let store = MemoryStore()
        let dir = try await chosenLibrary(in: store)
        try FileManager.default.removeItem(at: dir)
        let gate = Gate(holding: 2)
        let session = LibrarySession(store: store, resume: { gate.pass(); return LibrarySetup.resume(bookmark: $0) })
        await session.resumeAtLaunch()
        guard case .unreachable = session.state else { return XCTFail("\(session.state)") }

        let rechecking = Task { await session.recheck() }
        await fulfillment(of: [gate.entered], timeout: 10)
        await session.recheck()
        XCTAssertEqual(gate.calls, 2, "the second re-check did not resume")
        gate.open()
        await rechecking.value
        XCTAssertFalse(session.isWorking)
    }

    /// A re-check leaves *Choose…* enabled, and a library chosen while its
    /// resume runs wins.
    func testChooseDuringARechecksResumeProceedsAndWins() async throws {
        let store = MemoryStore()
        let dir = try await chosenLibrary(in: store)
        try FileManager.default.removeItem(at: dir)
        let gate = Gate(holding: 2)
        let session = LibrarySession(store: store, resume: { gate.pass(); return LibrarySetup.resume(bookmark: $0) })
        await session.resumeAtLaunch()
        let rechecking = Task { await session.recheck() }
        await fulfillment(of: [gate.entered], timeout: 10)
        XCTAssertFalse(session.isWorking, "a re-check does not disable the Library setting's buttons")

        let other = try freshFolder()
        await session.choose(other)
        defer { session.stopAccess() }
        gate.open()
        await rechecking.value
        guard case let .reachable(name, _) = session.state else { return XCTFail("\(session.state)") }
        XCTAssertEqual(name, other.lastPathComponent)
        XCTAssertEqual(session.access?.folderURL.lastPathComponent, other.lastPathComponent)
    }

    /// A held library found lost is resumed at once: a drive remounted
    /// elsewhere is reached on the same activation.
    func testAHeldLibraryFoundLostIsResumedAtOnce() async throws {
        let store = MemoryStore()
        let gate = Gate(holding: 0)
        let session = LibrarySession(
            store: store, resume: { gate.pass(); return LibrarySetup.resume(bookmark: $0) },
            recheckFolder: { _ in "gone" })
        await session.choose(try freshFolder())
        await session.recheck()
        defer { session.stopAccess() }
        XCTAssertEqual(gate.calls, 1)
        guard case .reachable = session.state else { return XCTFail("\(session.state)") }
        XCTAssertNotNil(session.access)
    }

    /// The library a fetch goes through while the one set cannot be reached:
    /// one that fails with the reason, so a source fetched waits (design §4.6).
    func testTheUnreachableLibraryIsOnlyForAnUnreachableOne() async throws {
        let store = MemoryStore()
        let session = LibrarySession(store: store)
        XCTAssertNil(session.unreachableLibrary, "none set")
        await session.choose(try freshFolder())
        XCTAssertNil(session.unreachableLibrary, "reachable")
        session.stopAccess()

        let dir = try await chosenLibrary(in: store)
        try FileManager.default.removeItem(at: dir)
        let lost = LibrarySession(store: store)
        await lost.resumeAtLaunch()
        guard case let .unreachable(reason) = lost.state else { return XCTFail("\(lost.state)") }
        let paper = LibraryPaper(pmid: "1", doi: nil, pmcId: nil)
        guard case let .failed(message) = try XCTUnwrap(lost.unreachableLibrary).jats(for: paper) else {
            return XCTFail("not failed")
        }
        XCTAssertTrue(message.contains(reason))
    }
}
#endif
