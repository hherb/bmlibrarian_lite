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

        XCTAssertEqual(outcome.couldNotMove, [])
        XCTAssertEqual(outcome.keptAs.count, StoreRecovery.storeFileNames.count)
        for name in StoreRecovery.storeFileNames {
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path))
        }
        for (original, kept) in zip(StoreRecovery.storeFileNames, outcome.keptAs) {
            let contents = try Data(contentsOf: directory.appendingPathComponent(kept))
            XCTAssertEqual(String(decoding: contents, as: UTF8.self), original)
        }
    }

    /// The name a file is kept under says what it is and when it happened, so a
    /// device this happens to twice keeps both.
    func testTheKeptNameSaysWhatHappenedAndWhen() throws {
        try writeStoreFiles()

        let outcome = StoreRecovery.setAsideStore(in: directory, at: moment)

        XCTAssertEqual(outcome.keptAs.first, "default.store.unreadable-20260910-002640")
    }

    /// A second failure does not overwrite what the first one kept.
    func testASecondFailureKeepsBothCopies() throws {
        try writeStoreFiles()
        _ = StoreRecovery.setAsideStore(in: directory, at: moment)
        try writeStoreFiles()

        _ = StoreRecovery.setAsideStore(in: directory, at: moment.addingTimeInterval(60))

        let kept = try names(in: directory).filter { $0.contains("unreadable") }
        XCTAssertEqual(kept.count, 2 * StoreRecovery.storeFileNames.count)
    }

    /// A file that could not be moved is reported rather than passed over.
    func testAFileThatCouldNotBeMovedIsReported() throws {
        try writeStoreFiles()
        // A directory already standing where the file would be moved to: the
        // move fails, and the store file is still where it was.
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("default.store.unreadable-20260910-002640"),
            withIntermediateDirectories: true
        )

        let outcome = StoreRecovery.setAsideStore(in: directory, at: moment)

        XCTAssertEqual(outcome.couldNotMove, ["default.store"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("default.store").path))
    }

    /// Nothing to set aside is not a failure, and says nothing to the user.
    func testAnAbsentStoreLeavesNothingToTell() {
        let outcome = StoreRecovery.setAsideStore(in: directory, at: moment)

        XCTAssertTrue(outcome.isEmpty)
        XCTAssertNil(StoreRecovery.message(for: outcome))
    }

    // MARK: - What the user is told

    /// The sentence says the history is gone from the app, and that the file is not.
    func testTheMessageSaysNothingWasDeleted() throws {
        try writeStoreFiles()

        let message = try XCTUnwrap(StoreRecovery.message(for: StoreRecovery.setAsideStore(in: directory, at: moment)))

        XCTAssertTrue(message.contains("default.store.unreadable-20260910-002640"))
        XCTAssertTrue(message.lowercased().contains("deleted"))
    }

    /// A file that could not be moved is named to the user too: it is why the
    /// app may meet the same wall again.
    func testTheMessageNamesAFileThatCouldNotBeMoved() throws {
        try writeStoreFiles()
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("default.store.unreadable-20260910-002640"),
            withIntermediateDirectories: true
        )

        let message = try XCTUnwrap(StoreRecovery.message(for: StoreRecovery.setAsideStore(in: directory, at: moment)))

        XCTAssertTrue(message.contains("default.store"))
        XCTAssertTrue(message.lowercased().contains("could not be moved"))
    }

    /// A device where the store's own directory cannot be found still owes the
    /// user the reason their History is empty.
    func testAStoreThatCouldNotEvenBeSetAsideIsStillExplained() {
        XCTAssertTrue(StoreRecovery.unreachableStoreMessage.contains("History"))
        XCTAssertTrue(StoreRecovery.unreachableStoreMessage.lowercased().contains("deleted"))
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
}
