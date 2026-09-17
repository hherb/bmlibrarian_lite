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


import Foundation
import XCTest
@testable import MedicalFactChecker

/// A store that cannot be opened is set aside, never deleted (#285).
///
/// The last resort of container creation used to remove `default.store` and its
/// write-ahead files: every fact check the user had ever saved, gone, with a
/// `print` as the only trace. Nothing here deletes, and what happened is kept
/// for the next launch to tell the user about.
final class StoreRecoveryTests: XCTestCase {
    private var directory: URL!

    /// A fixed moment, so the names the files are given are predictable.
    private let moment = Date(timeIntervalSince1970: 1_789_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("store-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func writeStoreFiles() throws {
        for name in StoreRecovery.storeFileNames {
            try Data(name.utf8).write(to: directory.appendingPathComponent(name))
        }
    }

    private func names(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    // MARK: - Setting the store aside

    /// The files are moved, not removed, and what they held is still there.
    func testTheStoreIsMovedAsideRatherThanDeleted() throws {
        try writeStoreFiles()

        let outcome = StoreRecovery.setAsideStore(in: directory, at: moment)

        guard case .keptWhole(let folder, let fileNames) = outcome else {
            return XCTFail("The whole store should have been kept, got \(outcome)")
        }
        XCTAssertEqual(fileNames, StoreRecovery.storeFileNames)
        for name in StoreRecovery.storeFileNames {
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path))
            let kept = directory.appendingPathComponent(folder).appendingPathComponent(name)
            XCTAssertEqual(String(decoding: try Data(contentsOf: kept), as: UTF8.self), name)
        }
    }

    /// The folder the store is kept in says when it happened.
    func testTheKeptFolderSaysWhenItHappened() throws {
        try writeStoreFiles()

        let outcome = StoreRecovery.setAsideStore(in: directory, at: moment)

        guard case .keptWhole(let folder, _) = outcome else {
            return XCTFail("The whole store should have been kept, got \(outcome)")
        }
        XCTAssertEqual(folder, "unreadable-20260910-002640")
    }

    /// A second failure does not overwrite what the first one kept.
    func testASecondFailureKeepsBothCopies() throws {
        try writeStoreFiles()
        _ = StoreRecovery.setAsideStore(in: directory, at: moment)
        try writeStoreFiles()

        _ = StoreRecovery.setAsideStore(in: directory, at: moment.addingTimeInterval(60))

        let kept = try names(in: directory).filter { $0.hasPrefix("unreadable-") }
        XCTAssertEqual(kept.count, 2)
    }

    /// Twice in the same second is still twice: the stamp has one-second
    /// resolution, so the second folder steps past the name the first one took.
    func testASecondFailureInTheSameSecondKeepsBothCopies() throws {
        try writeStoreFiles()
        _ = StoreRecovery.setAsideStore(in: directory, at: moment)
        try writeStoreFiles()

        let outcome = StoreRecovery.setAsideStore(in: directory, at: moment)

        guard case .keptWhole(let folder, _) = outcome else {
            return XCTFail("The whole store should have been kept, got \(outcome)")
        }
        XCTAssertEqual(folder, "unreadable-20260910-002640-2")
        let first = directory
            .appendingPathComponent("unreadable-20260910-002640")
            .appendingPathComponent("default.store")
        XCTAssertEqual(String(decoding: try Data(contentsOf: first), as: UTF8.self), "default.store")
    }

