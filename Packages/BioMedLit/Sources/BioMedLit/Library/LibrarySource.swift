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

/// The fetch's library: an open library folder (step 3a's ``LibraryAccess``)
/// used as this installation, by bmlib's rules through bmlib-ffi (its
/// full-text service's `read_library`, `usable_library_jats` and
/// `LibraryStore`). No selection rule is made here: which file may be served
/// is `newestSource`, which ids contradict is `paperIdsContradiction`, and
/// whether a use is already noted is `listsUse`.
public final class LibrarySource: FullTextLibrary {

    private let access: LibraryAccess
    private let who: Installation

    /// A source over `access`, saving as installation `installationID`
    /// (``LibrarySession/installationID()``) labelled `label`
    /// (``LibraryInstallation/label(machineName:)``).
    ///
    /// - Throws: ``LibraryLookupFailure`` with bmlib's text when bmlib refuses
    ///   the id or the label.
    public init(access: LibraryAccess, installationID: String, label: String) throws {
        do {
            who = try installationNew(app: BioMedLitConstants.libraryAppName, id: installationID, label: label)
        } catch {
            let failure = LibraryLookupFailure(
                description: BioMedLitConstants.libraryInstallationFailure(id: installationID, reason: "\(error)"),
                waits: Self.waits(error))
            Self.warn(failure.description)
            throw failure
        }
        self.access = access
    }

    // MARK: FullTextLibrary

    public func jats(for paper: LibraryPaper) -> LibraryJATSLookup {
        guard let ids = paper.libraryRequestIDs else { return .none }
        let held: (file: FileRef, bytes: Data)
        switch source(ids, kind: .jats) {
        case let .success(found?): held = found
        case .success(nil): return .none
        case let .failure(failure): return .failed(failure)
        }
        let at = "\(held.file.folder)/\(held.file.name)"
        let article: JatsArticle
        do {
            guard let xml = String(data: held.bytes, encoding: .utf8) else {
                return unusable(BioMedLitConstants.libraryJATSUnparseableNote(
                    file: at, reason: BioMedLitConstants.libraryJATSNotUTF8Reason))
            }
            article = try parseJats(xml: xml)
        } catch {
            return unusable(BioMedLitConstants.libraryJATSUnparseableNote(file: at, reason: Self.jatsReason(error)))
        }
        let own = libraryIds(pmid: article.pmid, doi: article.doi, pmcid: article.pmcId).ids
        do {
            if let clash = try paperIdsContradiction(theirs: own, ours: ids) {
                let message = BioMedLitConstants.libraryJATSWrongPaperNote(
                    file: at, field: clash.field, theirs: clash.theirs, ours: clash.ours)
                Self.warn(message)
                return .wrongPaper(message)
            }
        } catch {
            return .failed(fail(ids, held.file, error))
        }
        guard article.hasBody else {
            return unusable(BioMedLitConstants.libraryJATSBodylessNote(file: at))
        }
        return .usable(held.bytes, Self.reference(held.file))
    }

    public func pdf(for paper: LibraryPaper) -> Result<LibraryHeldPDF?, LibraryLookupFailure> {
        guard let ids = paper.libraryRequestIDs else { return .success(nil) }
        return source(ids, kind: .pdf).map { held in
            held.map { LibraryHeldPDF(path: path(held: $0.file), file: Self.reference($0.file)) }
        }
    }

    public func keep(_ bytes: Data, kind: String, paper: LibraryPaper, origin: String)
        -> Result<LibraryKept?, LibraryLookupFailure> {
        guard let ids = paper.libraryRequestIDs else { return .success(nil) }
        guard let sourceKind = Self.sourceKind(kind) else {
            return .failure(fail(ids, nil, BioMedLitConstants.libraryUnknownKindReason(kind)))
        }
        do {
            let file = try access.library.save(who: who, paper: info(paper, ids), bytes: bytes,
                                               kind: sourceKind, origin: origin)
            return .success(LibraryKept(file: Self.reference(file), path: path(held: file)))
        } catch {
            return .failure(fail(ids, nil, error))
        }
    }

    public func noteUse(_ file: LibraryFileReference, paper: LibraryPaper) -> LibraryLookupFailure? {
        guard let ids = paper.libraryRequestIDs else { return nil }
        guard let kind = Self.sourceKind(file.kind) else {
            return fail(ids, nil, BioMedLitConstants.libraryUnknownKindReason(file.kind))
        }
        let scan: LibraryScan
        let found: FileRef?
        do {
            scan = try access.library.scan()
            found = try scan.findDigest(sha256: file.sha256, kind: kind)
        } catch {
            return fail(ids, nil, error)
        }
        guard let ref = found else {
            return fail(ids, nil, BioMedLitConstants.libraryDigestNotHeldReason(kind: file.kind, sha256: file.sha256))
        }
        do {
            if try scan.listsUse(who: who, file: ref) { return nil }
            try access.library.recordUse(who: who, paper: info(paper, ids), file: ref)
            return nil
        } catch {
            return fail(ids, ref, error)
        }
    }

    public func path(of file: LibraryFileReference) -> String? {
        guard let kind = Self.sourceKind(file.kind) else {
            Self.warn(BioMedLitConstants.libraryFileFailure(
                kind: file.kind, sha256: file.sha256, reason: BioMedLitConstants.libraryUnknownKindReason(file.kind)))
            return nil
        }
        do {
            return try access.library.scan().findDigest(sha256: file.sha256, kind: kind).map(path(held:))
        } catch {
            Self.warn(BioMedLitConstants.libraryFileFailure(kind: file.kind, sha256: file.sha256, reason: "\(error)"))
            return nil
        }
    }

