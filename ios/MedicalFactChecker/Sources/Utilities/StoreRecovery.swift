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

/// What became of a store that could not be opened.
///
/// Returned by ``StoreRecovery/setAsideStore(in:at:fileManager:)`` so the caller
/// can log it, decide whether a fresh store may be opened where it stood, and
/// tell the user at the next launch.
///
/// ## Why there is no "some of it moved" case
///
/// A store is only whole with all of its files: a database separated from its
/// write-ahead log has lost whatever that log had not yet checkpointed. So the
/// move is all or nothing — anything moved is moved back before this returns.
/// ``leftInPieces`` is the one exception, and it exists only because moving a
/// file back can fail too.
enum SetAsideStore: Equatable {
    /// There was no store to set aside, so nothing happened to the user's data.
    case noStoreFound

    /// The whole store was moved into a folder of its own, beside where it was.
    ///
    /// - Parameters:
    ///   - directoryName: The folder the store now lives in.
    ///   - fileNames: The store's own file names, unchanged, inside that folder.
    case keptWhole(directoryName: String, fileNames: [String])

    /// Nothing was moved, and the store is exactly where it was.
    ///
    /// Whatever had been moved was moved back, so the store is still whole. The
    /// app will meet the same wall next launch, which is why the reason is
    /// carried out rather than dropped (golden rule 8).
    case leftInPlace(fileNames: [String], reason: String)

    /// Part of the store was moved and could not be moved back.
    ///
    /// The worst outcome and the rarest. Nothing is deleted, but nothing may be
    /// written here either: a fresh database beside an orphaned write-ahead log
    /// is how data that *was* recoverable stops being so.
    case leftInPieces(directoryName: String, moved: [String], leftBehind: [String], reason: String)

    /// Whether a fresh, empty store may be opened where this one stood.
    ///
    /// `false` whenever any of the store's files are still where SwiftData
    /// writes: a new database beside an old write-ahead log is a corruption
    /// hazard, not a leftover.
    var isSafeToStartFresh: Bool {
        switch self {
        case .noStoreFound, .keptWhole:
            return true
        case .leftInPlace, .leftInPieces:
            return false
        }
    }
}

/// Why the app could not start, when setting the store aside did not work either.
///
/// Raised instead of opening a fresh store over files that are still in place,
/// so the reason reaches the log rather than SwiftData failing obscurely a
/// moment later.
struct StoreSetAsideFailure: LocalizedError, Equatable {
    /// What became of the store.
    let outcome: SetAsideStore

    var errorDescription: String? {
        StoreRecovery.message(for: outcome) ?? StoreRecovery.unreachableStoreMessage
    }
}

/// Keeps a store that cannot be opened, and carries the news to the next launch.
///
/// The container is built before there is any window to show a message in, so
/// what happened is written down here and shown by the first view that appears.
///
/// ## Why nothing is deleted
///
/// The last resort of container creation used to remove `default.store` and its
/// write-ahead files — every fact check the user had ever saved — and say so
/// only with a `print`, so in a release build the user opened the app to an
/// empty History and no explanation (#285). Moving the files aside costs a few
/// megabytes and keeps the data recoverable by hand or by a later repair.
enum StoreRecovery {

    // MARK: - Constants

    /// The store's own files: the database, SQLite's write-ahead log, and the
    /// shared-memory index that log is read through.
    ///
    /// A store is only whole with all three, so they are moved together.
    static let storeFileNames = [
        "default.store",
        "default.store-shm",
        "default.store-wal",
    ]

    /// Names the folder an unreadable store is kept in, ahead of the moment it happened.
    private static let setAsideDirectoryPrefix = "unreadable-"

    /// How the moment is written into the name: sortable, and legal on every filesystem.
    private static let setAsideDateFormat = "yyyyMMdd-HHmmss"

