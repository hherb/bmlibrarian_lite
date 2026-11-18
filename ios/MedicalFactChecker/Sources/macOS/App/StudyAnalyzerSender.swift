#if os(macOS)
// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2026 Dr Horst Herb
//
// Licensed under the GNU Affero General Public License, version 3 or later.

import AppKit
import BioMedLit
import Foundation
import Network
import os

/// Hands a paper to StudyAnalyzer (StudyAnalyzer's shared-library design
/// §5.4): writes a `.studyanalyzer` file in this app's temporary folder and
/// opens it with StudyAnalyzer, so Launch Services grants it that one file.
/// The file is transient: hand-off files older than
/// `MacStudyAnalyzer.handoffMaxAge` are deleted at launch and on each send
/// that writes a file.
@MainActor
enum StudyAnalyzerSender {
    /// StudyAnalyzer's app, or `nil` when Launch Services knows none.
    static func appURL() -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: BioMedLitConstants.studyAnalyzerBundleID)
    }

    /// Writes and opens the hand-off of `document`.
    ///
    /// - Parameter document: The paper to hand over.
    /// - Returns: The sentences to show: empty on a clean send; the choice's
    ///   notes when sources were passed over or the text is incomplete; when
    ///   nothing was sent, the notes on what was passed over, then why.
    static func send(_ document: Document) async -> [String] {
        guard let app = appURL() else { return failed([MacStudyAnalyzer.notFound]) }
        // The document's fields are copied here, on the main actor; the reads
        // (a PDF of any size, mapped before its 100 MiB cap is checked; a
        // library file perhaps on an external or synced folder), the encoding
        // and the write run off it.
        let paper = document.studyAnalyzerPaper
        let online = await isOnline()
        let library = LibraryController.library()
        let prepared = await Task.detached(priority: .userInitiated) {
            prepare(paper, online: online, library: library)
        }.value
        let file: URL, notes: [String]
        switch prepared {
        case .success(let written): (file, notes) = written
        case .failure(let failure): return failed(failure.sentences)
        }
        for note in notes {
            AppLogger.data.warning("Open in StudyAnalyzer: \(note, privacy: .public)")
        }
        do {
            _ = try await NSWorkspace.shared.open([file], withApplicationAt: app,
                                                  configuration: NSWorkspace.OpenConfiguration())
        } catch {
            do { try FileManager.default.removeItem(at: file) } catch {
                AppLogger.data.warning("Could not delete an unopened hand-off file: \(error.localizedDescription)")
            }
            return failed([String(format: MacStudyAnalyzer.notOpened, error.localizedDescription)])
        }
        return notes
    }

    /// A failure to send, as the sentences shown: what was passed over, then why.
    private struct SendFailure: Error {
        let sentences: [String]
    }

    /// Chooses, encodes and writes the hand-off of `paper`, off the main actor.
    ///
    /// - Parameters:
    ///   - paper: The document's fields.
    ///   - online: Whether the Mac was online at the click.
    ///   - library: The shared paper library, or `nil` when none is set or
    ///     it cannot be used (bmlib refuses this installation, access lapsed).
    /// - Returns: The written file and the choice's notes, or the failure.
    nonisolated private static func prepare(
        _ paper: StudyAnalyzerPaper, online: Bool, library: (any FullTextLibrary)?
    ) -> Result<(URL, [String]), SendFailure> {
        let choice = paper.handoff(
            online: online,
            readLibrary: { file in
                library?.read(file) ?? .failure(LibraryLookupFailure(description: MacStudyAnalyzer.noLibrary, waits: false))
            },
            readFile: { try Data(contentsOf: URL(fileURLWithPath: $0), options: .mappedIfSafe) }
        )
        guard let handoff = choice.handoff else {
            return .failure(SendFailure(sentences: choice.notes + [MacStudyAnalyzer.nothingToSend]))
        }

        removeOldHandoffs()
        do {
            let folder = handoffFolder()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(BioMedLitConstants.handoffFileExtension)
            try handoff.encoded().write(to: file, options: .atomic)
            return .success((file, choice.notes))
        } catch {
            return .failure(SendFailure(sentences: [String(format: MacStudyAnalyzer.notWritten, error.localizedDescription)]))
        }
    }

    /// `sentences`, logged, as the sentences to show.
    private static func failed(_ sentences: [String]) -> [String] {
        AppLogger.data.error("Open in StudyAnalyzer failed: \(sentences.joined(separator: " "), privacy: .public)")
        return sentences
    }

    /// Deletes hand-off files older than `MacStudyAnalyzer.handoffMaxAge`, so
    /// a file sent moments ago stays for StudyAnalyzer to read.
    nonisolated static func removeOldHandoffs() {
        let manager = FileManager.default
        let files: [URL]
        do {
            files = try manager.contentsOfDirectory(
                at: handoffFolder(), includingPropertiesForKeys: [.contentModificationDateKey])
        } catch CocoaError.fileReadNoSuchFile {
            return // no folder yet: nothing to delete
        } catch {
            AppLogger.data.warning("Could not list the hand-off files: \(error.localizedDescription)")
            return
        }
        let cutoff = Date().addingTimeInterval(-MacStudyAnalyzer.handoffMaxAge)
        for file in files where file.pathExtension == BioMedLitConstants.handoffFileExtension {
            do {
                let modified = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                if let modified, modified < cutoff { try manager.removeItem(at: file) }
            } catch {
                AppLogger.data.warning("Could not delete an old hand-off file: \(error.localizedDescription)")
            }
        }
    }

    /// The folder in the app's temporary directory the hand-off files go in.
    nonisolated private static func handoffFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(MacStudyAnalyzer.handoffFolderName)
    }

    /// Whether the network path is satisfied now; no answer within
    /// `MacStudyAnalyzer.networkCheckTimeout` counts as offline.
    private static func isOnline() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "StudyAnalyzerSender.network")
            let answered = OSAllocatedUnfairLock(initialState: false)
            @Sendable func answer(_ online: Bool) {
                let first = answered.withLock { was in defer { was = true }; return !was }
                guard first else { return }
                monitor.cancel()
                continuation.resume(returning: online)
            }
            monitor.pathUpdateHandler = { path in answer(path.status == .satisfied) }
            monitor.start(queue: queue)
            queue.asyncAfter(deadline: .now() + MacStudyAnalyzer.networkCheckTimeout) { answer(false) }
        }
    }
}
#endif // os(macOS)
