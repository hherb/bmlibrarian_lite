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
import Foundation

/// One source file in a paper's folder, as the manual clear lists it.
public struct LibraryListedFile: Sendable, Equatable {
    /// Its name in the folder (`pdf-3f9a1c2e7b40.pdf`): its kind and a prefix
    /// of its digest.
    public let name: String
    /// Its size in bytes on disk; nil when it cannot be read.
    public let size: UInt64?
    /// The other installations whose records list it, by their labels.
    public let usedBy: [String]
    /// Whether this installation's record lists it.
    public let usedHere: Bool

    /// The file `name`, `size` bytes, listed by `usedBy` and, when
    /// `usedHere`, by this installation.
    public init(name: String, size: UInt64?, usedBy: [String], usedHere: Bool) {
        self.name = name
        self.size = size
        self.usedBy = usedBy
        self.usedHere = usedHere
    }
}

/// One paper folder of the library, as the manual clear lists it.
public struct LibraryListedPaper: Sendable, Equatable {
    /// The folder's name under `papers/`; what ``LibraryClear/remove(_:folder:name:)`` takes.
    public let folder: String
    /// The title the first record that has one gives, if any.
    public let title: String?
    /// Its source files, ordered by name.
    public let files: [LibraryListedFile]

    /// The folder `folder`, titled `title`, holding `files`.
    public init(folder: String, title: String?, files: [LibraryListedFile]) {
        self.folder = folder
        self.title = title
        self.files = files
    }

    /// What the list and the confirmation call it: its title, or its folder.
    public var label: String { title ?? folder }

    /// The other installations using any of its files, each once, in order.
    public var usedBy: [String] {
        var seen: Set<String> = []
        return files.flatMap(\.usedBy).filter { seen.insert($0).inserted }
    }

    /// Whether this installation uses any of its files.
    public var usedHere: Bool { files.contains(where: \.usedHere) }
}

/// What the manual clear shows: the papers, and what the scan found odd.
public struct LibraryListing: Sendable, Equatable {
    /// Every paper folder, ordered by name.
    public let papers: [LibraryListedPaper]
    /// Each thing the scan found odd and did not use, as bmlib's
    /// `LibraryProblem` prints. shortcut: no sentence per kind yet (as
    /// StudyAnalyzer's clear); give each one before the App Store release.
    public let problems: [String]

    /// `papers`, and `problems` found while listing them.
    public init(papers: [LibraryListedPaper], problems: [String]) {
        self.papers = papers
        self.problems = problems
    }
}

/// The manual clear (design §4.8; StudyAnalyzer's `library_clear.rs`, the
/// same rules): the library's papers with each file's size and users, and the
/// removal of a paper's folder or one file. Nothing here runs on its own: the
/// user asks for each removal after a confirmation naming the other apps
/// still using it. Disk I/O on the calling thread: call it off the main
/// thread.
public enum LibraryClear {

    /// The library's papers, from one scan. Each problem the scan found is
    /// logged and listed.
    ///
    /// - Parameters:
    ///   - access: The held library.
    ///   - installationID: This installation's id
    ///     (``LibrarySession/installationID()``), to tell its uses apart.
    /// - Returns: The listing, or why the library could not be listed.
    public static func list(_ access: LibraryAccess, installationID: String)
        -> Result<LibraryListing, LibraryLookupFailure> {
        let scan: LibraryScan
        do {
            scan = try access.library.scan()
        } catch {
            return .failure(failure(BioMedLitConstants.libraryClearListFailed(reason: "\(error)"), error))
        }
        let problems = scan.problems().map { "\($0)" }
        for problem in problems {
            BioMedLitLib.logger?.warning("The library scan found: \(problem)", category: .library)
        }
        let papers = scan.folders().map { listed($0, in: access, installationID: installationID) }
        return .success(LibraryListing(papers: papers, problems: problems))
    }

