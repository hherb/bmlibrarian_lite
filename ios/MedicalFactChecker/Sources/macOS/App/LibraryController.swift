#if os(macOS)
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

import AppKit
import BioMedLit
import SwiftData
import SystemConfiguration

/// The app's one shared-paper-library session, with its launch and quit:
/// access to the library folder is started at launch and stopped at exit
/// (design §4.1). Its logic is `LibrarySession`'s (BioMedLit, tested there).
@MainActor
enum LibraryController {

    /// The session the Library setting shows and later steps read.
    static let session = LibrarySession(store: AppSettings.shared)

    private static var started = false

    /// The app's store, whose documents the move and the switch rewrite
    /// (design §4.7); nil when the store could not be opened.
    private static var container: ModelContainer?

    /// This Mac's name for the installation's label, read once.
    /// `SCDynamicStoreCopyComputerName` rather than `Host.current().localizedName`:
    /// `Host.current()` resolves the host's names and addresses, which can
    /// block on DNS (#792); the computer name is a local lookup. Primed off
    /// the main actor at launch; `nil` when the system gives none, and the
    /// label is then the app's name alone.
    nonisolated private static let machineName: String? = SCDynamicStoreCopyComputerName(nil, nil) as String?

    /// Resume the library, re-check it each time the app becomes active
    /// (design §4.6: a drive unplugged or plugged back in meanwhile), and
    /// arrange to stop access when the app quits. Each time a library is
    /// held, the sources waiting for it move in (design §4.6). Called once
    /// from the app's `init`, with its store (nil when it could not be
    /// opened); a second call does nothing.
    static func startAtLaunch(container: ModelContainer?) {
        guard !started else { return }
        started = true
        self.container = container
        BMLFullTextService.appLibrary = library
        session.onHeld = { access in
            let summary = await moveIn(into: access, onlyWaiting: true)
            if summary.moved > 0 || !summary.failed.isEmpty {
                AppLogger.fullText.info(
                    "Waiting sources settled: \(summary.moved) moved, \(summary.failed.count) not"
                )
            }
        }
        Task.detached(priority: .utility) { _ = machineName }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { session.stopAccess() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in await session.recheck() }
        }
        Task { await session.resumeAtLaunch() }
    }

    /// The library a full-text fetch goes through (design §4.5): a
    /// `LibrarySource` over the held access as this installation; while the
    /// library set cannot be reached, or the launch still reaches it, one
    /// that fails with why, so a source fetched meanwhile waits for it
    /// (§4.6); or `nil` when none is set, or when bmlib refuses the
    /// installation (logged at error with bmlib's reason). Without one the
    /// fetch runs as it does with no library set.
    static func library() -> (any FullTextLibrary)? {
        if let unreachable = session.unreachableLibrary { return unreachable }
        guard let access = session.access else { return nil }
        return source(for: access)
    }

    /// A `LibrarySource` over `access` as this installation, or nil when bmlib
    /// refuses the installation (logged at error with bmlib's reason).
    static func source(for access: LibraryAccess) -> LibrarySource? {
        do {
            return try LibrarySource(
                access: access,
                installationID: session.installationID(),
                label: LibraryInstallation.label(machineName: machineName)
            )
        } catch {
            AppLogger.fullText.error(
                "The paper library is not used for this fetch: \(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    /// Find `document`'s PDF again in the library when its stored path is
    /// gone (design §4.4: a stored library path is only a hint), and store
    /// the file found. Does nothing for a document with no library PDF, a
    /// file still where it was, or no library held. The disk work runs off
    /// the main actor.
    static func refindPDF(of document: Document) async {
        guard let file = document.libraryPDFReference, let path = document.localPDFFilePath else { return }
        // The common case, the file still there, builds no library
        let gone = await Task.detached(priority: .userInitiated) { !FileManager.default.fileExists(atPath: path) }.value
        // An unreachable library holds nothing to find: its banner says so
        guard gone, session.access != nil, let library = library() else { return }
        let found = await Task.detached(priority: .userInitiated) { library.path(of: file) }.value
        guard let refound = found else {
            AppLogger.fullText.warning(
                "The PDF at \(path, privacy: .public) is gone and the library holds no \(file.sha256, privacy: .public)"
            )
            return
        }
        // A fetch meanwhile stored another file: that one stands
        guard document.localPDFFilePath == path else { return }
        AppLogger.fullText.info(
            "The library PDF \(file.sha256, privacy: .public) moved from \(path, privacy: .public) to \(refound, privacy: .public)"
        )
        document.storeRefoundLibraryPDF(at: refound)
    }
}
// MARK: - The move and the switch (design §4.7)

extension LibraryController {

    /// Every document in the store; none without one (logged).
    private static func documents() -> [Document] {
        guard let container else { return [] }
        do {
            return try container.mainContext.fetch(FetchDescriptor<Document>())
        } catch {
            AppLogger.fullText.error("The documents could not be read for the library: \(error, privacy: .public)")
            return []
        }
    }

    /// Save the documents a move or a copy rewrote; a failure is logged and
    /// added to `summary`'s failures, so the setting shows it.
    private static func save(_ summary: inout LibraryMoveSummary) {
        do {
            try container?.mainContext.save()
        } catch {
            AppLogger.fullText.error("The documents' library files were not saved: \(error, privacy: .public)")
            summary.failed.append("The documents could not be saved: \(error.localizedDescription)")
        }
    }

    /// The PDF cache and the names in it, listed off the main actor; an
    /// unreadable cache lists nothing (logged).
    private static func cacheListing() async -> (URL, Set<String>) {
        await Task.detached(priority: .userInitiated) {
            let directory = BioMedLit.FullTextService.pdfCacheDirectory
            do {
                return (directory, Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)))
            } catch {
                AppLogger.fullText.error("The PDF cache could not be listed: \(error, privacy: .public)")
                return (directory, [])
            }
        }.value
    }

    /// How many of this app's files the move would bring into the library.
    static func pendingCount() async -> Int {
        let (directory, names) = await cacheListing()
        return LibraryMover.moveItems(documents(), cacheDirectory: directory, cacheNames: names,
                                      onlyWaiting: false).count
    }

    /// How many library files this app's documents use.
    static func usedCount() -> Int {
        LibraryMover.libraryFiles(documents()).count
    }

    /// Move this app's files into the library at `access`: every document's
    /// (the user's move), or only those waiting for it (the settle).
    @discardableResult
    static func moveIn(into access: LibraryAccess, onlyWaiting: Bool) async -> LibraryMoveSummary {
        let (directory, names) = await cacheListing()
        let groups = LibraryMover.moveItems(documents(), cacheDirectory: directory, cacheNames: names,
                                            onlyWaiting: onlyWaiting)
        guard !groups.isEmpty else { return LibraryMoveSummary(moved: 0, failed: []) }
        guard let library = source(for: access) else {
            return LibraryMoveSummary(moved: 0, failed: [BioMedLitConstants.libraryInstallationRefusedText])
        }
        let items = groups.map(\.item)
        let outcomes = await Task.detached(priority: .userInitiated) { LibraryMove.moveIn(items, into: library) }.value
        var summary = LibraryMover.apply(outcomes, to: groups.map(\.documents))
        save(&summary)
        return summary
    }

    /// A switch of folder: copy the library files this app uses from `old`
    /// into `new` when `copying`; a file not copied is noted on its documents
    /// as left in `old` (design §4.7). The old folder is not changed.
    static func carry(from old: LibraryAccess, to new: LibraryAccess, copying: Bool) async -> LibraryMoveSummary {
        let groups = LibraryMover.libraryFiles(documents())
        let note = BioMedLitConstants.libraryNotCarriedNote(folderName: old.folderName)
        var summary = LibraryMoveSummary(moved: 0, failed: [])
        if copying, !groups.isEmpty, let from = source(for: old), let to = source(for: new) {
            let files = groups.map { (file: $0.file, paper: $0.paper) }
            let outcomes = await Task.detached(priority: .userInitiated) {
                LibraryMove.copy(files, from: from, to: to)
            }.value
            summary = LibraryMover.apply(outcomes, to: groups.map(\.documents), notCarriedNote: note)
        } else {
            LibraryMover.notCarried(groups.flatMap(\.documents), note: note)
        }
        save(&summary)
        return summary
    }

    /// *Stop using*: copy the library files this app uses back into the PDF
    /// cache when `copying`; a file not copied is noted on its documents as
    /// in a library this app no longer uses (design §4.7).
    static func carryBack(from access: LibraryAccess, copying: Bool) async -> LibraryMoveSummary {
        let groups = LibraryMover.libraryFiles(documents())
        let note = BioMedLitConstants.libraryNoLongerUsedNote
        var summary = LibraryMoveSummary(moved: 0, failed: [])
        guard copying, let library = source(for: access) else {
            LibraryMover.notCarried(groups.flatMap(\.documents), note: note)
            save(&summary)
            return summary
        }
        let keyed = groups.filter { $0.key != nil }
        let files = keyed.compactMap { group in group.key.map { (file: group.file, key: $0) } }
        let results = await Task.detached(priority: .userInitiated) {
            LibraryMove.copyBack(files, from: library, into: BioMedLit.FullTextService.pdfCacheDirectory)
        }.value
        for (result, group) in zip(results, keyed) {
            switch result {
            case let .success(path):
                summary.moved += 1
                for document in group.documents { document.storeAppCopy(at: path, kind: group.file.kind) }
            case let .failure(failure):
                summary.failed.append("\(group.documents.first?.title ?? ""): \(failure.description)")
                LibraryMover.notCarried(group.documents, note: note)
            }
        }
        LibraryMover.notCarried(groups.filter { $0.key == nil }.flatMap(\.documents), note: note)
        save(&summary)
        return summary
    }
}
#endif