    /// A store that cannot be moved whole is not moved at all: a database
    /// parted from its write-ahead log has lost what that log still held.
    func testAStoreThatCannotBeMovedWholeIsLeftWhereItIs() throws {
        try writeStoreFiles()
        // The last of the three refuses to move, so the first two have already
        // moved when the attempt fails.
        let fileManager = FileManagerRefusing("default.store-wal")

        let outcome = StoreRecovery.setAsideStore(in: directory, at: moment, fileManager: fileManager)

        guard case .leftInPlace(let fileNames, let reason) = outcome else {
            return XCTFail("A store that cannot move whole must stay put, got \(outcome)")
        }
        XCTAssertEqual(fileNames, StoreRecovery.storeFileNames)
        XCTAssertFalse(reason.isEmpty, "Why it could not move is the user's to know")
        for name in StoreRecovery.storeFileNames {
            let original = directory.appendingPathComponent(name)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: original.path),
                "\(name) should have been moved back"
            )
            XCTAssertEqual(String(decoding: try Data(contentsOf: original), as: UTF8.self), name)
        }
    }

    /// Rolling back leaves no empty folder behind, and takes nothing with it.
    func testAStoreLeftInPlaceLeavesNoLeftovers() throws {
        try writeStoreFiles()

        _ = StoreRecovery.setAsideStore(
            in: directory,
            at: moment,
            fileManager: FileManagerRefusing("default.store-wal")
        )

        XCTAssertEqual(try names(in: directory), StoreRecovery.storeFileNames.sorted())
    }

    /// When a moved file cannot be moved back, that is said plainly rather than
    /// reported as a store that is still whole.
    func testAStoreThatCouldNotBeMovedBackIsReportedInPieces() throws {
        try writeStoreFiles()
        // Refuses to move `default.store-wal` either way, so the two that moved
        // before it cannot all be put back.
        let fileManager = FileManagerRefusing("default.store-wal", andBack: "default.store-shm")

        let outcome = StoreRecovery.setAsideStore(in: directory, at: moment, fileManager: fileManager)

        guard case .leftInPieces(_, let moved, let leftBehind, _) = outcome else {
            return XCTFail("A store that could not be put back is in pieces, got \(outcome)")
        }
        XCTAssertEqual(moved, ["default.store-shm"])
        XCTAssertEqual(leftBehind, ["default.store", "default.store-wal"])
        XCTAssertFalse(outcome.isSafeToStartFresh, "Nothing may be written where the rest still lies")
    }

    /// A store left where it is must not be written over by a fresh one.
    func testAStoreLeftInPlaceIsNotSafeToStartFreshOver() {
        XCTAssertFalse(SetAsideStore.leftInPlace(fileNames: ["default.store"], reason: "why").isSafeToStartFresh)
        XCTAssertFalse(
            SetAsideStore.leftInPieces(
                directoryName: "unreadable-20260910-002640",
                moved: ["default.store"],
                leftBehind: ["default.store-wal"],
                reason: "why"
            ).isSafeToStartFresh
        )
        XCTAssertTrue(SetAsideStore.noStoreFound.isSafeToStartFresh)
        XCTAssertTrue(
            SetAsideStore.keptWhole(directoryName: "unreadable-20260910-002640", fileNames: []).isSafeToStartFresh
        )
    }

    /// Nothing to set aside is not a failure, and says nothing to the user.
    func testAnAbsentStoreLeavesNothingToTell() {
        let outcome = StoreRecovery.setAsideStore(in: directory, at: moment)

        XCTAssertEqual(outcome, .noStoreFound)
        XCTAssertNil(StoreRecovery.message(for: outcome))
    }

    // MARK: - What the user is told

    /// Every message this app shows says that nothing was deleted, because that
    /// is the whole of what changed (#285).
    func testEveryMessageSaysNothingWasDeleted() throws {
        let outcomes: [SetAsideStore] = [
            .keptWhole(directoryName: "unreadable-20260910-002640", fileNames: StoreRecovery.storeFileNames),
            .leftInPlace(fileNames: StoreRecovery.storeFileNames, reason: "the disk is full"),
            .leftInPlace(fileNames: ["default.store"], reason: "the disk is full"),
            .leftInPieces(
                directoryName: "unreadable-20260910-002640",
                moved: ["default.store"],
                leftBehind: ["default.store-shm", "default.store-wal"],
                reason: "the disk is full"
            ),
        ]

        for outcome in outcomes {
            let message = try XCTUnwrap(StoreRecovery.message(for: outcome), "\(outcome) owes the user a message")
            XCTAssertTrue(message.contains("Nothing was deleted"), "\(outcome) said: \(message)")
        }
        XCTAssertTrue(StoreRecovery.unreachableStoreMessage.contains("Nothing was deleted"))
    }

    /// The sentence names the folder the old database is kept in.
    func testTheMessageNamesWhereTheStoreIsKept() throws {
        try writeStoreFiles()

        let message = try XCTUnwrap(StoreRecovery.message(for: StoreRecovery.setAsideStore(in: directory, at: moment)))

        XCTAssertTrue(message.contains("unreadable-20260910-002640"), message)
        XCTAssertTrue(message.contains("Nothing was deleted"), message)
    }

    /// One file is "is", several are "are": the user reads this, so it reads.
    func testTheMessageCountsTheFilesItNames() throws {
        let one = try XCTUnwrap(
            StoreRecovery.message(for: .leftInPlace(fileNames: ["default.store"], reason: "no permission"))
        )
        XCTAssertTrue(one.contains("default.store is still where it was"), one)

        let several = try XCTUnwrap(
            StoreRecovery.message(
                for: .leftInPlace(fileNames: StoreRecovery.storeFileNames, reason: "no permission")
            )
        )
        XCTAssertTrue(several.contains("and default.store-wal are still where"), several)
    }

    /// Why the move failed is carried to the user, not dropped at the catch.
    func testTheMessageSaysWhyTheStoreCouldNotBeMoved() throws {
        let message = try XCTUnwrap(
            StoreRecovery.message(for: .leftInPlace(fileNames: ["default.store"], reason: "the volume is read-only"))
        )

        XCTAssertTrue(message.contains("the volume is read-only"), message)
    }

    /// A device where the store's own directory cannot be found still owes the
    /// user the reason their History is empty.
    func testAStoreThatCouldNotEvenBeSetAsideIsStillExplained() {
        XCTAssertTrue(StoreRecovery.unreachableStoreMessage.contains("History"))
        XCTAssertTrue(StoreRecovery.unreachableStoreMessage.contains("Nothing was deleted"))
    }

    // MARK: - Reaching the next launch

    /// The container is built before there is anything to show a message on, so
    /// what happened waits for the launch after it.
    func testWhatHappenedWaitsForTheNextLaunch() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "store-recovery-\(UUID().uuidString)"))

        StoreRecovery.recordPendingMessage("The history could not be opened.", in: defaults)

        XCTAssertEqual(StoreRecovery.pendingMessage(in: defaults), "The history could not be opened.")
    }

    /// Once the user has been told, it is not told again.
    func testAMessageIsShownOnce() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "store-recovery-\(UUID().uuidString)"))
        StoreRecovery.recordPendingMessage("The history could not be opened.", in: defaults)

        StoreRecovery.clearPendingMessage(in: defaults)

        XCTAssertNil(StoreRecovery.pendingMessage(in: defaults))
    }

    /// Nothing pending is the ordinary launch.
    func testAnOrdinaryLaunchHasNothingPending() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "store-recovery-\(UUID().uuidString)"))

        XCTAssertNil(StoreRecovery.pendingMessage(in: defaults))
    }

    // MARK: - Telling the user

    /// The message is read once, and every window shows that same one.
    func testTheMessageIsReadOnceForTheWholeApp() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "store-recovery-\(UUID().uuidString)"))
        StoreRecovery.recordPendingMessage("The history could not be opened.", in: defaults)

        let message = StoreRecoveryMessage(defaults: defaults)

        XCTAssertEqual(message.pending, "The history could not be opened.")
    }

    /// Acknowledging it is what forgets it — and only that.
    func testAcknowledgingTheMessageForgetsIt() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "store-recovery-\(UUID().uuidString)"))
        StoreRecovery.recordPendingMessage("The history could not be opened.", in: defaults)
        let message = StoreRecoveryMessage(defaults: defaults)

        message.acknowledge()

        XCTAssertNil(message.pending)
        XCTAssertNil(StoreRecovery.pendingMessage(in: defaults))
        XCTAssertNil(StoreRecoveryMessage(defaults: defaults).pending, "A later launch has nothing left to say")
    }

    /// A message the user never acknowledged is still there to be shown.
    ///
    /// SwiftUI drives an alert's binding to `false` for reasons that are not the
    /// user reading it — a sibling alert on the same view, a view torn down —
    /// and a message dropped then is the silence #285 is about.
    func testAMessageTheUserNeverReadSurvives() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "store-recovery-\(UUID().uuidString)"))
        StoreRecovery.recordPendingMessage("The history could not be opened.", in: defaults)

        _ = StoreRecoveryMessage(defaults: defaults)

        XCTAssertEqual(
            StoreRecoveryMessage(defaults: defaults).pending,
            "The history could not be opened.",
            "Only acknowledging it may forget it"
        )
    }

    /// An ordinary launch has nothing to say.
    func testAnOrdinaryLaunchShowsNoMessage() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "store-recovery-\(UUID().uuidString)"))

        XCTAssertNil(StoreRecoveryMessage(defaults: defaults).pending)
    }
}

/// A file manager that refuses to move particular files.
///
/// The move failures this exists to test — a name taken, a permission missing, a
/// file another process holds — cannot be staged with a real one, because
/// ``StoreRecovery`` steps past a taken folder name by design.
private final class FileManagerRefusing: FileManager {
    /// The file that will not move out of the store's directory.
    private let refusedOut: String

    /// The file that will not move back into it, if any.
    private let refusedBack: String?

    /// - Parameters:
    ///   - refusedOut: The file that cannot be set aside.
    ///   - andBack: The file that cannot be put back afterwards.
    init(_ refusedOut: String, andBack refusedBack: String? = nil) {
        self.refusedOut = refusedOut
        self.refusedBack = refusedBack
        super.init()
    }

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        let name = srcURL.lastPathComponent
        // Going aside lands in the `unreadable-` folder; going back does not.
        let isGoingBack = !dstURL.deletingLastPathComponent()
            .lastPathComponent
            .hasPrefix("unreadable-")
        if name == refusedOut || (isGoingBack && name == refusedBack) {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}

