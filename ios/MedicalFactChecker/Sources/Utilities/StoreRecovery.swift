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
/// can log it and the next launch can tell the user about it, rather than the
/// store quietly vanishing.
struct SetAsideStore: Equatable {
    /// The names the store's files now have, in the order they were moved.
    let keptAs: [String]

    /// The names of the files that could not be moved out of the way.
    ///
    /// They are still where they were. A store file left behind is why the app
    /// may meet the same wall on the next launch, so it is reported, not passed
    /// over (golden rule 8).
    let couldNotMove: [String]

    /// Whether there was a store to set aside at all.
    var isEmpty: Bool { keptAs.isEmpty && couldNotMove.isEmpty }
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

    /// The store's own files: the database and SQLite's two write-ahead files.
    ///
    /// A store is only whole with all three, so they are moved together.
    static let storeFileNames = [
        "default.store",
        "default.store-shm",
        "default.store-wal",
    ]

    /// Marks a file as one this app could not read, ahead of the moment it happened.
    private static let setAsideSuffix = ".unreadable-"

    /// How the moment is written into the name: sortable, and legal on every filesystem.
    private static let setAsideDateFormat = "yyyyMMdd-HHmmss"

    /// Separates the names of files in a sentence.
    private static let nameSeparator = ", "

    /// Opens what the user is told: their History is empty, and this is why.
    private static let emptyHistorySentence =
        "Your saved fact checks could not be opened, so this app has started with an empty History."

    /// What the user is told when there is not even a directory to set the store aside in.
    ///
    /// Rare, and still theirs to know: the History they had is not the History
    /// they now see, and nothing this app did removed it.
    static let unreachableStoreMessage = emptyHistorySentence + " Nothing was deleted."

    /// Where the pending message waits for the next launch.
    private static let pendingMessageKey = "store_recovery_pending_message"

    // MARK: - Setting a store aside

    /// Move a store that could not be opened out of the way, keeping every byte.
    ///
    /// - Parameters:
    ///   - directory: Where the store lives, usually Application Support.
    ///   - date: The moment the store was found to be unreadable, which names
    ///     the files it is kept under.
    ///   - fileManager: The file manager to move with; the default is the shared one.
    /// - Returns: What was moved and what could not be, for the caller to log
    ///   and to tell the user about.
    static func setAsideStore(
        in directory: URL,
        at date: Date = Date(),
        fileManager: FileManager = .default
    ) -> SetAsideStore {
        let stamp = timestamp(for: date)
        var keptAs: [String] = []
        var couldNotMove: [String] = []

        for name in storeFileNames {
            let original = directory.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: original.path) else { continue }

            let keptName = name + setAsideSuffix + stamp
            do {
                try fileManager.moveItem(at: original, to: directory.appendingPathComponent(keptName))
                keptAs.append(keptName)
            } catch {
                couldNotMove.append(name)
            }
        }

        return SetAsideStore(keptAs: keptAs, couldNotMove: couldNotMove)
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

    /// The sentence telling the user their history could not be opened.
    ///
    /// - Parameter outcome: What became of the store.
    /// - Returns: What to show at the next launch, or `nil` when there was no
    ///   store to set aside and so nothing happened to the user's data.
    static func message(for outcome: SetAsideStore) -> String? {
        guard !outcome.isEmpty else { return nil }

        var sentences: [String] = [emptyHistorySentence]
        if !outcome.keptAs.isEmpty {
            sentences.append(
                "Nothing was deleted: the old database is kept as "
                    + outcome.keptAs.joined(separator: nameSeparator)
                    + "."
            )
        }
        if !outcome.couldNotMove.isEmpty {
            sentences.append(
                "These files could not be moved aside, so this may happen again: "
                    + outcome.couldNotMove.joined(separator: nameSeparator)
                    + "."
            )
        }
        return sentences.joined(separator: " ")
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
