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

import CryptoKit
import Foundation

/// One file this app keeps that is to go into the library: the paper it is
/// of, where it is, and what it is.
public struct LibraryMoveItem: Sendable {
    /// The paper, as the library is told of it.
    public let paper: LibraryPaper
    /// Where the app keeps the file (the PDF cache).
    public let path: String
    /// bmlib's name of its kind (`BioMedLitConstants.libraryKindPDF`, `libraryKindJATS`).
    public let kind: String
    /// Who found it, as the library records it (a tier's display name).
    public let origin: String

    /// The file at `path`, a `kind` of `paper` found by `origin`.
    public init(paper: LibraryPaper, path: String, kind: String, origin: String) {
        self.paper = paper
        self.path = path
        self.kind = kind
        self.origin = origin
    }
}

/// What became of one file in a move or a copy.
public enum LibraryMoveOutcome: Sendable, Equatable {
    /// The library holds it, checked, at the path given.
    case moved(LibraryKept)
    /// It was not moved or copied; the sentence says why. The app's copy, if
    /// any, is where it was.
    case failed(String)
}

/// Moving this app's files into the shared paper library and copying the
/// library's files on a switch (design §4.7). Every copy is read back
/// through bmlib (digest checked) and compared; the app's copy goes only
/// through ``removeAppCopies(_:)``, once the caller has saved the documents
/// that now point at the library. Nothing is ever removed from a library. Disk I/O on the calling thread:
/// call it off the main thread.
public enum LibraryMove {

    /// Move `items` into `library`, in order: read the app's copy, keep it in
    /// the library, read it back and compare. The app's copy stays: remove it
    /// with ``removeAppCopies(_:)`` once the documents reading it are saved,
    /// so a crash or a failed save never leaves one pointing at a removed file.
    ///
    /// - Returns: One outcome per item, in the same order.
    public static func moveIn(_ items: [LibraryMoveItem], into library: any FullTextLibrary) -> [LibraryMoveOutcome] {
        items.map { item in
            let bytes: Data
            do {
                bytes = try Data(contentsOf: URL(fileURLWithPath: item.path))
            } catch {
                return failed(BioMedLitConstants.libraryMoveUnreadableReason(
                    path: item.path, reason: error.localizedDescription))
            }
            let outcome = keepChecked(bytes, kind: item.kind, paper: item.paper, origin: item.origin, in: library)
            if case let .moved(kept) = outcome {
                BioMedLitLib.logger?.info("Kept \(item.path) in the library at \(kept.path)", category: .library)
            }
            return outcome
        }
    }

    /// Remove the app's copies at `paths`, files the library now holds
    /// (checked by ``moveIn(_:into:)``) whose documents are saved. A failed
    /// remove is logged: the library's copy is the one read from now, so the
    /// leftover is only disk.
    public static func removeAppCopies(_ paths: [String]) {
        for path in paths {
            do {
                try FileManager.default.removeItem(atPath: path)
            } catch {
                BioMedLitLib.logger?.warning(
                    "Could not remove \(path), now in the library: \(error.localizedDescription)", category: .library)
            }
        }
    }

    /// Copy `files` from `old` into `new` on a switch of folder: read from
    /// `old` (digest checked), keep in `new`, read back and compare. Nothing
    /// is removed from either.
    ///
    /// - Returns: One outcome per file, in the same order.
    public static func copy(
        _ files: [(file: LibraryFileReference, paper: LibraryPaper)],
        from old: any FullTextLibrary, to new: any FullTextLibrary
    ) -> [LibraryMoveOutcome] {
        files.map { entry in
            switch old.read(entry.file) {
            case let .failure(failure): return failed(failure.description)
            case let .success(bytes):
                return keepChecked(bytes, kind: entry.file.kind, paper: entry.paper,
                                   origin: BioMedLitConstants.libraryAppName, in: new)
            }
        }
    }

    /// Copy `files` from `library` back into `directory` (the PDF cache) when
    /// the app stops using the library, each named ``appCopyName(key:sha256:kind:)``.
    /// The library is not changed.
    ///
    /// - Returns: The path written, or why not, per file in the same order.
    public static func copyBack(
        _ files: [(file: LibraryFileReference, key: ArticleCacheKey)],
        from library: any FullTextLibrary, into directory: URL
    ) -> [Result<String, LibraryLookupFailure>] {
        files.map { entry in
            library.read(entry.file).flatMap { bytes in
                let url = directory.appendingPathComponent(
                    appCopyName(key: entry.key, sha256: entry.file.sha256, kind: entry.file.kind))
                do {
                    try FullTextService.writeAtomically(bytes, to: url)
                    return .success(url.path)
                } catch {
                    let failure = LibraryLookupFailure(
                        description: BioMedLitConstants.libraryFileFailure(
                            kind: entry.file.kind, sha256: entry.file.sha256,
                            reason: "\(url.path) could not be written (\(error.localizedDescription))"),
                        waits: false)
                    BioMedLitLib.logger?.error(failure.description, category: .library)
                    return .failure(failure)
                }
            }
        }
    }

    /// The name this app keeps a library file under in the PDF cache:
    /// `<cacheKey>-<sha12>.xml` for a JATS (3b's waiting files) and
    /// `<cacheKey>-<sha12>.pdf` for anything else.
    ///
    /// - Parameters:
    ///   - key: Names the article.
    ///   - sha256: The file's digest, hex.
    ///   - kind: bmlib's name of its kind.
    public static func appCopyName(key: ArticleCacheKey, sha256: String, kind: String) -> String {
        let suffix = kind == BioMedLitConstants.libraryKindJATS
            ? BioMedLitConstants.libraryWaitingJATSSuffix : BioMedLitConstants.libraryAppCopyPDFSuffix
        return "\(key.filenameComponent)-\(sha256.prefix(BioMedLitConstants.libraryWaitingDigestHexChars))\(suffix)"
    }

    /// The SHA-256 of `bytes`, lower-case hex.
    static func sha256(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// Keep `bytes` in `library` and read them back: moved only when the
    /// library returns the same bytes.
    private static func keepChecked(
        _ bytes: Data, kind: String, paper: LibraryPaper, origin: String, in library: any FullTextLibrary
    ) -> LibraryMoveOutcome {
        let kept: LibraryKept
        switch library.keep(bytes, kind: kind, paper: paper, origin: origin) {
        case let .failure(failure): return failed(failure.description)
        case .success(nil): return failed(BioMedLitConstants.libraryMoveNoIdentifierReason)
        case let .success(found?): kept = found
        }
        switch library.read(kept.file) {
        case let .failure(failure): return failed(failure.description)
        case let .success(back) where back != bytes:
            return failed(BioMedLitConstants.libraryFileFailure(
                kind: kept.file.kind, sha256: kept.file.sha256,
                reason: BioMedLitConstants.libraryMoveReadBackMismatchReason))
        case .success: return .moved(kept)
        }
    }

    /// `reason` as a failed outcome, logged at warning.
    private static func failed(_ reason: String) -> LibraryMoveOutcome {
        BioMedLitLib.logger?.warning("Not moved into the library: \(reason)", category: .library)
        return .failed(reason)
    }
}