    public func read(_ file: LibraryFileReference) -> Result<Data, LibraryLookupFailure> {
        func failure(_ error: Any) -> LibraryLookupFailure {
            let failure = LibraryLookupFailure(
                description: BioMedLitConstants.libraryFileFailure(kind: file.kind, sha256: file.sha256,
                                                                   reason: "\(error)"),
                waits: Self.waits(error))
            Self.warn(failure.description)
            return failure
        }
        guard let kind = Self.sourceKind(file.kind) else {
            return .failure(failure(BioMedLitConstants.libraryUnknownKindReason(file.kind)))
        }
        do {
            guard let ref = try access.library.scan().findDigest(sha256: file.sha256, kind: kind) else {
                return .failure(failure(BioMedLitConstants.libraryDigestNotHeldReason(kind: file.kind,
                                                                                      sha256: file.sha256)))
            }
            return .success(try access.library.read(file: ref))
        } catch {
            return .failure(failure(error))
        }
    }

    // MARK: bmlib's rules

    /// The paper's newest source of `kind` that may be served, read and
    /// digest checked (bmlib's `find_source`): one scan. A file failing its
    /// digest is a failure, never passed over for an older one.
    private func source(_ ids: PaperIds, kind: SourceKind) -> Result<(file: FileRef, bytes: Data)?, LibraryLookupFailure> {
        let file: FileRef?
        do {
            file = try access.library.scan().newestSource(ids: ids, kind: kind)
        } catch {
            return .failure(fail(ids, nil, error))
        }
        guard let file else { return .success(nil) }
        do {
            return .success((file, try access.library.read(file: file)))
        } catch {
            return .failure(fail(ids, file, error))
        }
    }

    /// bmlib's `paper_info` without a JATS: the canonical ids and the
    /// paper's details.
    private func info(_ paper: LibraryPaper, _ ids: PaperIds) -> PaperInfo {
        PaperInfo(ids: ids, title: paper.title, year: paper.year.flatMap { Int32(exactly: $0) },
                  firstAuthor: paper.firstAuthor)
    }

    /// `<root>/papers/<folder>/<name>`, bmlib's layout.
    private func path(held file: FileRef) -> String {
        URL(fileURLWithPath: access.library.root(), isDirectory: true)
            .appendingPathComponent(BioMedLitConstants.libraryPapersFolderName, isDirectory: true)
            .appendingPathComponent(file.folder, isDirectory: true)
            .appendingPathComponent(file.name)
            .path
    }

    /// bmlib's `failure`: "library, paper <ids>[ file F/N]: <error>", logged.
    private func fail(_ ids: PaperIds, _ file: FileRef?, _ error: Any) -> LibraryLookupFailure {
        let failure = LibraryLookupFailure(
            description: BioMedLitConstants.libraryFailure(
                ids: LibraryPaper.describe(ids), file: file.map { "\($0.folder)/\($0.name)" }, reason: "\(error)"),
            waits: Self.waits(error))
        Self.warn(failure.description)
        return failure
    }

    /// Whether a failure for `error` leaves the source waiting for the
    /// library (design §4.6): yes when the library could not be reached,
    /// read or written, so it may come back (a folder gone or not a library
    /// now, a drive read-only, an iCloud file not downloaded, the file
    /// system's error); no when the library was reached and refused (a digest
    /// mismatch, another paper's JATS, a name clash, a refused identifier,
    /// name or installation, a newer record). Our own reason (a `String`: a
    /// kind or digest the library has not) is no reachability failure; any
    /// other error (a panic in bmlib) waits, so the source is kept, not lost.
    /// Exhaustive, so a case bmlib adds fails the build here.
    static func waits(_ error: Any) -> Bool {
        switch error {
        case let error as LibraryError:
            switch error {
            case .Unreachable, .NotALibrary, .NewerLibrary, .ReadOnly, .Missing, .NotDownloaded, .Io:
                return true
            case .BadIdentifier, .BadInstallation, .BadName, .DigestMismatch, .FileClash, .NewerRecord,
                 .ForeignJats:
                return false
            }
        case is String: return false
        default: return true
        }
    }

    /// bmlib-ffi's text for a failed parse, not Swift's debug form of the
    /// error.
    static func jatsReason(_ error: Error) -> String {
        switch error {
        case let JatsError.Xml(reason), let JatsError.Resource(reason): return reason
        case let JatsError.NestingTooDeep(depth, limit):
            return BioMedLitConstants.libraryJATSNestingReason(depth: depth, limit: limit)
        default: return "\(error)"
        }
    }

    private func unusable(_ note: String) -> LibraryJATSLookup {
        Self.warn(note)
        return .unusable(note: note)
    }

    // MARK: Kinds, the one mapping

    /// The name of `kind` in a ``LibraryFileReference``: bmlib's lower-case
    /// name. Exhaustive, so a kind bmlib adds fails the build here.
    static func name(of kind: SourceKind) -> String {
        switch kind {
        case .pdf: return BioMedLitConstants.libraryKindPDF
        case .jats: return BioMedLitConstants.libraryKindJATS
        case .html: return BioMedLitConstants.libraryKindHTML
        case .markdown: return BioMedLitConstants.libraryKindMarkdown
        case .text: return BioMedLitConstants.libraryKindText
        }
    }

    /// The kind named `name`, or nil for a name bmlib does not have.
    static func sourceKind(_ name: String) -> SourceKind? {
        let all: [SourceKind] = [.pdf, .jats, .html, .markdown, .text]
        return all.first { self.name(of: $0) == name }
    }

    /// `file` by digest and kind name.
    static func reference(_ file: FileRef) -> LibraryFileReference {
        LibraryFileReference(sha256: file.sha256, kind: name(of: file.kind))
    }

    private static func warn(_ message: String) {
        BioMedLitLib.logger?.warning(message, category: .library)
    }
}
#endif