    /// How many names to try before giving up on finding a free one.
    ///
    /// The stamp has one-second resolution, so two failures in the same second
    /// want the same folder. Stepping past a taken name is what makes "a device
    /// this happens to twice keeps both copies" true rather than nearly true.
    private static let maxSetAsideAttempts = 10

    /// The alert's title. The sentences below do not repeat it.
    static let noticeTitle = "Your saved fact checks could not be opened"

    /// Opens what the user is told when the app started anyway.
    private static let emptyHistorySentence =
        "This app has started with an empty History."

    /// Opens what the user is told when the store could not be moved aside either.
    private static let couldNotSetAsideSentence =
        "This app could not move the old database aside either, so it may not start until that is put right."

    /// The assurance every message owes the user, whatever else happened.
    private static let nothingDeleted = "Nothing was deleted"

    /// What the user is told when there is not even a directory to set the store aside in.
    ///
    /// Rare, and still theirs to know: the History they had is not the History
    /// they now see, and nothing this app did removed it.
    static let unreachableStoreMessage = emptyHistorySentence + " " + nothingDeleted + "."

    /// Where the pending message waits for the next launch.
    private static let pendingMessageKey = "store_recovery_pending_message"

    // MARK: - Setting a store aside

    /// Move a store that could not be opened out of the way, keeping every byte.
    ///
    /// All of the store's files move into one new folder, or none of them do.
    ///
    /// - Parameters:
    ///   - directory: Where the store lives, usually Application Support.
    ///   - date: The moment the store was found to be unreadable, which names
    ///     the folder it is kept in.
    ///   - fileManager: The file manager to move with; the default is the shared one.
    /// - Returns: What became of the store, for the caller to log, to decide
    ///   whether it may start fresh, and to tell the user about.
    static func setAsideStore(
        in directory: URL,
        at date: Date = Date(),
        fileManager: FileManager = .default
    ) -> SetAsideStore {
        let present = storeFileNames.filter {
            fileManager.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
        guard !present.isEmpty else { return .noStoreFound }

        let destination: URL
        do {
            destination = try makeSetAsideDirectory(in: directory, at: date, fileManager: fileManager)
        } catch {
            return .leftInPlace(fileNames: present, reason: error.localizedDescription)
        }

        var moved: [String] = []
        for name in present {
            do {
                try fileManager.moveItem(
                    at: directory.appendingPathComponent(name),
                    to: destination.appendingPathComponent(name)
                )
                moved.append(name)
            } catch {
                // One file short is not a store worth keeping apart from its
                // own log, so put back what moved before reporting.
                return rollBack(
                    moved,
                    from: destination,
                    to: directory,
                    present: present,
                    reason: error.localizedDescription,
                    fileManager: fileManager
                )
            }
        }

        return .keptWhole(directoryName: destination.lastPathComponent, fileNames: moved)
    }

    /// Put back everything this attempt had moved, so the store is whole again.
    ///
    /// - Returns: ``SetAsideStore/leftInPlace(fileNames:reason:)`` when every
    ///   file is back, and ``SetAsideStore/leftInPieces(directoryName:moved:leftBehind:reason:)``
    ///   when one could not be.
    private static func rollBack(
        _ moved: [String],
        from destination: URL,
        to directory: URL,
        present: [String],
        reason: String,
        fileManager: FileManager
    ) -> SetAsideStore {
        var stranded: [String] = []
        for name in moved {
            do {
                try fileManager.moveItem(
                    at: destination.appendingPathComponent(name),
                    to: directory.appendingPathComponent(name)
                )
            } catch {
                stranded.append(name)
            }
        }

        guard stranded.isEmpty else {
            return .leftInPieces(
                directoryName: destination.lastPathComponent,
                moved: stranded,
                leftBehind: present.filter { !stranded.contains($0) },
                reason: reason
            )
        }

        // Only ever the empty folder this attempt made, never the user's data.
        if let left = try? fileManager.contentsOfDirectory(atPath: destination.path), left.isEmpty {
            try? fileManager.removeItem(at: destination)
        }
        return .leftInPlace(fileNames: present, reason: reason)
    }

    /// Make a folder of its own for a store that could not be read.
    ///
    /// - Returns: The new folder, which was not there before this call.
    /// - Throws: Whatever the last attempt to create one raised.
    private static func makeSetAsideDirectory(
        in directory: URL,
        at date: Date,
        fileManager: FileManager
    ) throws -> URL {
        let stamp = timestamp(for: date)
        var lastError: Error?

        for attempt in 1...maxSetAsideAttempts {
            let suffix = attempt == 1 ? "" : "-\(attempt)"
            let candidate = directory.appendingPathComponent(
                setAsideDirectoryPrefix + stamp + suffix,
                isDirectory: true
            )
            do {
                // `withIntermediateDirectories: false` so a folder that is
                // already there is a name to step past, never one to move a
                // second store into on top of the first.
                try fileManager.createDirectory(at: candidate, withIntermediateDirectories: false)
                return candidate
            } catch {
                lastError = error
            }
        }

        throw lastError ?? CocoaError(.fileWriteUnknown)
    }

    /// Write the moment into a name that sorts and that every filesystem accepts.
    ///
    /// - Parameter date: The moment.
    /// - Returns: The moment in UTC, as `yyyyMMdd-HHmmss`.
    private static func timestamp(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = setAsideDateFormat
        return formatter.string(from: date)
    }

    // MARK: - What the user is told

    /// The sentences telling the user what became of their saved fact checks.
    ///
    /// Every one of them says that nothing was deleted, which is the whole
    /// point of the change they describe.
    ///
    /// - Parameter outcome: What became of the store.
    /// - Returns: What to show, or `nil` when there was no store to set aside
    ///   and so nothing happened to the user's data.
    static func message(for outcome: SetAsideStore) -> String? {
        switch outcome {
        case .noStoreFound:
            return nil

        case .keptWhole(let directoryName, _):
            return emptyHistorySentence + " " + nothingDeleted
                + ": the old database is kept in a folder named " + directoryName + "."

        case .leftInPlace(let fileNames, let reason):
            return couldNotSetAsideSentence + " " + nothingDeleted + ": "
                + list(fileNames) + (fileNames.count == 1 ? " is" : " are")
                + " still where it was. The reason given was: " + reason

        case .leftInPieces(let directoryName, let moved, let leftBehind, let reason):
            return couldNotSetAsideSentence + " " + nothingDeleted + ", but the old database"
                + " could not be moved aside whole: " + list(moved)
                + (moved.count == 1 ? " is" : " are") + " now in a folder named " + directoryName
                + ", while " + list(leftBehind) + (leftBehind.count == 1 ? " is" : " are")
                + " still where it was. The reason given was: " + reason
        }
    }

    /// Name some files the way a sentence does.
    ///
    /// - Parameter names: The file names, in the order they should be read.
    /// - Returns: One name, or names separated by commas and a final "and".
    private static func list(_ names: [String]) -> String {
        guard let last = names.last else { return "" }
        guard names.count > 1 else { return last }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }

    // MARK: - Reaching the next launch

    /// Keep a message for the first view that can show it.
    ///
    /// - Parameters:
    ///   - message: What to tell the user.
    ///   - defaults: Where to keep it; the default is the standard defaults.
    static func recordPendingMessage(_ message: String, in defaults: UserDefaults = .standard) {
        defaults.set(message, forKey: pendingMessageKey)
    }

    /// What the user has yet to be told about their store.
    ///
    /// - Parameter defaults: Where it was kept.
    /// - Returns: The message, or `nil` on an ordinary launch.
    static func pendingMessage(in defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: pendingMessageKey)
    }

    /// Forget a message the user has now seen, so it is shown once.
    ///
    /// - Parameter defaults: Where it was kept.
    static func clearPendingMessage(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: pendingMessageKey)
    }
}
