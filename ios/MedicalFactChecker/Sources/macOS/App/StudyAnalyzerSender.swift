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
/// `MacStudyAnalyzer.handoffMaxAge` are deleted at launch and on each send.
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
    ///   notes when sources were passed over; one failure sentence when
    ///   nothing was sent.
    static func send(_ document: Document) async -> [String] {
        guard let app = appURL() else { return [MacStudyAnalyzer.notFound] }
        let online = await isOnline()
        let library = LibraryController.library()
        guard let choice = document.studyAnalyzerHandoff(
            online: online,
            readLibrary: { file in
                library?.read(file) ?? .failure(LibraryLookupFailure(description: MacStudyAnalyzer.noLibrary, waits: false))
            },
            readFile: { try Data(contentsOf: URL(fileURLWithPath: $0)) }
        ) else { return [MacStudyAnalyzer.nothingToSend] }

        removeOldHandoffs()
        let file: URL
        do {
            let folder = handoffFolder()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            file = folder.appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(BioMedLitConstants.handoffFileExtension)
            try choice.handoff.encoded().write(to: file, options: .atomic)
        } catch {
            return [String(format: MacStudyAnalyzer.notWritten, error.localizedDescription)]
        }
        do {
            _ = try await NSWorkspace.shared.open([file], withApplicationAt: app,
                                                  configuration: NSWorkspace.OpenConfiguration())
        } catch {
            try? FileManager.default.removeItem(at: file)
            return [String(format: MacStudyAnalyzer.notOpened, error.localizedDescription)]
        }
        return choice.notes
    }

    /// Deletes hand-off files older than `MacStudyAnalyzer.handoffMaxAge`, so
    /// a file sent moments ago stays for StudyAnalyzer to read.
    static func removeOldHandoffs() {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(
            at: handoffFolder(), includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return } // no folder yet: nothing to delete
        let cutoff = Date().addingTimeInterval(-MacStudyAnalyzer.handoffMaxAge)
        for file in files where file.pathExtension == BioMedLitConstants.handoffFileExtension {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff {
                do { try manager.removeItem(at: file) } catch {
                    AppLogger.data.warning("Could not delete an old hand-off file: \(error.localizedDescription)")
                }
            }
        }
    }

    /// The folder in the app's temporary directory the hand-off files go in.
    private static func handoffFolder() -> URL {
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