    /// Delete the paper folder `folder`, records and all, or with `name`, only
    /// that file of it (every record is left listing it, so each app reports
    /// it missing). A fresh scan must still list the folder (and the file): a
    /// list shown earlier may be stale, so anything it no longer holds is
    /// refused, nothing removed. A folder name bmlib refuses is not touched;
    /// a folder whose deletion fails otherwise may be partly gone, and the
    /// failure says so.
    ///
    /// - Returns: The removed files the records name (digest and kind), so
    ///   the documents reading them can be told; or why nothing was removed.
    public static func remove(_ access: LibraryAccess, folder: String, name: String?)
        -> Result<[LibraryFileReference], LibraryLookupFailure> {
        let what = name.map { "\(folder)/\($0)" } ?? folder
        let found: PaperFolder
        do {
            guard let listed = try access.library.scan().folders().first(where: { $0.folder == folder }) else {
                return .failure(failure(BioMedLitConstants.libraryClearFailed(
                    what: what, reason: BioMedLitConstants.libraryClearStaleReason), nil))
            }
            found = listed
        } catch {
            return .failure(failure(BioMedLitConstants.libraryClearFailed(what: what, reason: "\(error)"), error))
        }
        guard let name else { return removeFolder(found, from: access) }
        guard found.filesOnDisk.contains(name) else {
            return .failure(failure(BioMedLitConstants.libraryClearFailed(
                what: what, reason: BioMedLitConstants.libraryClearStaleReason), nil))
        }
        let entry = entries(of: found).first { $0.name == name }
        do {
            // bmlib's `remove_file` locates by folder and name only, so a file
            // no record lists needs no digest
            try access.library.removeFile(file: FileRef(
                folder: folder, name: name, sha256: entry?.sha256 ?? "", kind: entry?.kind ?? .text))
        } catch {
            return .failure(failure(BioMedLitConstants.libraryClearFailed(what: what, reason: "\(error)"), error))
        }
        BioMedLitLib.logger?.info("\(what) was removed from the library", category: .library)
        return .success(entry.map { [LibrarySource.reference(FileRef(
            folder: folder, name: name, sha256: $0.sha256, kind: $0.kind))] } ?? [])
    }

    // MARK: The wording (StudyAnalyzer's `library.ts`)

    /// A size as the clear shows it ("1.2 MB"), or that it is unknown.
    public static func sizeText(_ bytes: UInt64?) -> String {
        guard let bytes else { return BioMedLitConstants.libraryClearSizeUnknown }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    /// A paper's size: the sum of its files', saying so when some could not
    /// be read.
    public static func sizeText(of paper: LibraryListedPaper) -> String {
        let known = paper.files.compactMap(\.size)
        guard !known.isEmpty else { return sizeText(nil) }
        let sum = sizeText(known.reduce(0) { $0 &+ $1 })
        return known.count < paper.files.count ? sum + BioMedLitConstants.libraryClearSomeSizesUnknown : sum
    }

    /// Who uses a file or paper, as its line in the list says it: "used by
    /// this app, StudyAnalyzer on …", or "used by no app".
    public static func usersText(usedBy: [String], usedHere: Bool) -> String {
        let who = (usedHere ? [BioMedLitConstants.libraryClearThisApp] : []) + usedBy
        return who.isEmpty
            ? BioMedLitConstants.libraryClearUsedByNoApp
            : BioMedLitConstants.libraryClearUsedByPrefix + who.joined(separator: ", ")
    }

    /// The confirmation before `what` (a paper's label or a file's name) is
    /// removed: it names the other apps still using it, and says what this
    /// app's documents keep when they use it too.
    public static func removeQuestion(what: String, usedBy: [String], usedHere: Bool) -> String {
        var parts = [BioMedLitConstants.libraryClearQuestion(what: what)]
        if !usedBy.isEmpty {
            parts.append(BioMedLitConstants.libraryClearStillUsed(by: usedBy))
        } else if !usedHere {
            parts.append(BioMedLitConstants.libraryClearUsedByNone)
        }
        if usedHere { parts.append(BioMedLitConstants.libraryClearUsedHere) }
        return parts.joined(separator: " ")
    }

    /// What the scan found odd, as one line under the list, or nil when
    /// nothing was.
    public static func problemsText(_ problems: [String]) -> String? {
        problems.isEmpty ? nil : BioMedLitConstants.libraryClearProblems(problems)
    }

    // MARK: Private

    /// The clear's view of one folder: its title and each file on disk with
    /// its size and users.
    private static func listed(_ folder: PaperFolder, in access: LibraryAccess,
                               installationID: String) -> LibraryListedPaper {
        let directory = URL(fileURLWithPath: access.library.root(), isDirectory: true)
            .appendingPathComponent(BioMedLitConstants.libraryPapersFolderName, isDirectory: true)
            .appendingPathComponent(folder.folder, isDirectory: true)
        let files = folder.filesOnDisk.map { name in
            var usedBy: [String] = []
            var usedHere = false
            for record in folder.records where record.files.contains(where: { $0.name == name }) {
                if record.installation.app == BioMedLitConstants.libraryAppName,
                   record.installation.id == installationID {
                    usedHere = true
                } else {
                    usedBy.append(record.installation.label)
                }
            }
            return LibraryListedFile(name: name, size: size(of: directory.appendingPathComponent(name)),
                                     usedBy: usedBy, usedHere: usedHere)
        }
        return LibraryListedPaper(folder: folder.folder, title: folder.records.lazy.compactMap(\.paper.title).first,
                                  files: files)
    }

    /// Delete `folder` whole, a fresh scan having just listed it.
    private static func removeFolder(_ folder: PaperFolder, from access: LibraryAccess)
        -> Result<[LibraryFileReference], LibraryLookupFailure> {
        let name = folder.folder
        // The files the records name that are on disk, each once: what goes
        var seen: Set<String> = []
        let removed = entries(of: folder)
            .filter { folder.filesOnDisk.contains($0.name) && seen.insert($0.name).inserted }
            .map { LibrarySource.reference(FileRef(folder: name, name: $0.name, sha256: $0.sha256, kind: $0.kind)) }
        do {
            try access.library.removeFolder(folder: name)
        } catch let error as LibraryError {
            // bmlib refuses such a name before it deletes anything (StudyAnalyzer #789)
            if case .BadName = error {
                return .failure(failure(BioMedLitConstants.libraryClearRenameText(folder: name), error))
            }
            return .failure(failure(BioMedLitConstants.libraryClearPartlyText(folder: name, reason: "\(error)"), error))
        } catch {
            return .failure(failure(BioMedLitConstants.libraryClearPartlyText(folder: name, reason: "\(error)"), error))
        }
        BioMedLitLib.logger?.info("The paper folder \(name) was removed from the library", category: .library)
        return .success(removed)
    }

    /// Every file entry of every record in `folder`.
    private static func entries(of folder: PaperFolder) -> [FileEntry] {
        folder.records.flatMap(\.files)
    }

    /// The size of the file at `url`, or nil (logged) when it cannot be read.
    private static func size(of url: URL) -> UInt64? {
        do {
            return (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value
        } catch {
            BioMedLitLib.logger?.warning("The size of \(url.path) cannot be read: \(error.localizedDescription)",
                                        category: .library)
            return nil
        }
    }

    /// `description` as a failure, logged at warning; it waits as bmlib's
    /// `error` would (``LibrarySource/waits(_:)``), or not for our own reason.
    private static func failure(_ description: String, _ error: Error?) -> LibraryLookupFailure {
        BioMedLitLib.logger?.warning(description, category: .library)
        return LibraryLookupFailure(description: description, waits: error.map(LibrarySource.waits) ?? false)
    }
}
#endif
